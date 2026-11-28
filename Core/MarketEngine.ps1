# MarketEngine.ps1 - Entitas Tunggal Penggerak Harga Saham
Set-StrictMode -Version 2.0
$Global:StockDataPath = Join-Path $PSScriptRoot '..\Data\stocks.json'
$votesPath = Join-Path $PSScriptRoot '..\Data\stock_votes.json'
$annPath = Join-Path $PSScriptRoot '..\Data\announcements.json'
$profilesDir = Join-Path $PSScriptRoot '..\Data\profiles'
$logPath = Join-Path $PSScriptRoot '..\Data\market.log'

function Write-Log($msg) {
    try {
        $timestamp = [DateTime]::Now.ToString("HH:mm:ss")
        [System.IO.File]::AppendAllText($logPath, "[$timestamp] $msg`r`n")
    } catch {}
}

function Save-MarketData($stocks) {
    try {
        # Konversi Time ke string ISO agar aman saat diserialisasi
        foreach ($s in $stocks) {
            $newHist = @()
            foreach ($h in $s.History) {
                if ($h.Time -is [DateTime]) {
                    $newHist += @{ Time = $h.Time.ToString("o"); Price = $h.Price }
                } else {
                    $newHist += $h
                }
            }
            $s.History = $newHist
        }
        $json = $stocks | ConvertTo-Json -Depth 5 -Compress
        $tmp = "$Global:StockDataPath.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $Global:StockDataPath) { Remove-Item $Global:StockDataPath -Force -ErrorAction SilentlyContinue }
        Move-Item $tmp $Global:StockDataPath -Force
    } catch { Write-Log "SAVE ERROR: $($_.Exception.Message)" }
}

function Get-ProfileCountV {
    try {
        $files = @(Get-ChildItem $profilesDir -Filter "*.json" -ErrorAction SilentlyContinue)
        return $files.Count
    } catch { return 0 }
}

function Get-StockVotes {
    $result = @{}
    try {
        if (Test-Path $votesPath) {
            $raw = [System.IO.File]::ReadAllText($votesPath) -replace "^\uFEFF", ""
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                foreach ($p in $obj.PSObject.Properties) {
                    $list = @()
                    if ($null -ne $p.Value) { foreach ($v in @($p.Value)) { $list += [string]$v } }
                    $result[[string]$p.Name] = $list
                }
            }
        }
    } catch { }
    return $result
}

function Save-StockVotes($votes) {
    try {
        $tmp = "$votesPath.tmp"
        $json = "{}"
        if ($votes.Count -gt 0) { $json = $votes | ConvertTo-Json -Depth 5 -Compress }
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $votesPath) { Remove-Item $votesPath -Force -ErrorAction SilentlyContinue }
        Move-Item $tmp $votesPath -Force
    } catch { }
}

