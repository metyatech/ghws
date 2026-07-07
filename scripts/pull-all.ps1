Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# pull-all.ps1
# Runs `git pull` on every standalone Git repository found at the workspace
# root or in a direct child directory of the workspace root. Submodules (whose
# .git entry is a file, not a directory) are detected and skipped. Repositories
# without an upstream branch are reported as notes, while repositories whose
# local changes block pull remain failures.
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

function Invoke-WorkspaceGit {
    param([string[]]$Arguments)

    $saved = @{
        GIT_DIR       = $env:GIT_DIR
        GIT_WORK_TREE = $env:GIT_WORK_TREE
        GIT_INDEX_FILE = $env:GIT_INDEX_FILE
    }
    Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_WORK_TREE -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
    try {
        return & git @Arguments 2>&1
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item "Env:$name" $saved[$name]
            }
        }
    }
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
        return 'FAILED (local changes)'
    }
    if ($joined -match 'There is no tracking information for the current branch\.') {
        return 'NOTE (no upstream)'
    }

    return "FAILED (exit $ExitCode)"
}

function Check-RepoUpstream {
    param([string]$RepoPath)

    $raw = Invoke-WorkspaceGit -Arguments @('-C', $RepoPath, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    $exit = $LASTEXITCODE
    $lines = ConvertTo-DisplayLines -CommandOutput $raw
    return [PSCustomObject]@{ ExitCode = $exit; OutputLines = $lines; HasUpstream = ($exit -eq 0) }
}

function Classify-RevParseResult {
    param([int]$ExitCode, [string[]]$OutputLines)

    if ($ExitCode -eq 0) { return 'HAS_UPSTREAM' }

    $joined = $OutputLines -join "`n"
    if ($joined -match 'dubious ownership' -or $joined -match 'safe\.directory') {
        return 'FAILED (dubious ownership)'
    }

    return 'NOTE (no upstream)'
}

function Test-RepoHasUpstream {
    param([string]$RepoPath)

    $res = Check-RepoUpstream -RepoPath $RepoPath
    return $res.HasUpstream
}

function Get-WorkspaceCandidates {
    param(
        [System.IO.DirectoryInfo]$WorkspaceRoot,
        [char]$Separator
    )

    $discoveryErrors = $null
    $candidates = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    $candidates.Add($WorkspaceRoot)

    $children = Get-ChildItem `
        -Path $WorkspaceRoot.FullName `
        -Directory `
        -Force `
        -ErrorAction SilentlyContinue `
        -ErrorVariable discoveryErrors

    foreach ($directory in $children) {
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
        $upstreamInfo = Check-RepoUpstream -RepoPath $item.FullName
        if (-not $upstreamInfo.HasUpstream) {
            $classification = Classify-RevParseResult -ExitCode $upstreamInfo.ExitCode -OutputLines $upstreamInfo.OutputLines
            if ($classification -like 'FAILED*') {
                Write-Host ""
                Write-Host ">> $relPath  [$($item.FullName)]" -ForegroundColor Yellow
                foreach ($l in $upstreamInfo.OutputLines) { Write-Host "   $l" }
                Write-Host "   [$classification]" -ForegroundColor Red
                $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = $classification })
                continue
            }

            Write-Host ""
            Write-Host ">> $relPath  [$($item.FullName)]" -ForegroundColor Yellow
            Write-Host '   No upstream branch is configured for the current branch.' -ForegroundColor DarkYellow
            Write-Host '   [NOTE (no upstream)]' -ForegroundColor DarkYellow
            $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = 'NOTE (no upstream)' })
            continue
        }

        # .git is a directory -> standalone repository
        Write-Host ""
        Write-Host ">> $relPath  [$($item.FullName)]" -ForegroundColor Yellow

        $pullOutput   = Invoke-WorkspaceGit -Arguments @('-C', $item.FullName, 'pull')
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

        $statusColor = switch -Wildcard ($status) {
            'SKIP*' { 'DarkGray' }
            'NOTE*' { 'DarkYellow' }
            default { 'Red' }
        }
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
            'NOTE*'         { 'DarkYellow' }
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
