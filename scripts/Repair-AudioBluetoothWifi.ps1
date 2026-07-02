param(
    [switch]$NoPause,
    [switch]$NoSoundTest,
    [switch]$SelfTest,
    [switch]$PlanOnly,
    [switch]$DeepRepair,
    [string[]]$Module = @('All')
)

$ErrorActionPreference = 'Continue'
$script:HadError = $false
$script:ChangedItems = New-Object System.Collections.Generic.List[string]
$script:VerifiedItems = New-Object System.Collections.Generic.List[string]
$script:SkippedItems = New-Object System.Collections.Generic.List[string]
$script:NeedsApprovalItems = New-Object System.Collections.Generic.List[string]
$Module = @($Module | ForEach-Object { if ($null -ne $_) { $_ -split ',' } } | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $Module -or $Module.Count -eq 0) { $Module = @('All') }
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

function Add-NeedsApproval {
    param([string]$Message)
    $script:NeedsApprovalItems.Add($Message) | Out-Null
    Write-Log $Message 'APPROVAL'
}

function Test-ModuleEnabled {
    param([Parameter(Mandatory)][string]$Name)
    return ($Module -contains 'All' -or $Module -contains $Name)
}

function Invoke-RepairAction {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($PlanOnly) {
        Add-Skipped "PlanOnly: would repair $Description."
        return $true
    }
    try {
        & $Action
        Add-Changed $Description
        return $true
    } catch {
        $script:HadError = $true
        Write-Log "Failed to repair $Description`: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function ConvertTo-SafeVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match($Value, '\d+(\.\d+){1,3}')
    if (-not $match.Success) { return $null }
    try { return [version]$match.Value } catch { return $null }
}

function Get-WingetCommandPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) { return $cmd.Source }

    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $windowsApps -PathType Leaf) { return $windowsApps }

    $packages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)
    if (-not $packages -or $packages.Count -eq 0) {
        $packages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -AllUsers -ErrorAction SilentlyContinue)
    }
    foreach ($package in $packages) {
        if (-not [string]::IsNullOrWhiteSpace($package.InstallLocation)) {
            $candidate = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function Repair-WingetAvailability {
    $wingetPath = Get-WingetCommandPath
    if ($wingetPath) { return $wingetPath }

    $windowsAppsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (Test-Path -LiteralPath $windowsAppsDir -PathType Container) {
        $userPath = [Environment]::GetEnvironmentVariable('Path','User')
        if ($null -eq $userPath) { $userPath = '' }
        $pathParts = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($pathParts -notcontains $windowsAppsDir) {
            if (Invoke-RepairAction -Description "Added WindowsApps app-alias directory to user PATH for winget: $windowsAppsDir" -Action {
                $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $windowsAppsDir } else { "$userPath;$windowsAppsDir" }
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                $env:Path = "$env:Path;$windowsAppsDir"
            }) {
                $wingetPath = Get-WingetCommandPath
                if ($wingetPath) { return $wingetPath }
            }
        }
    }

    $appInstaller = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -AllUsers -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($appInstaller -and $appInstaller.InstallLocation) {
        $manifest = Join-Path $appInstaller.InstallLocation 'AppXManifest.xml'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            Invoke-RepairAction -Description 'Re-registered Microsoft App Installer package so winget app alias can resolve.' -Action {
                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            } | Out-Null
            $wingetPath = Get-WingetCommandPath
            if ($wingetPath) { return $wingetPath }
        }
    }

    if (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue) {
        $cacheRoot = Join-Path $Root 'tools\winget-cache'
        $bundlePath = Join-Path $cacheRoot 'Microsoft.DesktopAppInstaller.msixbundle'
        Invoke-RepairAction -Description 'Installed Microsoft App Installer from the official winget msixbundle so winget.exe can resolve.' -Action {
            New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
            Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundlePath -UseBasicParsing -ErrorAction Stop
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop
        } | Out-Null
        $wingetPath = Get-WingetCommandPath
        if ($wingetPath) { return $wingetPath }
    }

    Add-NeedsApproval 'winget.exe is still unavailable after PATH/App Installer repair attempts; Microsoft Store/App Installer may need manual repair.'
    return $null
}

function Get-VcRuntimeState {
    param([Parameter(Mandatory)][ValidateSet('x86','x64')][string]$Arch)
    $key = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$Arch"
    $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if (-not $item -and $Arch -eq 'x86') {
        $item = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\$Arch" -ErrorAction SilentlyContinue
    }
    if (-not $item) {
        return [pscustomobject]@{ Installed = $false; Version = $null; RawVersion = $null }
    }
    $raw = if ($item.Version) { [string]$item.Version } else { '{0}.{1}.{2}.{3}' -f $item.Major,$item.Minor,$item.Bld,$item.Rbld }
    return [pscustomobject]@{ Installed = ($item.Installed -eq 1); Version = (ConvertTo-SafeVersion $raw); RawVersion = $raw }
}

