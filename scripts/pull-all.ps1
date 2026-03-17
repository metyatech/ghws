Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# pull-all.ps1
# Runs `git pull` on every standalone Git repository found anywhere under the
# workspace root, including the root itself.  Discovery is recursive; paths
# that reside inside a .git directory (e.g. .git/modules/...) are excluded so
# internal git storage is never mistaken for a repository.  Submodules (whose
# .git entry is a file, not a directory) are detected and skipped. Repositories
# without an upstream branch, or whose local changes block pull, are reported
# as skips rather than hard failures.
# ---------------------------------------------------------------------------

function Get-RelPath {
    param(
        [string]$WorkspaceRootPath,
        [string]$FullPath,
        [char]$Separator
    )

    $rootStr = $WorkspaceRootPath.TrimEnd($Separator)
    if ($FullPath -eq $rootStr) { return '.' }
    return $FullPath.Substring($rootStr.Length + 1)
}

function ConvertTo-DisplayLines {
    param([object[]]$CommandOutput)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $CommandOutput) {
        if ($null -eq $entry) {
            continue
        }

        $text = if ($entry -is [System.Management.Automation.ErrorRecord]) {
            $entry.Exception.Message
        } else {
            [string]$entry
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $lines.Add($text.TrimEnd())
    }

    return $lines
}

function Get-PullStatus {
    param(
        [int]$ExitCode,
        [string[]]$OutputLines
    )

    if ($ExitCode -eq 0) {
        return 'OK'
    }

    $joined = $OutputLines -join "`n"
    if ($joined -match 'Your local changes to the following files would be overwritten by merge:') {
        return 'SKIP (local changes)'
    }
    if ($joined -match 'There is no tracking information for the current branch\.') {
        return 'SKIP (no upstream)'
    }

    return "FAILED (exit $ExitCode)"
}

function Test-RepoHasUpstream {
    param([string]$RepoPath)

    $null = & git -C $RepoPath rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-WorkspaceCandidates {
    param(
        [System.IO.DirectoryInfo]$WorkspaceRoot,
        [char]$Separator
    )

    $discoveryErrors = $null
    $candidates = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    $candidates.Add($WorkspaceRoot)

    $descendants = Get-ChildItem `
        -Path $WorkspaceRoot.FullName `
        -Directory `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue `
        -ErrorVariable discoveryErrors |
        Where-Object { $_.FullName -notmatch ([regex]::Escape("${Separator}.git${Separator}")) }

    foreach ($directory in $descendants) {
        $candidates.Add($directory)
    }

    return [PSCustomObject]@{
        Candidates      = @($candidates)
        DiscoveryErrors = @($discoveryErrors)
    }
}

function Invoke-PullAll {
    $workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $sep           = [IO.Path]::DirectorySeparatorChar
    $results       = [System.Collections.Generic.List[PSCustomObject]]::new()
    $candidateInfo = Get-WorkspaceCandidates -WorkspaceRoot (Get-Item -Path $workspaceRoot.Path) -Separator $sep

    Write-Host "Workspace: $workspaceRoot" -ForegroundColor Cyan
    Write-Host ('-' * 60)

    foreach ($item in $candidateInfo.Candidates) {
        $gitEntry = Join-Path $item.FullName '.git'
        $relPath  = Get-RelPath -WorkspaceRootPath $workspaceRoot.Path -FullPath $item.FullName -Separator $sep

        # No .git entry -> not a Git repository; skip silently
        if (-not (Test-Path -Path $gitEntry)) {
            continue
        }

        # .git is a file (not a directory) -> submodule; skip with notice
        if ((Get-Item -Path $gitEntry -Force).PSIsContainer -eq $false) {
            Write-Host "  SKIP (submodule)  $relPath  [$($item.FullName)]" -ForegroundColor DarkGray
            $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = 'SKIP (submodule)' })
            continue
        }

        # A local branch with no upstream cannot be pulled deterministically.
        if (-not (Test-RepoHasUpstream -RepoPath $item.FullName)) {
            Write-Host ""
            Write-Host ">> $relPath  [$($item.FullName)]" -ForegroundColor Yellow
            Write-Host '   No upstream branch is configured for the current branch.' -ForegroundColor DarkGray
            Write-Host '   [SKIP (no upstream)]' -ForegroundColor DarkGray
            $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = 'SKIP (no upstream)' })
            continue
        }

        # .git is a directory -> standalone repository
        Write-Host ""
        Write-Host ">> $relPath  [$($item.FullName)]" -ForegroundColor Yellow

        $pullOutput   = & git -C $item.FullName pull 2>&1
        $displayLines = ConvertTo-DisplayLines -CommandOutput $pullOutput
        $exitCode     = $LASTEXITCODE
        $status       = Get-PullStatus -ExitCode $exitCode -OutputLines $displayLines

        foreach ($line in $displayLines) {
            Write-Host "   $line"
        }

        if ($status -eq 'OK') {
            $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = 'OK' })
            continue
        }

        $statusColor = if ($status -like 'SKIP*') { 'DarkGray' } else { 'Red' }
        Write-Host "   [$status]" -ForegroundColor $statusColor
        $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = $status })
    }

    $discoveryIssueCount = @(
        $candidateInfo.DiscoveryErrors |
            ForEach-Object { '{0}|{1}' -f $_.FullyQualifiedErrorId, $_.TargetObject } |
            Sort-Object -Unique
    ).Count

    Write-Host ""
    Write-Host ('-' * 60)
    Write-Host 'Summary:'
    foreach ($r in $results) {
        $color = switch -Wildcard ($r.Status) {
            'OK'            { 'Green'    }
            'SKIP*'         { 'DarkGray' }
            default         { 'Red'      }
        }
        Write-Host ("  {0,-50} {1}  [{2}]" -f $r.RelPath, $r.Status, $r.FullPath) -ForegroundColor $color
    }

    if ($discoveryIssueCount -gt 0) {
        Write-Host ""
        Write-Host "Repository discovery skipped $discoveryIssueCount unreadable or transient path(s)." -ForegroundColor DarkYellow
    }

    $failed = @($results | Where-Object { $_.Status -like 'FAILED*' })
    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Host "$($failed.Count) repository(ies) failed to pull." -ForegroundColor Red
        return 1
    }

    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-PullAll)
}
