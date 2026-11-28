# Engine.ps1 - state + loop + registry (Fase 2)
Set-StrictMode -Version 2.0

$Global:GameState = $null
$Global:Modules    = @{}
$Global:OfflineRateHooks = @()
$Global:AssetValueHooks  = @()

function New-GameState {
    return @{
        Meta = @{ SaveVersion = $Global:Config.SaveVersion; CreatedUtc = [DateTime]::UtcNow.ToString('o'); LastSaveUtc = [DateTime]::UtcNow.ToString('o') }
        Player = @{ Money = 0.0; Prestige = 0; Clicks = 0; MathSolved = 0; PlaytimeSec = 0.0 }
        Sectors = @{ Clicker = @{ Level = 1; AutoRate = 0.0 }; Investment = @{ Unlocked = $false; Portfolio = @() }; Trade = @{ Unlocked = $false; Routes = @(); Warehouse = 0 }; Mining = @{ Unlocked = $false; Ore = 0.0; ToolLevel = 1 } }
        Upgrades = @{}; Flags = @{ HasPrestige = $false }; ActiveBots = @{}
    }
}

function Register-Module($name, $hooks) { $Global:Modules[$name] = $hooks }
function Register-OfflineRateHook($scriptblock) { $Global:OfflineRateHooks += $scriptblock }
function Register-AssetValueHook($scriptblock) { $Global:AssetValueHooks += $scriptblock }

function Get-TotalAssetValue($state) {
    $total = 0.0
    if ($Global:AssetValueHooks) { foreach ($h in $Global:AssetValueHooks) { try { $total += [double](& $h $state) } catch { } } }
    return $total
}

function Get-NetWorth($state) {
    $cash = 0.0
    if ($state -and $state.ContainsKey('Player') -and $state.Player.ContainsKey('Money')) { $cash = [double]$state.Player.Money }
    return $cash + (Get-TotalAssetValue $state)
}

function Invoke-ModuleHook($hooks, $hookName, [object[]]$args2 = @()) {
    if ($null -eq $hooks -or -not ($hooks -is [System.Collections.IDictionary]) -or -not $hooks.ContainsKey($hookName)) { return }
    $fn = $hooks[$hookName]
    if ($null -eq $fn) { return }
    if ($args2.Count -gt 0) { & $fn @args2 } else { & $fn }
}

# --- FUNGSI SINKRONISASI WEB KE TUI ---
$script:WebReceiptIds = New-Object System.Collections.Generic.List[string]