function Update-VcRuntime {
    param([Parameter(Mandatory)][ValidateSet('x86','x64')][string]$Arch)
    $state = Get-VcRuntimeState -Arch $Arch
    $cacheRoot = Join-Path $Root 'tools\vcredist-cache'
    $installer = Join-Path $cacheRoot "vc_redist.$Arch.exe"
    $uri = "https://aka.ms/vc14/vc_redist.$Arch.exe"

    $needsDownload = -not (Test-Path -LiteralPath $installer -PathType Leaf)
    if ($needsDownload) {
        if ($PlanOnly) {
            Add-Skipped "PlanOnly: would download latest Visual C++ v14 $Arch redistributable from Microsoft."
            return
        }
        try {
            New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
            Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing -ErrorAction Stop
            Add-Changed "Downloaded latest Visual C++ v14 $Arch redistributable from Microsoft."
        } catch {
            Add-NeedsApproval "Could not download Visual C++ v14 $Arch redistributable from Microsoft: $($_.Exception.Message)"
            return
        }
    }

    $latestVersion = ConvertTo-SafeVersion ((Get-Item -LiteralPath $installer).VersionInfo.ProductVersion)
    if ($state.Installed -and $state.Version -and $latestVersion -and $state.Version -ge $latestVersion) {
        Add-Verified "Visual C++ v14 $Arch runtime is current enough: installed $($state.RawVersion), installer $latestVersion."
        return
    }

    if ($PlanOnly) {
        Add-Skipped "PlanOnly: would install/update Visual C++ v14 $Arch runtime from Microsoft installer."
        return
    }

    try {
        $process = Start-Process -FilePath $installer -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -in 0,1638,3010) {
            if ($process.ExitCode -eq 3010) { Add-NeedsApproval "Visual C++ v14 $Arch runtime installer requested reboot; no reboot was performed." }
            Add-Changed "Installed or repaired Visual C++ v14 $Arch runtime with Microsoft installer."
        } else {
            Add-NeedsApproval "Visual C++ v14 $Arch installer exited with code $($process.ExitCode); manual review may be needed."
        }
    } catch {
        Add-NeedsApproval "Visual C++ v14 $Arch installer could not run: $($_.Exception.Message)"
    }
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
        $code = Invoke-Sc -Args @('config', $Name, 'start=', $Start)
        if ($code -eq 0) {
            Add-Changed "Set $Name startup to $Start."
        } else {
            Add-NeedsApproval "Service $Name did not accept startup mode $Start automatically; sc.exe exit code $code."
        }
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

function Invoke-CommandIfNeeded {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Write-Log "Running conditional repair: $Description"
    $output = & $FilePath @Arguments 2>&1
    foreach ($line in $output) {
        if ($line) { Write-Log "$Description`: $line" }
    }
    if ($LASTEXITCODE -eq 0) {
        Add-Changed $Description
    } else {
        Write-Log "$Description returned exit code $LASTEXITCODE." 'WARN'
    }
}

