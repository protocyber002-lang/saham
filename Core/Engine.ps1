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
function Process-WebQueue {
    $queuePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data\queue.json'))
    if (-not (Test-Path $queuePath)) { return }

    try {
        $raw = $null
        try {
            $fs = [System.IO.File]::Open($queuePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs)
            $raw = $reader.ReadToEnd()
            $reader.Close(); $fs.Close()
        } catch { return }

        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq '[]') { return }
        
        $queue = @($raw | ConvertFrom-Json)
        if ($queue.Count -eq 0) { return }

        [System.IO.File]::WriteAllText($queuePath, '[]', [System.Text.Encoding]::UTF8)

        if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState.Portfolio = @{} }
        if (-not $Global:GameState.Player.ContainsKey('Money')) { $Global:GameState.Player.Money = 0.0 }

        $stocks = Load-StockData

        foreach ($q in $queue) {
            if ($q.Action -eq "BUY") {
                $ticker = $q.Ticker; $qty = [int]$q.Qty
                $stock = $stocks | Where-Object { $_.Ticker -eq $ticker } | Select-Object -First 1
                if (-not $stock) { continue }
                
                $cost = $stock.Price * $qty
                if ($Global:GameState.Player.Money -ge $cost) {
                    $Global:GameState.Player.Money -= $cost
                    if (-not $Global:GameState.Portfolio.ContainsKey($ticker)) { $Global:GameState.Portfolio[$ticker] = @{ Shares = 0; AvgPrice = 0.0 } }
                    $port = $Global:GameState.Portfolio[$ticker]
                    $oldTotal = $port.AvgPrice * $port.Shares
                    $port.Shares += $qty
                    $port.AvgPrice = ($oldTotal + $cost) / $port.Shares
                    $Global:GameState.Flags['LastClickMsg'] = ("[WEB] Sukses beli $qty lembar ${ticker} @ Rp {0:N2}" -f $stock.Price)
                    try { SaveSystem.Save } catch {}
                } else {
                    $Global:GameState.Flags['LastClickMsg'] = ("[WEB] Gagal beli ${ticker}: Uang tidak cukup." )
                }
            }
        }
    } catch { }
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