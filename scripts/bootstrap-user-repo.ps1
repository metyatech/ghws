param(
    [string]$Repository,
    [string]$RepoRoot,
    [string]$VerifyCommand,
    [string]$WorkspaceRoot,
    [switch]$CreateIfMissing,
    [switch]$Private,
    [switch]$Force
)

Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

$scriptRepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$workspaceRoot = if ($WorkspaceRoot) {
    Resolve-Path -LiteralPath $WorkspaceRoot
} else {
    $scriptRepoRoot
}
$templateRoot = Join-Path $scriptRepoRoot 'scripts\bootstrap-assets\high-quality-flow'
$profilePath = Join-Path $scriptRepoRoot 'scripts\bootstrap-assets\repo-bootstrap-profiles.json'

function Get-RepoSlugFromRemoteUrl {
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $normalized = $RemoteUrl.Trim()
    if ($normalized -match 'github\.com[:/](?<owner>[^/]+)/(?<name>[^/.]+)(?:\.git)?$') {
        return "$($Matches.owner)/$($Matches.name)"
    }

    throw "Unable to derive GitHub repo slug from remote URL: $RemoteUrl"
}

function Get-UserControlledRepoInfo {
    param([Parameter(Mandatory = $true)][string]$Slug)

    $json = gh repo view $Slug --json nameWithOwner,owner,viewerPermission,isFork,parent
    $info = $json | ConvertFrom-Json
    $isUserOwned = [string]$info.owner.login -eq 'metyatech'
    if (-not $isUserOwned) {
        throw "Repository '$Slug' is not user-controlled and cannot be bootstrapped into ghws."
    }

    return $info
}

function Try-GetUserControlledRepoInfo {
    param([Parameter(Mandatory = $true)][string]$Slug)

    try {
        return Get-UserControlledRepoInfo -Slug $Slug
    } catch {
        return $null
    }
}

function Ensure-NewRepositoryScaffold {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Slug
    )

    $leafName = Split-Path -Leaf $TargetPath
    Ensure-Directory -Path $TargetPath

    if (-not (Test-Path -LiteralPath (Join-Path $TargetPath '.git'))) {
        git -C $TargetPath init -b main | Out-Host
    }

    $readmePath = Join-Path $TargetPath 'README.md'
    if (-not (Test-Path -LiteralPath $readmePath)) {
        [System.IO.File]::WriteAllText($readmePath, "# $leafName`n", [System.Text.UTF8Encoding]::new($false))
    }

    $licensePath = Join-Path $TargetPath 'LICENSE'
    if (-not (Test-Path -LiteralPath $licensePath)) {
        $licenseContent = @(
            'MIT License',
            '',
            "Copyright (c) $(Get-Date -Format yyyy) metyatech"
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText($licensePath, $licenseContent + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }

    $gitignorePath = Join-Path $TargetPath '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignorePath)) {
        [System.IO.File]::WriteAllText($gitignorePath, ".threads.jsonl`n", [System.Text.UTF8Encoding]::new($false))
    }

    $tasksPath = Join-Path $TargetPath '.tasks.jsonl'
    if (-not (Test-Path -LiteralPath $tasksPath)) {
        [System.IO.File]::WriteAllText($tasksPath, '', [System.Text.UTF8Encoding]::new($false))
    }

    $remoteName = if ($Private) { '--private' } else { '--public' }
    gh repo create $Slug $remoteName --source $TargetPath --remote origin | Out-Host
}

function Resolve-TargetRepoRoot {
    if ($RepoRoot) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }

    if (-not $Repository) {
        throw 'Specify either -RepoRoot or -Repository.'
    }

    $repoInfo = Try-GetUserControlledRepoInfo -Slug $Repository
    $leafName = if ($repoInfo) {
        ([string]$repoInfo.nameWithOwner).Split('/')[1]
    } else {
        $Repository.Split('/')[1]
    }
    $targetPath = Join-Path $workspaceRoot $leafName
    if (Test-Path -LiteralPath $targetPath) {
        return (Resolve-Path -LiteralPath $targetPath).Path
    }

    if (-not $repoInfo) {
        if (-not $CreateIfMissing) {
            throw "Repository '$Repository' does not exist. Re-run with -CreateIfMissing to scaffold and create it."
        }
        Ensure-NewRepositoryScaffold -TargetPath $targetPath -Slug $Repository
        return (Resolve-Path -LiteralPath $targetPath).Path
    }

    gh repo clone $Repository $targetPath -- --recursive | Out-Host
    return (Resolve-Path -LiteralPath $targetPath).Path
}

function Ensure-UserControlledRepo {
    param([Parameter(Mandatory = $true)][string]$TargetRepoRoot)

    $remoteUrl = git -C $TargetRepoRoot remote get-url origin
    $slug = Get-RepoSlugFromRemoteUrl -RemoteUrl $remoteUrl
    [void](Get-UserControlledRepoInfo -Slug $slug)
    return $slug
}

function Get-PackageManagerCommand {
    param([Parameter(Mandatory = $true)][string]$TargetRepoRoot)

    $packageJsonPath = Join-Path $TargetRepoRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonPath)) {
        return $null
    }

    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    $scripts = $packageJson.scripts
    if ($null -eq $scripts -or -not ($scripts.PSObject.Properties.Name -contains 'verify')) {
        return $null
    }

    $packageManager = [string]$packageJson.packageManager
    if ($packageManager -like 'bun@*') {
        return 'bun run verify'
    }

    return 'npm run verify'
}

