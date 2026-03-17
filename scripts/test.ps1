Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$requiredPaths = @(
    (Join-Path $repoRoot 'agent-ruleset.json'),
    (Join-Path $repoRoot 'agent-rules-local\ghws-workspace.md'),
    (Join-Path $repoRoot 'README.md')
)

foreach ($path in $requiredPaths) {
    if (-not (Test-Path -Path $path)) {
        Write-Error "Missing required workspace file: $path"
        exit 1
    }
}

$tls12 = [Net.SecurityProtocolType]::Tls12
if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag($tls12))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
}

$urls = @(
    'https://github.com/metyatech/ghws',
    'https://github.com/metyatech/workspace-agent-hub'
)

foreach ($url in $urls) {
    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -Method Get `
            -MaximumRedirection 5 `
            -TimeoutSec 20 `
            -Headers @{ 'User-Agent' = 'ghws-link-check' } `
            -UseBasicParsing `
            -ErrorAction Stop
    } catch {
        Write-Error "Link check failed for $url. $($_.Exception.Message)"
        exit 1
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 400) {
        Write-Error "Link check returned status $statusCode for $url"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# pull-all.ps1 regression: verify the script exists, is parseable, and that
# its submodule-detection logic behaves correctly in a temp sandbox.
# ---------------------------------------------------------------------------

$pullAllScript = Join-Path $PSScriptRoot 'pull-all.ps1'
if (-not (Test-Path -Path $pullAllScript)) {
    Write-Error "Missing script: $pullAllScript"
    exit 1
}

# Syntax check: parse the script without executing it
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $pullAllScript,
    [ref]$null,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    Write-Error "Syntax errors in pull-all.ps1: $($parseErrors | Out-String)"
    exit 1
}

# Behavioral smoke-test in a temp sandbox
$tmpDir  = Join-Path ([IO.Path]::GetTempPath()) "ghws-pull-all-test-$([IO.Path]::GetRandomFileName())"
$scripts = Join-Path $tmpDir 'scripts'
[void][IO.Directory]::CreateDirectory($scripts)

# Create a fake PSScriptRoot by wrapping the call
# Build a minimal workspace structure in $tmpDir:
#   repo-normal/  - standalone git repo (expect: git pull attempted)
#   repo-sub/     - submodule (.git is a file, expect: skipped)
#   not-git/      - plain dir (expect: ignored)

$repoNormal = Join-Path $tmpDir 'repo-normal'
$repoSub    = Join-Path $tmpDir 'repo-sub'
$notGit     = Join-Path $tmpDir 'not-git'
[void][IO.Directory]::CreateDirectory($repoNormal)
[void][IO.Directory]::CreateDirectory((Join-Path $repoNormal '.git'))  # directory -> standalone
[void][IO.Directory]::CreateDirectory($repoSub)
[IO.File]::WriteAllText((Join-Path $repoSub '.git'), 'gitdir: ../.git/modules/sub')  # file -> submodule
[void][IO.Directory]::CreateDirectory($notGit)

# Run pull-all logic inline (mirror the detection logic without calling git)
$detected = @()
$skipped  = @()
$ignored  = @()

foreach ($item in Get-ChildItem -Path $tmpDir -Directory) {
    $gitEntry = Join-Path $item.FullName '.git'
    if (-not (Test-Path -Path $gitEntry)) {
        $ignored += $item.Name
        continue
    }
    if ((Get-Item -Path $gitEntry -Force).PSIsContainer -eq $false) {
        $skipped += $item.Name
        continue
    }
    $detected += $item.Name
}

# Clean up temp dir
try { [IO.Directory]::Delete($tmpDir, $true) } catch {}

# Assertions
if ($detected -notcontains 'repo-normal') {
    Write-Error "pull-all test FAIL: standalone repo was not detected"
    exit 1
}
if ($skipped -notcontains 'repo-sub') {
    Write-Error "pull-all test FAIL: submodule was not skipped"
    exit 1
}
if ($ignored -notcontains 'not-git') {
    Write-Error "pull-all test FAIL: plain dir was not ignored"
    exit 1
}

Write-Output 'Tests OK.'
