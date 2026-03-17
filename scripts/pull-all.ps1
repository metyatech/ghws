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

# Candidates: workspace root itself, then every descendant directory that does
# not live inside a .git folder (which would be internal git storage).
$candidates  = @(Get-Item -Path $workspaceRoot)
$candidates += Get-ChildItem -Path $workspaceRoot -Directory -Recurse -Force |
    Where-Object { $_.FullName -notmatch ([regex]::Escape("${sep}.git${sep}")) }

foreach ($item in $candidates) {
    $gitEntry = Join-Path $item.FullName '.git'

    # No .git entry -> not a Git repository; skip silently
    if (-not (Test-Path -Path $gitEntry)) {
        continue
    }

    # .git is a file (not a directory) -> submodule; skip with notice
    if ((Get-Item -Path $gitEntry -Force).PSIsContainer -eq $false) {
        Write-Host "  SKIP (submodule) $($item.Name)" -ForegroundColor DarkGray
        $results.Add([PSCustomObject]@{ Repo = $item.Name; Status = 'SKIP (submodule)' })
        continue
    }

    # .git is a directory -> standalone repository
    Write-Host ""
    Write-Host ">> $($item.Name)" -ForegroundColor Yellow

    $pullOutput = & git -C $item.FullName pull 2>&1
    $exitCode   = $LASTEXITCODE

    foreach ($line in $pullOutput) {
        Write-Host "   $line"
    }

    if ($exitCode -eq 0) {
        $results.Add([PSCustomObject]@{ Repo = $item.Name; Status = 'OK' })
    } else {
        Write-Host "   [FAILED with exit code $exitCode]" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Repo = $item.Name; Status = "FAILED (exit $exitCode)" })
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
    Write-Host ("  {0,-35} {1}" -f $r.Repo, $r.Status) -ForegroundColor $color
}

$failed = @($results | Where-Object { $_.Status -like 'FAILED*' })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "$($failed.Count) repository(ies) failed to pull." -ForegroundColor Red
    exit 1
}
