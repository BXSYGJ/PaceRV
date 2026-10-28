[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [ValidateSet('V0','V1')][string]$Role = 'V0',
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$PdsRoot = $env:PDS_ROOT,
    [ValidateSet('RemoteLab','LocalBoard')][string]$UartPins = 'RemoteLab',
    [switch]$PrepareOnly
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    . ([System.IO.Path]::Combine($PSScriptRoot,'Common.ps1'))
    $releasePath = Get-FullPath $ReleaseRoot
    $outputPath = Get-FullPath $OutputDirectory
    if ($outputPath.StartsWith($releasePath+[System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase) -or $outputPath -eq $releasePath) { throw 'Build outside the frozen release directory' }
    if (Test-Path -LiteralPath $outputPath) { throw 'Use a new output directory for each build' }
    if ($outputPath -match '[{}\r\n]') { throw 'Tcl-incompatible characters in output path' }
    $recipe = Get-ReleaseRecipe $releasePath
    $image = $recipe.roles.$Role
    New-Item -ItemType Directory -Path $outputPath | Out-Null
    $inputPath = [System.IO.Path]::Combine($outputPath,'inputs')
    $frozenInputs = [System.IO.Path]::Combine($releasePath,$image.physical_inputs)
    Copy-Item -LiteralPath $frozenInputs -Destination $inputPath -Recurse
    $firmware = [System.IO.Path]::Combine($inputPath,'firmware.hex')
    Assert-FileHash $firmware $image.firmware_sha256
    $topPath = [System.IO.Path]::Combine($inputPath,'pds_soc_top.v')
    $top = Get-Content -LiteralPath $topPath -Raw -Encoding utf8
    $matchesInit = [regex]::Matches($top,'\.INIT_FILE\("[^"]+"\)')
    if ($matchesInit.Count -ne 1) { throw 'Expected exactly one physical firmware binding' }
    $replacement = '.INIT_FILE("' + $firmware.Replace([char]92,[char]47) + '")'
    $top = $top.Replace($matchesInit[0].Value,$replacement)
    [System.IO.File]::WriteAllText($topPath,$top,[System.Text.UTF8Encoding]::new($false))
    $synthesis = [System.IO.Path]::Combine($outputPath,'synthesis')
    $implementation = [System.IO.Path]::Combine($outputPath,'implementation')
    New-Item -ItemType Directory -Path $synthesis,$implementation | Out-Null
    $board = [System.IO.Path]::Combine($inputPath,'constraints','board.fdc').Replace([char]92,[char]47)
    $uartLeaf = if ($UartPins -eq 'RemoteLab') {'uart_remotelab.fdc'} else {'uart_board.fdc'}
    $uart = [System.IO.Path]::Combine($inputPath,'constraints',$uartLeaf).Replace([char]92,[char]47)
    $designs = @((Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($inputPath,'rtl')) -Filter '*.sv' -File | Sort-Object Name).FullName)
    $designs += $topPath
    $designs += [System.IO.Path]::Combine($inputPath,'fpga','rv32_pll.sv')
    $arch = 'set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676'
    $synLines = @($designs | ForEach-Object {'add_design {'+$_.Replace([char]92,[char]47)+'}'})
    $synLines += @(('add_constraint {'+$board+'}'),('add_constraint {'+$uart+'}'),$arch,'compile -system_verilog -top_module pds_soc_top','synthesize -ads -selected_syn_tool_opt 2')
    $netlist = [System.IO.Path]::Combine($implementation,'netlist.v').Replace([char]92,[char]47)
    $database = [System.IO.Path]::Combine($implementation,'source.adf').Replace([char]92,[char]47)
    $implLines = @(('add_design {'+$netlist+'}'),('add_constraint {'+$board+'}'),('add_constraint {'+$uart+'}'),$arch,'compile -system_verilog -top_module pds_soc_top',('dev_map -input_db_file {'+$database+'}'),('pnr '+$image.pnr_options),'report_timing','gen_bit_stream')
    foreach ($entry in @(@{Path=$synthesis;Lines=$synLines},@{Path=$implementation;Lines=$implLines})) {
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($entry.Path,'build.tcl'),($entry.Lines -join "`n")+"`n",[System.Text.UTF8Encoding]::new($false))
    }
    Write-Json @{Release=$recipe.release;Role=$Role;ClockHz=$recipe.clock_hz;UncertaintyNs=$recipe.clock_uncertainty_ns;UartPins=$UartPins;PreparedOnly=[bool]$PrepareOnly;OriginalManifestSHA256=$image.physical_manifest_sha256;Output=$outputPath} ([System.IO.Path]::Combine($outputPath,'PORTABLE_BUILD.json'))
    if ($PrepareOnly) { Write-Output "Prepared $($recipe.release) $Role at $outputPath"; exit 0 }
    if (-not $PdsRoot) { throw 'Set PDS_ROOT or supply -PdsRoot for installed PDS 2022.2-SP6.4' }
    $shell = [System.IO.Path]::Combine((Get-FullPath $PdsRoot),'bin','pds_shell.exe')
    if (-not (Test-Path -LiteralPath $shell)) { throw "PDS shell missing: $shell" }
    & $shell -file ([System.IO.Path]::Combine($synthesis,'build.tcl')) -work_dir $synthesis -project_name rvc153 *> ([System.IO.Path]::Combine($synthesis,'portable-console.log'))
    if ($LASTEXITCODE -ne 0) { throw 'PDS synthesis failed; inspect synthesis/portable-console.log' }
    Copy-Item -LiteralPath ([System.IO.Path]::Combine($synthesis,'synthesize','pds_soc_top_syn.vm')) -Destination $netlist
    Copy-Item -LiteralPath ([System.IO.Path]::Combine($synthesis,'synthesize','pds_soc_top_syn.adf')) -Destination $database
    & $shell -file ([System.IO.Path]::Combine($implementation,'build.tcl')) -work_dir $implementation -project_name rvc153 *> ([System.IO.Path]::Combine($implementation,'portable-console.log'))
    if ($LASTEXITCODE -ne 0) { throw 'PDS implementation failed; inspect implementation/portable-console.log' }
    & ([System.IO.Path]::Combine($PSScriptRoot,'Audit-Timing.ps1')) -ReportPath ([System.IO.Path]::Combine($implementation,'report_timing','pds_soc_top.rtr')) -OutputPath ([System.IO.Path]::Combine($outputPath,'TIMING_AUDIT.json'))
    if ($LASTEXITCODE -ne 0) { throw 'Timing audit failed' }
    Write-Output "Bitstream: $([System.IO.Path]::Combine($implementation,'generate_bitstream','pds_soc_top.sbit'))"
    exit 0
} catch { Write-Error $_; exit 1 }
