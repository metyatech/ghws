param(
    [ValidateSet('gui', 'codex', 'claude', 'gemini', 'shell', 'new', 'start', 'resume', 'existing', 'list', 'mobile')]
    [string]$Mode = 'gui',
    [ValidateSet('codex', 'claude', 'gemini', 'shell')]
    [string]$Type,
    [string]$Name = '',
    [string]$Title = '',
    [string]$SessionName = '',
    [string]$Distro = 'Ubuntu',
    [string]$WorkingDirectory = '',
    [switch]$Detach,
    [switch]$Json,
    [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tmuxScriptPath = Join-Path $PSScriptRoot 'wsl-tmux.ps1'
if (-not (Test-Path -Path $tmuxScriptPath)) {
    throw "Missing script: $tmuxScriptPath"
}

$sessionCatalogPath = Join-Path $env:USERPROFILE 'agent-handoff\session-catalog.json'
$workspaceRootPath = Split-Path -Parent $PSScriptRoot

$profiles = @{
    codex = @{
        Type = 'codex'
        StartupCommand = '~/.local/bin/codex'
        HealthCheckCommand = '~/.local/bin/codex --version'
        Label = 'Codex'
    }
    claude = @{
        Type = 'claude'
        StartupCommand = '~/.local/bin/claude'
        HealthCheckCommand = '~/.local/bin/claude --version'
        Label = 'Claude'
    }
    gemini = @{
        Type = 'gemini'
        StartupCommand = '~/.local/bin/gemini'
        HealthCheckCommand = '~/.local/bin/gemini --version'
        Label = 'Gemini'
    }
    shell = @{
        Type = 'shell'
        StartupCommand = $null
        Label = 'Shell'
    }
}

function Ensure-SessionCatalogFile {
    $catalogDirectory = Split-Path -Parent $sessionCatalogPath
    if (-not (Test-Path -Path $catalogDirectory)) {
        [void](New-Item -ItemType Directory -Path $catalogDirectory -Force)
    }

    if (-not (Test-Path -Path $sessionCatalogPath)) {
        '[]' | Set-Content -Path $sessionCatalogPath
    }
}

function Get-SessionCatalogEntries {
    Ensure-SessionCatalogFile

    $raw = (Get-Content -Path $sessionCatalogPath -Raw).Trim()
    if (-not $raw) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        return @($parsed)
    }
    return @($parsed)
}

function Save-SessionCatalogEntries {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    Ensure-SessionCatalogFile
    ($Entries | ConvertTo-Json -Depth 6) | Set-Content -Path $sessionCatalogPath
}

function Get-SessionCatalogMap {
    $map = @{}
    foreach ($entry in @(Get-SessionCatalogEntries)) {
        $map[[string]$entry.session_name] = $entry
    }
    return $map
}

function Upsert-SessionCatalogEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionNameValue,
        [Parameter(Mandatory = $true)]
        [string]$SessionTypeValue,
        [string]$SessionTitle,
        [string]$WorkingDirectoryWindows
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-SessionCatalogEntries)) {
        [void]$entries.Add($entry)
    }

    $nowUtc = (Get-Date).ToUniversalTime().ToString('o')
    $normalizedTitle = if ($SessionTitle) { $SessionTitle.Trim() } else { '' }
    $matchIndex = -1
    for ($index = 0; $index -lt $entries.Count; $index++) {
        if ([string]$entries[$index].session_name -eq $SessionNameValue) {
            $matchIndex = $index
            break
        }
    }

    if ($matchIndex -ge 0) {
        $entry = $entries[$matchIndex]
        $entry.session_type = $SessionTypeValue
        if ($normalizedTitle) {
            $entry.title = $normalizedTitle
        }
        if ($WorkingDirectoryWindows) {
            $entry.working_directory_windows = $WorkingDirectoryWindows
        }
        $entry.updated_utc = $nowUtc
        $entries[$matchIndex] = $entry
    } else {
        [void]$entries.Add([pscustomobject]@{
            session_name = $SessionNameValue
            session_type = $SessionTypeValue
            title = $normalizedTitle
            working_directory_windows = $WorkingDirectoryWindows
            created_utc = $nowUtc
            updated_utc = $nowUtc
        })
    }

    Save-SessionCatalogEntries -Entries @($entries)
}

function New-AutoSessionLabel {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 4)
    return "auto-$timestamp-$suffix"
}

