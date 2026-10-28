[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($true)
$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}
function Convert-ToWslPath([string]$Path) {
    $full = Get-FullPath $Path
    if ($full -notmatch '^([A-Za-z]):[/\\](.*)$') { throw "A local drive path is required: $full" }
    return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace([char]92,[char]47)
}
function Get-ReleaseRecipe([string]$Root) {
    $file = [System.IO.Path]::Combine((Get-FullPath $Root),'recipe.json')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Release recipe missing: $file" }
    return Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
}
function Resolve-RecipeArgument([string]$Argument,[string]$ReleaseRoot,[string]$OutputRoot,[string]$VendorRoot='') {
    $resolved = $Argument.Replace('{RELEASE}',(Convert-ToWslPath $ReleaseRoot)).Replace('{OUTPUT}',(Convert-ToWslPath $OutputRoot))
    if ($resolved.Contains('{VENDOR}')) {
        if (-not $VendorRoot) { throw 'Supply -NativeModelDirectory from your installed PDS simulation library.' }
        $resolved = $resolved.Replace('{VENDOR}',(Convert-ToWslPath $VendorRoot))
    }
    return $resolved
}
function Write-Json([object]$Value,[string]$Path) {
    [System.IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 30),[System.Text.UTF8Encoding]::new($true))
}
function Assert-FileHash([string]$Path,[string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected.ToLowerInvariant()) { throw "Hash mismatch: $Path" }
}
function Get-CoreMarkFrame([byte[]]$Bytes) {
    $text = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $start = 'ZGTC COREMARK START iterations=6000'
    $finish = 'ZGTC COREMARK FINISHED'
    $offset = $text.IndexOf($start,[System.StringComparison]::Ordinal)
    if ($offset -lt 0 -or $text.IndexOf($start,$offset+1,[System.StringComparison]::Ordinal) -ge 0) { throw 'Require exactly one complete CoreMark START marker' }
    $end = $text.IndexOf($finish,$offset,[System.StringComparison]::Ordinal)
    if ($end -lt 0 -or $text.IndexOf($finish,$end+1,[System.StringComparison]::Ordinal) -ge 0) { throw 'Require exactly one CoreMark FINISHED marker' }
    $end += $finish.Length
    $frame = $text.Substring($offset,$end-$offset)
    if ($frame.Contains([char]0)) { throw 'Embedded NUL byte in CoreMark frame' }
    $tail = $text.Substring($end)
    if ($tail.Trim().Length -ne 0) { throw 'Unexpected bytes after CoreMark FINISHED' }
    return $frame
}
