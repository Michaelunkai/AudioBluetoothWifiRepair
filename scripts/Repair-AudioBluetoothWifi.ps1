param(
    [switch]$NoPause,
    [switch]$NoSoundTest,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
$script:HadError = $false
$script:ChangedItems = New-Object System.Collections.Generic.List[string]
$script:VerifiedItems = New-Object System.Collections.Generic.List[string]
$script:SkippedItems = New-Object System.Collections.Generic.List[string]
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir ("repair-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Add-Changed {
    param([string]$Message)
    $script:ChangedItems.Add($Message) | Out-Null
    Write-Log $Message 'FIX'
}

function Add-Verified {
    param([string]$Message)
    $script:VerifiedItems.Add($Message) | Out-Null
    Write-Log $Message 'OK'
}

function Add-Skipped {
    param([string]$Message)
    $script:SkippedItems.Add($Message) | Out-Null
    Write-Log $Message 'SKIP'
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Sc {
    param([Parameter(Mandatory)][string[]]$Args)
    $output = & "$env:SystemRoot\System32\sc.exe" @Args 2>&1
    foreach ($line in $output) {
        if ($line) { Write-Log "sc $($Args -join ' '): $line" }
    }
    return $LASTEXITCODE
}

function Get-ScText {
    param([Parameter(Mandatory)][string[]]$Args)
    $output = & "$env:SystemRoot\System32\sc.exe" @Args 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join "`n")
        Lines = $output
    }
}

function Set-ServiceStartModeSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('auto','demand','disabled')][string]$Start
    )
    $query = & "$env:SystemRoot\System32\sc.exe" qc $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-Skipped "Service $Name is not installed; skipped startup mode $Start."
        return
    }
    $current = ($query | Select-String 'START_TYPE').ToString()
    $targetLabel = switch ($Start) {
        'auto' { 'AUTO_START' }
        'demand' { 'DEMAND_START' }
        'disabled' { 'DISABLED' }
    }
    if ($current -notmatch $targetLabel) {
        [void](Invoke-Sc -Args @('config', $Name, "start= $Start"))
        Add-Changed "Set $Name startup to $Start."
    } else {
        Add-Verified "$Name startup already $Start."
    }
}

function Start-ServiceSafe {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Skipped "Service $Name is not installed; skipped start."
        return
    }
    if ($svc.Status -ne 'Running') {
        try {
            Start-Service -Name $Name -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            Add-Changed "Started $Name."
        } catch {
            $script:HadError = $true
            Write-Log "Failed to start ${Name}: $($_.Exception.Message)" 'ERROR'
        }
    } else {
        Add-Verified "$Name already running."
    }
}

function Start-ScServiceOrDriverSafe {
    param([Parameter(Mandatory)][string]$Name)
    $query = Get-ScText -Args @('query', $Name)
    if ($query.ExitCode -ne 0) {
        Add-Skipped "$Name is not installed; skipped driver/service start."
        return
    }
    if ($query.Text -match 'STATE\s+:\s+4\s+RUNNING') {
        Add-Verified "$Name already running."
        return
    }
    $code = Invoke-Sc -Args @('start', $Name)
    if ($code -eq 0) {
        Add-Changed "Started $Name."
    } elseif ($code -eq 1056) {
        Add-Verified "$Name already running."
    } else {
        $script:HadError = $true
        Write-Log "Failed to start $Name through sc.exe; exit code $code." 'ERROR'
    }
}

function Enable-NetworkInterfaceIfDisabled {
    param([Parameter(Mandatory)][string]$Name)
    $output = & "$env:SystemRoot\System32\netsh.exe" interface show interface name="$Name" 2>&1
    if ($LASTEXITCODE -ne 0 -or (($output -join "`n") -match 'does not exist')) {
        Add-Skipped "Network interface $Name was not found."
        return
    }
    if (($output -join "`n") -match 'Admin State\s+:\s+Disabled') {
        & "$env:SystemRoot\System32\netsh.exe" interface set interface name="$Name" admin=enabled | Out-Null
        Add-Changed "Enabled network interface $Name."
    } else {
        Add-Verified "Network interface $Name is not administratively disabled."
    }
}

