[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReleaseRoot,[ValidateSet('V0','V1')][string]$Role='V0',[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$VerilatorLinuxPath,[Parameter(Mandatory)][string]$NativeModelDirectory,[string]$VerilatorIncludeLinux,[switch]$CompileOnly,[ValidateRange(1,2400000000)][long]$CycleBudget=2400000000)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    . ([System.IO.Path]::Combine($PSScriptRoot,'Common.ps1'))
    $releasePath = Get-FullPath $ReleaseRoot
    $outputPath = Get-FullPath $OutputDirectory
    if (Test-Path -LiteralPath $outputPath) { throw 'Use a new output directory' }
    if ($VerilatorLinuxPath -notmatch '^/[^\r\n]+/verilator$') { throw 'Supply an absolute WSL Verilator executable path' }
    New-Item -ItemType Directory -Path $outputPath | Out-Null
    $recipe = Get-ReleaseRecipe $releasePath
    foreach ($model in $recipe.simulation.external_models) {
        Assert-FileHash ([System.IO.Path]::Combine((Get-FullPath $NativeModelDirectory),$model.name)) $model.sha256
    }
    $argv = @($recipe.simulation.argv | ForEach-Object {Resolve-RecipeArgument $_ $releasePath $outputPath $NativeModelDirectory})
    $toolArgv = @($VerilatorLinuxPath) + $argv
    if ($VerilatorIncludeLinux) {$toolArgv = @('/usr/bin/env',('VERILATOR_ROOT='+$VerilatorIncludeLinux))+$toolArgv}
    & wsl.exe --cd (Convert-ToWslPath $outputPath) --exec @toolArgv *> ([System.IO.Path]::Combine($outputPath,'compile.log'))
    if ($LASTEXITCODE -ne 0) { throw 'Simulation compile failed; inspect compile.log' }
    $exe = [System.IO.Path]::Combine($outputPath,'objects','Vrv32_observed_soc')
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Compiled simulator missing' }
    Write-Json @{Release=$recipe.release;Verilator=$VerilatorLinuxPath;Argv=$argv;CompileOnly=[bool]$CompileOnly;TimedNativeMemory=$recipe.simulation.timed_native_memory} ([System.IO.Path]::Combine($outputPath,'SIMULATION_REPLAY.json'))
    if ($CompileOnly) { Write-Output 'Simulator compiled successfully.'; exit 0 }
    Copy-Item -LiteralPath ([System.IO.Path]::Combine($releasePath,$recipe.roles.$Role.firmware_hex)) -Destination ([System.IO.Path]::Combine($outputPath,'firmware.hex'))
    $uart = [System.IO.Path]::Combine($outputPath,'uart.log')
    & wsl.exe --cd (Convert-ToWslPath $outputPath) --exec (Convert-ToWslPath $exe) (Convert-ToWslPath $uart) $CycleBudget.ToString() *> ([System.IO.Path]::Combine($outputPath,'simulation.log'))
    if ($LASTEXITCODE -ne 0) { throw 'Simulation failed or exceeded the selected cycle budget' }
    & ([System.IO.Path]::Combine($PSScriptRoot,'Audit-BoardCapture.ps1')) -ReleaseRoot $releasePath -Role $Role -RawCapture $uart -OutputPath ([System.IO.Path]::Combine($outputPath,'UART_AUDIT.json'))
    if ($LASTEXITCODE -ne 0) { throw 'UART audit failed' }
    exit 0
} catch { Write-Error $_; exit 1 }