function Get-SessionPreviewText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSessionName,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $preview = & wsl.exe -d $TargetDistro -- bash -lc "tmux capture-pane -pt '$TargetSessionName' -S -40 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1"
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return (($preview | Out-String).Trim())
}

function Convert-WslPathToWindowsPath {
    param(
        [string]$WslPath
    )

    if (-not $WslPath) {
        return ''
    }

    if ($WslPath -match '^/mnt/(?<drive>[a-z])(?<rest>/.*)?$') {
        $driveLetter = $Matches['drive'].ToUpperInvariant()
        $rest = if ($Matches['rest']) { ($Matches['rest'] -replace '/', '\') } else { '' }
        return "${driveLetter}:$rest"
    }

    return $WslPath
}

function Get-SessionWorkingDirectoryWindows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSessionName,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $panePathOutput = & wsl.exe -d $TargetDistro -- bash -lc "tmux display-message -p -t '$TargetSessionName' '#{pane_current_path}' 2>/dev/null"
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    $panePath = ($panePathOutput | Out-String).Trim()
    if (-not $panePath) {
        return ''
    }

    return Convert-WslPathToWindowsPath -WslPath $panePath
}

function Get-DefaultSessionTitle {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Session
    )

    $typeKey = [string]$Session.Type
    $typeLabel = if ($profiles.ContainsKey($typeKey)) { [string]$profiles[$typeKey].Label } else { 'Session' }
    $createdValue = if ($Session.PSObject.Properties.Name -contains 'CreatedLocal') { [string]$Session.CreatedLocal } else { '' }

    if ($createdValue.Trim()) {
        return "$typeLabel $createdValue"
    }

    return "$typeLabel session"
}

function Test-IsMeaningfulPreviewText {
    param(
        [string]$PreviewText
    )

    $trimmed = if ($PreviewText) { $PreviewText.Trim() } else { '' }
    if (-not $trimmed) {
        return $false
    }

    if ($trimmed -match '^[^@\s]+@[^:]+:.*[$#]$') {
        return $false
    }

    return $true
}

function Get-SessionDisplayTitle {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Session
    )

    if ($Session.PSObject.Properties.Name -contains 'Title') {
        $titleValue = [string]$Session.Title
        if ($titleValue.Trim()) {
            return $titleValue.Trim()
        }
    }

    $fallbackLabel = [string]$Session.DisplayName
    if ($fallbackLabel.Trim() -and -not $fallbackLabel.Trim().StartsWith('auto-')) {
        return $fallbackLabel.Trim()
    }

    if ($Session.PSObject.Properties.Name -contains 'PreviewText') {
        $previewValue = [string]$Session.PreviewText
        if (Test-IsMeaningfulPreviewText -PreviewText $previewValue) {
            return $previewValue.Trim()
        }
    }

    return Get-DefaultSessionTitle -Session $Session
}

function Test-WslCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    & wsl.exe -d $TargetDistro -- bash -lc "$Command >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Resolve-WindowsWorkingDirectory {
    param(
        [string]$PathText
    )

    $candidate = if ($PathText -and $PathText.Trim()) { $PathText.Trim() } else { $workspaceRootPath }
    $resolved = [System.IO.Path]::GetFullPath($candidate)

    if (-not (Test-Path -Path $resolved -PathType Container)) {
        throw "Working directory not found: $resolved"
    }

    return $resolved
}

function Convert-WindowsPathToWslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    if ($WindowsPath -match '^(?<drive>[A-Za-z]):(?<rest>\\.*)?$') {
        $driveLetter = $Matches['drive'].ToLowerInvariant()
        $rest = if ($Matches['rest']) { ($Matches['rest'] -replace '\\', '/') } else { '' }
        return "/mnt/$driveLetter$rest"
    }

    if ($WindowsPath.StartsWith('/')) {
        return $WindowsPath
    }

    $wslPathOutput = & wsl.exe -d $TargetDistro -- wslpath -a -u $WindowsPath
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to convert Windows path to WSL path: $WindowsPath"
    }

    $wslPath = ($wslPathOutput | Out-String).Trim()
    if (-not $wslPath) {
        throw "WSL path conversion returned empty output for: $WindowsPath"
    }

    return $wslPath
}

