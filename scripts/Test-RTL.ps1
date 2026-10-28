[CmdletBinding()]
param([string]$OutputDirectory = [System.IO.Path]::Combine($PSScriptRoot, '..', '.work', 'rtl-tests'))
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    $root = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
    $output = [System.IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $iverilog = (Get-Command iverilog -ErrorAction Stop).Source
    $vvp = (Get-Command vvp -ErrorAction Stop).Source
    $source = [System.IO.Path]::Combine($root, 'cpu', 'H3_Retained_145125', 'source')
    $rtl = [System.IO.Path]::Combine($source, 'h3o-retained-token', 'rtl')
    $records = [System.Collections.Generic.List[object]]::new()
    $cases = @(@{ Name='multiplier'; Top='mul_retention_tb'; Parameters=@(); Files=@([System.IO.Path]::Combine($rtl,'rv32_muldiv.sv'), [System.IO.Path]::Combine($source,'mul_retention_tb.sv')); Marker='MUL_RETENTION_PASS' })
    foreach ($early in 0,1) {
        foreach ($retained in 0,1) {
            $cases += @{ Name=('core-e'+$early+'-r'+$retained); Top='core_token_tb'; Parameters=@('-P',('core_token_tb.EARLY_MODE='+$early),'-P',('core_token_tb.TOKEN_MODE='+$retained)); Files=@((Get-ChildItem -LiteralPath $rtl -Filter '*.sv' -File | Sort-Object Name).FullName) + @([System.IO.Path]::Combine($source,'core_token_tb.sv')); Marker=('CORE_TOKEN_PASS early='+$early+' mode='+$retained+' scenarios=11') }
        }
    }
    foreach ($case in $cases) {
        $executable = [System.IO.Path]::Combine($output, ($case.Name+'.vvp'))
        $compileLog = [System.IO.Path]::Combine($output, ($case.Name+'-compile.log'))
        $runLog = [System.IO.Path]::Combine($output, ($case.Name+'-run.log'))
        $arguments = @('-g2012','-s',$case.Top,'-o',$executable) + $case.Parameters + $case.Files
        & $iverilog @arguments *> $compileLog
        if ($LASTEXITCODE -ne 0) { throw ('Compilation failed: '+$compileLog) }
        & $vvp $executable *> $runLog
        if ($LASTEXITCODE -ne 0) { throw ('Simulation failed: '+$runLog) }
        $text = Get-Content -LiteralPath $runLog -Raw -Encoding utf8
        if (-not $text.Contains($case.Marker)) { throw ('Missing success marker: '+$runLog) }
        $resultLine = @($text -split "`n" | Where-Object { $_.Contains($case.Marker) })[0].Trim()
        $records.Add(@{Test=$case.Name;Result=$resultLine;ExitCode=0})
        Write-Output $resultLine
    }
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($output,'RESULT.json'), (@{Passed=$true;Tests=$records.ToArray();Tool=$iverilog} | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($true))
    Write-Output 'RTL tests passed: multiplier oracle and 44 core scenarios.'
    exit 0
} catch { Write-Error $_; exit 1 }
