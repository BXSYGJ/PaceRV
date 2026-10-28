[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReleaseRoot,[ValidateSet('V0','V1')][string]$Role='V0',[Parameter(Mandatory)][ValidatePattern('^COM[1-9][0-9]*$')][string]$PortName,[Parameter(Mandatory)][string]$OutputDirectory,[ValidateRange(20,600)][int]$TimeoutSeconds=120)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
$serial = $null
$stream = $null
try {
    . ([System.IO.Path]::Combine($PSScriptRoot,'Common.ps1'))
    $recipe = Get-ReleaseRecipe $ReleaseRoot
    $outputPath = Get-FullPath $OutputDirectory
    if (Test-Path -LiteralPath $outputPath) { throw 'Use a new output directory for each cold capture' }
    New-Item -ItemType Directory -Path $outputPath | Out-Null
    $raw = [System.IO.Path]::Combine($outputPath,'rawserial.bin')
    $stream = [System.IO.File]::Open($raw,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write)
    $serial = [System.IO.Ports.SerialPort]::new($PortName,[int]$recipe.uart_baud,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
    $serial.ReadTimeout = 250
    $serial.WriteTimeout = 1000
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $serial.Open()
    Write-Output 'UART open. Reset the freshly programmed board now. The script sends G after READY.'
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $sent = $false
    $finished = $false
    $buffer = [byte[]]::new(1024)
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($serial.BytesToRead -gt 0) {
            $count = $serial.Read($buffer,0,[Math]::Min($buffer.Length,$serial.BytesToRead))
            $stream.Write($buffer,0,$count)
            for ($i=0;$i -lt $count;$i++) {$bytes.Add($buffer[$i])}
            $text = [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
            if (-not $sent -and $text.Contains('ZGTC COREMARK READY')) {$serial.Write('G');$sent=$true}
            if ($text.Contains("ZGTC COREMARK FINISHED`n") -or $text.Contains("ZGTC COREMARK FINISHED`r`n")) {$finished=$true;break}
        } else { Start-Sleep -Milliseconds 50 }
    }
    $stream.Dispose();$stream=$null
    $serial.Close();$serial.Dispose();$serial=$null
    Write-Json @{Release=$recipe.release;Role=$Role;Port=$PortName;Baud=$recipe.uart_baud;Bytes=$bytes.Count;SentG=$sent;Finished=$finished;CaptureSeconds=$timer.Elapsed.TotalSeconds;RawSHA256=(Get-FileHash -LiteralPath $raw).Hash} ([System.IO.Path]::Combine($outputPath,'CAPTURE.json'))
    if (-not $finished) { throw 'Incomplete capture; raw bytes are retained and no pass is claimed' }
    & ([System.IO.Path]::Combine($PSScriptRoot,'Audit-BoardCapture.ps1')) -ReleaseRoot $ReleaseRoot -Role $Role -RawCapture $raw -OutputPath ([System.IO.Path]::Combine($outputPath,'UART_AUDIT.json'))
    if ($LASTEXITCODE -ne 0) { throw 'Board UART audit failed' }
    exit 0
} catch { Write-Error $_; exit 1 }
finally { if ($stream) {$stream.Dispose()}; if ($serial) {if($serial.IsOpen){$serial.Close()};$serial.Dispose()} }