function Get-WorkspaceDirectorySuggestions {
    $ordered = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($pathValue in @($workspaceRootPath)) {
        if ($pathValue -and $seen.Add($pathValue)) {
            [void]$ordered.Add($pathValue)
        }
    }

    foreach ($entry in @(Get-SessionCatalogEntries)) {
        if ($entry.PSObject.Properties.Name -contains 'working_directory_windows') {
            $pathValue = [string]$entry.working_directory_windows
            if ($pathValue -and (Test-Path -Path $pathValue -PathType Container) -and $seen.Add($pathValue)) {
                [void]$ordered.Add($pathValue)
            }
        }
    }

    $childDirectories = @(Get-ChildItem -Path $workspaceRootPath -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    foreach ($directory in $childDirectories) {
        $pathValue = $directory.FullName
        if ($seen.Add($pathValue)) {
            [void]$ordered.Add($pathValue)
        }
    }

    return @($ordered)
}

function Invoke-TmuxScript {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    & $tmuxScriptPath @Parameters
    if ($LASTEXITCODE -ne 0) {
        throw "wsl-tmux.ps1 failed with exit code $LASTEXITCODE."
    }
}

function Get-ProfileLaunchSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,
        [Parameter(Mandatory = $true)]
        [string]$SessionLabel,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $profile = $profiles[$ProfileName]
    if (-not $profile) {
        throw "Unknown profile '$ProfileName'."
    }

    $startupCommand = if ($profile.ContainsKey('StartupCommand')) { $profile['StartupCommand'] } else { $null }
    $healthCheckCommand = if ($profile.ContainsKey('HealthCheckCommand')) { [string]$profile['HealthCheckCommand'] } else { '' }
    $fallbackMessage = $null

    if ($startupCommand -and $healthCheckCommand) {
        $isHealthy = Test-WslCommand -Command $healthCheckCommand -TargetDistro $TargetDistro
        if (-not $isHealthy) {
            $startupCommand = $null
            $fallbackMessage = "$($profile.Label) startup command is not runnable in WSL distro '$TargetDistro'. A plain shell session will be opened for this typed session."
        }
    }

    return @{
        SessionType = [string]$profile.Type
        SessionLabel = $SessionLabel
        StartupCommand = $startupCommand
        FallbackMessage = $fallbackMessage
    }
}

function Invoke-EnsureTypedSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionType,
        [Parameter(Mandatory = $true)]
        [string]$SessionLabel,
        [string]$StartupCommand,
        [string]$WorkingDirectoryPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro,
        [switch]$NoAttach
    )

    $params = @{
        Action = 'ensure'
        Distro = $TargetDistro
        SessionType = $SessionType
        SessionLabel = $SessionLabel
    }

    if ($StartupCommand) {
        $params.StartupCommand = $StartupCommand
    }
    if ($WorkingDirectoryPath) {
        $params.WorkingDirectory = $WorkingDirectoryPath
    }
    if ($NoAttach) {
        $params.Detach = $true
    }

    Invoke-TmuxScript -Parameters $params
}

function Invoke-AttachSessionByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSessionName,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    Invoke-TmuxScript -Parameters @{
        Action = 'attach'
        Distro = $TargetDistro
        SessionName = $TargetSessionName
    }
}

function Get-ExistingSessions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $jsonText = & $tmuxScriptPath -Action list -Distro $TargetDistro -Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to retrieve tmux sessions.'
    }

    $raw = ($jsonText | Out-String).Trim()
    if (-not $raw) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json
    $sessions = if ($parsed -is [System.Array]) { @($parsed) } else { @($parsed) }
    $catalogMap = Get-SessionCatalogMap

    foreach ($session in $sessions) {
        $sessionNameValue = [string]$session.Name
        $metadata = $catalogMap[$sessionNameValue]
        $previewText = Get-SessionPreviewText -TargetSessionName $sessionNameValue -TargetDistro $TargetDistro
        $titleValue = if ($metadata) { [string]$metadata.title } else { '' }
        $workingDirectoryValue = if ($metadata -and $metadata.PSObject.Properties.Name -contains 'working_directory_windows') { [string]$metadata.working_directory_windows } else { '' }
        if (-not $workingDirectoryValue) {
            $workingDirectoryValue = Get-SessionWorkingDirectoryWindows -TargetSessionName $sessionNameValue -TargetDistro $TargetDistro
        }
        Add-Member -InputObject $session -NotePropertyName 'Title' -NotePropertyValue $titleValue -Force
        Add-Member -InputObject $session -NotePropertyName 'WorkingDirectoryWindows' -NotePropertyValue $workingDirectoryValue -Force
        Add-Member -InputObject $session -NotePropertyName 'PreviewText' -NotePropertyValue $previewText -Force
        Add-Member -InputObject $session -NotePropertyName 'DisplayTitle' -NotePropertyValue (Get-SessionDisplayTitle -Session $session) -Force
    }

    return $sessions
}