function Test-InternetConnectivity {
    $targets = @('1.1.1.1','8.8.8.8')
    foreach ($target in $targets) {
        if (Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Test-DnsResolution {
    try {
        [void][System.Net.Dns]::GetHostAddresses('www.microsoft.com')
        return $true
    } catch {
        return $false
    }
}

function Enable-PnpDevicesIfDisabled {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Classes,
        [string]$NameExcludeRegex = ''
    )
    $getPnp = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    $enablePnp = Get-Command Enable-PnpDevice -ErrorAction SilentlyContinue
    if (-not $getPnp -or -not $enablePnp) {
        Add-Skipped "PnP cmdlets are unavailable; skipped disabled $Label device repair."
        return
    }

    $devices = @()
    foreach ($class in $Classes) {
        $devices += @(Get-PnpDevice -Class $class -ErrorAction SilentlyContinue)
    }
    $devices = $devices | Where-Object {
        $_ -and $_.Status -eq 'Disabled' -and
        ($NameExcludeRegex -eq '' -or $_.FriendlyName -notmatch $NameExcludeRegex)
    }
    if (-not $devices -or $devices.Count -eq 0) {
        Add-Verified "No disabled $Label devices found."
        return
    }
    foreach ($device in $devices) {
        try {
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop
            Add-Changed "Enabled disabled $Label device: $($device.FriendlyName)"
        } catch {
            $script:HadError = $true
            Write-Log "Failed to enable $Label device $($device.FriendlyName): $($_.Exception.Message)" 'ERROR'
        }
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

    Set-ServiceStartModeSafe -Name 'Dnscache' -Start auto
    Start-ServiceSafe -Name 'Dnscache'

    Set-ServiceStartModeSafe -Name 'Winmgmt' -Start auto
    Start-ServiceSafe -Name 'Winmgmt'

    Set-ServiceStartModeSafe -Name 'PlugPlay' -Start demand
    Start-ServiceSafe -Name 'PlugPlay'
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

function Repair-PnpDevices {
    Write-Log 'Repairing disabled audio, Bluetooth, and network Plug and Play devices when needed.'
    Enable-PnpDevicesIfDisabled -Label 'audio' -Classes @('AudioEndpoint','MEDIA') -NameExcludeRegex "Michael's S25 Ultra"
    Enable-PnpDevicesIfDisabled -Label 'Bluetooth' -Classes @('Bluetooth')
    Enable-PnpDevicesIfDisabled -Label 'network' -Classes @('Net')
}

function Repair-DnsAndConnectivity {
    Write-Log 'Checking DNS and internet connectivity before network stack repair.'
    $online = Test-InternetConnectivity
    $dnsOk = Test-DnsResolution
    if ($online -and $dnsOk) {
        Add-Verified 'Internet connectivity and DNS resolution already work.'
        return
    }

    if (-not $dnsOk) {
        Invoke-CommandIfNeeded -Description 'Flushed DNS resolver cache because DNS resolution failed.' -FilePath "$env:SystemRoot\System32\ipconfig.exe" -Arguments @('/flushdns')
        Invoke-CommandIfNeeded -Description 'Registered DNS records because DNS resolution failed.' -FilePath "$env:SystemRoot\System32\ipconfig.exe" -Arguments @('/registerdns')
    } else {
        Add-Verified 'DNS resolution already works.'
    }

    if (-not $online) {
        $ipconfig = & "$env:SystemRoot\System32\ipconfig.exe" 2>&1
        $hasIpv4 = (($ipconfig -join "`n") -match 'IPv4 Address')
        if ($hasIpv4) {
            Add-Skipped 'Internet ping failed, but IPv4 configuration exists; skipped disruptive IP stack reset.'
        } else {
            Invoke-CommandIfNeeded -Description 'Renewed DHCP lease because no IPv4 address was detected.' -FilePath "$env:SystemRoot\System32\ipconfig.exe" -Arguments @('/renew')
        }
    } else {
        Add-Verified 'Internet connectivity already works.'
    }
}

function Get-DotNetRuntimeVersionForSdk {
    param([Parameter(Mandatory)][string]$SdkVersion)
    if ($SdkVersion -match '^(\d+)\.0\.100-(.+)$') {
        return ('{0}.0.0-{1}' -f $matches[1], $matches[2])
    }
    if ($SdkVersion -match '^(\d+)\.(\d+)\.(\d+)$') {
        return $null
    }
    return $null
}

function Test-DotNetRuntimePayload {
    param(
        [Parameter(Mandatory)][string]$RuntimeFolder,
        [Parameter(Mandatory)][string]$RuntimePath
    )
    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Container)) {
        return $false
    }
    if ($RuntimeFolder -eq 'Microsoft.NETCore.App') {
        return (Test-Path -LiteralPath (Join-Path $RuntimePath 'System.Private.CoreLib.dll') -PathType Leaf)
    }
    if ($RuntimeFolder -eq 'Microsoft.WindowsDesktop.App') {
        return (Test-Path -LiteralPath (Join-Path $RuntimePath 'PresentationCore.dll') -PathType Leaf)
    }
    return $false
}

function Get-DotNetRuntimeArchiveUrl {
    param(
        [Parameter(Mandatory)][string]$RuntimeName,
        [Parameter(Mandatory)][string]$Version
    )
    if ($RuntimeName -eq 'dotnet') {
        return "https://builds.dotnet.microsoft.com/dotnet/Runtime/$Version/dotnet-runtime-$Version-win-x64.zip"
    }
    if ($RuntimeName -eq 'windowsdesktop') {
        return "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/$Version/windowsdesktop-runtime-$Version-win-x64.zip"
    }
    throw "Unsupported .NET runtime payload: $RuntimeName"
}

function Expand-DotNetSharedRuntimePayload {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$RuntimeFolder,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$RuntimePath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $prefix = "shared/$RuntimeFolder/$Version/"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $extracted = 0
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }
            if (-not $entry.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = $entry.FullName.Substring($prefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $target = Join-Path $RuntimePath $relative
            $targetDirectory = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            }
            if (Test-Path -LiteralPath $target -PathType Leaf) { continue }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            $extracted++
        }
    } finally {
        $zip.Dispose()
    }
    return $extracted
}

function Expand-DotNetSdkRuntimeTargetsPayload {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$SdkVersion,
        [Parameter(Mandatory)][string]$SdkPath,
        [Parameter(Mandatory)][string]$TargetRelativeRoot
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $prefix = "sdk/$SdkVersion/$($TargetRelativeRoot.Replace('\','/'))/"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $extracted = 0
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) { continue }
            if (-not $entry.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = $entry.FullName.Substring(("sdk/$SdkVersion/").Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $target = Join-Path $SdkPath $relative
            $targetDirectory = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            }
            if (Test-Path -LiteralPath $target -PathType Leaf) { continue }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            $extracted++
        }
    } finally {
        $zip.Dispose()
    }
    return $extracted
}

function Install-DotNetRuntimeIfMissing {
    param(
        [Parameter(Mandatory)][string]$RuntimeName,
        [Parameter(Mandatory)][string]$RuntimeFolder,
        [Parameter(Mandatory)][string]$Version
    )
    $dotnetRoot = Join-Path $env:ProgramFiles 'dotnet'
    $runtimePath = Join-Path (Join-Path (Join-Path $dotnetRoot 'shared') $RuntimeFolder) $Version
    if (Test-DotNetRuntimePayload -RuntimeFolder $RuntimeFolder -RuntimePath $runtimePath) {
        Add-Verified "$RuntimeName $Version already installed."
        return
    }

    $cacheRoot = Join-Path $Root 'tools\dotnet-runtime-cache'
    if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    }
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null
    }

    $archiveUrl = Get-DotNetRuntimeArchiveUrl -RuntimeName $RuntimeName -Version $Version
    $archivePath = Join-Path $cacheRoot ([System.IO.Path]::GetFileName($archiveUrl))
    Write-Log "Installing missing $RuntimeName $Version shared runtime from $archiveUrl."
    try {
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 180
        } else {
            Write-Log "Using cached .NET runtime archive $archivePath."
        }
        $extracted = Expand-DotNetSharedRuntimePayload -ArchivePath $archivePath -RuntimeFolder $RuntimeFolder -Version $Version -RuntimePath $runtimePath
        Write-Log "Extracted $extracted missing $RuntimeFolder files for $Version without replacing dotnet.exe."
    } catch {
        $script:HadError = $true
        Write-Log "Failed to install missing $RuntimeName $Version`: $($_.Exception.Message)" 'ERROR'
        return
    }

    if (Test-DotNetRuntimePayload -RuntimeFolder $RuntimeFolder -RuntimePath $runtimePath) {
        Add-Changed "Installed missing $RuntimeName $Version shared runtime payload."
    } else {
        $script:HadError = $true
        Write-Log "Missing $RuntimeName $Version payload validation file after extraction." 'ERROR'
    }
}

