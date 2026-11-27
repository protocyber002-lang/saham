# Input.ps1 - Logika Kontrol Game & Menu
Set-StrictMode -Version 2.0

$Global:StockInputBuffer = ""

function Get-AutoClickerCost {
    $lvl = [int]$Global:GameState.Sectors.Clicker.Level
    return $Global:Config.ClickerUpgradeBase * [Math]::Pow($Global:Config.ClickerUpgradeMul, $lvl - 1)
}

function Grant-BuyBuff($qty) {
    $mult = 1.0
    $sec = 0
    if ($qty -ge $Global:Config.StockBuyBuff400_Qty) { $mult = $Global:Config.StockBuyBuff400_Mult; $sec = $Global:Config.StockBuyBuff400_Sec }
    elseif ($qty -ge $Global:Config.StockBuyBuff200_Qty) { $mult = $Global:Config.StockBuyBuff200_Mult; $sec = $Global:Config.StockBuyBuff200_Sec }
    elseif ($qty -ge $Global:Config.StockBuyBuff100_Qty) { $mult = $Global:Config.StockBuyBuff100_Mult; $sec = $Global:Config.StockBuyBuff100_Sec }
    elseif ($qty -ge $Global:Config.StockBuyBuff50_Qty) { $mult = $Global:Config.StockBuyBuff50_Mult; $sec = $Global:Config.StockBuyBuff50_Sec }
    elseif ($qty -ge $Global:Config.StockBuyBuff10_Qty) { $mult = $Global:Config.StockBuyBuff10_Mult; $sec = $Global:Config.StockBuyBuff10_Sec }

    if ($sec -gt 0) {
        $Global:GameState.Flags['StockBuffUntil'] = [DateTime]::UtcNow.AddSeconds($sec).ToString('o')
        $Global:GameState.Flags['StockBuffMult'] = $mult
        $Global:GameState.Flags['LastClickMsg'] = ("BONUS BELI SAHAM! Auto Income x{0} selama {1} detik." -f $mult, $sec)
    }
}