function Test-ExistingSessionName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSessionName,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $sessions = @(Get-ExistingSessions -TargetDistro $TargetDistro)
    foreach ($session in $sessions) {
        if ([string]$session.Name -eq $TargetSessionName) {
            return $true
        }
    }
    return $false
}

function Resolve-TypedSessionName {
    param(
        [string]$TargetSessionName,
        [string]$TargetType,
        [string]$TargetName
    )

    if ($TargetSessionName) {
        return $TargetSessionName
    }

    if ($TargetType -and $TargetName -and $TargetName.Trim()) {
        $safe = $TargetName.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
        $safe = $safe.Trim('-')
        if (-not $safe) {
            throw 'Name is not valid after normalization.'
        }
        return "$TargetType-$safe"
    }

    return ''
}

function Start-ProfileSession {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codex', 'claude', 'gemini', 'shell')]
        [string]$ProfileName,
        [string]$SessionLabel,
        [string]$SessionTitle,
        [string]$WindowsWorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $resolvedSessionLabel = if ($SessionLabel -and $SessionLabel.Trim()) { $SessionLabel } else { New-AutoSessionLabel }
    $resolvedWindowsWorkingDirectory = Resolve-WindowsWorkingDirectory -PathText $WindowsWorkingDirectory
    $resolvedWslWorkingDirectory = Convert-WindowsPathToWslPath -WindowsPath $resolvedWindowsWorkingDirectory -TargetDistro $TargetDistro

    $settings = Get-ProfileLaunchSettings -ProfileName $ProfileName -SessionLabel $resolvedSessionLabel -TargetDistro $TargetDistro
    if ($settings.FallbackMessage) {
        Write-Warning $settings.FallbackMessage
    }

    $resolvedSessionName = "$($settings.SessionType)-$($settings.SessionLabel.ToLowerInvariant())"
    Upsert-SessionCatalogEntry -SessionNameValue $resolvedSessionName -SessionTypeValue $settings.SessionType -SessionTitle $SessionTitle -WorkingDirectoryWindows $resolvedWindowsWorkingDirectory
    Invoke-EnsureTypedSession -SessionType $settings.SessionType -SessionLabel $settings.SessionLabel -StartupCommand $settings.StartupCommand -WorkingDirectoryPath $resolvedWslWorkingDirectory -TargetDistro $TargetDistro -NoAttach:$Detach
}

function Read-Choice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string[]]$Allowed
    )

    while ($true) {
        $value = [string](Read-Host $Prompt)
        if ($Allowed -contains $value) {
            return $value
        }
        Write-Host "Invalid choice. Allowed values: $($Allowed -join ', ')"
    }
}

function Select-ExistingSessionInteractive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $sessions = @(Get-ExistingSessions -TargetDistro $TargetDistro)
    if ($sessions.Count -eq 0) {
        throw "No tmux sessions found in distro '$TargetDistro'."
    }

    for ($i = 0; $i -lt $sessions.Count; $i++) {
        $s = $sessions[$i]
        $index = $i + 1
        $displayTitle = Get-SessionDisplayTitle -Session $s
        $previewText = [string]$s.PreviewText
        Write-Host ("[{0}] {1}  type={2}  preview={3}  attached={4}  windows={5}  activity={6}" -f $index, $displayTitle, $s.Type, $previewText, $s.AttachedClients, $s.WindowCount, $s.LastActivityLocal)
    }

    while ($true) {
        $choiceText = [string](Read-Host 'Select session number')
        $choice = 0
        if ([int]::TryParse($choiceText, [ref]$choice)) {
            if ($choice -ge 1 -and $choice -le $sessions.Count) {
                return [string]$sessions[$choice - 1].Name
            }
        }
        Write-Host 'Invalid number.'
    }
}

function Open-PlainWslShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    & wsl.exe -d $TargetDistro
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to open plain WSL shell for distro '$TargetDistro'."
    }
}

