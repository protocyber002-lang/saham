# SaveSystem.ps1 - save + offline + session history + multi-profile
Set-StrictMode -Version 2.0
$Global:ProfileMutexes = @()
$script:CurrentLockPath = $null

$script:ProfilesDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\profiles'))
$script:SavePath    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\save.json'))
$script:ActiveProfile = $null
$Global:SessionStartPlaytime = 0.0

function Set-ActiveProfile($name) {
    if (-not $name) { throw "Nama profil kosong." }
    if ($name -notmatch '^[A-Za-z0-9_\-]{1,32}$') {
        throw "Nama profil hanya boleh huruf/angka/_/-, maks 32 karakter."
    }
    $script:ActiveProfile = $name
    $path = Join-Path $script:ProfilesDir ($name + '.json')
    $script:SavePath = [System.IO.Path]::GetFullPath($path)
    if (-not (Test-Path $script:ProfilesDir)) {
        New-Item -ItemType Directory -Path $script:ProfilesDir -Force | Out-Null
    }
    return $script:SavePath
}

function Get-ActiveProfile { return $script:ActiveProfile }
function Get-ProfilesDir  { return $script:ProfilesDir }

function Get-ProfileList {
    $list = @()
    if (-not (Test-Path $script:ProfilesDir)) { return $list }
    $files = Get-ChildItem -Path $script:ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $money = 0.0
        $last = ''
        $playtime = 0.0
        $level = 1
        $netWorth = 0.0
        try {
            $raw = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            $obj = ConvertFrom-JsonCompat $raw
            $h   = ConvertTo-Hashtable $obj
            
            if ($h.ContainsKey('Player')) {
                if ($h.Player.ContainsKey('Money')) { $money = [double]$h.Player.Money }
                if ($h.Player.ContainsKey('PlaytimeSec')) { $playtime = [double]$h.Player.PlaytimeSec }
            }
            if ($h.ContainsKey('Sectors') -and $h.Sectors.ContainsKey('Clicker')) {
                if ($h.Sectors.Clicker.ContainsKey('Level')) { $level = [int]$h.Sectors.Clicker.Level }
            }
            if ($h.ContainsKey('Meta') -and $h.Meta.ContainsKey('LastSaveUtc')) { $last = [string]$h.Meta.LastSaveUtc }
            
            # Hitung Net Worth (butuh fungsi dari Engine, atau hitung kasar jika tidak tersedia)
            $assetVal = 0.0
            if (Get-Command Get-TotalAssetValue -ErrorAction SilentlyContinue) {
                $assetVal = Get-TotalAssetValue $h
            }
            $netWorth = $money + $assetVal
        } catch { }
        
        $list += [pscustomobject]@{
            Name        = $name
            Money       = $money
            Playtime    = $playtime
            Level       = $level
            NetWorth    = $netWorth
            LastSaveUtc = $last
            Path        = $f.FullName
        }
    }
    return @($list | Sort-Object Name)
}

function New-Profile($name) {
    if ($name -notmatch '^[A-Za-z0-9_\-]{1,32}$') {
        throw "Nama profil hanya boleh huruf/angka/_/-, maks 32 karakter."
    }
    $path = Join-Path $script:ProfilesDir ($name + '.json')
    if (Test-Path $path) { throw ("Profil '{0}' sudah ada." -f $name) }
    Set-ActiveProfile $name | Out-Null
    $Global:GameState = New-GameState
    SaveSystem.Save
    return $path
}


# --- PROFILE LOCK ---
function Get-ProfileLockPath($name) {
    return (Join-Path $script:ProfilesDir ($name + '.lock'))
}

