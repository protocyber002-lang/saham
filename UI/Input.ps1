# Input.ps1 - Logika Kontrol Game & Menu
Set-StrictMode -Version 2.0

function Get-AutoClickerCost {
    $lvl = [int]$Global:GameState.Sectors.Clicker.Level
    return $Global:Config.ClickerUpgradeBase * [Math]::Pow($Global:Config.ClickerUpgradeMul, $lvl - 1)
}

function Grant-BuyBuff($qty) {
    $mult = 1.0
    $sec = 0
    
    if ($qty -ge $Global:Config.StockBuyBuff400_Qty) {
        $mult = $Global:Config.StockBuyBuff400_Mult
        $sec = $Global:Config.StockBuyBuff400_Sec
    } elseif ($qty -ge $Global:Config.StockBuyBuff200_Qty) {
        $mult = $Global:Config.StockBuyBuff200_Mult
        $sec = $Global:Config.StockBuyBuff200_Sec
    } elseif ($qty -ge $Global:Config.StockBuyBuff100_Qty) {
        $mult = $Global:Config.StockBuyBuff100_Mult
        $sec = $Global:Config.StockBuyBuff100_Sec
    } elseif ($qty -ge $Global:Config.StockBuyBuff50_Qty) {
        $mult = $Global:Config.StockBuyBuff50_Mult
        $sec = $Global:Config.StockBuyBuff50_Sec
    } elseif ($qty -ge $Global:Config.StockBuyBuff10_Qty) {
        $mult = $Global:Config.StockBuyBuff10_Mult
        $sec = $Global:Config.StockBuyBuff10_Sec
    }

    if ($sec -gt 0) {
        $Global:GameState.Flags['StockBuffUntil'] = [DateTime]::UtcNow.AddSeconds($sec).ToString('o')
        $Global:GameState.Flags['StockBuffMult'] = $mult
        $Global:GameState.Flags['LastClickMsg'] = ("BONUS BELI SAHAM! Auto Income x{0} selama {1} detik." -f $mult, $sec)
    }
}