function Start-MobileFlow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    while ($true) {
        Write-Host "AI session mobile menu (distro: $TargetDistro)"
        Write-Host '[1] Start new typed session'
        Write-Host '[2] Resume existing session'
        Write-Host '[3] List sessions'
        Write-Host '[4] Open plain WSL shell'
        Write-Host '[5] Exit'
        $menuChoice = Read-Choice -Prompt 'Choose 1/2/3/4/5' -Allowed @('1', '2', '3', '4', '5')

        if ($menuChoice -eq '1') {
            $typeChoice = Read-Choice -Prompt 'Type (codex/claude/gemini/shell)' -Allowed @('codex', 'claude', 'gemini', 'shell')
            $sessionTitle = [string](Read-Host 'What is this session about? (optional)')
            $sessionWorkingDirectory = [string](Read-Host "Working directory (optional, default: $workspaceRootPath)")
            Start-ProfileSession -ProfileName $typeChoice -SessionTitle $sessionTitle -WindowsWorkingDirectory $sessionWorkingDirectory -TargetDistro $TargetDistro
            continue
        }

        if ($menuChoice -eq '2') {
            $selectedName = Select-ExistingSessionInteractive -TargetDistro $TargetDistro
            Invoke-AttachSessionByName -TargetSessionName $selectedName -TargetDistro $TargetDistro
            continue
        }

        if ($menuChoice -eq '3') {
            $items = @(Get-ExistingSessions -TargetDistro $TargetDistro)
            if ($Json) {
                if ($items.Count -eq 0) { '[]' } else { $items | ConvertTo-Json -Depth 4 }
                return
            }

            if ($items.Count -eq 0) {
                Write-Host 'No sessions found.'
            } else {
                $items | Format-Table DisplayTitle, Type, WorkingDirectoryWindows, PreviewText, AttachedClients, WindowCount, LastActivityLocal -AutoSize
            }
            continue
        }

        if ($menuChoice -eq '4') {
            Open-PlainWslShell -TargetDistro $TargetDistro
            continue
        }

        return
    }
}

if ($Mode -eq 'list') {
    $items = @(Get-ExistingSessions -TargetDistro $Distro)
    if ($Json) {
        if ($items.Count -eq 0) { '[]' } else { $items | ConvertTo-Json -Depth 4 }
    } else {
        $items | Format-Table DisplayTitle, Type, WorkingDirectoryWindows, PreviewText, AttachedClients, WindowCount, LastActivityLocal -AutoSize
    }
    exit 0
}

if ($Mode -eq 'new' -or $Mode -eq 'start') {
    if (-not $Type) {
        throw 'Use -Type with -Mode new/start.'
    }
    Start-ProfileSession -ProfileName $Type -SessionLabel $Name -SessionTitle $Title -WindowsWorkingDirectory $WorkingDirectory -TargetDistro $Distro
    exit 0
}

if ($Mode -eq 'resume' -or $Mode -eq 'existing') {
    $resolvedResumeName = Resolve-TypedSessionName -TargetSessionName $SessionName -TargetType $Type -TargetName $Name
    if ($resolvedResumeName) {
        if ($Detach) {
            if (-not (Test-ExistingSessionName -TargetSessionName $resolvedResumeName -TargetDistro $Distro)) {
                throw "Session '$resolvedResumeName' not found in distro '$Distro'."
            }
            Write-Output "Session '$resolvedResumeName' is available in distro '$Distro'."
        } else {
            Invoke-AttachSessionByName -TargetSessionName $resolvedResumeName -TargetDistro $Distro
        }
    } else {
        $selectedName = Select-ExistingSessionInteractive -TargetDistro $Distro
        Invoke-AttachSessionByName -TargetSessionName $selectedName -TargetDistro $Distro
    }
    exit 0
}

if ($Mode -eq 'mobile') {
    if ($Type -and $Name.Trim()) {
        Start-ProfileSession -ProfileName $Type -SessionLabel $Name -SessionTitle $Title -WindowsWorkingDirectory $WorkingDirectory -TargetDistro $Distro
        exit 0
    }
    if ($Type -and $Title.Trim()) {
        Start-ProfileSession -ProfileName $Type -SessionTitle $Title -WindowsWorkingDirectory $WorkingDirectory -TargetDistro $Distro
        exit 0
    }
    $resolvedMobileResumeName = Resolve-TypedSessionName -TargetSessionName $SessionName -TargetType $Type -TargetName $Name
    if ($resolvedMobileResumeName) {
        if ($Detach) {
            if (-not (Test-ExistingSessionName -TargetSessionName $resolvedMobileResumeName -TargetDistro $Distro)) {
                throw "Session '$resolvedMobileResumeName' not found in distro '$Distro'."
            }
            Write-Output "Session '$resolvedMobileResumeName' is available in distro '$Distro'."
        } else {
            Invoke-AttachSessionByName -TargetSessionName $resolvedMobileResumeName -TargetDistro $Distro
        }
        exit 0
    }
    Start-MobileFlow -TargetDistro $Distro
    exit 0
}

