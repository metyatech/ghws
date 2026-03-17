Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# pull-all.ps1
# Runs `git pull` on every standalone Git repository that is a direct child
# of the workspace root.  Submodules (whose .git entry is a file, not a
# directory) are intentionally skipped.
# ---------------------------------------------------------------------------

$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

Write-Host "Workspace: $workspaceRoot" -ForegroundColor Cyan
Write-Host ('-' * 60)

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($item in Get-ChildItem -Path $workspaceRoot -Directory) {
    $gitEntry = Join-Path $item.FullName '.git'

    # .git does not exist at all -> not a Git repository
    if (-not (Test-Path -Path $gitEntry)) {
        continue
    }

    # .git is a file (not a directory) -> this is a submodule; skip
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
