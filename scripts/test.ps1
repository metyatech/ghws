Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$bootstrapScript = '/mnt/d/ghws/scripts/wsl-mobile-login-bootstrap.sh'

$probeViaWslEnv = wsl.exe -d Ubuntu -- env AI_AGENT_MOBILE_ASSUME_TTY=1 SSH_CONNECTION=test-via-wsl bash -lc "$bootstrapScript --probe"
if (($probeViaWslEnv | Out-String).Trim() -ne 'open-menu') {
    Write-Error 'Expected mobile menu probe to open when SSH_CONNECTION is present in WSL.'
    exit 1
}

$previousSshConnection = $env:SSH_CONNECTION
try {
    $env:SSH_CONNECTION = 'test-via-windows'
    $probeViaWindowsEnv = wsl.exe -d Ubuntu -- env AI_AGENT_MOBILE_ASSUME_TTY=1 bash -lc "$bootstrapScript --probe"
} finally {
    if ($null -eq $previousSshConnection) {
        [Environment]::SetEnvironmentVariable('SSH_CONNECTION', $null, 'Process')
    } else {
        $env:SSH_CONNECTION = $previousSshConnection
    }
}

if (($probeViaWindowsEnv | Out-String).Trim() -ne 'open-menu') {
    Write-Error 'Expected mobile menu probe to open when SSH_CONNECTION exists only in the Windows parent environment.'
    exit 1
}

$probeBypassed = wsl.exe -d Ubuntu -- env AI_AGENT_MOBILE_ASSUME_TTY=1 AI_AGENT_MOBILE_BYPASS=1 SSH_CONNECTION=test-bypass bash -lc "$bootstrapScript --probe"
if (($probeBypassed | Out-String).Trim() -ne 'skip-menu') {
    Write-Error 'Expected mobile menu probe to skip when AI_AGENT_MOBILE_BYPASS is set.'
    exit 1
}

$resumeMenuOutput = wsl.exe -d Ubuntu -- bash -lc '/mnt/d/ghws/scripts/test-wsl-mobile-menu-resume.sh'
if (($resumeMenuOutput | Out-String).Trim() -notmatch 'PASS') {
    Write-Error 'Expected resume menu to render the numbered session list to the interactive terminal.'
    exit 1
}

$startMenuOutput = wsl.exe -d Ubuntu -- bash -lc '/mnt/d/ghws/scripts/test-wsl-mobile-menu-start.sh'
if (($startMenuOutput | Out-String).Trim() -notmatch 'PASS') {
    Write-Error 'Expected start-menu flow to create a session with the requested title and directory.'
    exit 1
}

$mobileSshOutput = python (Join-Path $PSScriptRoot 'test-mobile-ssh.py')
if (($mobileSshOutput | Out-String).Trim() -notmatch 'PASS') {
    Write-Error 'Expected the SSH -> WSL mobile menu path to pass resume verification.'
    exit 1
}

$tls12 = [Net.SecurityProtocolType]::Tls12
if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag($tls12))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $tls12
}

$urls = @(
    'https://github.com/metyatech/ghws'
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

Write-Output 'Tests OK.'