$clickerHooks = @{
    OnInput = {
        param($key)
        
        if ($null -ne $Global:GameState -and -not $Global:GameState.ContainsKey('TransactionLog')) {
            $Global:GameState['TransactionLog'] = @()
        }
        
        if ($Global:MathState -and $Global:MathState.Active) { return }
        
        # Reset menu states jika tidak sedang di menu saham
        if (-not $Global:GameState.Flags.ContainsKey('ShowStockMenu') -or -not [bool]$Global:GameState.Flags['ShowStockMenu']) {
            $Global:GameState.Flags['ShowBotMenu'] = $false
        }
        if (-not $Global:GameState.Flags.ContainsKey('ShowBotMenu')) { $Global:GameState.Flags['ShowBotMenu'] = $false }

        # --- MENU LOG TRANSAKSI ---
        if ($Global:GameState.Flags.ContainsKey('ShowLogMenu') -and [bool]$Global:GameState.Flags['ShowLogMenu']) {
            if ($key.Key -eq 'Escape') {
                $Global:GameState.Flags['ShowLogMenu'] = $false
                $Global:GameState.Flags['LastClickMsg'] = "Kembali ke Pasar Saham."
            }
            if ($key.Key -eq 'Q') {
                $Global:EngineExitReason = 'QUIT'
                throw "QUIT_GAME"
            }
            return
        }

        # --- MENU AUTO-BOT ---
        if ($Global:GameState.Flags.ContainsKey('ShowBotMenu') -and [bool]$Global:GameState.Flags['ShowBotMenu']) {
            $stocks = Load-StockData
            $selIdx = 0
            if ($Global:GameState.Flags.ContainsKey('BotSelectedIdx')) { $selIdx = [int]$Global:GameState.Flags['BotSelectedIdx'] }
            if ($selIdx -ge $stocks.Count) { $selIdx = $stocks.Count - 1 }
            $selTicker = $stocks[$selIdx].Ticker
            $msg = ""

            switch ($key.Key) {
                'Q' { $Global:EngineExitReason = 'QUIT'; throw "QUIT_GAME" }
                'B' { $Global:GameState.Flags['ShowBotMenu'] = $false; $msg = "Kembali ke Pasar Saham."; return }
                'W' { if ($selIdx -gt 0) { $selIdx-- } }
                'S' { if ($selIdx -lt $stocks.Count - 1) { $selIdx++ } }
                'D1' { $selIdx = 0 }
                'D2' { $selIdx = 1 }
                'D3' { $selIdx = 2 }
                'D4' {
                    $qty = 100
                    $cost = $stocks[$selIdx].Price * $qty
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState.Portfolio = @{} }
                        $selPort = $Global:GameState.Portfolio[$selTicker]
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += $qty
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selTicker; Type = "BUY"; Qty = $qty; Price = $stocks[$selIdx].Price }
                        $Global:GameState.TransactionLog += $logEntry
                        
                        Grant-BuyBuff $qty
                        $msg = "Beli $qty lembar $selTicker"
                    } else { 
                        $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) 
                    }
                }
                'Subtract' {
                    if (($null -ne $Global:GameState -and $Global:GameState.ContainsKey('ActiveBots') -and $Global:GameState.ActiveBots.ContainsKey($selTicker))) {
                        $Global:GameState.ActiveBots[$selTicker].BuyPct -= 1.0
                        $msg = "Trigger Beli ${selTicker}: $($Global:GameState.ActiveBots[$selTicker].BuyPct)%"
                    }
                }
                'E' {
                    $cost = $Global:Config.AutoBotEcoCost
                    if ($Global:GameState.Player.Money -ge $cost) {
                        if (-not ($null -ne $Global:GameState -and $Global:GameState.ContainsKey('ActiveBots') -and $Global:GameState.ActiveBots.ContainsKey($selTicker))) {
                            $Global:GameState.Player.Money -= $cost
                            $Global:GameState.ActiveBots[$selTicker] = @{
                                TimeLeft = $Global:Config.AutoBotEcoDurationMin * 60
                                BuyPct = $Global:Config.AutoBotDefaultBuyPct
                                SellPct = $Global:Config.AutoBotDefaultSellPct
                            }
                            $msg = "Auto-Bot $selTicker (Paket Ekonomis) aktif."
                        } else {
                            $msg = "Bot untuk $selTicker sudah aktif."
                        }
                    } else { $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) }
                }
            }
            $Global:GameState.Flags['BotSelectedIdx'] = $selIdx
            $Global:GameState.Flags['LastClickMsg'] = $msg
            return
        }

        # --- MENU SAHAM ---
        if ($Global:GameState.Flags.ContainsKey('ShowStockMenu') -and [bool]$Global:GameState.Flags['ShowStockMenu']) {
            $stocks = Load-StockData
            $selIdx = 0
            if ($Global:GameState.Flags.ContainsKey('StockSelectedIdx')) { $selIdx = [int]$Global:GameState.Flags['StockSelectedIdx'] }
            if ($selIdx -ge $stocks.Count) { $selIdx = $stocks.Count - 1 }
            
            if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState.Portfolio = @{} }
            foreach ($st in $stocks) {
                if (-not $Global:GameState.Portfolio.ContainsKey($st.Ticker)) { $Global:GameState.Portfolio[$st.Ticker] = @{ Shares = 0; AvgPrice = 0.0 } }
            }

            $selSt = $stocks[$selIdx]
            $selPort = $Global:GameState.Portfolio[$selSt.Ticker]
            $msg = ""

            switch ($key.Key) {
                'Q' { $Global:EngineExitReason = 'QUIT'; throw "QUIT_GAME" }
                'Escape' { $Global:GameState.Flags['ShowStockMenu'] = $false; $Global:GameState.Flags['LastClickMsg'] = "Kembali dari Pasar Saham."; return }
                'L' { $Global:GameState.Flags['ShowLogMenu'] = $true; $Global:GameState.Flags['LastClickMsg'] = "Membuka Log Transaksi."; return }
                'B' { $Global:GameState.Flags['ShowBotMenu'] = $true; $Global:GameState.Flags['BotSelectedIdx'] = 0; $Global:GameState.Flags['LastClickMsg'] = "Menu Auto-Bot."; return }
                'W' { if ($selIdx -gt 0) { $selIdx-- } }
                'UpArrow' { if ($selIdx -gt 0) { $selIdx-- } }
                'S' { if ($selIdx -lt $stocks.Count - 1) { $selIdx++ } }
                'DownArrow' { if ($selIdx -lt $stocks.Count - 1) { $selIdx++ } }
                'D1' {
                    $qty = 1
                    $cost = $selSt.Price * $qty
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += $qty
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        Grant-BuyBuff $qty
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selSt.Ticker; Type = "BUY"; Qty = $qty; Price = $selSt.Price }
                        $Global:GameState.TransactionLog += $logEntry
                        $msg = "Beli $qty lembar $($selSt.Ticker)"
                    } else { $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) }
                }
                'D2' {
                    $qty = 10
                    $cost = $selSt.Price * $qty
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += $qty
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        Grant-BuyBuff $qty
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selSt.Ticker; Type = "BUY"; Qty = $qty; Price = $selSt.Price }
                        $Global:GameState.TransactionLog += $logEntry
                        $msg = "Beli $qty lembar $($selSt.Ticker)"
                    } else { $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) }
                }
                'D3' {
                    $qty = 50
                    $cost = $selSt.Price * $qty
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += $qty
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        Grant-BuyBuff $qty
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selSt.Ticker; Type = "BUY"; Qty = $qty; Price = $selSt.Price }
                        $Global:GameState.TransactionLog += $logEntry
                        $msg = "Beli $qty lembar $($selSt.Ticker)"
                    } else { $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) }
                }
                'D4' {
                    $qty = 100
                    $cost = $selSt.Price * $qty
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += $qty
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        Grant-BuyBuff $qty
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selSt.Ticker; Type = "BUY"; Qty = $qty; Price = $selSt.Price }
                        $Global:GameState.TransactionLog += $logEntry
                        $msg = "Beli $qty lembar $($selSt.Ticker)"
                    } else { $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) }
                }
                'D5' {
                    $qty = [Math]::Min(10, $selPort.Shares)
                    if ($qty -gt 0) {
                        $earn = $selSt.Price * $qty
                        $Global:GameState.Player.Money += $earn
                        $selPort.Shares -= $qty; if ($selPort.Shares -eq 0) { $selPort.AvgPrice = 0 }
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selSt.Ticker; Type = "SELL"; Qty = $qty; Price = $selSt.Price }
                        $Global:GameState.TransactionLog += $logEntry
                        $msg = "Jual $qty lembar $($selSt.Ticker)"
                    } else { $msg = "Saham tidak cukup!" }
                }
                'D6' {
                    if ($selPort.Shares -gt 0) {
                        $qty = $selPort.Shares; $earn = $selSt.Price * $qty
                        $Global:GameState.Player.Money += $earn
                        $selPort.Shares = 0; $selPort.AvgPrice = 0
                        $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $selSt.Ticker; Type = "SELL"; Qty = $qty; Price = $selSt.Price }
                        $Global:GameState.TransactionLog += $logEntry
                        $msg = "Jual SEMUA $qty lembar $($selSt.Ticker)"
                    } else { $msg = "Saham tidak cukup!" }
                }
                'D7' {
                    $totalEarn = 0.0
                    $totalQty = 0
                    foreach ($st in $stocks) {
                        $p = $Global:GameState.Portfolio[$st.Ticker]
                        if ($p.Shares -gt 0) {
                            $q = $p.Shares
                            $earn = $st.Price * $q
                            $Global:GameState.Player.Money += $earn
                            $totalEarn += $earn
                            $totalQty += $q
                            
                            $logEntry = @{ Time = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Ticker = $st.Ticker; Type = "SELL"; Qty = $q; Price = $st.Price }
                            $Global:GameState.TransactionLog += $logEntry
                            
                            $p.Shares = 0
                            $p.AvgPrice = 0.0
                        }
                    }
                    if ($totalQty -gt 0) { $msg = "Jual SEMUA SAHAM ($totalQty lembar)" }
                    else { $msg = "Tidak ada saham untuk dijual." }
                }
            }
            $Global:GameState.Flags['StockSelectedIdx'] = $selIdx
            $Global:GameState.Flags['LastClickMsg'] = $msg
            return
        }

        # --- DARI GAME UTAMA ---
        if ($key.Key -eq 'S') {
            $Global:GameState.Flags['ShowStockMenu'] = $true
            $Global:GameState.Flags['StockSelectedIdx'] = 0
            $Global:GameState.Flags['LastClickMsg'] = "Selamat datang di Pasar Saham."
            return
        }

        if ($key.Key -eq 'Q') {
            $Global:EngineExitReason = 'MENU'
            throw "QUIT_GAME"
        }
        if ($key.Key -eq 'P') {
            if (-not $Global:GameState.Flags.ContainsKey('AutoIncomePaused')) { $Global:GameState.Flags['AutoIncomePaused'] = $false }
            $newStatus = -not [bool]$Global:GameState.Flags['AutoIncomePaused']
            $Global:GameState.Flags['AutoIncomePaused'] = $newStatus
            if ($newStatus) { $Global:GameState.Flags['LastClickMsg'] = "AUTO-INCOME DIJEDA" }
            else { $Global:GameState.Flags['LastClickMsg'] = "AUTO-INCOME BERJALAN" }
            return
        }

        switch ($key.Key) {
            'Spacebar' {
                $clickBuff = 1.0
                if ($Global:GameState.Flags.ContainsKey('ClickBuffUntil')) {
                    try {
                        $until = [DateTime]::Parse($Global:GameState.Flags['ClickBuffUntil'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ([DateTime]::UtcNow -lt $until) { $clickBuff = [double]$Global:GameState.Flags['ClickBuffMult'] }
                    } catch {}
                }
                $buff = Math-GetBuffMultiplier
                $gain = [double]$Global:GameState.Sectors.Clicker.Level * $buff * $clickBuff
                $Global:GameState.Player.Clicks += 1
                $Global:GameState.Player.Money  += $gain
            }
            'U' {
                $cost = Get-AutoClickerCost
                if ($Global:GameState.Player.Money -ge $cost) {
                    $Global:GameState.Player.Money -= $cost
                    $Global:GameState.Sectors.Clicker.Level += 1
                    $Global:GameState.Sectors.Clicker.AutoRate = [double]$Global:GameState.Sectors.Clicker.Level * $Global:Config.ClickerAutoPerLvl
                    $Global:GameState.Flags['LastClickMsg'] = ("Upgrade! Lvl {0}, auto {1:N2}/s" -f $Global:GameState.Sectors.Clicker.Level, $Global:GameState.Sectors.Clicker.AutoRate)
                } else {
                    $Global:GameState.Flags['LastClickMsg'] = ("Butuh {0:N2} money" -f $cost)
                }
            }
        }
    }
    
    OnTick = {
        param($dt)
        $rate = [double]$Global:GameState.Sectors.Clicker.AutoRate
        if ($Global:GameState.Flags.ContainsKey('AutoIncomePaused') -and $Global:GameState.Flags['AutoIncomePaused']) { $rate = 0.0 }
        
        if ($rate -gt 0) {
            $buff = Math-GetBuffMultiplier
            $stockBuff = 1.0
            if ($Global:GameState.Flags.ContainsKey('StockBuffUntil')) {
                try {
                    $until = [DateTime]::Parse($Global:GameState.Flags['StockBuffUntil'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    if ([DateTime]::UtcNow -lt $until) {
                        $stockBuff = [double]$Global:GameState.Flags['StockBuffMult']
                    }
                } catch {}
            }
            $Global:GameState.Player.Money += ($rate * $buff * $stockBuff * $dt)
        }
    }
}

Register-Module 'Clicker' $clickerHooks

Register-OfflineRateHook {
    param($state)
    if ($state.Sectors.ContainsKey('Clicker')) { return [double]$state.Sectors.Clicker.AutoRate }
    return 0.0
}

Register-AssetValueHook {
    param($state)
    if (-not $state.Sectors.ContainsKey('Clicker')) { return 0.0 }
    $lvl = [int]$state.Sectors.Clicker.Level
    if ($lvl -le 1) { return 0.0 }
    $base = [double]$Global:Config.ClickerUpgradeBase
    $mul  = [double]$Global:Config.ClickerUpgradeMul
    $n    = $lvl - 1
    if ([Math]::Abs($mul - 1.0) -lt 0.000001) { return $base * $n }
    $sum = $base * ([Math]::Pow($mul, $n) - 1.0) / ($mul - 1.0)
    return [Math]::Round($sum, 2)
}