function Add-Announcement($msg) {
    try {
        $items = @()
        if (Test-Path $annPath) {
            $raw = [System.IO.File]::ReadAllText($annPath) -replace "^\uFEFF", ""
            if (-not [string]::IsNullOrWhiteSpace($raw)) { try { $items = @($raw | ConvertFrom-Json) } catch { $items = @() } }
        }
        $items += @{ Time = [DateTime]::UtcNow.ToString("o"); Message = $msg }
        while (@($items).Count -gt 50) { $items = @($items[1..(@($items).Count - 1)]) }
        $tmp = "$annPath.tmp"
        [System.IO.File]::WriteAllText($tmp, ($items | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $annPath) { Remove-Item $annPath -Force -ErrorAction SilentlyContinue }
        Move-Item $tmp $annPath -Force
    } catch { }
}

function Load-MarketData {
    $defaults = @(
        @{ Ticker = "AAPL"; Name = "Apple Inc."; Price = 150.00; History = @(); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "GOOG"; Name = "Google LLC"; Price = 2800.00; History = @(); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "TSLA"; Name = "Tesla Inc."; Price = 800.00; History = @(); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "AMZN"; Name = "Amazon.com"; Price = 3300.00; History = @(); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "BTC";  Name = "Bitcoin"; Price = 45000.00; History = @(); Trend = 0; TrendTimeLeft = 0 }
    )
    
    $needsBackfill = $false
    $parsed = @()

    if (Test-Path $Global:StockDataPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($Global:StockDataPath, [System.Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $loaded = $raw | ConvertFrom-Json
                foreach ($s in $loaded) {
                    $trend = 0; $trendTime = 0
                    if ($null -ne $s.Trend) { $trend = [int]$s.Trend }
                    if ($null -ne $s.TrendTimeLeft) { $trendTime = [int]$s.TrendTimeLeft }
                    
                    $hist = @()
                    if ($null -ne $s.History) {
                        foreach ($h in $s.History) {
                            if ($h -is [string] -or $h -is [double] -or $h -is [int]) {
                                $hist += @{ Time = [DateTime]::Now; Price = [double]$h }
                            } else {
                                $t = [DateTime]::Now
                                if ($null -ne $h.Time) { [DateTime]::TryParse([string]$h.Time, [ref]$t) | Out-Null }
                                $hist += @{ Time = $t; Price = [double]$h.Price }
                            }
                        }
                    }
                    
                    if ($hist.Count -lt 5) { $needsBackfill = $true }

                    $parsed += @{
                        Ticker = [string]$s.Ticker; Name = [string]$s.Name; Price = [double]$s.Price
                        History = $hist; Trend = $trend; TrendTimeLeft = $trendTime
                    }
                }
            } else { $needsBackfill = $true }
        } catch { $needsBackfill = $true }
    } else {
        $needsBackfill = $true
    }

    if ($needsBackfill -or $parsed.Count -eq 0) {
        Write-Log "File kosong/baru. Melakukan Backfill 1 Jam (720 candle)..."
        $parsed = $defaults
        $now = [DateTime]::Now
        foreach ($s in $parsed) {
            $s.History = @()
            $currentPrice = $s.Price
            # Buat 720 data ke belakang (1 jam ke belakang)
            for ($i = 720; $i -ge 1; $i--) {
                $time = $now.AddSeconds(-$i * 5)
                $change = (Get-Random -Minimum -20 -Maximum 20) / 100.0
                $currentPrice += $change
                if ($currentPrice -lt 1.0) { $currentPrice = 1.0 }
                $s.History += @{ Time = $time; Price = $currentPrice }
            }
            $s.Price = $currentPrice
        }
        Save-MarketData $parsed
    }

    return $parsed
}

Write-Log "=== MARKET ENGINE STARTED ==="
while ($true) {
    try {
        $stocks = Load-MarketData
        $now = [DateTime]::Now

        # Proses vote hapus saham: >= 51% dari semua profil meminta
        try {
            $profCount = Get-ProfileCountV
            if ($profCount -ge 1) {
                $threshold = [Math]::Ceiling(0.51 * $profCount)
                $votes = Get-StockVotes
                $votesChanged = $false
                foreach ($tk in @($votes.Keys)) {
                    $voters = @($votes[$tk])
                    if ($voters.Count -ge $threshold) {
                        $target = $null
                        foreach ($s in $stocks) { if ($s.Ticker -eq $tk) { $target = $s; break } }
                        if ($null -ne $target) {
                            $stocks = @($stocks | Where-Object { $_.Ticker -ne $tk })
                            Add-Announcement ("Saham {0} ({1}) dihapus - disetujui {2} dari {3} profil" -f $tk, $target.Name, $voters.Count, $profCount)
                            Write-Log ("Saham {0} dihapus (vote {1}/{2} profil)" -f $tk, $voters.Count, $profCount)
                        }
                        $votes.Remove($tk)
                        $votesChanged = $true
                    }
                }
                if ($votesChanged) { Save-StockVotes $votes }
            }
        } catch { Write-Log ("VOTE ERROR: " + $_.Exception.Message) }
        
        foreach ($s in $stocks) {
            if ($s.TrendTimeLeft -le 0) {
                $s.Trend = Get-Random -Minimum 0 -Maximum 3
                $s.TrendTimeLeft = Get-Random -Minimum 10 -Maximum 31
            }

            $change = 0.0
            if ($s.Trend -eq 1) { $change = (Get-Random -Minimum 0 -Maximum 51) / 100.0 }
            elseif ($s.Trend -eq 2) { $change = (Get-Random -Minimum -50 -Maximum 1) / 100.0 }
            else { $change = (Get-Random -Minimum -10 -Maximum 11) / 100.0 }

            $s.Price += $change
            if ($s.Price -lt 1.0) { $s.Price = 1.0 }
            $s.TrendTimeLeft--

            # Tambahkan data baru
            $s.History += @{ Time = $now; Price = $s.Price }
            
            # Batasi maksimal 1000 candle
            if ($s.History.Count -gt 1000) { 
                $s.History = $s.History[($s.History.Count - 1000)..($s.History.Count - 1)] 
            }
        }
        Save-MarketData $stocks
    } catch {
        Write-Log "TICK ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 1
}