function Resolve-VerifyCommand {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepoRoot,
        [Parameter(Mandatory = $true)][string]$RepoSlug
    )

    if ($VerifyCommand) {
        return $VerifyCommand
    }

    if (Test-Path -LiteralPath $profilePath) {
        $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $profileProperty = $profiles.PSObject.Properties | Where-Object { $_.Name -eq $RepoSlug } | Select-Object -First 1
        if ($profileProperty -and [string]$profileProperty.Value.verifyCommand) {
            return [string]$profileProperty.Value.verifyCommand
        }
    }

    $powershellVerify = Join-Path $TargetRepoRoot 'scripts\verify.ps1'
    if (Test-Path -LiteralPath $powershellVerify) {
        return 'pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1'
    }

    $shellVerify = Join-Path $TargetRepoRoot 'scripts\verify.sh'
    if (Test-Path -LiteralPath $shellVerify) {
        return 'bash scripts/verify.sh'
    }

    $packageManagerCommand = Get-PackageManagerCommand -TargetRepoRoot $TargetRepoRoot
    if ($packageManagerCommand) {
        return $packageManagerCommand
    }

    throw "No canonical verification command found in '$TargetRepoRoot'. Add scripts/verify.ps1, scripts/verify.sh, or a package.json verify script first."
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
}

function Write-TemplateFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$VerifyCommand
    )

    $content = (Get-Content -LiteralPath $SourcePath -Raw).Replace('{{VERIFY_COMMAND}}', $VerifyCommand)
    $destinationDirectory = Split-Path -Parent $DestinationPath
    Ensure-Directory -Path $destinationDirectory

    if ((Test-Path -LiteralPath $DestinationPath) -and -not $Force) {
        return
    }

    [System.IO.File]::WriteAllText($DestinationPath, $content, [System.Text.UTF8Encoding]::new($false))
}

function Ensure-AgentRuleset {
    param([Parameter(Mandatory = $true)][string]$TargetRepoRoot)

    $rulesetPath = Join-Path $TargetRepoRoot 'agent-ruleset.json'
    if (-not (Test-Path -LiteralPath $rulesetPath)) {
        $extra = @('agent-rules-local/high-quality-workflow.md')
        $existingAgentsPath = Join-Path $TargetRepoRoot 'AGENTS.md'
        if (Test-Path -LiteralPath $existingAgentsPath) {
            $existingRulePath = Join-Path $TargetRepoRoot 'agent-rules-local\repo-existing-instructions.md'
            Ensure-Directory -Path (Split-Path -Parent $existingRulePath)
            $existingAgentsContent = Get-Content -LiteralPath $existingAgentsPath -Raw
            [System.IO.File]::WriteAllText($existingRulePath, $existingAgentsContent, [System.Text.UTF8Encoding]::new($false))
            $extra = @('agent-rules-local/repo-existing-instructions.md', 'agent-rules-local/high-quality-workflow.md')
        }

        $ruleset = [ordered]@{
            source = 'github:metyatech/agent-rules'
            output = 'AGENTS.md'
            extra = $extra
        }
        $json = $ruleset | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($rulesetPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        return
    }

    $rawRuleset = Get-Content -LiteralPath $rulesetPath -Raw
    $withoutBlockComments = [regex]::Replace($rawRuleset, '/\*.*?\*/', '', 'Singleline')
    $withoutLineComments = [regex]::Replace($withoutBlockComments, '(?m)^\s*//.*$', '')
    $ruleset = $withoutLineComments | ConvertFrom-Json
    if ($null -eq $ruleset.extra) {
        $ruleset | Add-Member -NotePropertyName extra -NotePropertyValue @()
    }
    $extra = @($ruleset.extra)
    if ($extra -notcontains 'agent-rules-local/high-quality-workflow.md') {
        $extra += 'agent-rules-local/high-quality-workflow.md'
        $ruleset.extra = $extra
    }

    $json = $ruleset | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($rulesetPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

$targetRepoRoot = Resolve-TargetRepoRoot
$targetRepoRoot = (Resolve-Path -LiteralPath $targetRepoRoot).Path
$repoSlug = Ensure-UserControlledRepo -TargetRepoRoot $targetRepoRoot
$verifyCommand = Resolve-VerifyCommand -TargetRepoRoot $targetRepoRoot -RepoSlug $repoSlug

Ensure-AgentRuleset -TargetRepoRoot $targetRepoRoot

$ruleSourcePath = Join-Path $templateRoot 'agent-rules-local\high-quality-workflow.md'
$ruleDestinationPath = Join-Path $targetRepoRoot 'agent-rules-local\high-quality-workflow.md'
Write-TemplateFile -SourcePath $ruleSourcePath -DestinationPath $ruleDestinationPath -VerifyCommand $verifyCommand

foreach ($commandName in @('start-task','verify','fix-bug','deliver')) {
    $sourcePath = Join-Path $templateRoot ".opencode\commands\$commandName.md"
    $destinationPath = Join-Path $targetRepoRoot ".opencode\commands\$commandName.md"
    Write-TemplateFile -SourcePath $sourcePath -DestinationPath $destinationPath -VerifyCommand $verifyCommand
}

$hookSetupScript = Join-Path $targetRepoRoot 'scripts\setup-hooks.ps1'
if (Test-Path -LiteralPath $hookSetupScript) {
    pwsh -NoProfile -ExecutionPolicy Bypass -File $hookSetupScript | Out-Host
}

compose-agentsmd --root $targetRepoRoot | Out-Host

Write-Output "Bootstrapped high-quality workflow for $repoSlug at $targetRepoRoot"
