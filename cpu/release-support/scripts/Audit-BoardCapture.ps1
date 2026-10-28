[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReleaseRoot,[ValidateSet('V0','V1')][string]$Role='V0',[Parameter(Mandatory)][string]$RawCapture,[Parameter(Mandatory)][string]$OutputPath)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    . ([System.IO.Path]::Combine($PSScriptRoot,'Common.ps1'))
    $recipe = Get-ReleaseRecipe $ReleaseRoot
    $image = $recipe.roles.$Role
    $reference = [System.IO.Path]::Combine((Get-FullPath $ReleaseRoot),$image.reference_uart)
    Assert-FileHash $reference $image.reference_uart_sha256
    $expected = Get-CoreMarkFrame ([System.IO.File]::ReadAllBytes($reference))
    $actual = Get-CoreMarkFrame ([System.IO.File]::ReadAllBytes((Get-FullPath $RawCapture)))
    if ($actual -cne $expected) { throw 'Unmodified START-to-FINISHED bytes differ from the frozen reference' }
    $counts = [regex]::Match($actual,'cycles_hex=([0-9a-fA-F]{16}) retired_hex=([0-9a-fA-F]{16}) clock_hz=(\d+)')
    if (-not $counts.Success) { throw 'Missing 64-bit measurement counters' }
    $cycles = [Convert]::ToUInt64($counts.Groups[1].Value,16)
    $retired = [Convert]::ToUInt64($counts.Groups[2].Value,16)
    $clock = [long]$counts.Groups[3].Value
    if ($clock -ne $recipe.clock_hz) { throw 'Firmware clock metadata differs from the selected release' }
    Write-Json @{Passed=$true;Release=$recipe.release;Role=$Role;ExactFrameMatch=$true;Cycles=$cycles;Retired=$retired;ConfiguredClockHz=$clock;CoreMarkPerMHz=6000000000.0/$cycles;CoreMark=6000.0*$clock/$cycles;RawSHA256=(Get-FileHash -LiteralPath $RawCapture).Hash;Scope='Configured frequency; no external oscillator measurement'} $OutputPath
    Write-Output "Exact full frame passed: $cycles cycles; $retired retired instructions."
    exit 0
} catch { Write-Error $_; exit 1 }
