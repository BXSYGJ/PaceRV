[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_]+$')][string]$Project,
    [ValidateSet('compile','synthesize','dev_map','pnr','report_timing','gen_bit_stream')][string]$StopAfter='gen_bit_stream',
    [string]$PdsRoot=$env:PDS_ROOT,
    [switch]$PrepareOnly
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'
try {
    if (-not $PrepareOnly -and @(Get-Process -Name pds_shell -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'A PDS build is already running.'
    }
    $tool = [System.IO.Path]::Combine($PSScriptRoot,'build_project.py')
    $arguments = @($tool,$Project,'--stop-after',$StopAfter)
    if ($PrepareOnly) { $arguments += '--prepare-only' }
    if ($PdsRoot) { $arguments += @('--pds-root',[System.IO.Path]::GetFullPath($PdsRoot)) }
    & python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'PDS preparation or execution failed.' }
} catch { Write-Error $_; exit 1 }
