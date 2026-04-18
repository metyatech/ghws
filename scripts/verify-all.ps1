param(
    [string]$WorkspaceRoot,
    [string[]]$RepoRoot = @(),
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$auditScriptPath = Join-Path $PSScriptRoot 'audit-all.ps1'
$resolvedWorkspaceRoot = if ($WorkspaceRoot) {
    Resolve-Path -LiteralPath $WorkspaceRoot
} else {
    $scriptRepoRoot
}

$auditArgs = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $auditScriptPath,
    '-WorkspaceRoot',
    $resolvedWorkspaceRoot.Path,
    '-Json'
)
foreach ($targetRepoRoot in $RepoRoot) {
    $auditArgs += @('-RepoRoot', $targetRepoRoot)
}

$auditResults = & pwsh @auditArgs | ConvertFrom-Json
$results = foreach ($auditResult in @($auditResults)) {
    if (-not $auditResult.inScope) {
        [PSCustomObject]@{
            repoSlug = $auditResult.repoSlug
            repoRoot = $auditResult.repoRoot
            status = 'skipped'
            detail = 'foreign-repository'
        }
        continue
    }

    if (-not $auditResult.verifyCommand) {
        [PSCustomObject]@{
            repoSlug = $auditResult.repoSlug
            repoRoot = $auditResult.repoRoot
            status = 'failed'
            detail = 'missing-verify-command'
        }
        continue
    }

    Push-Location $auditResult.repoRoot
    try {
        & pwsh -NoProfile -Command $auditResult.verifyCommand | Out-Host
        [PSCustomObject]@{
            repoSlug = $auditResult.repoSlug
            repoRoot = $auditResult.repoRoot
            status = if ($LASTEXITCODE -eq 0) { 'passed' } else { 'failed' }
            detail = $auditResult.verifyCommand
        }
    } finally {
        Pop-Location
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 6
} else {
    foreach ($result in $results) {
        Write-Output ("[{0}] {1} :: {2}" -f $result.status.ToUpperInvariant(), $result.repoSlug, $result.detail)
    }
}

if ($results | Where-Object { $_.status -eq 'failed' }) {
    exit 1
}
