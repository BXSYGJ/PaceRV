[CmdletBinding()]
param([string]$OutputDirectory = [System.IO.Path]::Combine($PSScriptRoot, '..', '.work', 'archive-audit'))
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    $root = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
    $output = [System.IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $scripts = [System.IO.Path]::Combine($root,'cpu','release-support','scripts')
    . ([System.IO.Path]::Combine($scripts,'Common.ps1'))
    $hashes = 0
    foreach ($entry in (Import-Csv -LiteralPath ([System.IO.Path]::Combine($root,'FILE_MANIFEST.csv')))) {
        $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root,$entry.Path))
        if (-not $path.StartsWith($root+[System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path leaves repository.' }
        Assert-FileHash $path $entry.SHA256
        if ((Get-Item -LiteralPath $path).Length -ne [long]$entry.Bytes) { throw ('Size mismatch: '+$entry.Path) }
        $hashes++
    }
    $captures=0; $timing=0; $bindings=0; $external=0
    foreach ($name in @('H3_Base_145125','H3_Retained_145125')) {
        $release = [System.IO.Path]::Combine($root,'cpu',$name)
        $recipe = Get-ReleaseRecipe $release
        $performance = Get-Content -LiteralPath ([System.IO.Path]::Combine($release,'PERFORMANCE.json')) -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($binding in @($recipe.source_copies)+@($recipe.simulation.sources)) {
            Assert-FileHash ([System.IO.Path]::Combine($release,$binding.portable)) $binding.sha256
            $bindings++
        }
        $external += @($recipe.simulation.external_models).Count
        foreach ($role in @('V0','V1')) {
            $image = $recipe.roles.$role
            Assert-FileHash ([System.IO.Path]::Combine($release,$image.bitstream)) $image.bitstream_sha256
            Assert-FileHash ([System.IO.Path]::Combine($release,$image.firmware_hex)) $image.firmware_sha256
            $expected = $performance | Where-Object configuration -eq $role
            foreach ($capture in $image.board_originals) {
                $raw = [System.IO.Path]::Combine($release,$capture.portable)
                Assert-FileHash $raw $capture.sha256
                $audit = [System.IO.Path]::Combine($output,($name+'-'+$role+'-'+$captures+'.json'))
                & ([System.IO.Path]::Combine($scripts,'Audit-BoardCapture.ps1')) -ReleaseRoot $release -Role $role -RawCapture $raw -OutputPath $audit
                if ($LASTEXITCODE -ne 0) { throw 'Board-frame audit failed.' }
                $actual = Get-Content -LiteralPath $audit -Raw -Encoding utf8 | ConvertFrom-Json
                if ($actual.Cycles -ne $expected.cycles -or $actual.Retired -ne $expected.retired -or [Math]::Abs($actual.CoreMarkPerMHz-$expected.coremark_per_mhz) -gt 0.000000001) { throw 'Performance counters differ.' }
                $captures++
            }
            $physical = [System.IO.Path]::Combine($release,'evidence','physical',$role,'implementation')
            & ([System.IO.Path]::Combine($scripts,'Audit-Timing.ps1')) -ReportPath ([System.IO.Path]::Combine($physical,'report_timing','pds_soc_top.rtr')) -OutputPath ([System.IO.Path]::Combine($output,($name+'-'+$role+'-timing.json')))
            if ($LASTEXITCODE -ne 0) { throw 'Timing audit failed.' }
            $summary = Get-Content -LiteralPath ([System.IO.Path]::Combine($physical,'resource-timing-summary.json')) -Raw -Encoding utf8 | ConvertFrom-Json
            if (-not $summary.constraints_met -or $summary.clock_hz -ne $recipe.clock_hz -or $summary.resources.post_route_luts -ne $expected.lut -or $summary.resources.post_route_ffs -ne $expected.ff) { throw 'Physical measurements differ.' }
            $timing++
        }
    }
    $parsed=0
    $workPattern = '*'+[System.IO.Path]::DirectorySeparatorChar+'.work'+[System.IO.Path]::DirectorySeparatorChar+'*'
    foreach ($file in (Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File | Where-Object FullName -NotLike $workPattern)) {
        $tokens=$null; $errors=$null
        $null=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw ('PowerShell syntax errors: '+$file.Name) }
        $parsed++
    }
    $record=@{Passed=$true;Files=$hashes;SourceBindings=$bindings;BoardCaptures=$captures;TimingReports=$timing;ExternalModelBindings=$external;PowerShellScriptsParsed=$parsed;Scope='Offline evidence and integrity audit; external PDS models are not distributed.'}
    Write-Json $record ([System.IO.Path]::Combine($output,'RESULT.json'))
    Write-Output ('Archive audit passed: {0} files, {1} source bindings, {2} board captures, {3} timing reports.' -f $hashes,$bindings,$captures,$timing)
    exit 0
} catch { Write-Error $_; exit 1 }
