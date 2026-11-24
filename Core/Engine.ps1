# Engine.ps1 - state + loop + registry (Fase 2)
Set-StrictMode -Version 2.0

$Global:GameState = $null
$Global:Modules    = @{}
$Global:OfflineRateHooks = @()
$Global:AssetValueHooks  = @()

function New-GameState {
    return @{
        Meta = @{
            SaveVersion = $Global:Config.SaveVersion
            CreatedUtc  = [DateTime]::UtcNow.ToString('o')
            LastSaveUtc = [DateTime]::UtcNow.ToString('o')
        }
        Player = @{
            Money       = 0.0
            Prestige    = 0
            Clicks      = 0
            MathSolved  = 0
            PlaytimeSec = 0.0
        }
        Sectors = @{
            Clicker    = @{ Level = 1; AutoRate = 0.0 }
            Investment = @{ Unlocked = $false; Portfolio = @() }
            Trade      = @{ Unlocked = $false; Routes = @(); Warehouse = 0 }
            Mining     = @{ Unlocked = $false; Ore = 0.0; ToolLevel = 1 }
        }
        Upgrades = @{}
        Flags    = @{
            HasPrestige = $false
        }
        ActiveBots = @{}
    }
}

function Register-Module($name, $hooks) { $Global:Modules[$name] = $hooks }
function Register-OfflineRateHook($scriptblock) { $Global:OfflineRateHooks += $scriptblock }
function Register-AssetValueHook($scriptblock) { $Global:AssetValueHooks += $scriptblock }

function Get-TotalAssetValue($state) {
    $total = 0.0
    if ($Global:AssetValueHooks) {
        foreach ($h in $Global:AssetValueHooks) {
            try { $total += [double](& $h $state) } catch { }
        }
    }
    return $total
}

function Get-NetWorth($state) {
    $cash = 0.0
    if ($state -and $state.ContainsKey('Player') -and $state.Player.ContainsKey('Money')) {
        $cash = [double]$state.Player.Money
    }
    return $cash + (Get-TotalAssetValue $state)
}

function Invoke-ModuleHook($hooks, $hookName, [object[]]$args2 = @()) {
    if ($null -eq $hooks) { return }
    if (-not ($hooks -is [System.Collections.IDictionary])) { return }
    if (-not $hooks.ContainsKey($hookName)) { return }
    $fn = $hooks[$hookName]
    if ($null -eq $fn) { return }
    if ($args2.Count -gt 0) { & $fn @args2 } else { & $fn }
}

function Restart-MarketEngineIfDead {
    try {
        $job = Get-Job -Name 'MarketEngine' -ErrorAction SilentlyContinue
        if ($null -eq $job -or $job.State -ne 'Running') {
            if ($null -ne $job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            $corePath = Join-Path $PSScriptRoot 'MarketEngine.ps1'
            if (Test-Path $corePath) {
                Start-Job -FilePath $corePath -Name 'MarketEngine' | Out-Null
            }
        }
    } catch {}
}

function Start-Engine {
    param([string]$ProfileName = $null)
    try {

    $Global:EngineExitReason = 'QUIT'
    if (-not $ProfileName) { return 'MENU' }

    # 1) SET PROFIL & CEK LOCK
    Set-ActiveProfile $ProfileName | Out-Null
    try {
        Acquire-ProfileLock $ProfileName | Out-Null
    } catch {
        Write-Host ""
        Write-Host ("[DITOLAK] " + $_.Exception.Message) -ForegroundColor Red
        Write-Host "Profil sedang aktif. Kembali ke menu..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return 'MENU'
    }

    # 2) LOAD STATE
    try {$Global:GameState = SaveSystem.Load
        if (-not $Global:GameState.ContainsKey('TransactionLog')) {
            $Global:GameState['TransactionLog'] = @()
        }
        
        # Paksa menu saham & bot TERTUTUP SAAT BARU MASUK GAME
        if ($null -eq $Global:GameState.Flags) { $Global:GameState.Flags = @{} }
        $Global:GameState.Flags['ShowStockMenu'] = $false
        $Global:GameState.Flags['ShowBotMenu'] = $false
        # Paksa menu saham tertutup saat baru masuk game
        if ($null -eq $Global:GameState.Flags) { $Global:GameState.Flags    = @{
            HasPrestige = $false
        }
        ActiveBots = @{} }
        $Global:GameState.Flags['ShowStockMenu'] = $false
    } catch {
        Write-Host ("[LOAD-ERR] " + $_.Exception.Message) -ForegroundColor Red
        try { Release-ProfileLock } catch {}
        return 'MENU'
    }

    $last = [DateTime]::UtcNow
    $accSave = 0.0
    $accRender = 0.0
    $running = $true

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
                        foreach ($m in $Global:Modules.Values) {
                            Invoke-ModuleHook $m 'OnInput' @($key)
                        }
                        if ($key.Key -eq 'Q' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                            $running = $false
                            $Global:EngineExitReason = 'MENU'
                        }
                    }
                } catch {
                    $interactive = $false
                }
            }

            foreach ($m in $Global:Modules.Values) {
                try { Invoke-ModuleHook $m 'OnTick' @($dt) } catch {}
            }

            $accRender += $dt
            if ($accRender -ge $Global:Config.RenderThrottle) {
                $accRender = 0
                try { 
                    Render-Dashboard 
                } catch { 
                    $errMsg = $_.Exception.Message
                    $errLine = $_.InvocationInfo.ScriptLineNumber
                    $errCode = $_.InvocationInfo.Line
                    Write-Host ""
                    Write-Host "=== [RENDER-ERROR] ===" -ForegroundColor Red
                    Write-Host ("Pesan: " + $errMsg) -ForegroundColor Red
                    Write-Host ("Baris: " + $errLine) -ForegroundColor Yellow
                    Write-Host ("Kode : " + $errCode) -ForegroundColor DarkGray
                    Write-Host "Tekan Enter untuk keluar..." -ForegroundColor Yellow
                    Read-Host | Out-Null
                    $running = $false 
                }
            }

            $accSave += $dt
            if ($accSave -ge $Global:Config.AutosaveInterval) {
                $accSave = 0
                try { SaveSystem.Save } catch {}
            }

            Start-Sleep -Milliseconds 50
        }
    } finally {
        try { Record-Session 'Exit' } catch {}
        try { SaveSystem.Save } catch {}
        try { Release-ProfileLock } catch {}
        Write-Host ""
        if ($Global:EngineExitReason -eq 'QUIT') {
            Write-Host "Game disimpan. Sampai jumpa!" -ForegroundColor Cyan
        } else {
            Write-Host "Game disimpan. Kembali ke menu profil..." -ForegroundColor Cyan
        }
    }
    return $Global:EngineExitReason
    } catch {
        Write-Host ""
        Write-Host "=== [ENGINE-FATAL] ===" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        Write-Host ""
        Write-Host "Tekan Enter untuk kembali ke menu..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch { Start-Sleep -Seconds 3 }
        return 'MENU'
    }
}