function Get-LockOwnerMessage($name, $lockPath) {
    $owner = "jendela lain"
    try {
        $parts = ([System.IO.File]::ReadAllText($lockPath, [System.Text.Encoding]::UTF8).Trim() -split '\|')
        if ($parts.Count -ge 5) {
            if ($parts[4] -eq 'GUI') { $owner = "DashboardGUI (jendela lain)" }
            elseif ($parts[4] -eq 'TUI') { $owner = "TUI" }
        }
    } catch { }
    return ("Profil '{0}' sedang berjalan di {1}. Tutup dulu, lalu coba lagi (satu profil hanya bisa dibuka di satu tempat: GUI atau TUI)." -f $name, $owner)
}

function Test-ProcessAlive($pid) {
    if (-not $pid) { return $false }
    try {
        $p = Get-Process -Id $pid -ErrorAction Stop
        return ($null -ne $p)
    } catch { return $false }
}

function Get-ProfileLockInfo($name) {
    $lp = Get-ProfileLockPath $name
    if (-not (Test-Path $lp)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($lp, [System.Text.Encoding]::UTF8).Trim()
        $parts = $raw -split '\|'
        $pid = 0
        [int]::TryParse($parts[0], [ref]$pid) | Out-Null
        $host_ = ''
        if ($parts.Count -gt 1) { $host_ = $parts[1] }
        if (-not (Test-ProcessAlive $pid)) {
            Remove-Item $lp -Force -ErrorAction SilentlyContinue
            return $null
        }
        return [pscustomobject]@{ Pid = $pid; Host = $host_; Path = $lp }
    } catch {
        Remove-Item $lp -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Acquire-ProfileLock($name, $app = "TUI") {
    $lp = Get-ProfileLockPath $name
    $sessionGuid = [System.Guid]::NewGuid().ToString()
    $content = ("{0}|{1}|{2}|{3}|{4}" -f $PID, $env:COMPUTERNAME, [DateTime]::UtcNow.ToString('o'), $sessionGuid, $app)

    # Coba buat file lock secara eksklusif (jika sudah ada, gagal)
    try {
        $fs = [System.IO.File]::Open($lp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Close()
        $fs.Dispose()
    } catch {
        # File sudah ada. Cek apakah valid atau stale.
        $existing = Get-ProfileLockInfo $name
        if ($existing) {
            throw (Get-LockOwnerMessage $name $lp)
        } else {
            # Stale lock, paksa hapus dan coba lagi
            Remove-Item $lp -Force -ErrorAction SilentlyContinue
            $fs = [System.IO.File]::Open($lp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close()
            $fs.Dispose()
        }
    }

    $script:CurrentLockPath = $lp
    return $lp
}

function Release-ProfileLock {
    foreach ($m in $Global:ProfileMutexes) {
        try {
            $m.ReleaseMutex()
            $m.Dispose()
        } catch { }
    }
    $Global:ProfileMutexes = @()
}
function SaveSystem.Save {
    $state = $Global:GameState
    if ($null -eq $state) { return }
    $state.Meta.LastSaveUtc = [DateTime]::UtcNow.ToString('o')
    $state.Meta.SaveVersion = $Global:Config.SaveVersion

    $json = ConvertTo-JsonCompat $state
    $dir  = Split-Path $script:SavePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $tmp = "$script:SavePath.tmp"
    $bak = "$script:SavePath.bak"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    if (Test-Path $script:SavePath) { Copy-Item $script:SavePath $bak -Force }
    Move-Item $tmp $script:SavePath -Force
}

function Record-Session($reason) {
    $state = $Global:GameState
    if ($null -eq $state) { return }
    if (-not $state.Meta.ContainsKey('Sessions') -or $null -eq $state.Meta.Sessions) {
        $state.Meta.Sessions = @()
    }
    $sessionPlay = [double]$state.Player.PlaytimeSec - [double]$Global:SessionStartPlaytime
    if ($sessionPlay -lt 0) { $sessionPlay = 0 }
    $entry = @{
        ExitUtc     = [DateTime]::UtcNow.ToString('o')
        PlaytimeSec = [Math]::Round($sessionPlay, 1)
        MoneyEnd    = [double]$state.Player.Money
        AssetEnd    = [double](Get-TotalAssetValue $state)
        NetWorth    = [double]$state.Player.Money + (Get-TotalAssetValue $state)
        Clicks      = [int]$state.Player.Clicks
        MathSolved  = [int]$state.Player.MathSolved
        ClickerLvl  = [int]$state.Sectors.Clicker.Level
        AutoRate    = [double]$state.Sectors.Clicker.AutoRate
        Reason      = [string]$reason
    }
    $new = @($entry)
    foreach ($e in $state.Meta.Sessions) { $new += $e }
    if ($new.Count -gt 10) { $new = $new[0..9] }
    $state.Meta.Sessions = $new
}

function SaveSystem.Load {
    return (Load-StateFromDisk -allowBackup $true)
}

function Load-StateFromDisk([bool]$allowBackup) {
    if (-not (Test-Path $script:SavePath)) { return (New-GameState) }
    try {
        $json  = [System.IO.File]::ReadAllText($script:SavePath, [System.Text.Encoding]::UTF8)
        $obj   = ConvertFrom-JsonCompat $json
        $state = ConvertTo-Hashtable $obj

        if (-not (Test-SaveSchema $state)) { throw "Skema save tidak valid." }
        $state = Migrate-State $state

        $offline = 0.0
        try {
            $last = [DateTime]::Parse($state.Meta.LastSaveUtc, $script:Invariant, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $offline = ([DateTime]::UtcNow - $last).TotalSeconds
        } catch { $offline = 0.0 }
        if ($offline -lt 0) { $offline = 0 }
        if ($offline -gt ($Global:Config.OfflineCapHours * 3600)) { $offline = $Global:Config.OfflineCapHours * 3600 }

        if ($offline -ge $Global:Config.OfflineMinSeconds) {
            $rate   = Get-OfflineRate $state
            $earned = $rate * $offline
            if ($earned -gt 0) {
                $state.Player.Money += $earned
                Write-Host ("Offline {0:N1}s x {1:N2}/s = +{2:N2} money" -f $offline, $rate, $earned) -ForegroundColor Yellow
            } else {
                Write-Host ("Offline {0:N1}s, tidak ada income pasif." -f $offline) -ForegroundColor DarkYellow
            }
        }

        if ($state.Meta.ContainsKey('Sessions') -and $state.Meta.Sessions.Count -gt 0) {
            Write-Host ""
            Write-Host "=== Riwayat Sesi Terakhir ===" -ForegroundColor Cyan
            $shown = 0
            foreach ($e in $state.Meta.Sessions) {
                if ($shown -ge 3) { break }
                try {
                    $t = [DateTime]::Parse($e.ExitUtc, $script:Invariant, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    $local = $t.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                    $assetVal = 0.0
                    if ($e.ContainsKey('AssetEnd')) { $assetVal = [double]$e.AssetEnd }
                    $nw = [double]$e.MoneyEnd
                    if ($e.ContainsKey('NetWorth')) { $nw = [double]$e.NetWorth }
                    $line = "  [{0}] {1,7:N1}s  cash={2,10:N2}  asset={3,10:N2}  net={4,10:N2}  clkLvl={5,3}  auto={6:N2}/s" -f `
                        $local, $e.PlaytimeSec, $e.MoneyEnd, $assetVal, $nw, $e.ClickerLvl, $e.AutoRate
                    Write-Host $line -ForegroundColor DarkGray
                } catch { }
                $shown++
            }
            if ($state.Meta.Sessions.Count -gt 3) {
                Write-Host ("  ... dan {0} sesi lain" -f ($state.Meta.Sessions.Count - 3)) -ForegroundColor DarkGray
            }
            Write-Host ""
        }

        $Global:SessionStartPlaytime = [double]$state.Player.PlaytimeSec
        return $state
    } catch {
        Write-Host ("Save rusak: " + $_.Exception.Message) -ForegroundColor Red
        if ($allowBackup -and (Test-Path "$script:SavePath.bak")) {
            Write-Host "Mencoba backup..." -ForegroundColor Yellow
            Copy-Item "$script:SavePath.bak" $script:SavePath -Force
            return (Load-StateFromDisk -allowBackup $false)
        }
        Write-Host "Membuat save baru." -ForegroundColor Yellow
        return (New-GameState)
    }
}

function Migrate-State($state) {
    if (-not $state.ContainsKey('Meta'))    { $state.Meta = @{} }
    if (-not $state.ContainsKey('Player'))  { $state.Player = @{ Money=0.0; Prestige=0; Clicks=0; MathSolved=0; PlaytimeSec=0.0 } }
    if (-not $state.ContainsKey('Sectors')) { $state.Sectors = @{} }
    if (-not $state.ContainsKey('Flags'))   { $state.Flags = @{} }
    if (-not $state.ContainsKey('Upgrades')){ $state.Upgrades = @{} }

    if (-not $state.Sectors.ContainsKey('Clicker')) {
        $state.Sectors.Clicker = @{ Level = 1; AutoRate = 0.0 }
    } else {
        if (-not $state.Sectors.Clicker.ContainsKey('Level'))    { $state.Sectors.Clicker.Level = 1 }
        if (-not $state.Sectors.Clicker.ContainsKey('AutoRate')) { $state.Sectors.Clicker.AutoRate = 0.0 }
        if ([double]$state.Sectors.Clicker.AutoRate -eq 0 -and [int]$state.Sectors.Clicker.Level -gt 1) {
            $state.Sectors.Clicker.AutoRate = [double]$state.Sectors.Clicker.Level * $Global:Config.ClickerAutoPerLvl
        }
    }

    if (-not $state.Sectors.ContainsKey('Investment')) { $state.Sectors.Investment = @{ Unlocked=$false; Portfolio=@() } }
    if (-not $state.Sectors.ContainsKey('Trade'))      { $state.Sectors.Trade = @{ Unlocked=$false; Routes=@(); Warehouse=0 } }
    if (-not $state.Sectors.ContainsKey('Mining'))     { $state.Sectors.Mining = @{ Unlocked=$false; Ore=0.0; ToolLevel=1 } }

    if (-not $state.Meta.ContainsKey('SaveVersion')) { $state.Meta.SaveVersion = $Global:Config.SaveVersion }
    if (-not $state.Meta.ContainsKey('CreatedUtc'))  { $state.Meta.CreatedUtc = [DateTime]::UtcNow.ToString('o') }
    if (-not $state.Meta.ContainsKey('LastSaveUtc')) { $state.Meta.LastSaveUtc = [DateTime]::UtcNow.ToString('o') }
    if (-not $state.Meta.ContainsKey('Sessions'))    { $state.Meta.Sessions = @() }

    return $state
}

function ConvertTo-Hashtable($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [string] -or $obj -is [ValueType]) { return $obj }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $obj.Keys) { $h[$k] = ConvertTo-Hashtable $obj[$k] }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable]) {
        $arr = @()
        foreach ($i in $obj) { $arr += ,(ConvertTo-Hashtable $i) }
        return ,$arr
    }
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
    return $h
}

function Test-SaveSchema($state) {
    return ($state -is [System.Collections.IDictionary]) -and
           $state.ContainsKey('Meta') -and
           $state.ContainsKey('Player') -and
           $state.ContainsKey('Sectors')
}

function Get-OfflineRate($state) {
    $rate = 0.0
    if ($state.ContainsKey('Sectors') -and $state.Sectors.ContainsKey('Clicker')) {
        $rate += [double]$state.Sectors.Clicker.AutoRate
    }
    if ($Global:OfflineRateHooks) {
        foreach ($h in $Global:OfflineRateHooks) {
            try { $rate += [double](& $h $state) } catch { }
        }
    }
    return $rate
}