function Repair-CoreServices {
    Write-Log 'Repairing Windows audio, diagnostics, network, WiFi, and Bluetooth services.'
    Set-ServiceStartModeSafe -Name 'EventLog' -Start auto
    Start-ServiceSafe -Name 'EventLog'

    Set-ServiceStartModeSafe -Name 'DPS' -Start auto
    Start-ServiceSafe -Name 'DPS'

    Set-ServiceStartModeSafe -Name 'NlaSvc' -Start auto
    Start-ServiceSafe -Name 'NlaSvc'

    Set-ServiceStartModeSafe -Name 'Netman' -Start demand
    Start-ServiceSafe -Name 'Netman'

    Set-ServiceStartModeSafe -Name 'WlanSvc' -Start auto
    Start-ServiceSafe -Name 'WlanSvc'

    Set-ServiceStartModeSafe -Name 'BthServ' -Start demand
    Start-ServiceSafe -Name 'BthServ'

    Get-Service -Name 'BluetoothUserService_*' -ErrorAction SilentlyContinue | ForEach-Object {
        Start-ServiceSafe -Name $_.Name
    }

    Set-ServiceStartModeSafe -Name 'AudioEndpointBuilder' -Start auto
    Start-ServiceSafe -Name 'AudioEndpointBuilder'

    Set-ServiceStartModeSafe -Name 'Audiosrv' -Start auto
    Start-ServiceSafe -Name 'Audiosrv'

    Set-ServiceStartModeSafe -Name 'RtkAudioUniversalService' -Start auto
    Start-ServiceSafe -Name 'RtkAudioUniversalService'

    Set-ServiceStartModeSafe -Name 'Dhcp' -Start auto
    Start-ServiceSafe -Name 'Dhcp'

    Set-ServiceStartModeSafe -Name 'DeviceAssociationService' -Start auto
    Start-ServiceSafe -Name 'DeviceAssociationService'

    Set-ServiceStartModeSafe -Name 'ShellHWDetection' -Start auto
    Start-ServiceSafe -Name 'ShellHWDetection'

    Set-ServiceStartModeSafe -Name 'DeviceInstall' -Start demand
}

function Repair-AudioDrivers {
    Write-Log 'Repairing NVIDIA audio driver service startup states.'
    Set-ServiceStartModeSafe -Name 'NVHDA' -Start demand
    Start-ScServiceOrDriverSafe -Name 'NVHDA'
    Set-ServiceStartModeSafe -Name 'NvVAD_WaveExtensible' -Start demand
    Start-ScServiceOrDriverSafe -Name 'NvVAD_WaveExtensible'

    Set-ServiceStartModeSafe -Name 'NVDisplay.ContainerLocalSystem' -Start auto
    Start-ServiceSafe -Name 'NVDisplay.ContainerLocalSystem'
}

function Repair-NetworkInterfaces {
    Write-Log 'Repairing network adapter administrative state when needed.'
    Enable-NetworkInterfaceIfDisabled -Name 'Wi-Fi'
    Enable-NetworkInterfaceIfDisabled -Name 'Ethernet'
}

function Set-PlaybackRoute {
    Write-Log 'Repairing default playback route and system volume.'
    $nircmd = Join-Path $env:SystemRoot 'System32\nircmd.exe'
    if (-not (Test-Path -LiteralPath $nircmd)) {
        Write-Log "nircmd.exe not found at $nircmd; cannot set default sound device automatically." 'WARN'
        return
    }

    $preferredDevices = @('1 - M27UP', 'Realtek Digital Output', 'M27UP')
    $activeNames = @(Get-RenderEndpoints | Where-Object { $_.State -eq 1 } | ForEach-Object { $_.Name })
    if ($activeNames -contains 'M27UP') {
        Add-Verified 'M27UP is already an active render endpoint before route enforcement.'
    }
    foreach ($device in $preferredDevices) {
        foreach ($role in 0,1,2) {
            & $nircmd setdefaultsounddevice $device $role | Out-Null
        }
        Write-Log "Attempted default playback route: $device for roles 0,1,2."
    }
    & $nircmd mutesysvolume 0 | Out-Null
    & $nircmd setsysvolume 57344 | Out-Null
    Add-Changed 'Unmuted system audio and set volume to 87.5%.'
    Add-Changed 'Set preferred playback route order ending on M27UP for console, multimedia, and communications.'
}

function Get-RenderEndpoints {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\*' -Name DeviceState -ErrorAction SilentlyContinue |
        ForEach-Object {
            $props = Get-ItemProperty (Join-Path $_.PSPath 'Properties') -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Name = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
                State = $_.DeviceState
                Id = $_.PSChildName
            }
        }
}

