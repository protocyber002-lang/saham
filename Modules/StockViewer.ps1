# StockViewer.ps1 - GUI Candlestick (Data Asli dari stocks.json)
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
    
    # Konfigurasi Timeframe (Disamakan dengan DashboardGUI)
    $Global:TfConfig = @(
        @{ Label = "1 Mnt";  Minutes = 1;   BucketSec = 2 },
        @{ Label = "5 Mnt";  Minutes = 5;   BucketSec = 5 },
        @{ Label = "15 Mnt"; Minutes = 15;  BucketSec = 10 },
        @{ Label = "1 Jam";  Minutes = 60;  BucketSec = 15 },
        @{ Label = "12 Jam"; Minutes = 720; BucketSec = 30 },
        @{ Label = "1 Hari"; Minutes = 1440;BucketSec = 60 }
    )
    $Global:CurrentTfIdx = 1
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
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $series.BorderWidth = 2
    $series.Color = [System.Drawing.Color]::Cyan
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

        # --- PARSING DATA ASLI (SAMA DENGAN DASHBOARD) ---
        $history = @()
        if ($s.History) {
            foreach ($h in $s.History) {
                if ($h -is [System.Collections.IDictionary]) {
                    if ($h.ContainsKey('Time') -and $h.ContainsKey('Price')) {
                        $dt = [DateTime]::MinValue
                        $timeStr = [string]$h.Time
                        
                        if ($timeStr -match '^\d{10,13}$') {
                            if ($timeStr.Length -eq 13) { $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$timeStr).LocalDateTime }
                            else { $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$timeStr).LocalDateTime }
                        } elseif ($timeStr -match '^\d{4}-\d{2}-\d{2}T') {
                            $dt = [DateTime]::Parse($timeStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                        } else {
                            try { $dt = [DateTime]::Parse($timeStr) } catch {}
                        }
                        
                        if ($dt -ne [DateTime]::MinValue) {
                            $history += @{ Time = $dt; Price = [double]$h.Price }
                        }
                    }
                } elseif ($h -is [double] -or $h -is [int]) {
                    $history += @{ Time = $now; Price = [double]$h }
                }
            }
        }

        if ($history.Count -eq 0) {
            $chartArea.AxisX.Minimum = $startTime.ToOADate()
            $chartArea.AxisX.Maximum = $now.ToOADate()
            return
        }

        # --- BUCKETING DATA (Untuk Line Chart) ---
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
        $minPrice = [double]::MaxValue
        $maxPrice = [double]::MinValue

        foreach ($key in $sortedKeys) {
            $prices = $buckets[$key]
            $close = [double]$prices[$prices.Count - 1]
            
            if ($close -lt $minPrice) { $minPrice = $close }
            if ($close -gt $maxPrice) { $maxPrice = $close }

            $time = [DateTime]::new($key * ([TimeSpan]::TicksPerSecond * $bucketSec))
            $series.Points.AddXY($time, $close)
        }
        
        # Set Batas X
        if (-not $Global:IsZoomed) {
            if ($series.Points.Count -gt 0) {
                # Auto-Fit Sumbu X: Hanya menampilkan rentang data yang ada
                $firstTime = [DateTime]::FromOADate($series.Points[0].XValue)
                $lastTime = [DateTime]::FromOADate($series.Points[$series.Points.Count - 1].XValue)
                
                $chartArea.AxisX.Minimum = $firstTime.AddSeconds(-$bucketSec).ToOADate()
                $chartArea.AxisX.Maximum = $lastTime.AddSeconds($bucketSec).ToOADate()
            } else {
                $chartArea.AxisX.Minimum = $startTime.ToOADate()
                $chartArea.AxisX.Maximum = $now.ToOADate()
            }
        }

        # Set Batas Y (Auto-Zoom persis seperti Dashboard)
        if ($series.Points.Count -gt 0) {
            $margin = ($maxPrice - $minPrice) * 0.2
            if ($margin -eq 0) { $margin = 1 }
            
            if (-not $Global:IsZoomed) {
                $chartArea.AxisY.Minimum = $minPrice - $margin
                $chartArea.AxisY.Maximum = $maxPrice + $margin
                $chartArea.AxisY.Interval = [Math]::Max(1, [Math]::Round(($maxPrice - $minPrice) / 5))
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
        if ($null -ne $Global:SelectedStockView) { foreach ($s in $Global:StockViewerData) { if ($s.Ticker -eq $Global:SelectedStockView.Ticker) { $Global:SelectedStockView = $s; break } } }
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