function Repair-DotNetSdkRuntimeTargets {
    param(
        [Parameter(Mandatory)][string]$SdkVersion,
        [Parameter(Mandatory)][string]$SdkPath
    )
    if ($SdkVersion -notmatch '^(\d+)\.') { return }
    $major = $matches[1]
    $targetRelativeRoot = "runtimes\win\lib\net$major.0"
    $targetRoot = Join-Path $SdkPath $targetRelativeRoot
    $requiredFiles = @(
        'System.ServiceProcess.ServiceController.dll',
        'System.Diagnostics.EventLog.dll',
        'System.Diagnostics.EventLog.Messages.dll',
        'System.Security.Cryptography.Pkcs.dll'
    )
    $missing = @()
    foreach ($fileName in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $targetRoot $fileName) -PathType Leaf)) {
            $missing += $fileName
        }
    }
    if (-not $missing -or $missing.Count -eq 0) {
        Add-Verified ".NET SDK $SdkVersion Windows runtime-target files already present."
        return
    }

    $cacheRoot = Join-Path $Root 'tools\dotnet-runtime-cache'
    if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    }
    $archiveUrl = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$SdkVersion/dotnet-sdk-$SdkVersion-win-x64.zip"
    $archivePath = Join-Path $cacheRoot ([System.IO.Path]::GetFileName($archiveUrl))
    Write-Log "Restoring missing .NET SDK $SdkVersion Windows runtime-target files from $archiveUrl."
    try {
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 240
        } else {
            Write-Log "Using cached .NET SDK archive $archivePath."
        }
        $extracted = Expand-DotNetSdkRuntimeTargetsPayload -ArchivePath $archivePath -SdkVersion $SdkVersion -SdkPath $SdkPath -TargetRelativeRoot $targetRelativeRoot
        Write-Log "Extracted $extracted missing .NET SDK $SdkVersion runtime-target files without replacing dotnet.exe."
    } catch {
        $script:HadError = $true
        Write-Log "Failed to restore .NET SDK $SdkVersion runtime-target files: $($_.Exception.Message)" 'ERROR'
        return
    }

    $stillMissing = @()
    foreach ($fileName in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $targetRoot $fileName) -PathType Leaf)) {
            $stillMissing += $fileName
        }
    }
    if ($stillMissing.Count -eq 0) {
        Add-Changed "Restored missing .NET SDK $SdkVersion Windows runtime-target files."
    } else {
        $script:HadError = $true
        Write-Log "Still missing .NET SDK $SdkVersion runtime-target files: $($stillMissing -join ', ')" 'ERROR'
    }
}

