param(
    [string]$WorkspaceRoot,
    [string[]]$RepoRoot = @(),
    [switch]$Json,
    [switch]$FailOnIssue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$resolvedWorkspaceRoot = if ($WorkspaceRoot) {
    Resolve-Path -LiteralPath $WorkspaceRoot
} else {
    $scriptRepoRoot
}
$profilePath = Join-Path $scriptRepoRoot 'config\repo-bootstrap-profiles.json'

function Get-RepoSlugFromRemoteUrl {
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $normalized = $RemoteUrl.Trim()
    if ($normalized -match 'github\.com[:/](?<owner>[^/]+)/(?<name>[^/.]+)(?:\.git)?$') {
        return "$($Matches.owner)/$($Matches.name)"
    }

    throw "Unable to derive GitHub repo slug from remote URL: $RemoteUrl"
}

function Resolve-VerifyCommand {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepoRoot,
        [Parameter(Mandatory = $true)][string]$RepoSlug
    )

    if (Test-Path -LiteralPath $profilePath) {
        $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $profileProperty = $profiles.PSObject.Properties | Where-Object { $_.Name -eq $RepoSlug } | Select-Object -First 1
        if ($profileProperty -and [string]$profileProperty.Value.verifyCommand) {
            return [string]$profileProperty.Value.verifyCommand
        }
    }

    if (Test-Path -LiteralPath (Join-Path $TargetRepoRoot 'scripts\verify.ps1')) {
        return 'pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1'
    }

    if (Test-Path -LiteralPath (Join-Path $TargetRepoRoot 'scripts\verify.sh')) {
        return 'bash scripts/verify.sh'
    }

    $packageJsonPath = Join-Path $TargetRepoRoot 'package.json'
    if (Test-Path -LiteralPath $packageJsonPath) {
        $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
        if ($packageJson.scripts -and ($packageJson.scripts.PSObject.Properties.Name -contains 'verify')) {
            $packageManager = [string]$packageJson.packageManager
            if ($packageManager -like 'bun@*') {
                return 'bun run verify'
            }

            return 'npm run verify'
        }
    }

    return $null
}

function Test-TasksTracked {
    param([Parameter(Mandatory = $true)][string]$TargetRepoRoot)

    & git -C $TargetRepoRoot ls-files --error-unmatch '.tasks.jsonl' *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-ThreadsGitignored {
    param([Parameter(Mandatory = $true)][string]$TargetRepoRoot)

    & git -C $TargetRepoRoot check-ignore '.threads.jsonl' *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-UserControlledRepo {
    param([Parameter(Mandatory = $true)][string]$TargetRepoRoot)

    $remoteUrl = git -C $TargetRepoRoot remote get-url origin
    $slug = Get-RepoSlugFromRemoteUrl -RemoteUrl $remoteUrl
    $json = gh repo view $slug --json nameWithOwner,owner,viewerPermission,isFork,parent
    $info = $json | ConvertFrom-Json

    return [PSCustomObject]@{
        Slug = $slug
        IsUserControlled = ([string]$info.owner.login -eq 'metyatech')
        Owner = [string]$info.owner.login
        IsFork = [bool]$info.isFork
    }
}

function Get-TargetRepos {
    if ($RepoRoot.Count -gt 0) {
        return @($RepoRoot | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
    }

    return @(Get-ChildItem -Path $resolvedWorkspaceRoot -Directory -Force |
        Where-Object { $_.Name -ne 'agent-rules-local' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Select-Object -ExpandProperty FullName)
}

$results = foreach ($targetRepoRoot in Get-TargetRepos) {
    $repoInfo = Test-UserControlledRepo -TargetRepoRoot $targetRepoRoot
    $verifyCommand = Resolve-VerifyCommand -TargetRepoRoot $targetRepoRoot -RepoSlug $repoInfo.Slug
    $issues = @()

    if (-not $repoInfo.IsUserControlled) {
        [PSCustomObject]@{
            repoRoot = $targetRepoRoot
            repoSlug = $repoInfo.Slug
            owner = $repoInfo.Owner
            inScope = $false
            issues = @('foreign-repository')
            verifyCommand = $verifyCommand
        }
        continue
    }

    if (-not (Test-Path -LiteralPath (Join-Path $targetRepoRoot 'agent-ruleset.json'))) {
        $issues += 'missing-agent-ruleset'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetRepoRoot 'AGENTS.md'))) {
        $issues += 'missing-agents'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetRepoRoot 'README.md'))) {
        $issues += 'missing-readme'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetRepoRoot 'LICENSE'))) {
        $issues += 'missing-license'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetRepoRoot '.gitignore'))) {
        $issues += 'missing-gitignore'
    }
    if (-not $verifyCommand) {
        $issues += 'missing-verify-command'
    }
    if (-not (Test-TasksTracked -TargetRepoRoot $targetRepoRoot)) {
        $issues += 'tasks-not-tracked'
    }
    if (-not (Test-ThreadsGitignored -TargetRepoRoot $targetRepoRoot)) {
        $issues += 'threads-not-gitignored'
    }

    [PSCustomObject]@{
        repoRoot = $targetRepoRoot
        repoSlug = $repoInfo.Slug
        owner = $repoInfo.Owner
        inScope = $true
        issues = $issues
        verifyCommand = $verifyCommand
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 6
} else {
    foreach ($result in $results) {
        $scopeLabel = if ($result.inScope) { 'IN-SCOPE' } else { 'SKIP' }
        $issueLabel = if ($result.issues.Count -eq 0) { 'OK' } else { $result.issues -join ', ' }
        Write-Output ("[{0}] {1} :: {2}" -f $scopeLabel, $result.repoSlug, $issueLabel)
    }
}

if ($FailOnIssue -and ($results | Where-Object { $_.inScope -and $_.issues.Count -gt 0 })) {
    exit 1
}
