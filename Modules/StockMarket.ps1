# StockMarket.ps1 - Logika Data Saham (Global / MetaTrader Style)
Set-StrictMode -Version 2.0
$Global:StockDataPath = Join-Path $PSScriptRoot '..\Data\stocks.json'

function Save-StockData($stocks) {
    try {
        $json = $stocks | ConvertTo-JsonCompat -Compress
        # Tulis langsung ke file global
        [System.IO.File]::WriteAllText($Global:StockDataPath, $json, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Load-StockData {
    $defaultStocks = @(
        @{ Ticker = "AAPL"; Name = "Apple Inc."; Price = 150.00; History = @(150.00); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "GOOG"; Name = "Google LLC"; Price = 2800.00; History = @(2800.00); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "TSLA"; Name = "Tesla Inc."; Price = 800.00; History = @(800.00); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "AMZN"; Name = "Amazon.com"; Price = 3300.00; History = @(3300.00); Trend = 0; TrendTimeLeft = 0 }
        @{ Ticker = "BTC";  Name = "Bitcoin"; Price = 45000.00; History = @(45000.00); Trend = 0; TrendTimeLeft = 0 }
    )
    if (-not (Test-Path $Global:StockDataPath)) { return $defaultStocks }
    try {
        $raw = [System.IO.File]::ReadAllText($Global:StockDataPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaultStocks }
        $loaded = ConvertFrom-JsonCompat $raw
        if ($null -eq $loaded) { return $defaultStocks }
        $arr = @($loaded)
        if ($arr.Count -eq 0) { return $defaultStocks }
        $parsed = @()
        foreach ($s in $arr) {
            # Ekstrak History murni sebagai angka
            $hist = @()
            if ($null -ne $s.History) {
                foreach ($h in $s.History) {
                    if ($h -is [System.Collections.IDictionary]) {
                        if ($h.ContainsKey('Price')) { $hist += [double]$h.Price }
                    } elseif ($h -is [double] -or $h -is [int] -or $h -is [decimal]) {
                        $hist += [double]$h
                    }
                }
            }
            if ($hist.Count -eq 0) { $hist = @([double]$s.Price) }
            
            $trend = 0
            $trendTime = 0
            if ($null -ne $s.Trend) { $trend = [int]$s.Trend }
            if ($null -ne $s.TrendTimeLeft) { $trendTime = [int]$s.TrendTimeLeft }

            $parsed += @{
                Ticker = [string]$s.Ticker; Name = [string]$s.Name; Price = [double]$s.Price
                History = $hist; Trend = $trend; TrendTimeLeft = $trendTime
            }
        }
        return $parsed
    } catch { return $defaultStocks }
}