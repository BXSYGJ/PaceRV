[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReleaseRoot,[ValidateSet('V0','V1')][string]$Role='V0',[Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$GccLinuxPath)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    . ([System.IO.Path]::Combine($PSScriptRoot,'Common.ps1'))
    $releasePath = Get-FullPath $ReleaseRoot
    $outputPath = Get-FullPath $OutputDirectory
    if (Test-Path -LiteralPath $outputPath) { throw 'Use a new output directory' }
    if ($GccLinuxPath -notmatch '^/[^\r\n]+riscv-none-embed-gcc$') { throw 'Supply an absolute WSL Linux GCC path' }
    New-Item -ItemType Directory -Path $outputPath | Out-Null
    $recipe = Get-ReleaseRecipe $releasePath
    $image = $recipe.roles.$Role
    $argv = @($image.firmware_argv | ForEach-Object {Resolve-RecipeArgument $_ $releasePath $outputPath})
    & wsl.exe --cd (Convert-ToWslPath $outputPath) --exec $GccLinuxPath @argv *> ([System.IO.Path]::Combine($outputPath,'compiler.log'))
    if ($LASTEXITCODE -ne 0) { throw 'GCC failed; inspect compiler.log' }
    $objcopy = $GccLinuxPath.Substring(0,$GccLinuxPath.Length-3)+'objcopy'
    & wsl.exe --cd (Convert-ToWslPath $outputPath) --exec $objcopy -O binary 'firmware.elf' 'firmware.bin'
    if ($LASTEXITCODE -ne 0) { throw 'objcopy failed' }
    $binary = [System.IO.File]::ReadAllBytes([System.IO.Path]::Combine($outputPath,'firmware.bin'))
    if ($binary.Length -gt 49152) { throw 'Firmware overlaps reserved stack partition' }
    $padded = [byte[]]::new(65536)
    [Array]::Copy($binary,$padded,$binary.Length)
    $lines = for ($offset=0;$offset -lt $padded.Length;$offset+=4) { [BitConverter]::ToUInt32($padded,$offset).ToString('x8') }
    $hex = [System.IO.Path]::Combine($outputPath,'firmware.hex')
    [System.IO.File]::WriteAllText($hex,($lines -join "`n")+"`n",[System.Text.UTF8Encoding]::new($false))
    Assert-FileHash $hex $image.firmware_sha256
    Write-Json @{Release=$recipe.release;Role=$Role;FirmwareSHA256=$image.firmware_sha256;ExactFrozenHexMatch=$true;Gcc=$GccLinuxPath;Argv=$argv} ([System.IO.Path]::Combine($outputPath,'FIRMWARE_REPLAY.json'))
    Write-Output 'Rebuilt firmware matches the frozen HEX exactly.'
    exit 0
} catch { Write-Error $_; exit 1 }
