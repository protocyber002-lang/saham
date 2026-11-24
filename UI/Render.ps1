# Render.ps1 - Dashboard TUI Final
Set-StrictMode -Version 2.0

function Format-Playtime([double]$seconds) {
    if ($seconds -lt 0) { $seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($seconds)
    $h = [int][Math]::Floor($ts.TotalHours)
    return ("{0:00}:{1:00}:{2:00}" -f $h, $ts.Minutes, $ts.Seconds)
}

function Get-SafeVal($obj, $key, $default) {
    if ($null -eq $obj) { return $default }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.ContainsKey($key)) { return $obj[$key] }
        return $default
    }
    $p = $obj.PSObject.Properties[$key]
    if ($null -ne $p) { return $p.Value }
    return $default
}

function Get-StockGraph($history) {
    if (-not $history -or $history.Count -eq 0) { return "" }
    
    $chars = @([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
    $validPrices = @()
    foreach ($h in $history) {
        if ($h -is [System.Collections.IDictionary]) {
            if ($h.ContainsKey('Price')) { $validPrices += [double]$h.Price }
        } elseif ($h -is [double] -or $h -is [int] -or $h -is [decimal]) {
            $validPrices += [double]$h
        }
    }
    
    if ($validPrices.Count -eq 0) { return "" }
    if ($validPrices.Count -lt 5) {
        $dummy = @()
        $lastP = $validPrices[0]
        for ($j=0; $j -lt 10; $j++) {
            $lastP += (Get-Random -Minimum -10 -Maximum 11) / 100.0
            $dummy += $lastP
        }
        $validPrices = $dummy
    }

    $min = ($validPrices | Measure-Object -Minimum).Minimum
    $max = ($validPrices | Measure-Object -Maximum).Maximum
    $range = $max - $min
    if ($range -eq 0) { $range = 1.0 }

    $sb = New-Object System.Text.StringBuilder
    $display = $validPrices
    if ($display.Count -gt 20) { $display = $display[($display.Count - 20)..($display.Count - 1)] }

    foreach ($p in $display) {
        $pct = ($p - $min) / $range
        $idx = [int]($pct * ($chars.Count - 1))
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $chars.Count) { $idx = $chars.Count - 1 }
        [void]$sb.Append($chars[$idx])
    }
    return $sb.ToString()
}

function Render-Dashboard { 
    param([switch]$ClearFirst)
    $s = $Global:GameState
    if ($ClearFirst) { try { Clear-Host } catch { } }
    
    $player  = Get-SafeVal $s 'Player'  @{}
    $flags   = Get-SafeVal $s 'Flags' @{}
    
    $isStockMenu = $false
    $isLogMenu = $false
    $isBotMenu = $false
    if ($flags.ContainsKey('ShowLogMenu') -and [bool]$flags['ShowLogMenu']) { $isLogMenu = $true }
    if ($flags.ContainsKey('ShowStockMenu') -and [bool]$flags['ShowStockMenu']) { $isStockMenu = $true }
    if ($flags.ContainsKey('ShowBotMenu') -and [bool]$flags['ShowBotMenu']) { $isBotMenu = $true }

    $w = 79
    try { if ([Console]::WindowWidth -gt 1) { $w = [Console]::WindowWidth - 1 } } catch {}
    if ($w -lt 40) { $w = 79 }

    $lines = @()

    # ==========================================
    # MENU AUTO-BOT
    # ==========================================
    if ($isBotMenu) {
        $stocks = Load-StockData
        $lines += "====================== AUTO-BOT SAHAM ======================"
        $lines += " ID | TICKER | STATUS | BELI% | JUAL% | SISA WAKTU"
        $lines += "------------------------------------------------------------"
        
        $selIdx = 0
        if ($flags.ContainsKey('BotSelectedIdx')) { $selIdx = [int]$flags['BotSelectedIdx'] }
        if ($selIdx -ge $stocks.Count) { $selIdx = $stocks.Count - 1 }

        for ($i = 0; $i -lt $stocks.Count; $i++) {
            $st = $stocks[$i]
            $botStatus = "OFF"
            $buyPct = $Global:Config.AutoBotDefaultBuyPct
            $sellPct = $Global:Config.AutoBotDefaultSellPct
            $timeLeft = "-"

            if ($null -ne $Global:GameState -and $Global:GameState.ContainsKey('ActiveBots') -and $Global:GameState.ActiveBots.ContainsKey($st.Ticker)) {
                $bot = $Global:GameState.ActiveBots[$st.Ticker]
                $botStatus = "ON"
                if ($bot.ContainsKey('BuyPct')) { $buyPct = $bot.BuyPct }
                if ($bot.ContainsKey('SellPct')) { $sellPct = $bot.SellPct }
                if ($bot.ContainsKey('TimeLeft')) { 
                    $mins = [Math]::Floor($bot.TimeLeft / 60)
                    $secs = $bot.TimeLeft % 60
                    $timeLeft = "{0:N0}m {1:N0}s" -f $mins, $secs 
                }
            }
            
            $sel = if ($i -eq $selIdx) { ">" } else { " " }
            $lines += ("{0}[{1}]  | {2,-6} | {3,6} | {4,4}% | {5,4}% | {6,10}" -f $sel, ($i+1), $st.Ticker, $botStatus, $buyPct, $sellPct, $timeLeft)
        }

        $lines += "------------------------------------------------------------"
        $lines += "[1-5] Pilih Saham | [E] Beli Paket Ekonomis | [V] Beli Paket VIP"
        $lines += "[+/-] Ubah Trigger Beli | [B] Kembali | [Q] Keluar Game"
        
        $msg = Get-SafeVal $flags 'LastClickMsg' ""
        if ($msg) { $lines += "  > $msg" }
    }
    # ==========================================
    # MENU LOG TRANSAKSI
    # ==========================================
    elseif ($isLogMenu) {
        $lines += "===================== LOG TRANSAKSI ====================="
        $lines += " WAKTU              | TICKER | TIPE | QTY  | HARGA"
        $lines += "---------------------------------------------------------"
        
        $logs = @()
        if ($Global:GameState.ContainsKey('TransactionLog')) { $logs = $Global:GameState.TransactionLog }
        
        $startIdx = [Math]::Max(0, $logs.Count - 15)
        for ($i = $startIdx; $i -lt $logs.Count; $i++) {
            $l = $logs[$i]
            $lines += (" {0} | {1,-6} | {2,-4} | {3,4} | {4,10:N2}" -f $l.Time, $l.Ticker, $l.Type, $l.Qty, $l.Price)
        }
        
        $lines += "---------------------------------------------------------"
        $lines += "[ESC] Kembali ke Pasar Saham | [Q] Keluar Game"
        $msg = Get-SafeVal $flags 'LastClickMsg' ""
        if ($msg) { $lines += "  > $msg" }
    }
    # ==========================================
    # MENU SAHAM
    # ==========================================
    elseif ($isStockMenu) {
        $stocks = Load-StockData
        if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState.Portfolio = @{} }
        foreach ($st in $stocks) {
            if (-not $Global:GameState.Portfolio.ContainsKey($st.Ticker)) { $Global:GameState.Portfolio[$st.Ticker] = @{ Shares = 0; AvgPrice = 0.0 } }
        }

        $selIdx = 0
        if ($flags.ContainsKey('StockSelectedIdx')) { $selIdx = [int]$flags['StockSelectedIdx'] }
        if ($selIdx -ge $stocks.Count) { $selIdx = $stocks.Count - 1 }

        $totalStockValue = 0.0
        $totalStockCost = 0.0
        foreach ($st in $stocks) {
            $shares = $Global:GameState.Portfolio[$st.Ticker].Shares
            if ($shares -gt 0) {
                $totalStockValue += ($st.Price * $shares)
                $totalStockCost += ($Global:GameState.Portfolio[$st.Ticker].AvgPrice * $shares)
            }
        }
        $totalProfit = $totalStockValue - $totalStockCost
        
        $lines += "================================ PASAR SAHAM =================================="
        $lines += " ID | TICKER | LMBR | AVG BELI | HARGA SKRG | TREN  | SINYAL (Prob) | GRAFIK 1 JAM"
        $lines += "------------------------------------------------------------------------------"
        
        for ($i = 0; $i -lt $stocks.Count; $i++) {
            $st = $stocks[$i]
            $owned = $Global:GameState.Portfolio[$st.Ticker].Shares
            $avgPrice = $Global:GameState.Portfolio[$st.Ticker].AvgPrice
            $avgStr = if ($owned -gt 0) { "{0:N2}" -f $avgPrice } else { "-" }
            
            $trend = 0.0
            if ($owned -gt 0 -and $avgPrice -gt 0) {
                $trend = (($st.Price - $avgPrice) / $avgPrice) * 100
            } elseif ($st.History.Count -gt 1) {
                $oldVal = $st.History[0]
                if ($oldVal -is [System.Collections.IDictionary] -and $oldVal.ContainsKey('Price')) { $oldVal = $oldVal.Price }
                $old = [double]$oldVal
                if ($old -gt 0) { $trend = (($st.Price - $old) / $old) * 100 }
            }
            
            $tStr = "{0:F2}%" -f $trend
            if ($trend -gt 0) { $tStr = "+$tStr" }
            
            $avg20 = 0.0
            if ($st.History.Count -gt 0) {
                $sum = 0.0
                foreach ($h in $st.History) { $sum += $h }
                $avg20 = $sum / $st.History.Count
            }
            $skorNilai = 0.0
            if ($avg20 -gt 0) { $skorNilai = (($avg20 - $st.Price) / $avg20) * 100 }
            $skorTren = 0
            if ($st.Trend -eq 1) { $skorTren = 30 }
            elseif ($st.Trend -eq 2) { $skorTren = -30 }
            
            $totalSkor = $skorNilai + $skorTren
            $prob = [Math]::Round(($totalSkor + 100) / 2)
            if ($prob -gt 100) { $prob = 100 }
            if ($prob -lt 0) { $prob = 0 }

            $sigStr = ""
            if ($prob -ge 70) { $sigStr = "[BELI  $prob%]" }
            elseif ($prob -le 39) { $sigStr = "[JUAL  $prob%]" }
            else { $sigStr = "[TUNGGU $prob%]" }

            $graphStr = Get-StockGraph $st.History
            $sel = if ($i -eq $selIdx) { ">" } else { " " }
            
            $lines += ("{0}[{1}]  | {2,-6} | {3,4} | {4,8} | {5,10:N2} | {6,5} | {7,13} | {8}" -f $sel, ($i+1), $st.Ticker, $owned, $avgStr, $st.Price, $tStr, $sigStr, $graphStr)
        }

        $lines += "------------------------------------------------------------------------------"
        $selSt = $stocks[$selIdx]
        $selPort = $Global:GameState.Portfolio[$selSt.Ticker]
        $profit = 0.0
        if ($selPort.Shares -gt 0) { $profit = ($selSt.Price - $selPort.AvgPrice) * $selPort.Shares }
        
        $lines += ("CASH ANDA: Rp {0:N2}" -f $Global:GameState.Player.Money)
        $lines += ("NILAI SAHAM: Rp {0:N2}" -f $totalStockValue)
        
        $pStr = "{0:N2}" -f $totalProfit
        if ($totalProfit -gt 0) { $pStr = "+$pStr" }
        $lines += ("TOTAL P/L : Rp {0,12}" -f $pStr)
        $lines += ("DETAIL {0}: {1} lembar | Avg Rp {2:N2} | Est P/L Rp {3:N2}" -f $selSt.Ticker, $selPort.Shares, $selPort.AvgPrice, $profit)
        $lines += "[W/S] Pilih | [1] Beli 1 | [2] Beli 10 | [3] Beli 50 | [4] Beli 100"
        $lines += "[5] Jual 10 | [6] Jual Saham Ini | [7] Jual SEMUA SAHAM | [B] Bot | [L] Log | [Q] Keluar | [ESC] Kembali"
        
        $msg = Get-SafeVal $flags 'LastClickMsg' ""
        if ($msg) { $lines += "  > $msg" }
    } 
    # ==========================================
    # GAME UTAMA (KLIKER)
    # ==========================================
    else {
        $sectors = Get-SafeVal $s 'Sectors' @{}
        $clicker = Get-SafeVal $sectors 'Clicker' @{}

        $cash     = [double](Get-SafeVal $player  'Money' 0.0)
        $clicks   = [int](Get-SafeVal $player  'Clicks' 0)
        $mathOk   = [int](Get-SafeVal $player  'MathSolved' 0)
        $playtime = [double](Get-SafeVal $player 'PlaytimeSec' 0.0)
        $clvl     = [int](Get-SafeVal $clicker 'Level' 1)
        $arate    = [double](Get-SafeVal $clicker 'AutoRate' 0.0)

        $asset    = Get-TotalAssetValue $s
        $netWorth = $cash + $asset

        $buff = 1.0
        $buffLeft = 0
        if ($Global:MathState -and $Global:MathState.BuffUntil -and [DateTime]::UtcNow -lt $Global:MathState.BuffUntil) {
            $buff = $Global:MathState.BuffMult
            $buffLeft = [int](($Global:MathState.BuffUntil - [DateTime]::UtcNow).TotalSeconds)
        }

        $clickBuff = 1.0
        $clickBuffLeft = 0
        if ($flags.ContainsKey('ClickBuffUntil')) {
            try {
                $until = [DateTime]::Parse($flags['ClickBuffUntil'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ([DateTime]::UtcNow -lt $until) {
                    $clickBuff = [double]$flags['ClickBuffMult']
                    $clickBuffLeft = [int](($until - [DateTime]::UtcNow).TotalSeconds)
                }
            } catch {}
        }

        # --- STOCK BUY BUFF ---
        $stockBuff = 1.0
        $stockBuffLeft = 0
        if ($flags.ContainsKey('StockBuffUntil')) {
            try {
                $untilStock = [DateTime]::Parse($flags['StockBuffUntil'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ([DateTime]::UtcNow -lt $untilStock) {
                    $stockBuff = [double]$flags['StockBuffMult']
                    $stockBuffLeft = [int](($untilStock - [DateTime]::UtcNow).TotalSeconds)
                }
            } catch {}
        }

        $stockValue = 0.0
        $stockCost = 0.0
        if ($Global:GameState.ContainsKey('Portfolio')) {
            $stocks = Load-StockData
            foreach ($stk in $stocks) {
                if ($Global:GameState.Portfolio.ContainsKey($stk.Ticker)) {
                    $p = $Global:GameState.Portfolio[$stk.Ticker]
                    $shares = [int]$p.Shares
                    if ($shares -gt 0) {
                        $stockValue += ($stk.Price * $shares)
                        $stockCost += ($p.AvgPrice * $shares)
                    }
                }
            }
        }
        $stockProfit = $stockValue - $stockCost
        $prof = Get-ActiveProfile
        if (-not $prof) { $prof = "unknown" }
        
        $lines += ("==== CLICK-TYCOON-IDLE ==== [{0}]" -f $prof)
        $lines += ("Cash      : {0,15:N2}" -f $cash)
        $lines += ("Asset     : {0,15:N2}" -f $asset)
        $lines += ("Net Worth : {0,15:N2}" -f $netWorth)
        
        $pStr = "{0:N2}" -f $stockProfit
        if ($stockProfit -gt 0) { $pStr = "+$pStr" }
        $lines += ("Stock P/L : {0,15}" -f $pStr)

        $lines += "----------------------------------------"
        if ($null -ne $Global:PairingCode) {
            $lines += ("PAIRING CODE: {0} | Admin: http://[IP]:8999/admin" -f $Global:PairingCode)
        }
        $lines += ("Clicks    : {0}" -f $clicks)
        $lines += ("Math ok   : {0}" -f $mathOk)
        $lines += ("Playtime  : {0}" -f (Format-Playtime $playtime))
        
        $autoStatus = ""
        if ($flags.ContainsKey('AutoIncomePaused') -and [bool]$flags['AutoIncomePaused']) { $autoStatus = " [PAUSED]" }
        $lines += ("Clicker   : lvl {0}  auto {1:N2}/s{2}" -f $clvl, $arate, $autoStatus)

        try {
            $manualGain = [Math]::Max(0, [double]$clvl) * [Math]::Max(1.0, [double]$buff) * [Math]::Max(1.0, [double]$clickBuff)
            $gainStr = "Click Gain: {0:N2} / klik" -f $manualGain
            if ($clickBuff -gt 1.0) {
                $gainStr += ("  [BONUS x{0:N1} : {1}s]" -f $clickBuff, $clickBuffLeft)
            }
            $lines += $gainStr
        } catch { $lines += "Click Gain: (error)" }
        
        if ($buff -gt 1.0) { $lines += ("BUFF AUTO : x{0:N2}  ({1}s)" -f $buff, $buffLeft) }
        if ($stockBuff -gt 1.0) { $lines += ("STOCK BUFF: x{0:N2}  ({1}s)" -f $stockBuff, $stockBuffLeft) }
        
        $lines += "----------------------------------------"
        if ($null -ne $Global:PairingCode) {
            $lines += ("PAIRING CODE: {0} | Admin: http://[IP]:8999/admin" -f $Global:PairingCode)
        }

        if ($Global:MathState -and $Global:MathState.Active) {
            $elapsed = ([DateTime]::UtcNow - $Global:MathState.StartedUtc).TotalSeconds
            $left = [int]($Global:MathState.TimeoutSec - $elapsed)
            if ($left -lt 0) { $left = 0 }
            $lines += ("SOAL: {0} = ?   [{1}s]" -f $Global:MathState.Question, $left)
            $lines += ("buffer: {0}_" -f $Global:MathState.Buffer)
            $lines += "Ketik jawaban, Enter=kirim, [S]=lewati, Esc=batal"
        } else {
            $lines += "Idle. [SPACE] klik  [U] upgrade  [M] math  [S] saham  [P] pause  [Q] keluar"
        }

        $msg1 = Get-SafeVal $flags 'LastClickMsg' ""
        $msg2 = Get-SafeVal $flags 'LastMathMsg' ""
        if ($msg1) { $lines += ("  > " + $msg1) }
        if ($msg2) { $lines += ("  > " + $msg2) }
    }

    # ==========================================
    # RENDER LAYAR
    # ==========================================
    try { [Console]::SetCursorPosition(0,0) } catch {}
    for ($i=0; $i -lt $lines.Count; $i++) {
        $ln = [string]$lines[$i]
        if ($ln.Length -gt $w) { $ln = $ln.Substring(0,$w) }
        $ln = $ln.PadRight($w)
        
        $color = "Gray"
        if ($ln -match '^STOCK BUFF') { $color = "Green" }
        elseif ($ln -match '^BUFF AUTO') { $color = "Cyan" }
        
        if ($isStockMenu) {
            if ($ln -match '\[BELI') { $color = "Green" }
            elseif ($ln -match '\[JUAL') { $color = "Red" }
            elseif ($ln -match '\[TUNGGU') { $color = "DarkGray" }
            elseif ($ln -match '^TOTAL P/L') {
                if ($ln -match '\-') { $color = "Red" }
                elseif ($ln -match '\+') { $color = "Green" }
            }
        } else {
            if ($ln -match '^Stock P/L') {
                if ($ln -match '\-') { $color = "Red" }
                elseif ($ln -match '\+') { $color = "Green" }
            }
        }
        
        Write-Host $ln -NoNewline -ForegroundColor $color
        if ($i -lt $lines.Count-1) { Write-Host "" }
    }
}