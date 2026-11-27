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

function Add-WebReceipt($id, $status, $message) {
    $receiptsPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\receipts.json'))
    try {
        $receipts = @()
        try {
            if (Test-Path $receiptsPath) {
                $rawR = [System.IO.File]::ReadAllText($receiptsPath)
                if (-not [string]::IsNullOrWhiteSpace($rawR)) {
                    try { $receipts = @($rawR -replace "^\uFEFF", "" | ConvertFrom-Json) } catch { $receipts = @() }
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

function Process-WebQueue {
    if ($null -eq $Global:GameState) { return }
    $activeProfile = ''
    try { $activeProfile = [string](Get-ActiveProfile) } catch { $activeProfile = '' }
    if ([string]::IsNullOrWhiteSpace($activeProfile)) { return }

    $queuePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\queue.json'))
    $lockPath  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\queue.lock'))
    $lockFs = $null
    for ($i = 0; $i -lt 60; $i++) {
        try { $lockFs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None); break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    if (-not $lockFs) { return }

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
        $queue = @(($raw -replace "^\uFEFF", "") | ConvertFrom-Json)
        if ($queue.Count -eq 0) { return }

        $mine = @(); $remaining = @()
        foreach ($q in $queue) {
            $qProf = $q.PSObject.Properties['Profile']
            if ($null -ne $qProf -and ([string]$qProf.Value) -ieq $activeProfile) { $mine += $q }
            else { $remaining += $q }
        }
        if ($mine.Count -eq 0) { return }

        if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState.Portfolio = @{} }
        if (-not $Global:GameState.Player.ContainsKey('Money')) { $Global:GameState.Player.Money = 0.0 }
        $stocks = Load-StockData

        $heldBack = @()
        foreach ($q in $mine) {
            if ($q.Action -ne "BUY") { continue }
            $id = Get-QueueOrderId $q
            $qty = 0
            try { $qty = [int]$q.Qty } catch { $qty = 0 }
            $stock = $stocks | Where-Object { $_.Ticker -eq [string]$q.Ticker } | Select-Object -First 1
            if (-not $stock -or $qty -lt 1 -or $qty -gt 1000) {
                Add-WebReceipt $id "Failed" "Ticker/qty tidak valid"
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
                try { SaveSystem.Save } catch {}
            } else {
                if (-not ($script:WebReceiptIds.Contains($id))) {
                    $script:WebReceiptIds.Add($id)
                    Add-WebReceipt $id "Held" "Uang belum cukup - order ditahan sampai uang cukup"
                }
                $heldBack += $q
            }
        }

        $toWrite = @($remaining) + @($heldBack)
        if ($toWrite.Count -eq 0) { [System.IO.File]::WriteAllText($queuePath, '[]', [System.Text.Encoding]::UTF8) }
        else { ConvertTo-Json -InputObject @($toWrite) -Depth 5 -Compress | Set-Content $queuePath -Encoding UTF8 }
    } catch { Write-Host ("[WEB QUEUE][ERROR] Process-WebQueue: " + $_.Exception.Message) -ForegroundColor Yellow }
    finally { if ($lockFs) { try { $lockFs.Close() } catch {} } }
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