function Verify-CurrentState {
    Write-Log 'Verifying repaired state.'
    foreach ($name in 'EventLog','DPS','NlaSvc','Netman','WlanSvc','BthServ','Dhcp','DeviceAssociationService','ShellHWDetection','Audiosrv','AudioEndpointBuilder','RtkAudioUniversalService') {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Add-Verified "$name is running."
        } else {
            $script:HadError = $true
            Write-Log "$name is not running." 'ERROR'
        }
    }

    foreach ($name in 'NVHDA','NvVAD_WaveExtensible') {
        $qc = & "$env:SystemRoot\System32\sc.exe" qc $name 2>&1
        if ($LASTEXITCODE -eq 0 -and ($qc -join "`n") -notmatch 'DISABLED') {
            Add-Verified "$name is installed and not disabled."
        } else {
            $script:HadError = $true
            Write-Log "$name is missing or disabled." 'ERROR'
        }
    }

    $badAudio = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { ($_.PNPClass -eq 'AudioEndpoint' -or $_.PNPClass -eq 'MEDIA') -and $_.Status -ne 'OK' -and $_.Name -notmatch "Michael's S25 Ultra" }
    if ($badAudio) {
        $script:HadError = $true
        $badAudio | ForEach-Object { Write-Log "Audio device not OK: $($_.Name) / $($_.Status)" 'ERROR' }
    } else {
        Add-Verified 'No present non-phone audio endpoint/media device reports a non-OK status.'
    }

    $badBluetooth = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPClass -eq 'Bluetooth' -and $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' }
    if ($badBluetooth) {
        $script:HadError = $true
        $badBluetooth | ForEach-Object { Write-Log "Bluetooth device not OK: $($_.Name) / $($_.Status)" 'ERROR' }
    } else {
        Add-Verified 'No present Bluetooth device reports a non-OK status.'
    }

    $badNetwork = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -match 'Wi-Fi|Wireless|Bluetooth|Realtek PCIe') -and $_.ConfigManagerErrorCode -ne 0 }
    if ($badNetwork) {
        $script:HadError = $true
        $badNetwork | ForEach-Object { Write-Log "Network adapter has ConfigManager error: $($_.Name) / $($_.ConfigManagerErrorCode)" 'ERROR' }
    } else {
        Add-Verified 'WiFi/Bluetooth/Ethernet adapters report no ConfigManager errors.'
    }

    $active = @(Get-RenderEndpoints | Where-Object { $_.State -eq 1 })
    if ($active.Name -contains 'M27UP') {
        Add-Verified 'M27UP render endpoint is active.'
    } else {
        Write-Log 'M27UP render endpoint is not active; current active endpoints follow.' 'WARN'
        $active | ForEach-Object { Write-Log "Active render endpoint: $($_.Name) [$($_.Id)]" 'WARN' }
    }

    $speakers = @(Get-RenderEndpoints | Where-Object { $_.Name -eq 'Speakers' })
    foreach ($speaker in $speakers) {
        if ($speaker.State -eq 8) {
            Add-Verified "Analog Speakers endpoint $($speaker.Id) is unplugged, not disabled."
        }
    }

    $wlan = & "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>&1
    if (($wlan -join "`n") -match 'State\s+:\s+connected') {
        Add-Verified 'WiFi interface is connected.'
    } else {
        Write-Log 'WiFi interface is not connected; services/drivers were still repaired.' 'WARN'
    }
}

function Play-SoundTest {
    if ($NoSoundTest) { return }
    $nircmd = Join-Path $env:SystemRoot 'System32\nircmd.exe'
    $sound = Join-Path $env:SystemRoot 'Media\Alarm01.wav'
    if ((Test-Path -LiteralPath $nircmd) -and (Test-Path -LiteralPath $sound)) {
        Write-Log 'Playing Windows test sound through current default playback route.'
        & $nircmd mediaplay 4000 $sound | Out-Null
    }
}

function Write-Summary {
    Write-Host ''
    Write-Host '=== Audio/Bluetooth/WiFi Repair Summary ==='
    Write-Host "Log: $LogPath"
    Write-Host ''
    Write-Host 'Fixed or enforced:'
    foreach ($item in $script:ChangedItems) { Write-Host " - $item" }
    Write-Host ''
    Write-Host 'Skipped because already good or not installed:'
    foreach ($item in $script:SkippedItems) { Write-Host " - $item" }
    Write-Host ''
    Write-Host 'Verified:'
    foreach ($item in $script:VerifiedItems) { Write-Host " - $item" }
    Write-Host ''
    if ($script:HadError) {
        Write-Host 'Result: completed with errors. Check the log above.'
    } else {
        Write-Host 'Result: repair completed and verification passed.'
    }
}

Write-Log 'AudioBluetoothWifiRepair started.'
Write-Log "Script path: $PSCommandPath"
Write-Log "Log path: $LogPath"

if (-not (Test-Admin)) {
    Write-Log 'This repair must run elevated. Relaunching with Administrator rights.' 'WARN'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($NoPause) { $args += '-NoPause' }
    if ($NoSoundTest) { $args += '-NoSoundTest' }
    if ($SelfTest) { $args += '-SelfTest' }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ($args -join ' ') -Verb RunAs | Out-Null
    exit 0
}

Repair-CoreServices
Repair-AudioDrivers
Repair-NetworkInterfaces
Set-PlaybackRoute
Verify-CurrentState
if (-not $SelfTest) { Play-SoundTest }
Write-Summary

if (-not $NoPause) {
    Write-Host ''
    Read-Host 'Press Enter to close'
}

if ($script:HadError) { exit 2 }
exit 0
