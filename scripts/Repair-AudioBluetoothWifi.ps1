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
Repair-PnpDevices
Repair-DnsAndConnectivity
Repair-DotNetRuntimeMismatch
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
