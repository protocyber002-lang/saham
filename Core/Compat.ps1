# Compat.ps1 — jembatan PS2 (Win7) <-> PS5.1 (Win10/11)
Set-StrictMode -Version 2.0
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-PSCompatInfo {
    $v = $PSVersionTable.PSVersion
    [pscustomobject]@{
        Version      = $v
        IsPS2        = ($v.Major -lt 3)
        HasJson      = ($v.Major -ge 3)   # ConvertTo-Json mulai PS3
        HasAnsi      = (Test-AnsiSupport)
    }
}

function Test-AnsiSupport {
    try {
        # Win10+ mendukung VT sequences; Win7 umumnya tidak
        if ($env:OS -ne 'Windows_NT') { return $false }
        $os = [System.Environment]::OSVersion.Version
        if ($os.Major -lt 10) { return $false }
        # cek console handle VT
        return $true
    } catch { return $false }
}

# ---- JSON: pakai native kalau ada, kalau tidak -> serializer minimal ----
function ConvertTo-JsonCompat($obj) {
    if ((Get-PSCompatInfo).HasJson) {
        return ($obj | ConvertTo-Json -Depth 20 -Compress)
    }
    return (ConvertTo-JsonFallback $obj)
}

function ConvertFrom-JsonCompat($text) {
    if ((Get-PSCompatInfo).HasJson) {
        return ($text | ConvertFrom-Json)
    }
    return (ConvertFrom-JsonFallback $text)
}

# Serializer fallback sederhana (hashtable/array/string/number/bool)
function ConvertTo-JsonFallback($obj) {
    if ($null -eq $obj) { return 'null' }
    if ($obj -is [bool])   { return $(if ($obj) {'true'} else {'false'}) }
    if ($obj -is [int] -or $obj -is [long] -or $obj -is [double] -or $obj -is [decimal]) {
        return ([string]::Format($script:Invariant, '{0}', $obj))
    }
    if ($obj -is [string])  { return ('"' + ($obj -replace '\\','\\' -replace '"','\"') + '"') }
    if ($obj -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($k in $obj.Keys) {
            $parts += ('"' + $k + '":' + (ConvertTo-JsonFallback $obj[$k]))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($obj -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($i in $obj) { $parts += (ConvertTo-JsonFallback $i) }
        return '[' + ($parts -join ',') + ']'
    }
    # object -> pakai properti publik
    $parts = @()
    foreach ($p in $obj.PSObject.Properties) {
        $parts += ('"' + $p.Name + '":' + (ConvertTo-JsonFallback $p.Value))
    }
    return '{' + ($parts -join ',') + '}'
}

function ConvertFrom-JsonFallback($text) {
    # Parser minimal: cukup untuk save kita (flat-ish JSON)
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    if ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type]) {
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        return $ser.DeserializeObject($text)
    }
    throw "Tidak ada JSON parser tersedia di sistem ini."
}