function Write-WebQueueLog($level, $message) {
    try {
        $logPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\web_queue_tui.log'))
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $message
        [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Find-JsonNodesDeep($node, [string[]]$propNames) {
    $found = @()
    if ($node -is [System.Array]) {
        foreach ($item in $node) { $found += @(Find-JsonNodesDeep $item $propNames) }
        return $found
    }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        $hasAll = $true
        foreach ($n in $propNames) {
            if ($null -eq $node.PSObject.Properties[$n]) { $hasAll = $false; break }
        }
        if ($hasAll) { return @($node) }
        foreach ($p in $node.PSObject.Properties) { $found += @(Find-JsonNodesDeep $p.Value $propNames) }
    }
    return $found
}

function Add-WebReceipt($id, $status, $message) {
    $receiptsPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\receipts.json'))
    try {
        $receipts = @()
        try {
            if (Test-Path $receiptsPath) {
                $rawR = [System.IO.File]::ReadAllText($receiptsPath)
                if (-not [string]::IsNullOrWhiteSpace($rawR)) {
                    try { $receipts = @(Find-JsonNodesDeep (($rawR -replace "^\uFEFF", "") | ConvertFrom-Json) @('Id','Status')) } catch { $receipts = @() }
                }
            }
        } catch { $receipts = @() }
        $cutoff = [DateTime]::UtcNow.AddMinutes(-15).ToString('o')
        $kept = @()
        foreach ($r in $receipts) {
            $rId = $r.PSObject.Properties['Id']
            if ($null -ne $rId -and $rId.Value -eq $id) { continue }
            $tProp = $r.PSObject.Properties['Time']
            if ($null -ne $tProp -and $tProp.Value -and ([string]$tProp.Value) -ge $cutoff) { $kept += $r }
        }
        $kept += @{ Id = $id; Status = $status; Message = $message; Time = [DateTime]::UtcNow.ToString('o') }
        if ($kept.Count -gt 50) { $kept = @($kept | Select-Object -Last 50) }
        $lastErr = $null
        for ($i = 0; $i -lt 10; $i++) {
            try {
                $tmp = $receiptsPath + ".tmp"
                ConvertTo-Json -InputObject @($kept) -Depth 5 -Compress | Set-Content $tmp -Encoding UTF8
                Move-Item $tmp $receiptsPath -Force
                return
            } catch { $lastErr = $_; Start-Sleep -Milliseconds 100 }
        }
        Write-Host ("[WEB BELI][WARN] Gagal tulis kuitansi " + $id + ": " + $lastErr.Exception.Message) -ForegroundColor Yellow
    } catch { Write-Host ("[WEB BELI][WARN] Gagal tulis kuitansi " + $id + ": " + $_.Exception.Message) -ForegroundColor Yellow }
}

function Get-QueueOrderId($q) {
    $idProp = $q.PSObject.Properties['Id']
    if ($null -ne $idProp -and $idProp.Value) { return [string]$idProp.Value }
    return ([string]$q.Ticker) + "|" + [string]$q.Qty + "|" + [string]$q.Time
}

$script:WebLastSkipLog = ""
$script:WebLastLockWarn = [DateTime]::MinValue

function Process-WebQueue {
    if ($null -eq $Global:GameState) { return }
    $activeProfile = ''
    try { $activeProfile = [string](Get-ActiveProfile) } catch { $activeProfile = '' }
    if ([string]::IsNullOrWhiteSpace($activeProfile)) {
        Write-WebQueueLog "WARN" "Profil aktif kosong - monitor antrian dilewati"
        return
    }

    $queuePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\queue.json'))
    $lockPath  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\queue.lock'))
    $lockFs = $null
    for ($i = 0; $i -lt 60; $i++) {
        try { $lockFs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None); break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    if (-not $lockFs) {
        if (([DateTime]::UtcNow - $script:WebLastLockWarn).TotalSeconds -ge 60) {
            $script:WebLastLockWarn = [DateTime]::UtcNow
            Write-WebQueueLog "WARN" "Gagal mengunci queue.lock 3 detik - tick dilewati (konsumen lain terlalu agresif?)"
        }
        return
    }

    try {
        if (-not (Test-Path $queuePath)) { return }
        $raw = $null
        try {
            $fs = [System.IO.File]::Open($queuePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs)
            $raw = $reader.ReadToEnd()
            $reader.Close(); $fs.Close()
        } catch { return }

        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $parsed = $null
        try { $parsed = ($raw -replace "^\uFEFF", "") | ConvertFrom-Json } catch {
            Write-WebQueueLog "ERROR" ("queue.json rusak, tidak bisa di-parse: " + $_.Exception.Message)
            return
        }
        $queue = @(Find-JsonNodesDeep $parsed @('Action','Ticker'))
        if ($queue.Count -eq 0) { return }
        $topCount = @($parsed).Count
        if ($queue.Count -ne $topCount) {
            Write-WebQueueLog "INFO" ("Antrian korup dipulihkan: {0} order asli digali dari {1} node bersarang - antrian ditulis ulang bersih" -f $queue.Count, $topCount)
        }

        $mine = @(); $remaining = @()
        foreach ($q in $queue) {
            $qProf = $q.PSObject.Properties['Profile']
            if ($null -ne $qProf -and ([string]$qProf.Value) -ieq $activeProfile) { $mine += $q }
            else { $remaining += $q }
        }
        if ($mine.Count -eq 0) {
            $profiles = (@($queue | ForEach-Object { $p = $_.PSObject.Properties['Profile']; if ($p) { [string]$p.Value } else { "(kosong)" } }) | Select-Object -Unique) -join ","
            $sig = $profiles + "|" + $activeProfile
            if ($script:WebLastSkipLog -ne $sig) {
                $script:WebLastSkipLog = $sig
                Write-WebQueueLog "INFO" ("Antrian berisi {0} order utk profil '{1}' - monitor ini '{2}', dilewati" -f $queue.Count, $profiles, $activeProfile)
            }
            if ($queue.Count -ne $topCount) {
                ConvertTo-Json -InputObject @($queue) -Depth 5 -Compress | Set-Content $queuePath -Encoding UTF8
            }
            return
        }
        $script:WebLastSkipLog = ""
        Write-WebQueueLog "INFO" ("Antrian diterima: {0} order utk profil '{1}'" -f $mine.Count, $activeProfile)

        if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState['Portfolio'] = @{} }
        Normalize-Portfolio
        if (-not $Global:GameState.Player.ContainsKey('Money')) { $Global:GameState.Player.Money = 0.0 }
        $stocks = Load-StockData
        if ($null -eq $stocks -or @($stocks).Count -eq 0) {
            Write-WebQueueLog "WARN" "Load-StockData kosong - order tidak bisa dieksekusi tick ini"
            return
        }

        $heldBack = @()
        foreach ($q in $mine) {
            if ($q.Action -ne "BUY") { continue }
            $id = Get-QueueOrderId $q
            $qty = 0
            try { $qty = [int]$q.Qty } catch { $qty = 0 }
            $stock = $stocks | Where-Object { $_.Ticker -eq [string]$q.Ticker } | Select-Object -First 1
            if (-not $stock -or $qty -lt 1 -or $qty -gt 1000) {
                Add-WebReceipt $id "Failed" "Ticker/qty tidak valid"
                Write-WebQueueLog "WARN" ("Order {0} gagal: ticker/qty tidak valid ({1} x{2})" -f $id.Substring(0, [Math]::Min(8, $id.Length)), $q.Ticker, $qty)
                continue
            }
            $cost = $stock.Price * $qty
            if ($Global:GameState.Player.Money -ge $cost) {
                $Global:GameState.Player.Money -= $cost
                if (-not $Global:GameState.Portfolio.ContainsKey([string]$q.Ticker)) { $Global:GameState.Portfolio[[string]$q.Ticker] = @{ Shares = 0; AvgPrice = 0.0 } }
                $port = $Global:GameState.Portfolio[[string]$q.Ticker]
                $oldTotal = $port.AvgPrice * $port.Shares
                $port.Shares += $qty
                $port.AvgPrice = ($oldTotal + $cost) / $port.Shares
                $Global:GameState.Flags['LastClickMsg'] = ("[WEB] Sukses beli $qty lembar " + $q.Ticker + " @ Rp {0:N2}" -f $stock.Price)
                Add-WebReceipt $id "Executed" ("Beli " + $qty + " lembar " + $q.Ticker + " tercatat di TUI")
                Write-WebQueueLog "OK" ("Profil '{0}' membeli {1} lembar {2} (order {3})" -f $activeProfile, $qty, $q.Ticker, $id.Substring(0, [Math]::Min(8, $id.Length)))
                try { SaveSystem.Save } catch {}
            } else {
                if (-not ($script:WebReceiptIds.Contains($id))) {
                    $script:WebReceiptIds.Add($id)
                    Add-WebReceipt $id "Held" "Uang belum cukup - order ditahan sampai uang cukup"
                    Write-WebQueueLog "WARN" ("Order {0} ditahan: uang belum cukup ({1} x{2}, butuh Rp {3:N0})" -f $id.Substring(0, [Math]::Min(8, $id.Length)), $q.Ticker, $qty, $cost)
                }
                $heldBack += $q
            }
        }

        $toWrite = @($remaining) + @($heldBack)
        if ($toWrite.Count -eq 0) { [System.IO.File]::WriteAllText($queuePath, '[]', [System.Text.Encoding]::UTF8) }
        else { ConvertTo-Json -InputObject @($toWrite) -Depth 5 -Compress | Set-Content $queuePath -Encoding UTF8 }
    } catch {
        Write-Host ("[WEB QUEUE][ERROR] Process-WebQueue: " + $_.Exception.Message) -ForegroundColor Yellow
        Write-WebQueueLog "ERROR" ("Process-WebQueue: " + $_.Exception.Message)
    }
    finally { if ($lockFs) { try { $lockFs.Close() } catch {} } }
}

function Normalize-Portfolio {
    if ($null -eq $Global:GameState) { return }
    if ($Global:GameState.Portfolio -is [System.Collections.IDictionary]) {
        foreach ($k in @($Global:GameState.Portfolio.Keys)) {
            if ($null -eq $Global:GameState.Portfolio[$k] -or -not ($Global:GameState.Portfolio[$k] -is [System.Collections.IDictionary])) {
                $Global:GameState.Portfolio[$k] = @{ Shares = 0; AvgPrice = 0.0 }
            }
        }
        return
    }
    $rebuilt = @{}
    if ($Global:GameState.Portfolio) {
        foreach ($e in @($Global:GameState.Portfolio)) {
            try {
                $t = [string]$e.Ticker
                if ($t) { $rebuilt[$t] = @{ Shares = [int]$e.Shares; AvgPrice = [double]$e.AvgPrice } }
            } catch { }
        }
    }
    $Global:GameState.Portfolio = $rebuilt
}

function Start-Engine {
    param([string]$ProfileName = $null)
    try {
    $Global:EngineExitReason = 'QUIT'
    if (-not $ProfileName) { return 'MENU' }

    Set-ActiveProfile $ProfileName | Out-Null
    try { Acquire-ProfileLock $ProfileName | Out-Null } catch {
        Write-Host ("[DITOLAK] " + $_.Exception.Message) -ForegroundColor Red
        Start-Sleep -Seconds 2; return 'MENU'
    }

    try { $Global:GameState = SaveSystem.Load
        if (-not $Global:GameState.ContainsKey('TransactionLog')) { $Global:GameState['TransactionLog'] = @() }
        if ($null -eq $Global:GameState.Flags) { $Global:GameState.Flags = @{} }
        if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState['Portfolio'] = @{} }
        Normalize-Portfolio
        Write-WebQueueLog "INFO" ("Monitor antrian web aktif untuk profil '{0}'" -f $ProfileName)
        $Global:GameState.Flags['ShowStockMenu'] = $false
        $Global:GameState.Flags['ShowBotMenu'] = $false
    } catch {
        Write-Host ("[LOAD-ERR] " + $_.Exception.Message) -ForegroundColor Red
        try { Release-ProfileLock } catch {}
        return 'MENU'
    }

    $last = [DateTime]::UtcNow; $accSave = 0.0; $accRender = 0.0; $running = $true
    try { Render-Dashboard } catch {}
    foreach ($m in $Global:Modules.Values) { Invoke-ModuleHook $m 'OnLoad' }

    $interactive = $true
    try { [void][Console]::KeyAvailable } catch { $interactive = $false }

    try {
        while ($running) {
            $now = [DateTime]::UtcNow
            $dt  = ($now - $last).TotalSeconds
            $last = $now
            if ($dt -lt 0) { $dt = 0 }
            if ($dt -gt $Global:Config.FrameClampSeconds) { $dt = $Global:Config.FrameClampSeconds }
            $Global:GameState.Player.PlaytimeSec += $dt

            if ($interactive) {
                try {
                    while ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true)
                        foreach ($m in $Global:Modules.Values) { Invoke-ModuleHook $m 'OnInput' @($key) }
                        if ($key.Key -eq 'Q' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { $running = $false; $Global:EngineExitReason = 'MENU' }
                    }
                } catch { $interactive = $false }
            }

            foreach ($m in $Global:Modules.Values) { try { Invoke-ModuleHook $m 'OnTick' @($dt) } catch {} }
            Process-WebQueue

            $accRender += $dt
            if ($accRender -ge $Global:Config.RenderThrottle) {
                $accRender = 0
                try { Render-Dashboard } catch { $running = $false }
            }

            $accSave += $dt
            if ($accSave -ge $Global:Config.AutosaveInterval) { $accSave = 0; try { SaveSystem.Save } catch {} }

            Start-Sleep -Milliseconds 50
        }
    } finally {
        try { Record-Session 'Exit' } catch {}
        try { SaveSystem.Save } catch {}
        try { Release-ProfileLock } catch {}
        if ($Global:EngineExitReason -eq 'QUIT') { Write-Host "Game disimpan. Sampai jumpa!" -ForegroundColor Cyan } else { Write-Host "Game disimpan. Kembali ke menu..." -ForegroundColor Cyan }
    }
    return $Global:EngineExitReason
    } catch {
        Write-Host "=== [ENGINE-FATAL] ===" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        try { Read-Host | Out-Null } catch { Start-Sleep -Seconds 3 }
        return 'MENU'
    }
}