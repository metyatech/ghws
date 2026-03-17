Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# pull-all.ps1
# Runs `git pull` on every standalone Git repository found anywhere under the
# workspace root, including the root itself.  Discovery is recursive; paths
# that reside inside a .git directory (e.g. .git/modules/...) are excluded so
# internal git storage is never mistaken for a repository.  Submodules (whose
# .git entry is a file, not a directory) are detected and skipped.
# ---------------------------------------------------------------------------

$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$sep           = [IO.Path]::DirectorySeparatorChar

Write-Host "Workspace: $workspaceRoot" -ForegroundColor Cyan
Write-Host ('-' * 60)

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# Returns the path of $fullPath relative to $workspaceRoot.
# The workspace root itself is represented as "." for clarity.
function Get-RelPath([string]$fullPath) {
    $rootStr = $workspaceRoot.Path.TrimEnd($sep)
    if ($fullPath -eq $rootStr) { return '.' }
    return $fullPath.Substring($rootStr.Length + 1)
}

# Candidates: workspace root itself, then every descendant directory that does
# not live inside a .git folder (which would be internal git storage).
$candidates  = @(Get-Item -Path $workspaceRoot)
$candidates += Get-ChildItem -Path $workspaceRoot -Directory -Recurse -Force |
    Where-Object { $_.FullName -notmatch ([regex]::Escape("${sep}.git${sep}")) }

foreach ($item in $candidates) {
    $gitEntry = Join-Path $item.FullName '.git'
    $relPath  = Get-RelPath $item.FullName

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

    # .git is a directory -> standalone repository
    Write-Host ""
    Write-Host ">> $relPath  [$($item.FullName)]" -ForegroundColor Yellow

    $pullOutput = & git -C $item.FullName pull 2>&1
    $exitCode   = $LASTEXITCODE

    foreach ($line in $pullOutput) {
        Write-Host "   $line"
    }

    if ($exitCode -eq 0) {
        $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = 'OK' })
    } else {
        Write-Host "   [FAILED with exit code $exitCode]" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ RelPath = $relPath; FullPath = $item.FullName; Status = "FAILED (exit $exitCode)" })
    }
}

Write-Host ""
Write-Host ('-' * 60)
Write-Host "Summary:"
foreach ($r in $results) {
    $color = switch -Wildcard ($r.Status) {
        'OK'            { 'Green'    }
        'SKIP*'         { 'DarkGray' }
        default         { 'Red'      }
    }
    Write-Host ("  {0,-50} {1}  [{2}]" -f $r.RelPath, $r.Status, $r.FullPath) -ForegroundColor $color
}

$failed = @($results | Where-Object { $_.Status -like 'FAILED*' })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "$($failed.Count) repository(ies) failed to pull." -ForegroundColor Red
    exit 1
}
