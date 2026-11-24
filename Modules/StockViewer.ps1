# StockViewer.ps1 - GUI Candlestick (Presisi & Backfill Instan)
Set-StrictMode -Version 2.0

function Start-StockViewer {
    [void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
    [void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms.DataVisualization")
    [void][Reflection.Assembly]::LoadWithPartialName("System.Drawing")

    if (-not (Get-Command Load-StockData -ErrorAction SilentlyContinue)) {
        Write-Host "Error: Modul StockMarket.ps1 belum dimuat." -ForegroundColor Red
        return
    }

    $Global:StockViewerData = Load-StockData
    if ($Global:StockViewerData.Count -eq 0) { Write-Host "Tidak ada data saham." -ForegroundColor Red; return }

    try { [void][System.Windows.Forms.Screen]::PrimaryScreen } catch {
        Write-Host "Lingkungan ini tidak mendukung GUI." -ForegroundColor Red
        return
    }

    $Global:SelectedStockView = $Global:StockViewerData[0]
    
    # Konfigurasi Timeframe
    $Global:TfConfig = @(
        @{ Label = "1 Mnt";  Minutes = 1;   BucketSec = 5 },    # Candle 5 detik (isi 5 data)
        @{ Label = "5 Mnt";  Minutes = 5;   BucketSec = 15 },   # Candle 15 detik (isi 15 data)
        @{ Label = "15 Mnt"; Minutes = 15;  BucketSec = 30 },   # Candle 30 detik (isi 30 data)
        @{ Label = "1 Jam";  Minutes = 60;  BucketSec = 60 },   # Candle 1 menit (isi 60 data)
        @{ Label = "12 Jam"; Minutes = 720; BucketSec = 600 },  # Candle 10 menit
        @{ Label = "1 Hari"; Minutes = 1440;BucketSec = 1200 }  # Candle 20 menit
    )
    $Global:CurrentTfIdx = 1 # Default 5 Mnt
    $Global:IsZoomed = $false

    # --- SETUP FORM ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ClickTycoonIdle - Market Chart"
    $form.Size = New-Object System.Drawing.Size(1000, 650)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false

    $panelTop = New-Object System.Windows.Forms.FlowLayoutPanel
    $panelTop.Dock = [System.Windows.Forms.DockStyle]::Top
    $panelTop.Height = 45
    $panelTop.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $panelTop.Padding = New-Object System.Windows.Forms.Padding(10)
    $form.Controls.Add($panelTop)

    $panelTF = New-Object System.Windows.Forms.FlowLayoutPanel
    $panelTF.Dock = [System.Windows.Forms.DockStyle]::Top
    $panelTF.Height = 40
    $panelTF.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
    $panelTF.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 0)
    $form.Controls.Add($panelTF)

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock = [System.Windows.Forms.DockStyle]::Fill
    $chart.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $form.Controls.Add($chart)

    $chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $chartArea.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $chartArea.AxisX.LabelStyle.ForeColor = [System.Drawing.Color]::DimGray
    $chartArea.AxisY.LabelStyle.ForeColor = [System.Drawing.Color]::DimGray
    $chartArea.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $chartArea.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $chartArea.AxisX.LabelStyle.Format = "HH:mm:ss"
    $chartArea.AxisY.LabelStyle.Format = "{0:N2}"
    $chartArea.AxisX.IsMarginVisible = $false
    $chart.ChartAreas.Add($chartArea)

    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name = "Price"
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Candlestick
    $series["PointWidth"] = "0.8"
    $series["PriceUpColor"] = "LimeGreen"
    $series["PriceDownColor"] = "Crimson"
    $series.Color = [System.Drawing.Color]::Gray
    $chart.Series.Add($series)

    function Reset-Zoom {
        $chartArea.AxisX.ScaleView.ZoomReset(0)
        $chartArea.AxisY.ScaleView.ZoomReset(0)
        $Global:IsZoomed = $false
        Update-ViewerChart
    }

    function Update-ViewerChart {
        $s = $Global:SelectedStockView
        if ($null -eq $s) { return }
        
        $series.Points.Clear()
        
        $cfg = $Global:TfConfig[$Global:CurrentTfIdx]
        $bucketSec = $cfg.BucketSec
        
        $now = [DateTime]::Now
        $startTime = $now.AddMinutes(-$cfg.Minutes)

        # --- DATA BACKFILL INSTAN (Jika data kurang dari 60 titik) ---
        $history = @($s.History)
        # Jika data kurang dari 60 titik (1 menit), buat backfill data per 1 detik
        if ($history.Count -lt 60) {
            $history = @()
            $tempPrice = $s.Price
            for ($i = 60; $i -ge 1; $i--) {
                $t = $now.AddSeconds(-$i * 1)
                $tempPrice += (Get-Random -Minimum -20 -Maximum 20) / 100.0
                $history += @{ Time = $t; Price = $tempPrice }
            }
            $history += @{ Time = $now; Price = $s.Price }
        }

        # --- BUCKETING DATA ---
        $buckets = @{}
        foreach ($pt in $history) {
            $t = [DateTime]$pt.Time
            if ($t -lt $startTime) { continue }
            
            $tick = [long]($t.Ticks / ([TimeSpan]::TicksPerSecond * $bucketSec))
            if (-not $buckets.ContainsKey($tick)) {
                $buckets[$tick] = New-Object System.Collections.ArrayList
            }
            [void]$buckets[$tick].Add([double]$pt.Price)
        }

        $sortedKeys = $buckets.Keys | Sort-Object
        foreach ($key in $sortedKeys) {
            $prices = $buckets[$key]
            $open = [double]$prices[0]
            $close = [double]$prices[$prices.Count - 1]
            $high = ($prices | Measure-Object -Maximum).Maximum
            $low = ($prices | Measure-Object -Minimum).Minimum
            
            $time = [DateTime]::new($key * ([TimeSpan]::TicksPerSecond * $bucketSec))
            $series.Points.AddXY($time, $high, $low, $open, $close)
        }
        
        # Set Batas X
        if (-not $Global:IsZoomed) {
            $chartArea.AxisX.Minimum = $startTime.ToOADate()
            $chartArea.AxisX.Maximum = $now.AddSeconds($bucketSec).ToOADate()
        }

        # Set Batas Y
        if ($series.Points.Count -gt 0) {
            $min = 999999.0
            $max = -999999.0
            foreach ($pt in $series.Points) {
                if ($pt.YValues[1] -lt $min) { $min = $pt.YValues[1] }
                if ($pt.YValues[0] -gt $max) { $max = $pt.YValues[0] }
            }
            $margin = ($max - $min) * 0.1
            if ($margin -eq 0) { $margin = 1 }
            
            if (-not $Global:IsZoomed) {
                $chartArea.AxisY.Minimum = $min - $margin
                $chartArea.AxisY.Maximum = $max + $margin
            }
        }
    }

    $stockButtons = @{}
    foreach ($s in $Global:StockViewerData) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $s.Ticker; $btn.Width = 70; $btn.Height = 25
        $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $btn.FlatAppearance.BorderSize = 0
        $btn.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $btn.ForeColor = [System.Drawing.Color]::White
        $btn.Tag = $s.Ticker
        $btn.Add_Click({
            $ticker = $this.Tag
            foreach ($st in $Global:StockViewerData) { if ($st.Ticker -eq $ticker) { $Global:SelectedStockView = $st; break } }
            foreach ($b in $script:stockButtons.Values) { $b.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50) }
            $this.BackColor = [System.Drawing.Color]::DodgerBlue
            Reset-Zoom
        })
        $panelTop.Controls.Add($btn)
        $stockButtons[$s.Ticker] = $btn
    }
    $stockButtons[$Global:StockViewerData[0].Ticker].BackColor = [System.Drawing.Color]::DodgerBlue

    $tfButtons = @{}
    for ($i = 0; $i -lt $Global:TfConfig.Count; $i++) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $Global:TfConfig[$i].Label; $btn.Width = 70; $btn.Height = 25
        $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $btn.FlatAppearance.BorderSize = 0
        $btn.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50); $btn.ForeColor = [System.Drawing.Color]::White
        $btn.Tag = $i
        $btn.Add_Click({
            $Global:CurrentTfIdx = $this.Tag
            foreach ($b in $script:tfButtons.Values) { $b.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50) }
            $this.BackColor = [System.Drawing.Color]::Purple
            Reset-Zoom
        })
        $panelTF.Controls.Add($btn)
        $tfButtons[$i] = $btn
    }
    $tfButtons[$Global:CurrentTfIdx].BackColor = [System.Drawing.Color]::Purple

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.Add_Tick({
        $Global:StockViewerData = Load-StockData
        if ($null -ne $Global:SelectedStockView) {
            foreach ($s in $Global:StockViewerData) {
                if ($s.Ticker -eq $Global:SelectedStockView.Ticker) {
                    $Global:SelectedStockView = $s
                    break
                }
            }
        }
        Update-ViewerChart
    })

    $script:chart = $chart
    $script:stockButtons = $stockButtons
    $script:tfButtons = $tfButtons

    Update-ViewerChart
    $timer.Start()
    [void]$form.ShowDialog()
    $timer.Stop()
}