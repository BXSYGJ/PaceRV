[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReportPath,[Parameter(Mandatory)][string]$OutputPath)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    . ([System.IO.Path]::Combine($PSScriptRoot,'Common.ps1'))
    $text = Get-Content -LiteralPath $ReportPath -Raw -Encoding utf8
    $checks = [ordered]@{}
    foreach ($corner in @('Slow','Fast')) {
        foreach ($kind in @('Setup','Hold','Recovery','Removal','Minimum Pulse Width')) {
            $pattern = [regex]::Escape($kind+' Summary('+ $corner+' Corner):')+'(?<body>.*?)(?=\r?\n=+)'
            $section = [regex]::Match($text,$pattern,[System.Text.RegularExpressions.RegexOptions]::Singleline)
            if (-not $section.Success) { throw "Missing timing section $kind/$corner" }
            $rows = [regex]::Matches($section.Groups['body'].Value,'(?m)^\s*([+-]?\d+\.\d+)\s+([+-]?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$')
            if ($rows.Count -eq 0) { throw "No timing endpoints $kind/$corner" }
            $slacks = @($rows | ForEach-Object {[double]::Parse($_.Groups[1].Value,[System.Globalization.CultureInfo]::InvariantCulture)})
            $failing = ($rows | ForEach-Object {[int]$_.Groups[3].Value} | Measure-Object -Sum).Sum
            $minimum = ($slacks | Measure-Object -Minimum).Minimum
            $checks[$kind+'_'+$corner] = @{MinimumSlackNs=$minimum;FailingEndpoints=$failing;ClockRows=$rows.Count}
            if ($minimum -lt 0 -or $failing -ne 0) { throw "Timing did not close: $kind/$corner" }
        }
    }
    $uncertainties = [regex]::Matches($text,'clock uncertainty\s+(-?\d+\.\d+)')
    if ($uncertainties.Count -eq 0) { throw 'No reported clock uncertainty' }
    $values = @($uncertainties | ForEach-Object {[Math]::Abs([double]::Parse($_.Groups[1].Value,[System.Globalization.CultureInfo]::InvariantCulture))})
    if (-not ($values | Where-Object {[Math]::Abs($_-0.150) -lt 0.00001})) { throw 'Required 0.150 ns clock uncertainty is absent' }
    Write-Json @{Passed=$true;Checks=$checks;ReportSHA256=(Get-FileHash -LiteralPath $ReportPath).Hash;Scope='All reported internal/generated clocks; external GPIO/UART timing is not specified'} $OutputPath
    Write-Output 'All ten internal timing checks passed; 0.150 ns uncertainty is reported.'
    exit 0
} catch { Write-Error $_; exit 1 }
