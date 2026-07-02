# AudioBluetoothWifiRepair

Durable repair tool for this machine's recurring Windows sound, Bluetooth, WiFi, diagnostics, and endpoint routing failures.

## Executable

Run:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe
```

The executable relaunches elevated if needed, then runs `scripts\Repair-AudioBluetoothWifi.ps1`.

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
- Default playback route repaired through the proven monitor endpoints, ending on `M27UP`.
- System audio unmuted and volume set to 87.5%.
- Audio endpoint, Bluetooth, WiFi, Ethernet, DNS, internet connectivity, and service state verified.
- Already-good services and drivers are detected and logged as OK/SKIP instead of being restarted repeatedly.

## Logs

Each run writes a timestamped log to:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\logs
```

## Self-Test

Run without playing sound:

```powershell
F:\study\Windows\Repair\AudioBluetoothWifiRepair\bin\AudioBluetoothWifiRepair.exe -SelfTest -NoSoundTest -NoPause
```

## Rebuild

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File F:\study\Windows\Repair\AudioBluetoothWifiRepair\build.ps1
```