function Repair-DotNetInstallRegistryMetadata {
    Write-Log 'Checking .NET x64 install registry metadata used by dotnet CLI workload/installer discovery.'
    $dotnetRoot = Join-Path $env:ProgramFiles 'dotnet'
    if (-not (Test-Path -LiteralPath $dotnetRoot -PathType Container)) {
        Add-Skipped '.NET root folder not found; skipped .NET install registry metadata repair.'
        return
    }

    $rootKeyPath = 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64'
    if (-not (Test-Path -LiteralPath $rootKeyPath)) {
        New-Item -Path $rootKeyPath -Force | Out-Null
        Add-Changed 'Created missing .NET x64 InstalledVersions registry key.'
    }
    $currentInstallLocation = (Get-ItemProperty -LiteralPath $rootKeyPath -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
    if ($currentInstallLocation -ne ($dotnetRoot + '\')) {
        New-ItemProperty -LiteralPath $rootKeyPath -Name InstallLocation -Value ($dotnetRoot + '\') -PropertyType String -Force | Out-Null
        Add-Changed 'Repaired .NET x64 InstallLocation registry value.'
    } else {
        Add-Verified '.NET x64 InstallLocation registry value already correct.'
    }

    $hostFxrRoot = Join-Path $dotnetRoot 'host\fxr'
    $hostVersion = $null
    if (Test-Path -LiteralPath $hostFxrRoot -PathType Container) {
        $hostVersion = Get-ChildItem -LiteralPath $hostFxrRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [version](($_.Name -replace '-.*$','')) } -Descending |
            Select-Object -First 1 -ExpandProperty Name
    }
    if ($hostVersion) {
        foreach ($subKey in @('hostfxr','sharedhost')) {
            $path = Join-Path $rootKeyPath $subKey
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
            $currentVersion = (Get-ItemProperty -LiteralPath $path -Name Version -ErrorAction SilentlyContinue).Version
            if ($currentVersion -ne $hostVersion) {
                New-ItemProperty -LiteralPath $path -Name Version -Value $hostVersion -PropertyType String -Force | Out-Null
                Add-Changed "Repaired .NET x64 $subKey registry version to $hostVersion."
            } else {
                Add-Verified ".NET x64 $subKey registry version already $hostVersion."
            }
        }
    } else {
        Add-Skipped '.NET host\fxr folder not found; skipped hostfxr/sharedhost registry values.'
    }

    $sharedRoot = Join-Path $dotnetRoot 'shared'
    if (-not (Test-Path -LiteralPath $sharedRoot -PathType Container)) {
        Add-Skipped '.NET shared runtime folder not found; skipped sharedfx registry values.'
        return
    }
    foreach ($frameworkFolder in Get-ChildItem -LiteralPath $sharedRoot -Directory -ErrorAction SilentlyContinue) {
        $frameworkKey = Join-Path (Join-Path $rootKeyPath 'sharedfx') $frameworkFolder.Name
        if (-not (Test-Path -LiteralPath $frameworkKey)) { New-Item -Path $frameworkKey -Force | Out-Null }
        foreach ($versionFolder in Get-ChildItem -LiteralPath $frameworkFolder.FullName -Directory -ErrorAction SilentlyContinue) {
            $current = (Get-ItemProperty -LiteralPath $frameworkKey -Name $versionFolder.Name -ErrorAction SilentlyContinue).($versionFolder.Name)
            if ($current -ne 1) {
                New-ItemProperty -LiteralPath $frameworkKey -Name $versionFolder.Name -Value 1 -PropertyType DWord -Force | Out-Null
                Add-Changed "Registered .NET x64 shared framework $($frameworkFolder.Name) $($versionFolder.Name)."
            } else {
                Add-Verified ".NET x64 shared framework $($frameworkFolder.Name) $($versionFolder.Name) already registered."
            }
        }
    }
}

function Repair-DotNetRuntimeMismatch {
    Write-Log 'Checking .NET SDK/runtime consistency for dotnet.exe hard-error popups.'
    $dotnetRoot = Join-Path $env:ProgramFiles 'dotnet'
    $sdkRoot = Join-Path $dotnetRoot 'sdk'
    if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
        Add-Skipped '.NET SDK folder not found; skipped .NET runtime mismatch repair.'
        return
    }

    $sdkVersions = @(Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $candidateVersions = @()
    foreach ($sdkVersion in $sdkVersions) {
        $runtimeVersion = Get-DotNetRuntimeVersionForSdk -SdkVersion $sdkVersion
        if ($runtimeVersion) { $candidateVersions += $runtimeVersion }
    }
    $candidateVersions = @($candidateVersions | Sort-Object -Unique)
    if (-not $candidateVersions -or $candidateVersions.Count -eq 0) {
        Add-Verified '.NET SDK/runtime layout has no preview SDK runtime mismatch candidates.'
        return
    }

    foreach ($version in $candidateVersions) {
        Install-DotNetRuntimeIfMissing -RuntimeName 'dotnet' -RuntimeFolder 'Microsoft.NETCore.App' -Version $version
        Install-DotNetRuntimeIfMissing -RuntimeName 'windowsdesktop' -RuntimeFolder 'Microsoft.WindowsDesktop.App' -Version $version
    }
    foreach ($sdkVersion in $sdkVersions) {
        if ($sdkVersion -match '-preview\.') {
            Repair-DotNetSdkRuntimeTargets -SdkVersion $sdkVersion -SdkPath (Join-Path $sdkRoot $sdkVersion)
        }
    }
    Repair-DotNetInstallRegistryMetadata
}

function Repair-WindowsUpdateAndCrypto {
    if (-not (Test-ModuleEnabled -Name 'Update')) { return }
    Write-Log 'Checking Windows Update, installer, cryptographic, certificate, and time repair gates.'
    foreach ($entry in @(
        @{Name='wuauserv'; Start='demand'},
        @{Name='bits'; Start='demand'},
        @{Name='UsoSvc'; Start='demand'},
        @{Name='WaaSMedicSvc'; Start='demand'},
        @{Name='cryptsvc'; Start='auto'},
        @{Name='msiserver'; Start='demand'},
        @{Name='TrustedInstaller'; Start='demand'},
        @{Name='W32Time'; Start='demand'}
    )) {
        Set-ServiceStartModeSafe -Name $entry.Name -Start $entry.Start
    }
    foreach ($name in 'cryptsvc','bits','wuauserv','msiserver') {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Stopped' -and $name -in 'cryptsvc','bits') {
            Start-ServiceSafe -Name $name
        } elseif ($svc) {
            Add-Verified "$name is installed; start is left on-demand unless needed."
        }
    }
    $rebootKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )
    foreach ($key in $rebootKeys) {
        if ($key -like '*Session Manager') {
            $pending = (Get-ItemProperty -LiteralPath $key -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($pending) { Add-NeedsApproval 'A reboot is pending because PendingFileRenameOperations exists; no reboot was performed.' }
        } elseif (Test-Path -LiteralPath $key) {
            Add-NeedsApproval "A reboot is pending because $key exists; no reboot was performed."
        }
    }
    $certAutoUpdate = 'HKLM:\Software\Policies\Microsoft\SystemCertificates\AuthRoot'
    $disableRoot = (Get-ItemProperty -LiteralPath $certAutoUpdate -Name DisableRootAutoUpdate -ErrorAction SilentlyContinue).DisableRootAutoUpdate
    if ($disableRoot -eq 1) {
        Add-NeedsApproval 'Root certificate auto-update is blocked by policy; left unchanged.'
    } else {
        Add-Verified 'Root certificate auto-update is not blocked by the common policy key.'
    }
}

function Repair-StoreWingetAndAppx {
    if (-not (Test-ModuleEnabled -Name 'Store')) { return }
    Write-Log 'Checking Microsoft Store, AppX, Winget, Gaming Services, and WebView2 gates.'
    foreach ($svcName in 'AppXSvc','ClipSVC','InstallService','GamingServices','GamingServicesNet') {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Set-ServiceStartModeSafe -Name $svcName -Start 'demand'
            Add-Verified "$svcName is installed for Store/AppX workflows."
        } else {
            Add-Skipped "$svcName is not installed; skipped Store dependency start repair."
        }
    }
    $wingetPath = Repair-WingetAvailability
    if ($wingetPath) {
        $sourceOutput = & $wingetPath source list 2>&1
        if ($LASTEXITCODE -eq 0) {
            Add-Verified "winget exists and source list works: $wingetPath"
        } else {
            if (-not $PlanOnly) {
                $resetOutput = & $wingetPath source reset --force 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Add-Changed 'Reset winget sources after source list failed.'
                } else {
                    Add-NeedsApproval "winget exists but source reset failed: $($resetOutput -join ' ')"
                }
            } else {
                Add-Skipped "PlanOnly: would reset winget sources after source list failed: $($sourceOutput -join ' ')"
            }
        }
    }
    $store = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue
    if ($store) { Add-Verified 'Microsoft Store package is registered.' } else { Add-NeedsApproval 'Microsoft Store package is missing or not registered.' }
    $webView = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\*' -ErrorAction SilentlyContinue | Where-Object { $_.name -match 'WebView2' }
    if ($webView) { Add-Verified 'Microsoft Edge WebView2 runtime registration exists.' } else { Add-NeedsApproval 'WebView2 runtime registration was not found; installer repair may be needed.' }
}

