$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$Src = Join-Path $Root 'src\AudioBluetoothWifiRepairLauncher.cs'
$Out = Join-Path $Root 'bin\AudioBluetoothWifiRepair.exe'
$CompilerCandidates = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$Compiler = $CompilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Compiler) {
    throw 'Could not find .NET Framework csc.exe compiler.'
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
& $Compiler /nologo /target:exe /platform:anycpu /optimize+ "/out:$Out" $Src
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE."
}
Write-Host $Out