if ($Mode -ne 'gui') {
    Start-ProfileSession -ProfileName $Mode -SessionLabel $Name -SessionTitle $Title -WindowsWorkingDirectory $WorkingDirectory -TargetDistro $Distro
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Open-TmuxInNewWindow {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ScriptArguments
    )

    $terminalArgs = @(
        '-NoExit',
        '-ExecutionPolicy', 'Bypass',
        '-File', $tmuxScriptPath
    ) + $ScriptArguments

    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    $shellPath = if ($pwsh) { $pwsh.Source } else { (Get-Command 'powershell.exe' -ErrorAction Stop).Source }

    Start-Process -FilePath $shellPath -ArgumentList $terminalArgs | Out-Null
}

function New-GuiProfileSession {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codex', 'claude', 'gemini', 'shell')]
        [string]$ProfileName,
        [string]$SessionTitle,
        [string]$WindowsWorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    $resolvedSessionLabel = New-AutoSessionLabel
    $resolvedWindowsWorkingDirectory = Resolve-WindowsWorkingDirectory -PathText $WindowsWorkingDirectory
    $resolvedWslWorkingDirectory = Convert-WindowsPathToWslPath -WindowsPath $resolvedWindowsWorkingDirectory -TargetDistro $TargetDistro

    $settings = Get-ProfileLaunchSettings -ProfileName $ProfileName -SessionLabel $resolvedSessionLabel -TargetDistro $TargetDistro
    if ($settings.FallbackMessage) {
        [System.Windows.Forms.MessageBox]::Show(
            $settings.FallbackMessage,
            "$($profiles[$ProfileName].Label) Fallback",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    Upsert-SessionCatalogEntry -SessionNameValue "$($settings.SessionType)-$($settings.SessionLabel.ToLowerInvariant())" -SessionTypeValue $settings.SessionType -SessionTitle $SessionTitle -WorkingDirectoryWindows $resolvedWindowsWorkingDirectory
    $scriptArgs = @(
        '-Action', 'ensure',
        '-Distro', $TargetDistro,
        '-SessionType', $settings.SessionType,
        '-SessionLabel', $settings.SessionLabel,
        '-WorkingDirectory', $resolvedWslWorkingDirectory
    )

    if ($settings.StartupCommand) {
        $scriptArgs += @('-StartupCommand', $settings.StartupCommand)
    }

    Open-TmuxInNewWindow -ScriptArguments $scriptArgs
}

function Open-GuiExistingSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSessionName,
        [Parameter(Mandatory = $true)]
        [string]$TargetDistro
    )

    Open-TmuxInNewWindow -ScriptArguments @(
        '-Action', 'attach',
        '-Distro', $TargetDistro,
        '-SessionName', $TargetSessionName
    )
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AI Agent Hub'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(960, 520)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Start Or Resume Agent Sessions'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(20, 16)
$form.Controls.Add($titleLabel)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Distro: $Distro. Internal IDs are generated automatically. Choose a folder first, then optionally add a short topic."
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(20, 48)
$form.Controls.Add($hint)

$newGroup = New-Object System.Windows.Forms.GroupBox
$newGroup.Text = 'Start New Session'
$newGroup.Location = New-Object System.Drawing.Point(20, 80)
$newGroup.Size = New-Object System.Drawing.Size(920, 160)
$form.Controls.Add($newGroup)

$typeLabel = New-Object System.Windows.Forms.Label
$typeLabel.Text = 'Agent Type'
$typeLabel.AutoSize = $true
$typeLabel.Location = New-Object System.Drawing.Point(18, 32)
$newGroup.Controls.Add($typeLabel)

$typeCombo = New-Object System.Windows.Forms.ComboBox
$typeCombo.DropDownStyle = 'DropDownList'
$typeCombo.Location = New-Object System.Drawing.Point(18, 54)
$typeCombo.Size = New-Object System.Drawing.Size(160, 28)
[void]$typeCombo.Items.AddRange(@('codex', 'claude', 'gemini', 'shell'))
$typeCombo.SelectedIndex = 0
$newGroup.Controls.Add($typeCombo)

$directoryLabel = New-Object System.Windows.Forms.Label
$directoryLabel.Text = 'Directory'
$directoryLabel.AutoSize = $true
$directoryLabel.Location = New-Object System.Drawing.Point(208, 32)
$newGroup.Controls.Add($directoryLabel)

$directoryCombo = New-Object System.Windows.Forms.ComboBox
$directoryCombo.DropDownStyle = 'DropDown'
$directoryCombo.Location = New-Object System.Drawing.Point(208, 54)
$directoryCombo.Size = New-Object System.Drawing.Size(540, 28)
$directoryCombo.Text = $workspaceRootPath
$directoryCombo.AutoCompleteMode = 'SuggestAppend'
$directoryCombo.AutoCompleteSource = 'ListItems'
$newGroup.Controls.Add($directoryCombo)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = 'Browse...'
$browseButton.Location = New-Object System.Drawing.Point(766, 52)
$browseButton.Size = New-Object System.Drawing.Size(120, 32)
$newGroup.Controls.Add($browseButton)

$nameLabel = New-Object System.Windows.Forms.Label
$nameLabel.Text = 'What Is This About?'
$nameLabel.AutoSize = $true
$nameLabel.Location = New-Object System.Drawing.Point(18, 98)
$newGroup.Controls.Add($nameLabel)

$nameBox = New-Object System.Windows.Forms.TextBox
$nameBox.Location = New-Object System.Drawing.Point(18, 120)
$nameBox.Size = New-Object System.Drawing.Size(730, 28)
$nameBox.Text = ''
$newGroup.Controls.Add($nameBox)

$createButton = New-Object System.Windows.Forms.Button
$createButton.Text = 'Start New Session'
$createButton.Location = New-Object System.Drawing.Point(766, 118)
$createButton.Size = New-Object System.Drawing.Size(120, 32)
$newGroup.Controls.Add($createButton)

$existingGroup = New-Object System.Windows.Forms.GroupBox
$existingGroup.Text = 'Resume Existing Session'
$existingGroup.Location = New-Object System.Drawing.Point(20, 256)
$existingGroup.Size = New-Object System.Drawing.Size(920, 216)
$form.Controls.Add($existingGroup)

$sessionList = New-Object System.Windows.Forms.ListView
$sessionList.Location = New-Object System.Drawing.Point(18, 30)
$sessionList.Size = New-Object System.Drawing.Size(880, 138)
$sessionList.View = [System.Windows.Forms.View]::Details
$sessionList.FullRowSelect = $true
$sessionList.GridLines = $true
[void]$sessionList.Columns.Add('Title', 200)
[void]$sessionList.Columns.Add('Type', 70)
[void]$sessionList.Columns.Add('Folder', 260)
[void]$sessionList.Columns.Add('Preview', 180)
[void]$sessionList.Columns.Add('Attached', 70)
[void]$sessionList.Columns.Add('Last Activity', 120)
$existingGroup.Controls.Add($sessionList)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object System.Drawing.Point(666, 176)
$refreshButton.Size = New-Object System.Drawing.Size(110, 30)
$existingGroup.Controls.Add($refreshButton)

$resumeButton = New-Object System.Windows.Forms.Button
$resumeButton.Text = 'Open Selected'
$resumeButton.Location = New-Object System.Drawing.Point(794, 176)
$resumeButton.Size = New-Object System.Drawing.Size(122, 30)
$existingGroup.Controls.Add($resumeButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Width = 100
$closeButton.Height = 34
$closeButton.Location = New-Object System.Drawing.Point(840, 480)
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$autoRefreshTimer = New-Object System.Windows.Forms.Timer
$autoRefreshTimer.Interval = 2500
$guiRefreshInProgress = $false
$lastGuiSessionSignature = ''

$doubleBufferProperty = $sessionList.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
if ($doubleBufferProperty) {
    $doubleBufferProperty.SetValue($sessionList, $true, $null)
}

function Refresh-GuiDirectorySuggestions {
    $selectedText = [string]$directoryCombo.Text
    $directoryCombo.Items.Clear()
    foreach ($pathValue in @(Get-WorkspaceDirectorySuggestions)) {
        [void]$directoryCombo.Items.Add($pathValue)
    }
    if ($selectedText.Trim()) {
        $directoryCombo.Text = $selectedText
    } else {
        $directoryCombo.Text = $workspaceRootPath
    }
}

function Get-GuiSessionListSignature {
    $jsonText = & $tmuxScriptPath -Action list -Distro $Distro -Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to retrieve tmux session signature.'
    }

    $raw = ($jsonText | Out-String).Trim()
    if (-not $raw) {
        return ''
    }

    $parsed = $raw | ConvertFrom-Json
    $sessions = if ($parsed -is [System.Array]) { @($parsed) } else { @($parsed) }
    $parts = foreach ($s in $sessions) {
        '{0}|{1}|{2}|{3}' -f $s.Name, $s.Type, $s.AttachedClients, $s.WindowCount
    }

    return (($parts | Sort-Object) -join "`n")
}

function Refresh-GuiSessions {
    param(
        [switch]$Force
    )

    if ($guiRefreshInProgress) {
        return
    }

    $guiRefreshInProgress = $true
    try {
        $signature = Get-GuiSessionListSignature
        if (-not $Force -and $signature -eq $lastGuiSessionSignature) {
            return
        }

        $selectedTag = ''
        if ($sessionList.SelectedItems.Count -gt 0) {
            $selectedTag = [string]$sessionList.SelectedItems[0].Tag
        }

        $sessions = @(Get-ExistingSessions -TargetDistro $Distro)
        $sessionList.BeginUpdate()
        try {
            $sessionList.Items.Clear()
            foreach ($s in $sessions) {
                $item = New-Object System.Windows.Forms.ListViewItem((Get-SessionDisplayTitle -Session $s))
                [void]$item.SubItems.Add([string]$s.Type)
                [void]$item.SubItems.Add([string]$s.WorkingDirectoryWindows)
                [void]$item.SubItems.Add([string]$s.PreviewText)
                [void]$item.SubItems.Add([string]$s.AttachedClients)
                [void]$item.SubItems.Add([string]$s.LastActivityLocal)
                $item.Tag = [string]$s.Name
                [void]$sessionList.Items.Add($item)

                if ($selectedTag -and [string]$item.Tag -eq $selectedTag) {
                    $item.Selected = $true
                    $item.Focused = $true
                    $item.EnsureVisible()
                }
            }
        } finally {
            $sessionList.EndUpdate()
        }

        $script:lastGuiSessionSignature = $signature
    } finally {
        $script:guiRefreshInProgress = $false
    }
}

$createButton.Add_Click({
    try {
        $selectedType = [string]$typeCombo.SelectedItem
        $sessionTitle = [string]$nameBox.Text
        $selectedDirectory = [string]$directoryCombo.Text
        New-GuiProfileSession -ProfileName $selectedType -SessionTitle $sessionTitle -WindowsWorkingDirectory $selectedDirectory -TargetDistro $Distro
        Refresh-GuiDirectorySuggestions
        Refresh-GuiSessions -Force
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Launch Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$browseButton.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose the folder to open for the new agent session'
        $dialog.SelectedPath = Resolve-WindowsWorkingDirectory -PathText ([string]$directoryCombo.Text)
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $directoryCombo.Text = $dialog.SelectedPath
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Browse Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$refreshButton.Add_Click({
    try {
        Refresh-GuiSessions -Force
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Refresh Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$form.Add_Activated({
    try {
        Refresh-GuiDirectorySuggestions
        Refresh-GuiSessions
    } catch {
    }
})

$autoRefreshTimer.Add_Tick({
    try {
        Refresh-GuiSessions
    } catch {
    }
})

$resumeButton.Add_Click({
    try {
        if ($sessionList.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Select a session first.',
                'Resume Session',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $selected = $sessionList.SelectedItems[0]
        Open-GuiExistingSession -TargetSessionName ([string]$selected.Tag) -TargetDistro $Distro
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Open Existing Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

[void]$form.Add_Shown({
    Refresh-GuiDirectorySuggestions
    Refresh-GuiSessions -Force
    $autoRefreshTimer.Start()
    if ($SmokeTest) {
        $form.Close()
    }
})

$form.Add_FormClosed({
    $autoRefreshTimer.Stop()
    $autoRefreshTimer.Dispose()
})

[void]$form.ShowDialog()