function Repair-PowerShellTerminalAndPath {
    if (-not (Test-ModuleEnabled -Name 'Shell')) { return }
    Write-Log 'Checking PowerShell, Terminal, app aliases, PATH, and developer tool gates.'
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    $pathText = "$machinePath;$userPath"
    foreach ($path in @(
        "$env:SystemRoot\System32",
        "$env:SystemRoot",
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps",
        "$env:USERPROFILE\bin",
        "$env:ProgramFiles\dotnet"
    )) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Add-Skipped "PATH candidate does not exist: $path"
        } elseif ($pathText -notlike "*$path*") {
            Invoke-RepairAction -Description "Added missing user PATH entry $path" -Action {
                $current = [Environment]::GetEnvironmentVariable('Path','User')
                if ($null -eq $current) { $current = '' }
                if ([string]::IsNullOrWhiteSpace($current)) {
                    [Environment]::SetEnvironmentVariable('Path', $path, 'User')
                } else {
                    [Environment]::SetEnvironmentVariable('Path', ($current.TrimEnd(';') + ';' + $path), 'User')
                }
            } | Out-Null
        } else {
            Add-Verified "PATH already contains $path."
        }
    }
    foreach ($profilePath in @(
        "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
        "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
    )) {
        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            $tokens = $null; $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($profilePath, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors -and $errors.Count -gt 0) {
                $script:HadError = $true
                Write-Log "PowerShell profile parse errors in $profilePath`: $($errors[0].Message)" 'ERROR'
            } else {
                Add-Verified "PowerShell profile parses cleanly: $profilePath"
            }
        } else {
            $parent = Split-Path -Parent $profilePath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                Invoke-RepairAction -Description "Created missing PowerShell profile folder $parent" -Action { New-Item -ItemType Directory -Force -Path $parent | Out-Null } | Out-Null
            } else {
                Add-Skipped "PowerShell profile file is absent but folder exists: $profilePath"
            }
        }
    }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) { Add-Verified "Windows Terminal launcher resolves to $($wt.Source)." } else { Add-NeedsApproval 'wt.exe was not found; Terminal/App Execution Alias repair may be needed.' }
    foreach ($cmd in 'git.exe','python.exe','py.exe','node.exe','npm.cmd','ssh.exe','dotnet.exe') {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) { Add-Verified "$cmd resolves." } else { Add-Skipped "$cmd is not currently available on PATH." }
    }
}

function Repair-SecurityFirewallAndDefender {
    if (-not (Test-ModuleEnabled -Name 'Security')) { return }
    Write-Log 'Checking firewall, Defender, Security Center, UAC, and credential service gates.'
    foreach ($entry in @(
        @{Name='BFE'; Start='auto'},
        @{Name='mpssvc'; Start='auto'},
        @{Name='SecurityHealthService'; Start='demand'},
        @{Name='wscsvc'; Start='demand'},
        @{Name='WinDefend'; Start='auto'},
        @{Name='WdNisSvc'; Start='demand'},
        @{Name='VaultSvc'; Start='demand'},
        @{Name='Appinfo'; Start='demand'}
    )) {
        Set-ServiceStartModeSafe -Name $entry.Name -Start $entry.Start
    }
    foreach ($name in 'BFE','mpssvc') { Start-ServiceSafe -Name $name }
    $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    if ($profiles) {
        foreach ($profile in $profiles) {
            if ($profile.Enabled) { Add-Verified "Firewall profile $($profile.Name) is enabled." } else { Add-NeedsApproval "Firewall profile $($profile.Name) is disabled; not changed automatically." }
        }
    } else {
        Add-Skipped 'Firewall profile cmdlets unavailable; skipped firewall profile verification.'
    }
}

