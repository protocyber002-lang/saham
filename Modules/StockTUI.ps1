# StockTUI.ps1 - Menu Saham berbasis Teks (TUI)
Set-StrictMode -Version 2.0

function Start-StockTUI {
    $stocks = Load-StockData
    
    # Pastikan portofolio ada di save
    if (-not $Global:GameState.ContainsKey('Portfolio')) { $Global:GameState.Portfolio = @{} }
    foreach ($s in $stocks) {
        if (-not $Global:GameState.Portfolio.ContainsKey($s.Ticker)) {
            $Global:GameState.Portfolio[$s.Ticker] = @{ Shares = 0; AvgPrice = 0.0 }
        }
    }

    $selectedIdx = 0
    $running = $true
    $lastUpdate = [DateTime]::UtcNow
    $msg = "Pilih saham untuk melihat detail."

    # Simpan state game sebelum masuk
    $Global:GameState.Flags['LastClickMsg'] = "Masuk ke Pasar Saham"

    while ($running) {
        $now = [DateTime]::UtcNow
        $dt = ($now - $lastUpdate).TotalSeconds
        
        # Update harga saham tiap 5 detik (Game tetap jalan)
        if ($dt -ge 5.0) {
            $lastUpdate = $now
            foreach ($s in $stocks) {
                $change = (Get-Random -Minimum -20 -Maximum 20) / 100.0
                $s.Price += $change
                if ($s.Price -lt 1.0) { $s.Price = 1.0 }
                $s.History += $s.Price
                if ($s.History.Count -gt 20) { $s.History = $s.History[1..19] }
            }
            Save-StockData $stocks
        }

        # --- RENDER TUI ---
        try { Clear-Host } catch { }
        Write-Host "==========================================================================" -ForegroundColor DarkCyan
        Write-Host "                            PASAR SAHAM                                   " -ForegroundColor Cyan
        Write-Host "==========================================================================" -ForegroundColor DarkCyan
        
        Write-Host " ID | TICKER | NAMA             | HARGA      | TREN 1H  | DIMILIKI" -ForegroundColor DarkGray
        Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkCyan

        for ($i = 0; $i -lt $stocks.Count; $i++) {
            $s = $stocks[$i]
            $owned = $Global:GameState.Portfolio[$s.Ticker].Shares
            
            # Hitung Tren 1 Jam
            $trend1h = 0.0
            if ($s.History.Count -gt 1) {
                $oldPrice = $s.History[0]
                $trend1h = (($s.Price - $oldPrice) / $oldPrice) * 100
            }
            
            $color = "Gray"
            $trendStr = "{0:F2}%" -f $trend1h
            if ($trend1h -gt 0) { $color = "Green"; $trendStr = "+$trendStr" }
            elseif ($trend1h -lt 0) { $color = "Red" }

            $sel = "  "
            if ($i -eq $selectedIdx) { $sel = "> " }

            Write-Host ("{0}[{1}]  | {2,-6} | {3,-16} | {4,10:N2} | " -f $sel, ($i+1), $s.Ticker, $s.Name, $s.Price) -NoNewline
            Write-Host ("{0,8} | {1,5}" -f $trendStr, $owned) -ForegroundColor $color
        }

        Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkCyan
        
        # --- DETAIL SAHAM TERPILIH ---
        $selStock = $stocks[$selectedIdx]
        $selPort = $Global:GameState.Portfolio[$selStock.Ticker]
        
        Write-Host ("UANG ANDA: Rp {0:N2}" -f $Global:GameState.Player.Money) -ForegroundColor Yellow
        Write-Host ("DETAIL {0}:" -f $selStock.Ticker) -ForegroundColor Cyan
        
        $profit = 0.0
        if ($selPort.Shares -gt 0) {
            $profit = ($selStock.Price - $selPort.AvgPrice) * $selPort.Shares
        }
        
        Write-Host ("  - Kepemilikan  : {0} lembar (Avg Beli: Rp {1:N2})" -f $selPort.Shares, $selPort.AvgPrice)
        $profitColor = "Gray"
        if ($profit -gt 0) { $profitColor = "Green" }
        elseif ($profit -lt 0) { $profitColor = "Red" }
        Write-Host ("  - Estimasi P/L : Rp {0:N2}" -f $profit) -ForegroundColor $profitColor
        
        Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host " [W/S] Pilih Saham | [1] Beli 1 | [2] Beli 10 | [3] Beli 50 | [4] Beli 100" -ForegroundColor DarkGray
        Write-Host " [5] Jual 10 | [6] Jual Semua | [ESC] Kembali ke Game" -ForegroundColor DarkGray
        Write-Host (" Status: {0}" -f $msg) -ForegroundColor Yellow

        # --- INPUT HANDLER (Non-blocking dengan Timeout) ---
        $key = $null
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
            }
        } catch {}

        if ($key) {
            switch ($key.Key) {
                'W' { if ($selectedIdx -gt 0) { $selectedIdx--; $msg = "" } }
                'UpArrow' { if ($selectedIdx -gt 0) { $selectedIdx--; $msg = "" } }
                'S' { if ($selectedIdx -lt $stocks.Count - 1) { $selectedIdx++; $msg = "" } }
                'DownArrow' { if ($selectedIdx -lt $stocks.Count - 1) { $selectedIdx++; $msg = "" } }
                'Escape' { $running = $false }
                
                'D1' {
                    $cost = $selStock.Price * 1
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += 1
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        $msg = "Beli 1 lembar $($selStock.Ticker)"
                    } else { $msg = "Uang tidak cukup!" }
                }
                'D2' {
                    $cost = $selStock.Price * 10
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += 10
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        $msg = "Beli 10 lembar $($selStock.Ticker)"
                    } else { $msg = "Uang tidak cukup!" }
                }
                'D3' {
                    $cost = $selStock.Price * 50
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += 50
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        $msg = "Beli 50 lembar $($selStock.Ticker)"
                    } else { $msg = "Uang tidak cukup!" }
                }
                'D4' {
                    $cost = $selStock.Price * 100
                    if ($Global:GameState.Player.Money -ge $cost) {
                        $Global:GameState.Player.Money -= $cost
                        $oldTotal = $selPort.AvgPrice * $selPort.Shares
                        $selPort.Shares += 100
                        $selPort.AvgPrice = ($oldTotal + $cost) / $selPort.Shares
                        $msg = "Beli 100 lembar $($selStock.Ticker)"
                    } else { $msg = "Uang tidak cukup!" }
                }
                'D5' {
                    $qty = [Math]::Min(10, $selPort.Shares)
                    if ($qty -gt 0) {
                        $earn = $selStock.Price * $qty
                        $Global:GameState.Player.Money += $earn
                        $selPort.Shares -= $qty
                        if ($selPort.Shares -eq 0) { $selPort.AvgPrice = 0 }
                        $msg = "Jual $qty lembar $($selStock.Ticker)"
                    } else { $msg = "Saham tidak cukup!" }
                }
                'D6' {
                    if ($selPort.Shares -gt 0) {
                        $qty = $selPort.Shares
                        $earn = $selStock.Price * $qty
                        $Global:GameState.Player.Money += $earn
                        $selPort.Shares = 0
                        $selPort.AvgPrice = 0
                        $msg = "Jual SEMUA $qty lembar $($selStock.Ticker)"
                    } else { $msg = "Saham tidak cukup!" }
                }
            }
        }

        Start-Sleep -Milliseconds 50 # Mencegah CPU 100%
    }
    
    # Kembali ke game
    SaveSystem.Save
}