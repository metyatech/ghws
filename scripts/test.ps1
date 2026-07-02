Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$requiredPaths = @(
    (Join-Path $repoRoot 'agent-ruleset.json'),
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

$pullAllContent = [IO.File]::ReadAllText($pullAllScript)

. $pullAllScript

# ---------------------------------------------------------------------------
# pull-all.ps1 regression: classify expected non-pullable states and normalize
# stderr lines so git messages stay readable.
# ---------------------------------------------------------------------------

$localChangesStatus = Get-PullStatus -ExitCode 1 -OutputLines @(
    'error: Your local changes to the following files would be overwritten by merge:',
    'AGENTS.md',
    'Please commit your changes or stash them before you merge.'
)
if ($localChangesStatus -ne 'FAILED (local changes)') {
    Write-Error "pull-all test FAIL: local-change pull block should remain FAILED, got '$localChangesStatus'"
    exit 1
}

$noUpstreamStatus = Get-PullStatus -ExitCode 1 -OutputLines @(
    'There is no tracking information for the current branch.'
)
if ($noUpstreamStatus -ne 'NOTE (no upstream)') {
    Write-Error "pull-all test FAIL: missing-upstream pull block should classify as NOTE, got '$noUpstreamStatus'"
    exit 1
}

$unknownFailureStatus = Get-PullStatus -ExitCode 7 -OutputLines @('fatal: unexpected failure')
if ($unknownFailureStatus -ne 'FAILED (exit 7)') {
    Write-Error "pull-all test FAIL: unexpected failures must remain FAILED, got '$unknownFailureStatus'"
    exit 1
}

$stderrMessage = 'There is no tracking information for the current branch.'
$stderrRecord  = [System.Management.Automation.ErrorRecord]::new(
    [System.Management.Automation.RemoteException]::new($stderrMessage),
    'git-stderr',
    [System.Management.Automation.ErrorCategory]::NotSpecified,
    $null
)
$displayLines = ConvertTo-DisplayLines -CommandOutput @($stderrRecord, 'stdout line')
if ($displayLines.Count -ne 2 -or $displayLines[0] -ne $stderrMessage -or $displayLines[1] -ne 'stdout line') {
    Write-Error "pull-all test FAIL: stderr normalization did not preserve readable git output"
    exit 1
}

$tmpDirUpstream = Join-Path ([IO.Path]::GetTempPath()) "ghws-pull-all-upstream-$([IO.Path]::GetRandomFileName())"
[void][IO.Directory]::CreateDirectory($tmpDirUpstream)
$null = & git -C $tmpDirUpstream init
if ($LASTEXITCODE -ne 0) {
    Write-Error "pull-all test FAIL: could not initialize temp repo for upstream detection"
    exit 1
}
if (Test-RepoHasUpstream -RepoPath $tmpDirUpstream) {
    Write-Error 'pull-all test FAIL: fresh repo without tracking branch was incorrectly treated as pullable'
    exit 1
}
try { [IO.Directory]::Delete($tmpDirUpstream, $true) } catch {}

# Dubious ownership classification test (should be treated as a failure, not NOTE)
$dubiousLines = @(
    'fatal: detected dubious ownership in repository at /some/path',
    'To add an exception, run: git config --global --add safe.directory /some/path'
)
$dubiousStatus = Classify-RevParseResult -ExitCode 128 -OutputLines $dubiousLines
if ($dubiousStatus -eq 'NOTE (no upstream)') {
    Write-Error "pull-all test FAIL: dubious ownership must not be classified as NOTE (no upstream), got '$dubiousStatus'"
    exit 1
}
if ($dubiousStatus -notmatch 'FAILED') {
    Write-Error "pull-all test FAIL: dubious ownership must be classified as FAILED, got '$dubiousStatus'"
    exit 1
}

# Behavioral smoke-test in a temp sandbox
$tmpDir  = Join-Path ([IO.Path]::GetTempPath()) "ghws-pull-all-test-$([IO.Path]::GetRandomFileName())"
$scripts = Join-Path $tmpDir 'scripts'
[void][IO.Directory]::CreateDirectory($scripts)

# Workspace structure under $tmpDir (acts as the workspace root):
#   .git/                          - root is a standalone git repo (expect: detected)
#   repo-normal/                   - standalone git repo (expect: detected)
#   repo-sub/                      - submodule (.git is file, expect: skipped)
#   not-git/                       - plain dir (expect: ignored)
#   repo-normal/.git/modules/inner - internal .git storage path (expect: NOT detected)

[void][IO.Directory]::CreateDirectory((Join-Path $tmpDir '.git'))  # root is a standalone repo

$repoNormal = Join-Path $tmpDir 'repo-normal'
$repoSub    = Join-Path $tmpDir 'repo-sub'
$notGit     = Join-Path $tmpDir 'not-git'
[void][IO.Directory]::CreateDirectory($repoNormal)
[void][IO.Directory]::CreateDirectory((Join-Path $repoNormal '.git'))  # directory -> standalone
[void][IO.Directory]::CreateDirectory($repoSub)
[IO.File]::WriteAllText((Join-Path $repoSub '.git'), 'gitdir: ../.git/modules/sub')  # file -> submodule
[void][IO.Directory]::CreateDirectory($notGit)

# Fake internal .git storage path — naive recursion would wrongly detect this as a repo root
$innerPath = Join-Path $repoNormal '.git\modules\inner'
[void][IO.Directory]::CreateDirectory((Join-Path $innerPath '.git'))

# Mirror the pull-all discovery logic: root + recursive, excluding .git internal paths
$sep      = [IO.Path]::DirectorySeparatorChar
$detected = @()
$skipped  = @()
$ignored  = @()

$rootName    = Split-Path $tmpDir -Leaf
$candidateInfo = Get-WorkspaceCandidates -WorkspaceRoot (Get-Item -Path $tmpDir) -Separator $sep
$candidates    = @($candidateInfo.Candidates)

foreach ($item in $candidates) {
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
if ($detected -notcontains $rootName) {
    Write-Error "pull-all test FAIL: workspace root repo was not detected"
    exit 1
}
if ($detected -notcontains 'repo-normal') {
    Write-Error "pull-all test FAIL: standalone child repo was not detected"
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
if ($detected -contains 'inner') {
    Write-Error "pull-all test FAIL: internal .git/modules path was incorrectly detected as a repo"
    exit 1
}

# ---------------------------------------------------------------------------
# pull-all.ps1 regression: relative-path labeling for unambiguous identity
# Covers: duplicate leaf names in different parent directories, and
# submodule hierarchy context (parent path visible in skipped label).
# ---------------------------------------------------------------------------

$tmpDir2 = Join-Path ([IO.Path]::GetTempPath()) "ghws-pull-all-test2-$([IO.Path]::GetRandomFileName())"
[void][IO.Directory]::CreateDirectory($tmpDir2)

# Workspace structure:
#   .git/              - root is a standalone repo
#   parent-a/repo/     - standalone repo (leaf name "repo")
#   parent-b/repo/     - standalone repo (same leaf name "repo" — must be distinguishable)
#   parent-a/sub/      - submodule under parent-a (hierarchy context must be visible)

[void][IO.Directory]::CreateDirectory((Join-Path $tmpDir2 '.git'))

$parentA = Join-Path $tmpDir2 'parent-a'
$parentB = Join-Path $tmpDir2 'parent-b'
[void][IO.Directory]::CreateDirectory($parentA)
[void][IO.Directory]::CreateDirectory($parentB)

# parent-a/repo and parent-b/repo — both standalone, both named "repo"
$parentARepo = Join-Path $parentA 'repo'
$parentBRepo = Join-Path $parentB 'repo'
[void][IO.Directory]::CreateDirectory($parentARepo)
[void][IO.Directory]::CreateDirectory((Join-Path $parentARepo '.git'))
[void][IO.Directory]::CreateDirectory($parentBRepo)
[void][IO.Directory]::CreateDirectory((Join-Path $parentBRepo '.git'))

# parent-a/sub — submodule; relative path must expose the parent-a context
$parentASub = Join-Path $parentA 'sub'
[void][IO.Directory]::CreateDirectory($parentASub)
[IO.File]::WriteAllText((Join-Path $parentASub '.git'), 'gitdir: ../../.git/modules/sub')

# Mirror pull-all discovery + relative-path computation
$sep2     = [IO.Path]::DirectorySeparatorChar
$detectedRelPaths = @()
$skippedRelPaths  = @()

$candidateInfo2 = Get-WorkspaceCandidates -WorkspaceRoot (Get-Item -Path $tmpDir2) -Separator $sep2
$candidates2    = @($candidateInfo2.Candidates)

foreach ($item in $candidates2) {
    $gitEntry = Join-Path $item.FullName '.git'
    $relPath  = Get-RelPath -WorkspaceRootPath $tmpDir2 -FullPath $item.FullName -Separator $sep2
    if (-not (Test-Path -Path $gitEntry)) { continue }
    if ((Get-Item -Path $gitEntry -Force).PSIsContainer -eq $false) {
        $skippedRelPaths += $relPath
        continue
    }
    $detectedRelPaths += $relPath
}

# Clean up temp dir
try { [IO.Directory]::Delete($tmpDir2, $true) } catch {}

# Both "repo" entries must appear with distinct relative paths
$repoRelPaths = @($detectedRelPaths | Where-Object { $_ -like '*repo*' })
if ($repoRelPaths.Count -ne 2) {
    Write-Error "pull-all test FAIL: expected 2 repos named 'repo' from different parents, got $($repoRelPaths.Count)"
    exit 1
}
if ($repoRelPaths[0] -eq $repoRelPaths[1]) {
    Write-Error "pull-all test FAIL: duplicate leaf-name repos have identical relative paths (not distinguishable)"
    exit 1
}
$expectedParentA = "parent-a${sep2}repo"
$expectedParentB = "parent-b${sep2}repo"
if ($repoRelPaths -notcontains $expectedParentA) {
    Write-Error "pull-all test FAIL: expected relative path '$expectedParentA', got: $($repoRelPaths -join ', ')"
    exit 1
}
if ($repoRelPaths -notcontains $expectedParentB) {
    Write-Error "pull-all test FAIL: expected relative path '$expectedParentB', got: $($repoRelPaths -join ', ')"
    exit 1
}

# Submodule's relative path must include the parent directory name for context
$expectedSubPath = "parent-a${sep2}sub"
if ($skippedRelPaths -notcontains $expectedSubPath) {
    Write-Error "pull-all test FAIL: submodule relative path '$expectedSubPath' not found in skipped list, got: $($skippedRelPaths -join ', ')"
    exit 1
}

# ---------------------------------------------------------------------------
# pull-all.ps1 regression: recursive discovery suppresses noisy enumeration
# errors while still capturing them for summary reporting.
# ---------------------------------------------------------------------------

if ($pullAllContent -notmatch 'Get-ChildItem\s+`?\s*-Path\s+\$WorkspaceRoot\.FullName\s+`?\s*-Directory\s+`?\s*-Recurse\s+`?\s*-Force\s+`?\s*-ErrorAction\s+SilentlyContinue') {
    Write-Error 'pull-all test FAIL: recursive discovery must suppress noisy enumeration errors'
    exit 1
}
if ($pullAllContent -notmatch '-ErrorVariable\s+discoveryErrors') {
    Write-Error 'pull-all test FAIL: recursive discovery must retain suppressed enumeration errors for summary reporting'
    exit 1
}

# ---------------------------------------------------------------------------
# pull-all.ps1 regression: summary output includes full path
# Verifies that the Summary: section's Write-Host line references FullPath so
# repositories with ambiguous leaf names remain unambiguous in the summary.
# ---------------------------------------------------------------------------

# Split on the "Summary:" string and check the tail of the script
$summarySection = ($pullAllContent -split 'Summary:')[1]
if ($null -eq $summarySection -or $summarySection -notmatch '\$r\.FullPath') {
    Write-Error "pull-all test FAIL: Summary section does not include `$r.FullPath — full path must appear in summary lines"
    exit 1
}

# ---------------------------------------------------------------------------
# pull-all.cmd wrapper: verify it exists and delegates to pull-all.ps1
# ---------------------------------------------------------------------------

$cmdLauncher = Join-Path $repoRoot 'pull-all.cmd'
if (-not (Test-Path -Path $cmdLauncher)) {
    Write-Error "Missing one-click launcher: $cmdLauncher"
    exit 1
}

$cmdContent = [IO.File]::ReadAllText($cmdLauncher)
if ($cmdContent -notmatch 'scripts\\pull-all\.ps1') {
    Write-Error "pull-all.cmd does not reference scripts\pull-all.ps1"
    exit 1
}

Write-Output 'Tests OK.'