function Repair-DevicesInputUsbDisplayPrinterCamera {
    if (-not (Test-ModuleEnabled -Name 'Devices')) { return }
    Write-Log 'Checking USB, HID/input, display, printer, camera, microphone, clipboard, and font gates.'
    foreach ($entry in @(
        @{Name='hidserv'; Start='demand'},
        @{Name='TabletInputService'; Start='demand'},
        @{Name='Spooler'; Start='auto'},
        @{Name='FrameServer'; Start='demand'},
        @{Name='cbdhsvc'; Start='demand'},
        @{Name='FontCache'; Start='auto'},
        @{Name='Power'; Start='auto'}
    )) {
        Set-ServiceStartModeSafe -Name $entry.Name -Start $entry.Start
    }
    foreach ($class in 'USB','HIDClass','Keyboard','Mouse','Monitor','Display','Camera','MEDIA','AudioEndpoint','PrintQueue') {
        $bad = @(Get-PnpDevice -Class $class -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Disabled' })
        if ($bad.Count -eq 0) {
            Add-Verified "No disabled/error PnP devices found for class $class."
        } else {
            foreach ($dev in $bad) {
                if ($dev.Status -eq 'Disabled') {
                    Invoke-RepairAction -Description "Enabled disabled $class device $($dev.FriendlyName)" -Action { Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop } | Out-Null
                } else {
                    Add-NeedsApproval "$class device has error status and may need driver repair: $($dev.FriendlyName) / $($dev.InstanceId)"
                }
            }
        }
    }
}

function Repair-NetworkStackExpanded {
    if (-not (Test-ModuleEnabled -Name 'Network')) { return }
    Write-Log 'Checking expanded network, VPN, proxy, SMB, RDP, and sharing gates.'
    foreach ($entry in @(
        @{Name='LanmanWorkstation'; Start='auto'},
        @{Name='LanmanServer'; Start='auto'},
        @{Name='lmhosts'; Start='demand'},
        @{Name='TermService'; Start='demand'},
        @{Name='SessionEnv'; Start='demand'},
        @{Name='UmRdpService'; Start='demand'},
        @{Name='iphlpsvc'; Start='auto'}
    )) {
        Set-ServiceStartModeSafe -Name $entry.Name -Start $entry.Start
    }
    $winHttpProxy = & "$env:SystemRoot\System32\netsh.exe" winhttp show proxy 2>&1
    if (($winHttpProxy -join "`n") -match 'Direct access') {
        Add-Verified 'WinHTTP proxy is direct.'
    } else {
        Add-NeedsApproval "WinHTTP proxy is configured; not reset automatically: $($winHttpProxy -join ' ')"
    }
    $proxyEnabled = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    if ($proxyEnabled -eq 1) {
        Add-NeedsApproval 'User proxy is enabled; not changed automatically.'
    } else {
        Add-Verified 'User proxy is not enabled.'
    }
    $vpnAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'VPN|TAP|Wintun|WireGuard|OpenVPN|Tailscale|ZeroTier' })
    foreach ($adapter in $vpnAdapters) {
        if ($adapter.Status -eq 'Disabled') { Add-Skipped "VPN-like adapter is disabled: $($adapter.Name)" } else { Add-Verified "VPN-like adapter present: $($adapter.Name) / $($adapter.Status)" }
    }
}

function Repair-RuntimesAndAppPrerequisites {
    if (-not (Test-ModuleEnabled -Name 'Runtimes')) { return }
    Write-Log 'Checking Visual C++, DirectX, WebView2, Gaming runtime, browser, and app prerequisite gates.'
    foreach ($arch in 'x64','x86') { Update-VcRuntime -Arch $arch }
    $dx = Join-Path $env:SystemRoot 'System32\xinput1_4.dll'
    if (Test-Path -LiteralPath $dx -PathType Leaf) { Add-Verified 'DirectX/XInput core runtime file exists.' } else { Add-NeedsApproval 'DirectX/XInput core runtime file is missing.' }
    $defaultBrowser = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction SilentlyContinue).ProgId
    if ($defaultBrowser) { Add-Verified "Default HTTP browser association exists: $defaultBrowser" } else { Add-NeedsApproval 'Default HTTP browser association was not found.' }
}

function Repair-EnvironmentTempAndAssociations {
    if (-not (Test-ModuleEnabled -Name 'Environment')) { return }
    Write-Log 'Checking environment variables, TEMP folders, app aliases, and core file associations.'
    foreach ($var in 'TEMP','TMP','USERPROFILE','ProgramFiles','ComSpec','PATHEXT') {
        $value = [Environment]::GetEnvironmentVariable($var)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $script:HadError = $true
            Write-Log "Critical environment variable $var is empty." 'ERROR'
        } else {
            Add-Verified "Environment variable $var is set."
        }
    }
    foreach ($temp in @($env:TEMP, $env:TMP)) {
        if ([string]::IsNullOrWhiteSpace($temp)) { continue }
        if (-not (Test-Path -LiteralPath $temp -PathType Container)) {
            Invoke-RepairAction -Description "Created missing temp folder $temp" -Action { New-Item -ItemType Directory -Force -Path $temp | Out-Null } | Out-Null
        } else {
            Add-Verified "Temp folder exists: $temp"
        }
    }
    $assocChecks = @{
        '.exe'='exefile';
        '.lnk'='lnkfile';
        '.cmd'='cmdfile';
        '.bat'='batfile';
        '.ps1'='Microsoft.PowerShellScript.1';
        '.msi'='Msi.Package';
        '.zip'='CompressedFolder'
    }
    foreach ($ext in $assocChecks.Keys) {
        $assocKey = Get-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\$ext" -ErrorAction SilentlyContinue
        $actual = $null
        if ($assocKey) { $actual = $assocKey.GetValue('') }
        if ($actual) { Add-Verified "$ext association exists as $actual." } else { Add-NeedsApproval "$ext association is missing; not recreated automatically." }
    }
}

