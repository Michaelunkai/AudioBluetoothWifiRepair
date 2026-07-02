# AudioBluetoothWifiRepair

Durable skip-aware repair tool for this machine's recurring Windows sound, Bluetooth, WiFi, diagnostics, endpoint routing, runtime, service, device, shell, Store, network, and Windows health failures.

## Executable

Run:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe
```

The executable relaunches elevated if needed, then runs `scripts\Repair-AudioBluetoothWifi.ps1`.

Useful switches:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe -SelfTest -NoSoundTest -NoPause
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe -PlanOnly -NoSoundTest -NoPause
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe -DeepRepair -NoSoundTest -NoPause
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe -Module Audio,Network -NoSoundTest -NoPause
```

## What It Repairs

- `EventLog` automatic and running.
- `DPS` automatic and running.
- `NlaSvc` automatic and running.
- `Netman` enabled and started.
- `WlanSvc` automatic and running.
- `BthServ` enabled and running.
- Current `BluetoothUserService_*` instances started when present.
- `Dhcp` automatic and running.
- `DeviceAssociationService` automatic and running.
- `ShellHWDetection` automatic and running.
- `DeviceInstall` enabled as demand start.
- `Dnscache` automatic and running.
- `Winmgmt` automatic and running.
- `PlugPlay` enabled and running.
- `Audiosrv` automatic and running.
- `AudioEndpointBuilder` automatic and running.
- `RtkAudioUniversalService` automatic and running.
- `NVHDA` enabled as demand start.
- `NvVAD_WaveExtensible` enabled as demand start.
- NVIDIA Display Container restored to automatic and running when installed.
- `Wi-Fi` and `Ethernet` interfaces enabled if they were administratively disabled.
- Disabled audio, Bluetooth, and network Plug and Play devices re-enabled when found.
- DNS cache flushed and DNS registration refreshed only when DNS resolution is broken.
- DHCP lease renewed only when internet connectivity is broken and no IPv4 address is detected.
- Missing .NET preview shared runtimes, SDK Windows runtime-target files, and x64 install registry metadata are restored additively when a machine-wide SDK exists without its matching payload, which prevents `dotnet.exe - System Error` hard-error popups caused by `FrameworkMissingFailure` and keeps `dotnet --info` healthy.
- Windows Update, BITS, Update Orchestrator, Windows Modules Installer, MSI Installer, Cryptographic Services, and Windows Time service startup state are repaired only when current state is wrong.
- Cryptographic Services and BITS are started only when stopped, so certificate, update, and package validation failures can recover without repeated restarts.
- Pending reboot registry markers are detected and reported for approval instead of forcing a reboot.
- Microsoft Store/AppX infrastructure, Client License Service, Install Service, Gaming Services, winget sources, Microsoft Store registration, and WebView2 registration are checked; missing or broken user-impacting app repairs are reported without destructive resets.
- PowerShell profile syntax, Windows Terminal availability, and safe user PATH entries for System32, Windows, WindowsPowerShell, WindowsApps, user bin, and dotnet are checked and repaired additively.
- Common developer/runtime commands are checked: `git`, `python`, `py`, `node`, `npm`, `ssh`, and `dotnet`.
- Base Filtering Engine, Windows Firewall, Windows Security Center, Defender services, Credential Manager, and elevation broker services are checked and repaired when disabled or stopped.
- Firewall profile health is verified without weakening firewall policy.
- USB, HID, keyboard, mouse, monitor, display, camera, media, audio endpoint, and printer Plug and Play classes are checked; only disabled devices are automatically re-enabled.
- Spooler, camera frame server, clipboard user service, font cache, HID service, tablet input, and power service state are checked and repaired only when needed.
- Workstation, Server, NetBIOS helper, RDP-related services, and IP Helper are checked for safe startup/running state.
- WinHTTP proxy, user proxy settings, and VPN-like adapters are detected and reported without destructive reset.
- VC++ runtime registry, DirectX/XInput presence, and default browser association are checked.
- `TEMP`, `TMP`, `ComSpec`, `Path`, temp directories, and core file associations for `.exe`, `.lnk`, `.cmd`, `.bat`, `.ps1`, `.msi`, and `.zip` are checked; missing associations are reported for review instead of blindly rewriting registry state.
- Recent Application event log failures for .NET Runtime, Application Error, Application Popup, and MSI Installer are scanned and folded into the report.
- Optional deep repair mode runs non-destructive health checks only: DISM ScanHealth, SFC verifyonly, WMI repository verification, and disk dirty query.
- Default playback route repaired through the proven monitor endpoints, ending on `M27UP`.
- System audio unmuted and volume set to 87.5%.
- Audio endpoint, Bluetooth, WiFi, Ethernet, DNS, internet connectivity, and service state verified.
- Already-good services and drivers are detected and logged as OK/SKIP instead of being restarted repeatedly.
- Every repair action is gated by current-state detection and logs OK, SKIP, FIX, VERIFY, APPROVAL, or ERROR.

## Logs

Each run writes a timestamped log to:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\logs
```

Each run also writes a matching JSON report in the same directory.

## Self-Test

Run without playing sound:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe -SelfTest -NoSoundTest -NoPause
```

## Rebuild

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File F:\study\Windows\Repair\AudioBluetoothWifiRepair\build.ps1
```