$clickerHooks = @{
    OnInput = {
        param($key)
        
        if ($null -ne $Global:GameState -and -not $Global:GameState.ContainsKey('TransactionLog')) { $Global:GameState['TransactionLog'] = @() }
        
        if ($Global:MathState -and $Global:MathState.Active) { return }
        
        if (-not $Global:GameState.Flags.ContainsKey('ShowStockMenu') -or -not [bool]$Global:GameState.Flags['ShowStockMenu']) { $Global:GameState.Flags['ShowBotMenu'] = $false }
        if (-not $Global:GameState.Flags.ContainsKey('ShowBotMenu')) { $Global:GameState.Flags['ShowBotMenu'] = $false }

        # --- MENU LOG TRANSAKSI ---
        if ($Global:GameState.Flags.ContainsKey('ShowLogMenu') -and [bool]$Global:GameState.Flags['ShowLogMenu']) {
            if ($key.Key -eq 'Escape') { $Global:GameState.Flags['ShowLogMenu'] = $false; $Global:GameState.Flags['LastClickMsg'] = "Kembali ke Pasar Saham." }
            if ($key.Key -eq 'Q') { $Global:EngineExitReason = 'QUIT'; throw "QUIT_GAME" }
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
                    } else { $msg = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost) }
                }
                'Subtract' { if (($null -ne $Global:GameState -and $Global:GameState.ContainsKey('ActiveBots') -and $Global:GameState.ActiveBots.ContainsKey($selTicker))) { $Global:GameState.ActiveBots[$selTicker].BuyPct -= 1.0; $msg = "Trigger Beli ${selTicker}: $($Global:GameState.ActiveBots[$selTicker].BuyPct)%" } }
                'E' {
                    $cost = $Global:Config.AutoBotEcoCost
                    if ($Global:GameState.Player.Money -ge $cost) {
                        if (-not ($null -ne $Global:GameState -and $Global:GameState.ContainsKey('ActiveBots') -and $Global:GameState.ActiveBots.ContainsKey($selTicker))) {
                            $Global:GameState.Player.Money -= $cost
                            $Global:GameState.ActiveBots[$selTicker] = @{ TimeLeft = $Global:Config.AutoBotEcoDurationMin * 60; BuyPct = $Global:Config.AutoBotDefaultBuyPct; SellPct = $Global:Config.AutoBotDefaultSellPct }
                            $msg = "Auto-Bot $selTicker (Paket Ekonomis) aktif."
                        } else { $msg = "Bot untuk $selTicker sudah aktif." }
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
            foreach ($st in $stocks) { if (-not $Global:GameState.Portfolio.ContainsKey($st.Ticker)) { $Global:GameState.Portfolio[$st.Ticker] = @{ Shares = 0; AvgPrice = 0.0 } } }

            $selSt = $stocks[$selIdx]
            $selPort = $Global:GameState.Portfolio[$selSt.Ticker]
            $msg = ""

            # --- LOGIKA INPUT CEPAT [i] ---
            if ($Global:StockInputBuffer -ne "" -or ($key.KeyChar -match '^\d$' -and $Global:StockInputBuffer -eq "")) {
                if ($key.Key -eq 'Escape') {
                    $Global:StockInputBuffer = ""
                    $Global:GameState.Flags['LastClickMsg'] = "Input dibatalkan."
                    return
                }
                if ($key.Key -eq 'Backspace') {
                    if ($Global:StockInputBuffer.Length -gt 0) { $Global:StockInputBuffer = $Global:StockInputBuffer.Substring(0, $Global:StockInputBuffer.Length - 1) }
                    return
                }
                if ($key.KeyChar -match '^\d$') {
                    $Global:StockInputBuffer += [string]$key.KeyChar
                    $Global:GameState.Flags['LastClickMsg'] = "Buffer: $Global:StockInputBuffer"
                    
                    if ($Global:StockInputBuffer.Length -eq 2) {
                        $sahamIdx = [int]($Global:StockInputBuffer[0].ToString()) - 1
                        $aksiIdx  = [int]($Global:StockInputBuffer[1].ToString())
                        
                        if ($sahamIdx -ge 0 -and $sahamIdx -lt $stocks.Count) {
                            $targetSt = $stocks[$sahamIdx]
                            $targetPort = $Global:GameState.Portfolio[$targetSt.Ticker]
                            
                            $qty = 0; $isBuy = $true
                            switch ($aksiIdx) {
                                1 { $qty = 1; $isBuy = $true }
                                2 { $qty = 10; $isBuy = $true }
                                3 { $qty = 50; $isBuy = $true }
                                4 { $qty = 100; $isBuy = $true }
                                5 { $qty = [Math]::Min(10, $targetPort.Shares); $isBuy = $false }
                                6 { $qty = $targetPort.Shares; $isBuy = $false }
                                default { $Global:GameState.Flags['LastClickMsg'] = "Aksi tidak valid." }
                            }
                            
                            if ($qty -gt 0) {
                                if ($isBuy) {
                                    $cost = $targetSt.Price * $qty
                                    if ($Global:GameState.Player.Money -ge $cost) {
                                        $Global:GameState.Player.Money -= $cost
                                        $oldTotal = $targetPort.AvgPrice * $targetPort.Shares
                                        $targetPort.Shares += $qty
                                        $targetPort.AvgPrice = ($oldTotal + $cost) / $targetPort.Shares
                                        Grant-BuyBuff $qty
                                        $Global:GameState.Flags['LastClickMsg'] = "Beli $qty lembar $($targetSt.Ticker) (Input Cepat)"
                                    } else { $Global:GameState.Flags['LastClickMsg'] = "Uang tidak cukup!" }
                                } else {
                                    $earn = $targetSt.Price * $qty
                                    $Global:GameState.Player.Money += $earn
                                    $targetPort.Shares -= $qty
                                    if ($targetPort.Shares -eq 0) { $targetPort.AvgPrice = 0 }
                                    $Global:GameState.Flags['LastClickMsg'] = "Jual $qty lembar $($targetSt.Ticker) (Input Cepat)"
                                }
                            } elseif ($aksiIdx -le 6) { $Global:GameState.Flags['LastClickMsg'] = "Gagal: Saham tidak mencukupi." }
                        } else { $Global:GameState.Flags['LastClickMsg'] = "Saham tidak valid." }
                        $Global:StockInputBuffer = ""
                    }
                    return
                }
            }

            switch ($key.Key) {
                'Q' { $Global:EngineExitReason = 'QUIT'; throw "QUIT_GAME" }
                'Escape' { $Global:GameState.Flags['ShowStockMenu'] = $false; $Global:GameState.Flags['LastClickMsg'] = "Kembali dari Pasar Saham."; return }
                'I' { 
                    $Global:StockInputBuffer = ""
                    $Global:GameState.Flags['LastClickMsg'] = "INPUT CEPAT: Ketik 2 digit (misal 11 = AAPL Beli 1). [ESC] Batal."
                    return
                }
                'L' { $Global:GameState.Flags['ShowLogMenu'] = $true; $Global:GameState.Flags['LastClickMsg'] = "Membuka Log Transaksi."; return }
                'B' { $Global:GameState.Flags['ShowBotMenu'] = $true; $Global:GameState.Flags['BotSelectedIdx'] = 0; $Global:GameState.Flags['LastClickMsg'] = "Menu Auto-Bot."; return }
                'W' { if ($selIdx -gt 0) { $selIdx-- } }
                'UpArrow' { if ($selIdx -gt 0) { $selIdx-- } }
                'S' { if ($selIdx -lt $stocks.Count - 1) { $selIdx++ } }
                'DownArrow' { if ($selIdx -lt $stocks.Count - 1) { $selIdx++ } }
                'D1' {
                    $qty = 1; $cost = $selSt.Price * $qty
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
                    $qty = 10; $cost = $selSt.Price * $qty
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
                    $qty = 50; $cost = $selSt.Price * $qty
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
                    $qty = 100; $cost = $selSt.Price * $qty
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
                        $selPort.Shares -= $qty
                        if ($selPort.Shares -eq 0) { $selPort.AvgPrice = 0 }
                        $msg = "Jual $qty lembar $($selSt.Ticker)"
                    } else { $msg = "Saham tidak cukup!" }
                }
                'D6' {
                    if ($selPort.Shares -gt 0) {
                        $qty = $selPort.Shares; $earn = $selSt.Price * $qty
                        $Global:GameState.Player.Money += $earn
                        $selPort.Shares = 0; $selPort.AvgPrice = 0
                        $msg = "Jual SEMUA $qty lembar $($selSt.Ticker)"
                    } else { $msg = "Saham tidak cukup!" }
                }
            }
            $Global:GameState.Flags['StockSelectedIdx'] = $selIdx
            $Global:GameState.Flags['LastClickMsg'] = $msg
            return
        }

        # --- DASHBOARD UTAMA (BUKAN MENU) ---
        switch ($key.Key) {
            'Spacebar' {
                $clvl = [int]$Global:GameState.Sectors.Clicker.Level
                $buff = 1.0
                if ($Global:MathState -and $Global:MathState.BuffUntil -and [DateTime]::UtcNow -lt $Global:MathState.BuffUntil) { $buff = $Global:MathState.BuffMult }
                
                $clickBuff = 1.0
                if ($Global:GameState.Flags.ContainsKey('ClickBuffUntil')) {
                    try { $until = [DateTime]::Parse($Global:GameState.Flags['ClickBuffUntil'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); if ([DateTime]::UtcNow -lt $until) { $clickBuff = [double]$Global:GameState.Flags['ClickBuffMult'] } } catch {}
                }
                
                $gain = [Math]::Max(1.0, [double]$clvl) * $buff * $clickBuff
                $Global:GameState.Player.Money += $gain
                $Global:GameState.Player.Clicks += 1
                $Global:GameState.Flags['LastClickMsg'] = ("Klik! +{0:N2}" -f $gain)
            }
            'U' {
                $cost = Get-AutoClickerCost
                if ($Global:GameState.Player.Money -ge $cost) {
                    $Global:GameState.Player.Money -= $cost
                    $Global:GameState.Sectors.Clicker.Level += 1
                    $Global:GameState.Sectors.Clicker.AutoRate = [double]$Global:GameState.Sectors.Clicker.Level * $Global:Config.ClickerAutoPerLvl
                    $Global:GameState.Flags['LastClickMsg'] = "Upgrade Clicker! Lvl $($Global:GameState.Sectors.Clicker.Level)"
                } else {
                    $Global:GameState.Flags['LastClickMsg'] = ("Uang tidak cukup! Butuh Rp {0:N2}" -f $cost)
                }
            }
            'S' { $Global:GameState.Flags['ShowStockMenu'] = $true; $Global:GameState.Flags['LastClickMsg'] = "Masuk ke Pasar Saham." }
            'M' { if (Get-Command Math-StartChallenge -ErrorAction SilentlyContinue) { Math-StartChallenge }; $Global:GameState.Flags['LastClickMsg'] = "Soal matematika dimulai!" }
            'P' { $Global:GameState.Flags['AutoIncomePaused'] = -not [bool]$Global:GameState.Flags['AutoIncomePaused'] }
        }
    }
    
    OnTick = { 
        param($dt) 
        $rate = 0.0
        if ($Global:GameState -and $Global:GameState.Sectors.Clicker.ContainsKey('AutoRate')) { $rate = [double]$Global:GameState.Sectors.Clicker.AutoRate }
        
        $buff = 1.0
        if ($Global:MathState -and $Global:MathState.BuffUntil -and [DateTime]::UtcNow -lt $Global:MathState.BuffUntil) { $buff = $Global:MathState.BuffMult }
        
        if ($Global:GameState.Flags.ContainsKey('StockBuffUntil')) {
            try { $until = [DateTime]::Parse($Global:GameState.Flags['StockBuffUntil'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); if ([DateTime]::UtcNow -lt $until) { $buff *= [double]$Global:GameState.Flags['StockBuffMult'] } } catch {}
        }

        if (-not [bool]$Global:GameState.Flags['AutoIncomePaused']) {
            $Global:GameState.Player.Money += $rate * $buff * $dt
        }
    }
}
Register-Module 'Clicker' $clickerHooks