function Invoke-DeepRepairIfRequested {
    if (-not $DeepRepair) {
        Add-Skipped 'DeepRepair not requested; skipped DISM/SFC/WMI/storage deep repair commands.'
        return
    }
    Write-Log 'DeepRepair requested; running verification-first component checks.'
    Invoke-RepairAction -Description 'Ran DISM ScanHealth' -Action { & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /ScanHealth | ForEach-Object { if ($_){ Write-Log "DISM: $_" } } } | Out-Null
    Invoke-RepairAction -Description 'Ran SFC verify-only scan' -Action { & "$env:SystemRoot\System32\sfc.exe" /verifyonly | ForEach-Object { if ($_){ Write-Log "SFC: $_" } } } | Out-Null
    $winmgmt = & "$env:SystemRoot\System32\wbem\winmgmt.exe" /verifyrepository 2>&1
    foreach ($line in $winmgmt) { if ($line) { Write-Log "WMI verify: $line" } }
    Add-Verified 'WMI repository verification command completed.'
    $dirty = & "$env:SystemRoot\System32\fsutil.exe" dirty query $env:SystemDrive 2>&1
    foreach ($line in $dirty) { if ($line) { Write-Log "Disk dirty query: $line" } }
}

function Invoke-RecentIssueScanner {
    if (-not (Test-ModuleEnabled -Name 'Events')) { return }
    Write-Log 'Scanning recent event log and visible popup evidence for known repairable patterns.'
    $start = (Get-Date).AddHours(-6)
    $events = @(Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$start} -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -in '.NET Runtime','Application Error','Application Popup','MsiInstaller' } |
        Select-Object -First 30)
    if ($events.Count -eq 0) {
        Add-Verified 'No recent known application/runtime/installer error events found in the scan window.'
    } else {
        foreach ($event in $events) {
            $message = ($event.Message -replace '\s+', ' ')
            if ($message -match 'FrameworkMissingFailure|hostfxr_initialize|dotnet\.exe') {
                Add-Verified 'Recent .NET failure pattern covered by .NET runtime mismatch repair.'
            } elseif ($message -match 'MsiInstaller') {
                Add-NeedsApproval "Recent MSI installer event needs review: $($event.TimeCreated) / $($event.Id)"
            } else {
                Add-Skipped "Recent event recorded for review: $($event.ProviderName) $($event.Id) $($event.TimeCreated)"
            }
        }
    }
}

function Set-PlaybackRoute {
    if (-not (Test-ModuleEnabled 'Audio')) { return }
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
    if ($PlanOnly) {
        Add-Skipped 'PlanOnly: would enforce preferred playback route and volume only if audio repair was requested.'
        return
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
    foreach ($name in 'EventLog','DPS','NlaSvc','Netman','WlanSvc','BthServ','Dhcp','DeviceAssociationService','ShellHWDetection','Dnscache','Winmgmt','PlugPlay','Audiosrv','AudioEndpointBuilder','RtkAudioUniversalService') {
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

    if (Test-InternetConnectivity) {
        Add-Verified 'Internet ping connectivity works.'
    } else {
        Write-Log 'Internet ping connectivity was not verified.' 'WARN'
    }
    if (Test-DnsResolution) {
        Add-Verified 'DNS resolution works.'
    } else {
        Write-Log 'DNS resolution was not verified.' 'WARN'
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
    Write-Host 'Needs approval or manual review:'
    foreach ($item in $script:NeedsApprovalItems) { Write-Host " - $item" }
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

function Write-JsonReport {
    $report = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        Executable = Join-Path $Root 'bin\AudioBluetoothWifiRepair.exe'
        Script = $PSCommandPath
        Log = $LogPath
        PlanOnly = [bool]$PlanOnly
        DeepRepair = [bool]$DeepRepair
        Modules = @($Module)
        FixedOrEnforced = @($script:ChangedItems)
        Skipped = @($script:SkippedItems)
        NeedsApproval = @($script:NeedsApprovalItems)
        Verified = @($script:VerifiedItems)
        HadError = [bool]$script:HadError
    }
    $jsonPath = [System.IO.Path]::ChangeExtension($LogPath, '.json')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Log "JSON report: $jsonPath"
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
Repair-PnpDevices
Repair-DnsAndConnectivity
Repair-DotNetRuntimeMismatch
Repair-WindowsUpdateAndCrypto
Repair-StoreWingetAndAppx
Repair-PowerShellTerminalAndPath
Repair-SecurityFirewallAndDefender
Repair-DevicesInputUsbDisplayPrinterCamera
Repair-NetworkStackExpanded
Repair-RuntimesAndAppPrerequisites
Repair-EnvironmentTempAndAssociations
Invoke-RecentIssueScanner
Invoke-DeepRepairIfRequested
Set-PlaybackRoute
Verify-CurrentState
if ((Test-ModuleEnabled 'Audio') -and -not $PlanOnly -and -not $SelfTest) { Play-SoundTest }
Write-JsonReport
Write-Summary

if (-not $NoPause) {
    Write-Host ''
    Read-Host 'Press Enter to close'
}

if ($script:HadError) { exit 2 }
exit 0
