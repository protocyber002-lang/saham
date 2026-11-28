# DashboardGUI.ps1 - GUI Utama ClickTycoonIdle (V19 - Tab Kerja)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms.DataVisualization

# --- ANTI-SLEEP ---
if (-not ([System.Management.Automation.PSTypeName]'SleepPreventer').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SleepPreventer {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
    public static void PreventSleep() { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED); }
    public static void AllowSleep() { SetThreadExecutionState(ES_CONTINUOUS); }
}
"@
}
[SleepPreventer]::PreventSleep()
Write-Host "[DashboardGUI] Versi antrian v3: eksekusi di luar kunci + kuitansi utk semua hasil (Executed/Held/Failed)" -ForegroundColor Cyan

# --- KONFIGURASI WARNA TEMA ---
$ColorBg       = [System.Drawing.Color]::FromArgb(24, 24, 28)
$ColorPanel    = [System.Drawing.Color]::FromArgb(36, 36, 42)
$ColorText     = [System.Drawing.Color]::FromArgb(220, 220, 225)
$ColorAccent   = [System.Drawing.Color]::FromArgb(0, 150, 255)
$ColorSuccess  = [System.Drawing.Color]::FromArgb(0, 200, 100)
$ColorDanger   = [System.Drawing.Color]::FromArgb(255, 60, 60)
$ColorGrid     = [System.Drawing.Color]::FromArgb(45, 45, 55)

# --- VARIABEL GLOBAL ---
$Global:RootPath = Split-Path -Parent $PSScriptRoot
$Global:ProfilesDir = Join-Path $Global:RootPath "Data\profiles"
$Global:StocksPath  = Join-Path $Global:RootPath "Data\stocks.json"
$Global:QueuePath   = Join-Path $Global:RootPath "Data\queue.json"
$Global:ReceiptsPath = Join-Path $Global:RootPath "Data\receipts.json"
$Global:QueueLockPath = Join-Path $Global:RootPath "Data\queue.lock"
$Global:ProcessedOrderIds = New-Object System.Collections.Generic.List[string]
$Global:QueueSeenIds = New-Object System.Collections.Generic.List[string]
$Global:ConfigPath  = Join-Path $Global:RootPath "Core\Config.ps1"
$Global:ProfilePath = ""
$Global:ActiveProfileName = ""
$Global:ProfileLockPath = ""
$Global:GameState   = $null
$Global:SaveCounter = 0
$Global:SelectedTicker = "AAPL"
$Global:CurrentTimeframe = 60
$Global:IsZoomed = $false
$Global:ZoomLevel = 1.0

# Load Config
$Global:Config = @{}
if (Test-Path $Global:ConfigPath) { . $Global:ConfigPath } 
else { $Global:Config = @{ MathWorkAutoMult=3.0; MathWorkAutoSec=20.0; MathWorkFastBonusClickMult=5.0; MathWorkFastBonusClickSec=15.0; MathWorkRewardBase=1000.0; BuildMaterialCost=500000; BuildLaborCost=200000; BuildWaitMinutes=30; BuildSellMarkupPct=50; HouseType21_Cost=500000.0; HouseType21_Wait=20.0; HouseType45_Cost=1000000.0; HouseType45_Wait=30.0; HouseType90_Cost=2500000.0; HouseType90_Wait=45.0; HouseType120_Cost=5000000.0; HouseType120_Wait=60.0; ContractRewardBase=5000.0; AuctionDurationSec=30.0; AuctionMaxMarkupPct=120.0; WorkerBaseIncome=1.0; WorkerBaseCost=25000.0; WorkerCostGrowth=1.35; WorkerXpPerLevel=10.0 } }

# --- KUNCI PROFIL (sama dengan TUI: satu profil satu proses) ---
function Get-LockOwnerMessage($name, $lockPath) {
    $owner = "jendela lain"
    try {
        $parts = ([System.IO.File]::ReadAllText($lockPath, [System.Text.Encoding]::UTF8).Trim() -split '\|')
        if ($parts.Count -ge 5) {
            if ($parts[4] -eq 'GUI') { $owner = "DashboardGUI (jendela lain)" }
            elseif ($parts[4] -eq 'TUI') { $owner = "TUI" }
        }
    } catch { }
    return ("Profil '{0}' sedang berjalan di {1}. Tutup dulu, lalu coba lagi (satu profil hanya bisa dibuka di satu tempat: GUI atau TUI)." -f $name, $owner)
}

function Lock-GuiProfile($name) {
    $lp = Join-Path $Global:ProfilesDir ($name + ".lock")
    $content = ("{0}|{1}|{2}|{3}|{4}" -f $PID, $env:COMPUTERNAME, [DateTime]::UtcNow.ToString('o'), [System.Guid]::NewGuid().ToString(), "GUI")
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $fs = [System.IO.File]::Open($lp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close(); $fs.Dispose()
            $Global:ProfileLockPath = $lp
            return
        } catch {
            $alive = $false
            try {
                $raw = [System.IO.File]::ReadAllText($lp).Trim()
                $lockPid = 0
                if ([int]::TryParse(($raw -split '\|')[0], [ref]$lockPid)) {
                    try { $null = Get-Process -Id $lockPid -ErrorAction Stop; $alive = $true } catch { $alive = $false }
                }
            } catch { $alive = $false }
            if ($alive) { throw (Get-LockOwnerMessage $name $lp) }
            Remove-Item $lp -Force -ErrorAction SilentlyContinue
        }
    }
    throw ("Gagal mengunci profil '{0}'. Coba lagi." -f $name)
}

function Unlock-GuiProfile {
    if ($Global:ProfileLockPath -ne "") {
        Remove-Item $Global:ProfileLockPath -Force -ErrorAction SilentlyContinue
        $Global:ProfileLockPath = ""
    }
}

# --- FUNGSI BANTU DATA ---
function Load-GameData {
    if ($Global:ProfilePath -ne "" -and (Test-Path $Global:ProfilePath)) {
        try {
            $fs = [System.IO.File]::Open($Global:ProfilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs)
            $raw = $reader.ReadToEnd()
            $reader.Close(); $fs.Close()
            $Global:GameState = $raw | ConvertFrom-Json
        } catch {}
    }
}

function Save-GameData {
    if ($null -ne $Global:GameState -and $Global:ProfilePath -ne "") {
        try {
            $Global:GameState.Meta.LastSaveUtc = [DateTime]::UtcNow.ToString('o')
            $json = $Global:GameState | ConvertTo-Json -Depth 10 -Compress
            [System.IO.File]::WriteAllText($Global:ProfilePath, $json, [System.Text.Encoding]::UTF8)
        } catch {}
    }
}

$Global:StocksCache = $null
$Global:StocksCacheTime = [DateTime]::MinValue
$Global:EngineCheckCounter = 0

function Load-StocksData {
    if ($null -ne $Global:StocksCache -and ([DateTime]::Now - $Global:StocksCacheTime).TotalMilliseconds -lt 900) { return $Global:StocksCache }
    if (Test-Path $Global:StocksPath) {
        try {
            $fs = [System.IO.File]::Open($Global:StocksPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs)
            $raw = $reader.ReadToEnd()
            $reader.Close(); $fs.Close()
            $parsed = $raw | ConvertFrom-Json
            $Global:StocksCache = $parsed
            $Global:StocksCacheTime = [DateTime]::Now
            return $parsed
        } catch { return @() }
    }
    return @()
}

function Test-MarketEngineAlive {
    try {
        if (-not (Test-Path $Global:StocksPath)) { return $false }
        return (([DateTime]::Now - (Get-Item $Global:StocksPath).LastWriteTime).TotalSeconds -lt 15)
    } catch { return $false }
}

function Ensure-MarketEngine {
    if (Test-MarketEngineAlive) { return }
    $enginePath = Join-Path $Global:RootPath "Core\MarketEngine.ps1"
    try {
        Start-Process -FilePath "powershell" -ArgumentList @("-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $enginePath) -WindowStyle Hidden | Out-Null
        Write-Host "[GUI] Market engine tidak terdeteksi -> dijalankan otomatis (harga & grafik aktif)."
    } catch {
        Write-Host "[GUI][WARN] Gagal menjalankan market engine: $($_.Exception.Message)"
    }
}

# =====================================================================
# FORM PEMILIHAN PROFIL
# =====================================================================
$formLogin = New-Object System.Windows.Forms.Form
$formLogin.Text = "Pilih Profil - ClickTycoonIdle"
$formLogin.Size = New-Object System.Drawing.Size(400, 500)
$formLogin.StartPosition = "CenterScreen"
$formLogin.BackColor = $ColorBg
$formLogin.ForeColor = $ColorText
$formLogin.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$formLogin.MaximizeBox = $false

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Pilih Profil Anda"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $ColorAccent
$lblTitle.Location = New-Object System.Drawing.Point(20, 20)
$lblTitle.AutoSize = $true
$formLogin.Controls.Add($lblTitle)

$listBoxProfiles = New-Object System.Windows.Forms.ListBox
$listBoxProfiles.Location = New-Object System.Drawing.Point(20, 60)
$listBoxProfiles.Size = New-Object System.Drawing.Size(340, 300)
$listBoxProfiles.BackColor = $ColorPanel
$listBoxProfiles.ForeColor = $ColorText
$listBoxProfiles.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$listBoxProfiles.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$formLogin.Controls.Add($listBoxProfiles)

if (Test-Path $Global:ProfilesDir) {
    $files = Get-ChildItem -Path $Global:ProfilesDir -Filter "*.json" | Select-Object -ExpandProperty BaseName
    foreach ($f in $files) { $listBoxProfiles.Items.Add($f) | Out-Null }
}

$btnLogin = New-Object System.Windows.Forms.Button
$btnLogin.Text = "Masuk Game"
$btnLogin.Location = New-Object System.Drawing.Point(20, 380)
$btnLogin.Size = New-Object System.Drawing.Size(340, 50)
$btnLogin.BackColor = $ColorAccent
$btnLogin.ForeColor = [System.Drawing.Color]::White
$btnLogin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnLogin.FlatAppearance.BorderSize = 0
$btnLogin.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$btnLogin.Add_Click({
    if ($listBoxProfiles.SelectedIndex -ge 0) {
        $name = $listBoxProfiles.SelectedItem.ToString()
        try {
            Lock-GuiProfile $name
            $Global:ActiveProfileName = $name
            $Global:ProfilePath = Join-Path $Global:ProfilesDir ($name + ".json")
            Write-Host ("[WEB BELI] Mulai memantau antrian Data\queue.json untuk profil '{0}'" -f $Global:ActiveProfileName) -ForegroundColor Cyan
            $formLogin.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Profil Sedang Dipakai")
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Silakan pilih profil terlebih dahulu!")
    }
})
$formLogin.Controls.Add($btnLogin)
$formLogin.ShowDialog() | Out-Null

if ($Global:ActiveProfileName -eq "") { return }
Load-GameData

# =====================================================================
# FORM UTAMA
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "ClickTycoonIdle - Dashboard (" + $Global:ActiveProfileName + ")"
$form.Size = New-Object System.Drawing.Size(1200, 900)
$form.StartPosition = "CenterScreen"
$form.BackColor = $ColorBg
$form.ForeColor = $ColorText

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($tabControl)

# =====================================================================
# TAB 1: DASHBOARD UTAMA
# =====================================================================
$tabMain = New-Object System.Windows.Forms.TabPage
$tabMain.Text = "  Dashboard Utama  "
$tabMain.BackColor = $ColorPanel
$tabControl.TabPages.Add($tabMain)

$lblProfileDash = New-Object System.Windows.Forms.Label
$lblProfileDash.Text = "Profil: " + $Global:ActiveProfileName
$lblProfileDash.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblProfileDash.ForeColor = $ColorSuccess
$lblProfileDash.Location = New-Object System.Drawing.Point(30, 30)
$lblProfileDash.AutoSize = $true
$tabMain.Controls.Add($lblProfileDash)

$lblCashDash = New-Object System.Windows.Forms.Label
$lblCashDash.Text = "Cash: Rp 0"
$lblCashDash.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
$lblCashDash.ForeColor = $ColorAccent
$lblCashDash.Location = New-Object System.Drawing.Point(30, 70)
$lblCashDash.AutoSize = $true
$tabMain.Controls.Add($lblCashDash)

$lblNetWorth = New-Object System.Windows.Forms.Label
$lblNetWorth.Text = "Net Worth: Rp 0"
$lblNetWorth.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$lblNetWorth.Location = New-Object System.Drawing.Point(30, 120)
$lblNetWorth.AutoSize = $true
$tabMain.Controls.Add($lblNetWorth)

$lblAssets = New-Object System.Windows.Forms.Label
$lblAssets.Text = "Assets: Rp 0"
$lblAssets.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$lblAssets.Location = New-Object System.Drawing.Point(30, 150)
$lblAssets.AutoSize = $true
$tabMain.Controls.Add($lblAssets)

$lblClickLvl = New-Object System.Windows.Forms.Label
$lblClickLvl.Text = "Clicker Level: 1"
$lblClickLvl.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblClickLvl.Location = New-Object System.Drawing.Point(30, 200)
$lblClickLvl.AutoSize = $true
$tabMain.Controls.Add($lblClickLvl)

$lblClickVal = New-Object System.Windows.Forms.Label
$lblClickVal.Text = "Click Value: Rp 1"
$lblClickVal.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblClickVal.Location = New-Object System.Drawing.Point(30, 230)
$lblClickVal.AutoSize = $true
$tabMain.Controls.Add($lblClickVal)

$lblAutoRate = New-Object System.Windows.Forms.Label
$lblAutoRate.Text = "Auto Income: Rp 0/s"
$lblAutoRate.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblAutoRate.Location = New-Object System.Drawing.Point(30, 260)
$lblAutoRate.AutoSize = $true
$tabMain.Controls.Add($lblAutoRate)

$lblBuffInfo = New-Object System.Windows.Forms.Label
$lblBuffInfo.Text = "Stock Buff: Tidak Ada"
$lblBuffInfo.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblBuffInfo.ForeColor = [System.Drawing.Color]::Orange
$lblBuffInfo.Location = New-Object System.Drawing.Point(30, 290)
$lblBuffInfo.AutoSize = $true
$tabMain.Controls.Add($lblBuffInfo)

$lblClickBuffInfo = New-Object System.Windows.Forms.Label
$lblClickBuffInfo.Text = "Click Buff: Tidak Ada"
$lblClickBuffInfo.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblClickBuffInfo.ForeColor = [System.Drawing.Color]::Orange
$lblClickBuffInfo.Location = New-Object System.Drawing.Point(30, 325)
$lblClickBuffInfo.AutoSize = $true
$tabMain.Controls.Add($lblClickBuffInfo)

function Create-ActionButton($text, $x, $y, $w, $h, $bgColor) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point($x, $y)
    $btn.Size = New-Object System.Drawing.Size($w, $h)
    $btn.BackColor = $bgColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

$btnClick = Create-ActionButton "KLIK SAYA!" 400 70 200 100 $ColorAccent
$btnClick.Add_Click({
    if ($null -eq $Global:GameState) { return }
    $lvl = [int]$Global:GameState.Sectors.Clicker.Level
    $buff = 1.0
    if ($Global:GameState.Flags.PSObject.Properties.Name -contains 'ClickBuffUntil') {
        try { $until = [DateTime]::Parse($Global:GameState.Flags.ClickBuffUntil, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); if ([DateTime]::UtcNow -lt $until) { $buff = [double]$Global:GameState.Flags.ClickBuffMult } } catch {}
    }
    if ($Global:GameState.Flags.PSObject.Properties.Name -contains 'StockBuffUntil') {
        try { $until = [DateTime]::Parse($Global:GameState.Flags.StockBuffUntil, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); if ([DateTime]::UtcNow -lt $until) { $buff *= [double]$Global:GameState.Flags.StockBuffMult } } catch {}
    }
    $gain = [Math]::Max(1.0, [double]$lvl) * $buff
    $Global:GameState.Player.Money += $gain
    $Global:GameState.Player.Clicks += 1
    Update-AllUI
})
$tabMain.Controls.Add($btnClick)

$btnUpgrade = Create-ActionButton "Upgrade Clicker" 400 190 200 50 $ColorSuccess
$btnUpgrade.Add_Click({
    $lvl = [int]$Global:GameState.Sectors.Clicker.Level
    $cost = 10.0 * [Math]::Pow(1.15, $lvl - 1)
    if ($Global:GameState.Player.Money -ge $cost) {
        $Global:GameState.Player.Money -= $cost
        $Global:GameState.Sectors.Clicker.Level += 1
        $Global:GameState.Sectors.Clicker.AutoRate = [double]$Global:GameState.Sectors.Clicker.Level * 0.2
        Update-AllUI
    } else {
        [System.Windows.Forms.MessageBox]::Show("Uang tidak cukup! Butuh Rp " + ("{0:N2}" -f $cost))
    }
})
$tabMain.Controls.Add($btnUpgrade)

# =====================================================================
# TAB 2: PASAR SAHAM
# =====================================================================
$tabStock = New-Object System.Windows.Forms.TabPage
$tabStock.Text = "  Pasar Saham  "
$tabStock.BackColor = $ColorPanel
$tabControl.TabPages.Add($tabStock)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainLayout.RowCount = 3
$mainLayout.ColumnCount = 1
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 200)))
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tabStock.Controls.Add($mainLayout)

$dgvStocks = New-Object System.Windows.Forms.DataGridView
$dgvStocks.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvStocks.BackgroundColor = $ColorPanel
$dgvStocks.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$dgvStocks.RowHeadersVisible = $false
$dgvStocks.AllowUserToAddRows = $false
$dgvStocks.ReadOnly = $true
$dgvStocks.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvStocks.MultiSelect = $false
$dgvStocks.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::AllCells
$dgvStocks.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$dgvStocks.ColumnHeadersDefaultCellStyle.BackColor = $ColorBg
$dgvStocks.ColumnHeadersDefaultCellStyle.ForeColor = $ColorAccent
$dgvStocks.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$dgvStocks.EnableHeadersVisualStyles = $false
$dgvStocks.DefaultCellStyle.BackColor = $ColorPanel
$dgvStocks.DefaultCellStyle.ForeColor = $ColorText
$dgvStocks.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 100, 200)
$dgvStocks.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$dgvStocks.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 50)
$mainLayout.Controls.Add($dgvStocks, 0, 0)

$dgvStocks.Columns.Add("Ticker", "Ticker") | Out-Null
$dgvStocks.Columns.Add("HargaBeli", "Harga Beli") | Out-Null
$dgvStocks.Columns.Add("HargaSkrg", "Harga Skrg") | Out-Null
$dgvStocks.Columns.Add("Dimiliki", "Dimiliki") | Out-Null
$dgvStocks.Columns.Add("NilaiSaham", "Nilai Saham") | Out-Null
$dgvStocks.Columns.Add("PL", "P/L (Rp)") | Out-Null
$dgvStocks.Columns.Add("Tren", "Tren") | Out-Null
$dgvStocks.Columns.Add("Sinyal", "Sinyal") | Out-Null

# Toolbar
$panelToolbar = New-Object System.Windows.Forms.Panel
$panelToolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelToolbar.BackColor = $ColorPanel
$panelToolbar.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)
$mainLayout.Controls.Add($panelToolbar, 0, 1)

function Create-TfButton($text, $x, $tfMinutes) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point($x, 5)
    $btn.Size = New-Object System.Drawing.Size(70, 30)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Tag = $tfMinutes
    $btn.Add_Click({
        $Global:CurrentTimeframe = [int]$this.Tag
        foreach ($ctrl in $panelToolbar.Controls) {
            if ($ctrl -is [System.Windows.Forms.Button] -and $ctrl.Text -ne "Logout" -and $ctrl.Text -ne "Reset") { $ctrl.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50) }
        }
        $this.BackColor = [System.Drawing.Color]::Purple
        $Global:IsZoomed = $false
        $Global:ZoomLevel = 1.0
        Update-Chart
    })
    return $btn
}

$btn1M = Create-TfButton "1 Mnt" 10 1
$btn5M = Create-TfButton "5 Mnt" 90 5
$btn15M = Create-TfButton "15 Mnt" 170 15
$btn1H = Create-TfButton "1 Jam" 250 60
$btn12H = Create-TfButton "12 Jam" 330 720
$btn1D = Create-TfButton "1 Hari" 410 1440

$btnZoomIn = New-Object System.Windows.Forms.Button
$btnZoomIn.Text = "[+]"
$btnZoomIn.Location = New-Object System.Drawing.Point(500, 5)
$btnZoomIn.Size = New-Object System.Drawing.Size(40, 30)
$btnZoomIn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnZoomIn.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$btnZoomIn.ForeColor = [System.Drawing.Color]::White
$btnZoomIn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnZoomIn.Add_Click({
    $Global:ZoomLevel *= 0.8
    if ($Global:ZoomLevel -lt 0.1) { $Global:ZoomLevel = 0.1 }
    $Global:IsZoomed = $true
    Update-Chart
})

$btnZoomOut = New-Object System.Windows.Forms.Button
$btnZoomOut.Text = "[-]"
$btnZoomOut.Location = New-Object System.Drawing.Point(545, 5)
$btnZoomOut.Size = New-Object System.Drawing.Size(40, 30)
$btnZoomOut.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnZoomOut.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$btnZoomOut.ForeColor = [System.Drawing.Color]::White
$btnZoomOut.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnZoomOut.Add_Click({
    $Global:ZoomLevel *= 1.25
    if ($Global:ZoomLevel -gt 5.0) { $Global:ZoomLevel = 5.0 }
    $Global:IsZoomed = $true
    Update-Chart
})

$lblZoomRatio = New-Object System.Windows.Forms.Label
$lblZoomRatio.Text = "100%"
$lblZoomRatio.Location = New-Object System.Drawing.Point(595, 10)
$lblZoomRatio.AutoSize = $true
$lblZoomRatio.ForeColor = [System.Drawing.Color]::White
$lblZoomRatio.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = "Reset"
$btnReset.Location = New-Object System.Drawing.Point(650, 5)
$btnReset.Size = New-Object System.Drawing.Size(70, 30)
$btnReset.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnReset.BackColor = [System.Drawing.Color]::FromArgb(200, 50, 50)
$btnReset.ForeColor = [System.Drawing.Color]::White
$btnReset.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnReset.Add_Click({
    $Global:IsZoomed = $false
    $Global:ZoomLevel = 1.0
    Update-Chart
})

$btnLogout = New-Object System.Windows.Forms.Button
$btnLogout.Text = "Logout"
$btnLogout.Location = New-Object System.Drawing.Point(1080, 5)
$btnLogout.Size = New-Object System.Drawing.Size(80, 30)
$btnLogout.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnLogout.BackColor = [System.Drawing.Color]::FromArgb(150, 50, 50)
$btnLogout.ForeColor = [System.Drawing.Color]::White
$btnLogout.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnLogout.Add_Click({
    $Global:ActiveProfileName = ""
    $Global:ProfilePath = ""
    $form.Close()
})

$panelToolbar.Controls.Add($btn1M)
$panelToolbar.Controls.Add($btn5M)
$panelToolbar.Controls.Add($btn15M)
$panelToolbar.Controls.Add($btn1H)
$panelToolbar.Controls.Add($btn12H)
$panelToolbar.Controls.Add($btn1D)
$panelToolbar.Controls.Add($btnZoomIn)
$panelToolbar.Controls.Add($btnZoomOut)
$panelToolbar.Controls.Add($lblZoomRatio)
$panelToolbar.Controls.Add($btnReset)
$panelToolbar.Controls.Add($btnLogout)

$btn1H.BackColor = [System.Drawing.Color]::Purple
foreach ($b in @($btn1M, $btn5M, $btn15M, $btn12H, $btn1D)) { $b.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50) }

# Panel Grafik
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelBottom.BackColor = $ColorPanel
$panelBottom.Width = 1180
$panelBottom.Height = 600
$mainLayout.Controls.Add($panelBottom, 0, 2)

$chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart.Dock = [System.Windows.Forms.DockStyle]::Fill
$chart.BackColor = $ColorPanel
$chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$chartArea.BackColor = $ColorPanel
$chartArea.AxisX.LabelStyle.ForeColor = $ColorText
$chartArea.AxisY.LabelStyle.ForeColor = $ColorText
$chartArea.AxisX.MajorGrid.LineColor = $ColorGrid
$chartArea.AxisY.MajorGrid.LineColor = $ColorGrid
$chartArea.AxisX.IsMarginVisible = $true
$chartArea.AxisY.IsStartedFromZero = $false
$chart.ChartAreas.Add($chartArea)

$series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
$series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
$series.BorderWidth = 2
$series.Color = $ColorAccent
$chart.Series.Add($series)

$panelBottom.Controls.Add($chart)

$panelOverlay = New-Object System.Windows.Forms.Panel
$panelOverlay.Dock = [System.Windows.Forms.DockStyle]::Right
$panelOverlay.Width = 320
$panelOverlay.BackColor = $ColorPanel
$panelOverlay.Padding = New-Object System.Windows.Forms.Padding(10)
$panelBottom.Controls.Add($panelOverlay)

$lblCashInfo = New-Object System.Windows.Forms.Label
$lblCashInfo.Text = "Cash: Rp 0"
$lblCashInfo.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblCashInfo.ForeColor = $ColorAccent
$lblCashInfo.Location = New-Object System.Drawing.Point(10, 10)
$lblCashInfo.AutoSize = $true
$panelOverlay.Controls.Add($lblCashInfo)

$lblStockVal = New-Object System.Windows.Forms.Label
$lblStockVal.Text = "Nilai Saham: Rp 0"
$lblStockVal.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$lblStockVal.Location = New-Object System.Drawing.Point(10, 40)
$lblStockVal.AutoSize = $true
$panelOverlay.Controls.Add($lblStockVal)

$lblPL = New-Object System.Windows.Forms.Label
$lblPL.Text = "Total P/L: Rp 0"
$lblPL.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblPL.Location = New-Object System.Drawing.Point(10, 65)
$lblPL.AutoSize = $true
$panelOverlay.Controls.Add($lblPL)

$lblBuffStock = New-Object System.Windows.Forms.Label
$lblBuffStock.Text = "Stock Buff: -"
$lblBuffStock.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblBuffStock.ForeColor = [System.Drawing.Color]::Orange
$lblBuffStock.Location = New-Object System.Drawing.Point(10, 95)
$lblBuffStock.AutoSize = $true
$panelOverlay.Controls.Add($lblBuffStock)

$flowBuy = New-Object System.Windows.Forms.FlowLayoutPanel
$flowBuy.Location = New-Object System.Drawing.Point(10, 130)
$flowBuy.Size = New-Object System.Drawing.Size(300, 120)
$flowBuy.BackColor = $ColorPanel
$panelOverlay.Controls.Add($flowBuy)

$flowSell = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSell.Location = New-Object System.Drawing.Point(10, 260)
$flowSell.Size = New-Object System.Drawing.Size(300, 80)
$flowSell.BackColor = $ColorPanel
$panelOverlay.Controls.Add($flowSell)

function Create-FlowButton($text, $bgColor) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Size = New-Object System.Drawing.Size(90, 35)
    $btn.Margin = New-Object System.Windows.Forms.Padding(2)
    $btn.BackColor = $bgColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

$btnBuy1 = Create-FlowButton "Beli 1" $ColorAccent
$btnBuy10 = Create-FlowButton "Beli 10" $ColorAccent
$btnBuy50 = Create-FlowButton "Beli 50" $ColorAccent
$btnBuy100 = Create-FlowButton "Beli 100" $ColorAccent
$btnBuy200 = Create-FlowButton "Beli 200" $ColorAccent
$btnBuy400 = Create-FlowButton "Beli 400" $ColorAccent

$flowBuy.Controls.Add($btnBuy1)
$flowBuy.Controls.Add($btnBuy10)
$flowBuy.Controls.Add($btnBuy50)
$flowBuy.Controls.Add($btnBuy100)
$flowBuy.Controls.Add($btnBuy200)
$flowBuy.Controls.Add($btnBuy400)

$btnSell1 = Create-FlowButton "Jual 1" $ColorDanger
$btnSell50 = Create-FlowButton "Jual 50%" $ColorDanger
$btnSellTicker = Create-FlowButton "Jual Saham" $ColorDanger
$btnSellAll = Create-FlowButton "Jual Semua" $ColorDanger

$flowSell.Controls.Add($btnSell1)
$flowSell.Controls.Add($btnSell50)
$flowSell.Controls.Add($btnSellTicker)
$flowSell.Controls.Add($btnSellAll)

# =====================================================================
# TAB 3: KERJA
# =====================================================================
$tabWork = New-Object System.Windows.Forms.TabPage
$tabWork.Text = "  Kerja  "
$tabWork.BackColor = $ColorPanel
$tabControl.TabPages.Add($tabWork)

$splitWork = New-Object System.Windows.Forms.SplitContainer
$splitWork.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitWork.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitWork.Width = 1180
$splitWork.Height = 600
$splitWork.SplitterDistance = 200
$splitWork.IsSplitterFixed = $true
$splitWork.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel1
$splitWork.Panel1MinSize = 200
$splitWork.Panel2MinSize = 500
$tabWork.Controls.Add($splitWork)

# --- PANEL KIRI: MENU ---
$panelMenu = New-Object System.Windows.Forms.Panel
$panelMenu.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelMenu.BackColor = $ColorBg
$splitWork.Panel1.Controls.Add($panelMenu)

$btnMenuStat = Create-ActionButton "0. Statistik Kerja" 10 10 180 50 $ColorSuccess
$btnMenuMath = Create-ActionButton "1. Matematika" 10 70 180 50 $ColorAccent
$btnMenuType = Create-ActionButton "2. Ketik Ulang" 10 130 180 50 $ColorAccent
$btnMenuBuild = Create-ActionButton "3. Developer Bangunan" 10 190 180 50 $ColorAccent
$btnMenuContract = Create-ActionButton "4. Kontrak Harian" 10 255 180 50 $ColorAccent
$btnMenuWorker = Create-ActionButton "5. Pekerja" 10 315 180 50 $ColorAccent
$lblMenuCash = New-Object System.Windows.Forms.Label
$lblMenuCash.Text = "Cash: Rp 0"
$lblMenuCash.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblMenuCash.ForeColor = $ColorSuccess
$lblMenuCash.Location = New-Object System.Drawing.Point(10, 375)
$lblMenuCash.AutoSize = $true
$panelMenu.Controls.Add($lblMenuCash)
$panelMenu.Controls.Add($btnMenuStat)
$panelMenu.Controls.Add($btnMenuMath)
$panelMenu.Controls.Add($btnMenuType)
$panelMenu.Controls.Add($btnMenuBuild)
$panelMenu.Controls.Add($btnMenuContract)
$panelMenu.Controls.Add($btnMenuWorker)

# --- PANEL KANAN: KONTEN ---
$panelContent = New-Object System.Windows.Forms.Panel
$panelContent.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelContent.BackColor = $ColorPanel
$splitWork.Panel2.Controls.Add($panelContent)

# --- SUB-PANEL STATISTIK KERJA ---
$panelStat = New-Object System.Windows.Forms.Panel
$panelStat.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelStat.Visible = $false
$panelContent.Controls.Add($panelStat)

$lblStatTitle = New-Object System.Windows.Forms.Label
$lblStatTitle.Text = "Statistik Kerja"
$lblStatTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblStatTitle.ForeColor = $ColorSuccess
$lblStatTitle.Location = New-Object System.Drawing.Point(20, 30)
$lblStatTitle.AutoSize = $true
$panelStat.Controls.Add($lblStatTitle)

$lblStatMath = New-Object System.Windows.Forms.Label
$lblStatMath.Text = "Matematika: -"
$lblStatMath.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblStatMath.Location = New-Object System.Drawing.Point(20, 100)
$lblStatMath.AutoSize = $true
$panelStat.Controls.Add($lblStatMath)

$lblStatType = New-Object System.Windows.Forms.Label
$lblStatType.Text = "Ketik Ulang: -"
$lblStatType.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblStatType.Location = New-Object System.Drawing.Point(20, 135)
$lblStatType.AutoSize = $true
$panelStat.Controls.Add($lblStatType)

$lblStatBuild = New-Object System.Windows.Forms.Label
$lblStatBuild.Text = "Bangunan: -"
$lblStatBuild.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblStatBuild.Location = New-Object System.Drawing.Point(20, 170)
$lblStatBuild.AutoSize = $true
$panelStat.Controls.Add($lblStatBuild)

$lblStatTotal = New-Object System.Windows.Forms.Label
$lblStatTotal.Text = "Total penghasilan kerja: Rp 0"
$lblStatTotal.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblStatTotal.ForeColor = [System.Drawing.Color]::Orange
$lblStatTotal.Location = New-Object System.Drawing.Point(20, 220)
$lblStatTotal.AutoSize = $true
$panelStat.Controls.Add($lblStatTotal)

# --- SUB-PANEL KONTRAK HARIAN ---
$panelContract = New-Object System.Windows.Forms.Panel
$panelContract.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelContract.Visible = $false
$panelContent.Controls.Add($panelContract)

$lblContractTitle = New-Object System.Windows.Forms.Label
$lblContractTitle.Text = "Kontrak Harian"
$lblContractTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblContractTitle.ForeColor = $ColorSuccess
$lblContractTitle.Location = New-Object System.Drawing.Point(20, 30)
$lblContractTitle.AutoSize = $true
$panelContract.Controls.Add($lblContractTitle)

$lblContract1 = New-Object System.Windows.Forms.Label
$lblContract1.Text = "-"
$lblContract1.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblContract1.Location = New-Object System.Drawing.Point(20, 100)
$lblContract1.AutoSize = $true
$panelContract.Controls.Add($lblContract1)

$btnClaim1 = Create-ActionButton "Klaim" 560 96 150 35 $ColorSuccess
$panelContract.Controls.Add($btnClaim1)

$lblContract2 = New-Object System.Windows.Forms.Label
$lblContract2.Text = "-"
$lblContract2.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblContract2.Location = New-Object System.Drawing.Point(20, 140)
$lblContract2.AutoSize = $true
$panelContract.Controls.Add($lblContract2)

$btnClaim2 = Create-ActionButton "Klaim" 560 136 150 35 $ColorSuccess
$panelContract.Controls.Add($btnClaim2)

$lblContract3 = New-Object System.Windows.Forms.Label
$lblContract3.Text = "-"
$lblContract3.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblContract3.Location = New-Object System.Drawing.Point(20, 180)
$lblContract3.AutoSize = $true
$panelContract.Controls.Add($lblContract3)

$btnClaim3 = Create-ActionButton "Klaim" 560 176 150 35 $ColorSuccess
$panelContract.Controls.Add($btnClaim3)

$lblContractNote = New-Object System.Windows.Forms.Label
$lblContractNote.Text = "Kontrak baru tiap hari (UTC). Progres dihitung dari aktivitas kerja hari ini."
$lblContractNote.ForeColor = [System.Drawing.Color]::Gray
$lblContractNote.Location = New-Object System.Drawing.Point(20, 230)
$lblContractNote.AutoSize = $true
$panelContract.Controls.Add($lblContractNote)

# --- SUB-PANEL PEKERJA ---
$panelWorker = New-Object System.Windows.Forms.Panel
$panelWorker.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelWorker.Visible = $false
$panelContent.Controls.Add($panelWorker)

$lblWorkerTitle = New-Object System.Windows.Forms.Label
$lblWorkerTitle.Text = "Pekerja"
$lblWorkerTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblWorkerTitle.ForeColor = $ColorSuccess
$lblWorkerTitle.Location = New-Object System.Drawing.Point(20, 30)
$lblWorkerTitle.AutoSize = $true
$panelWorker.Controls.Add($lblWorkerTitle)

$lblWorkerInfo = New-Object System.Windows.Forms.Label
$lblWorkerInfo.Text = "Pekerja: 0"
$lblWorkerInfo.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblWorkerInfo.Location = New-Object System.Drawing.Point(20, 100)
$lblWorkerInfo.AutoSize = $true
$panelWorker.Controls.Add($lblWorkerInfo)

$btnWorkerHire = Create-ActionButton "Rekrut Pekerja" 20 140 260 45 $ColorAccent
$panelWorker.Controls.Add($btnWorkerHire)

$lblWorkerNote = New-Object System.Windows.Forms.Label
$lblWorkerNote.Text = "XP naik dari aktivitas kerja (soal benar, ketik selesai, rumah dibangun). Income pekerja tidak terpengaruh buff saham."
$lblWorkerNote.ForeColor = [System.Drawing.Color]::Gray
$lblWorkerNote.Location = New-Object System.Drawing.Point(20, 200)
$lblWorkerNote.AutoSize = $true
$panelWorker.Controls.Add($lblWorkerNote)

# --- SUB-PANEL MATEMATIKA ---
$panelMath = New-Object System.Windows.Forms.Panel
$panelMath.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelMath.Visible = $false
$panelContent.Controls.Add($panelMath)

$lblMathSoal = New-Object System.Windows.Forms.Label
$lblMathSoal.Text = "Soal: ?"
$lblMathSoal.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
$lblMathSoal.Location = New-Object System.Drawing.Point(20, 30)
$lblMathSoal.AutoSize = $true
$panelMath.Controls.Add($lblMathSoal)

$txtMathAnswer = New-Object System.Windows.Forms.TextBox
$txtMathAnswer.Location = New-Object System.Drawing.Point(20, 90)
$txtMathAnswer.Size = New-Object System.Drawing.Size(200, 30)
$txtMathAnswer.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$panelMath.Controls.Add($txtMathAnswer)

$btnMathSubmit = Create-ActionButton "Jawab" 20 140 100 40 $ColorSuccess
$btnMathSkip = Create-ActionButton "Skip" 130 140 100 40 ([System.Drawing.Color]::DarkOrange)
$panelMath.Controls.Add($btnMathSubmit)
$panelMath.Controls.Add($btnMathSkip)

# --- SUB-PANEL KETIK ULANG ---
$panelType = New-Object System.Windows.Forms.Panel
$panelType.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelType.Visible = $false
$panelContent.Controls.Add($panelType)

$lblTypeText = New-Object System.Windows.Forms.Label
$lblTypeText.Text = "Ketik ulang teks ini."
$lblTypeText.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$lblTypeText.Location = New-Object System.Drawing.Point(20, 30)
$lblTypeText.AutoSize = $true
$panelType.Controls.Add($lblTypeText)

$txtTypeInput = New-Object System.Windows.Forms.TextBox
$txtTypeInput.Location = New-Object System.Drawing.Point(20, 80)
$txtTypeInput.Size = New-Object System.Drawing.Size(400, 30)
$txtTypeInput.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$panelType.Controls.Add($txtTypeInput)

$btnTypeSubmit = Create-ActionButton "Enter" 20 130 100 40 $ColorSuccess
$panelType.Controls.Add($btnTypeSubmit)

# --- SUB-PANEL BANGUNAN ---
$panelBuild = New-Object System.Windows.Forms.Panel
$panelBuild.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelBuild.Visible = $false
$panelContent.Controls.Add($panelBuild)

$lblBuildInfo = New-Object System.Windows.Forms.Label
$lblBuildInfo.Text = ("Type 21: Rp {0:N0} ({1} mnt) | Type 45: Rp {2:N0} ({3} mnt) | Type 90: Rp {4:N0} ({5} mnt) | Type 120: Rp {6:N0} ({7} mnt) | Jual +{8}%" -f `
    $Global:Config.HouseType21_Cost, $Global:Config.HouseType21_Wait, $Global:Config.HouseType45_Cost, $Global:Config.HouseType45_Wait, `
    $Global:Config.HouseType90_Cost, $Global:Config.HouseType90_Wait, $Global:Config.HouseType120_Cost, $Global:Config.HouseType120_Wait, $Global:Config.BuildSellMarkupPct)
$lblBuildInfo.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$lblBuildInfo.Location = New-Object System.Drawing.Point(20, 30)
$lblBuildInfo.AutoSize = $true
$panelBuild.Controls.Add($lblBuildInfo)

$btnBuildT21 = Create-ActionButton "Bangun Type 21" 20 70 125 40 $ColorAccent
$btnBuildT45 = Create-ActionButton "Bangun Type 45" 150 70 125 40 $ColorAccent
$btnBuildT90 = Create-ActionButton "Bangun Type 90" 280 70 125 40 $ColorAccent
$btnBuildT120 = Create-ActionButton "Bangun Type 120" 410 70 125 40 $ColorAccent
$panelBuild.Controls.Add($btnBuildT21)
$panelBuild.Controls.Add($btnBuildT45)
$panelBuild.Controls.Add($btnBuildT90)
$panelBuild.Controls.Add($btnBuildT120)

$lblBuildStatus = New-Object System.Windows.Forms.Label
$lblBuildStatus.Text = "Status: Belum ada bangunan."
$lblBuildStatus.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblBuildStatus.Location = New-Object System.Drawing.Point(20, 115)
$lblBuildStatus.AutoSize = $true
$panelBuild.Controls.Add($lblBuildStatus)

$lvBuilds = New-Object System.Windows.Forms.ListView
$lvBuilds.View = [System.Windows.Forms.View]::Details
$lvBuilds.FullRowSelect = $true
$lvBuilds.GridLines = $true
$lvBuilds.Location = New-Object System.Drawing.Point(20, 145)
$lvBuilds.Size = New-Object System.Drawing.Size(540, 210)
$lvBuilds.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
[void]$lvBuilds.Columns.Add("No", 40)
[void]$lvBuilds.Columns.Add("Tipe", 90)
[void]$lvBuilds.Columns.Add("Status", 90)
[void]$lvBuilds.Columns.Add("Sisa Waktu", 100)
[void]$lvBuilds.Columns.Add("Biaya", 110)
[void]$lvBuilds.Columns.Add("Keuntungan", 110)
[void]$lvBuilds.Columns.Add("Harga Jual", 120)
$panelBuild.Controls.Add($lvBuilds)

$btnBuildSell = Create-ActionButton "Jual Terpilih" 20 365 200 40 $ColorSuccess
$btnBuildSell.Enabled = $false
$panelBuild.Controls.Add($btnBuildSell)

$btnBuildAuction = Create-ActionButton "Lelang Terpilih" 240 365 200 40 $ColorAccent
$btnBuildAuction.Enabled = $false
$panelBuild.Controls.Add($btnBuildAuction)

$lblAuction = New-Object System.Windows.Forms.Label
$lblAuction.Text = "Lelang: tidak aktif"
$lblAuction.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblAuction.ForeColor = [System.Drawing.Color]::Gray
$lblAuction.Location = New-Object System.Drawing.Point(460, 375)
$lblAuction.AutoSize = $true
$panelBuild.Controls.Add($lblAuction)

# --- LOGIKA TAB KERJA ---
$Global:MathCurrentAnswer = 0
$Global:MathStartTime = $null
$Global:BuildEndTime = $null

function Show-WorkPanel($panel) {
    $panelStat.Visible = $false
    $panelMath.Visible = $false
    $panelType.Visible = $false
    $panelBuild.Visible = $false
    $panelContract.Visible = $false
    $panelWorker.Visible = $false
    $panel.Visible = $true
}

function Get-WorkStat([string]$key) {
    $ws = $Global:GameState.PSObject.Properties['WorkStats']
    if ($null -eq $ws) { return 0.0 }
    $v = $ws.Value.PSObject.Properties[$key]
    if ($null -eq $v) { return 0.0 }
    try { return [double]$v.Value } catch { return 0.0 }
}

function Add-WorkStat([string]$key, [double]$delta) {
    if ($null -eq $Global:GameState.PSObject.Properties['WorkStats']) {
        $Global:GameState | Add-Member -MemberType NoteProperty -Name "WorkStats" -Value (New-Object PSObject) -Force
    }
    $ws = $Global:GameState.PSObject.Properties['WorkStats'].Value
    $cur = 0.0
    $v = $ws.PSObject.Properties[$key]
    if ($null -ne $v) { try { $cur = [double]$v.Value } catch { $cur = 0.0 } }
    $ws | Add-Member -MemberType NoteProperty -Name $key -Value ($cur + $delta) -Force
    if ($key -eq 'MathCorrect' -or $key -eq 'TypeDone' -or $key -eq 'HouseBuilt') {
        Add-ContractProgress $key $delta
        if ($key -eq 'HouseBuilt') { Add-WorkerXp (2.0 * $delta) } else { Add-WorkerXp $delta }
    }
}

function Get-Cfg([string]$key, [double]$def) {
    try { if ($Global:Config.ContainsKey($key)) { return [double]$Global:Config[$key] } } catch {}
    return $def
}

function Get-UtcDateStr { return [DateTime]::UtcNow.ToString("yyyy-MM-dd") }

function Get-Contracts {
    if ($null -eq $Global:GameState.PSObject.Properties['Contracts'] -or $null -eq $Global:GameState.Contracts) {
        $Global:GameState | Add-Member -MemberType NoteProperty -Name "Contracts" -Value ([PSCustomObject]@{ Date = ""; M1 = $null; M2 = $null; M3 = $null }) -Force
    }
    return $Global:GameState.Contracts
}

function New-Contract([string]$type, [int]$target, [double]$rewardMult) {
    return [PSCustomObject]@{ Type = $type; Target = $target; Progress = 0; Claimed = $false; RewardMult = $rewardMult }
}

function Ensure-Contracts {
    $c = Get-Contracts
    $today = Get-UtcDateStr
    if ([string]$c.Date -eq $today) { return }
    $pool = @(
        @('MathCorrect', 10, 1.0), @('MathCorrect', 15, 1.5),
        @('TypeDone', 3, 1.5), @('TypeDone', 5, 2.0),
        @('HouseBuilt', 2, 2.0), @('HouseBuilt', 3, 2.5)
    )
    $seed = ([DateTime]::UtcNow.Date - [DateTime]"2026-01-01").Days
    $c | Add-Member -MemberType NoteProperty -Name Date -Value $today -Force
    for ($i = 1; $i -le 3; $i++) {
        $def = $pool[($seed + ($i - 1) * 2) % $pool.Count]
        $c.PSObject.Properties[("M" + $i)].Value = (New-Contract $def[0] $def[1] $def[2])
    }
}

function Add-ContractProgress([string]$key, [double]$delta) {
    Ensure-Contracts
    $c = Get-Contracts
    for ($i = 1; $i -le 3; $i++) {
        $m = $c.PSObject.Properties[("M" + $i)].Value
        if ($null -eq $m -or $m.Claimed) { continue }
        if ([string]$m.Type -eq $key) {
            $m | Add-Member -MemberType NoteProperty -Name Progress -Value (([double]$m.Progress) + $delta) -Force
        }
    }
}

function Get-ContractReward($m) {
    return (Get-Cfg 'ContractRewardBase' 5000.0) * [double]$m.RewardMult
}

function Claim-Contract([int]$idx) {
    $c = Get-Contracts
    $m = $c.PSObject.Properties[("M" + $idx)].Value
    if ($null -eq $m -or $m.Claimed -or $m.Progress -lt $m.Target) { return }
    $reward = Get-ContractReward $m
    $Global:GameState.Player.Money += $reward
    $m | Add-Member -MemberType NoteProperty -Name Claimed -Value $true -Force
    Add-WorkStat 'ContractReward' $reward
    Update-ContractsUI
    Update-WorkStatsUI
    Update-AllUI
}

function Update-ContractsUI {
    if ($null -eq $Global:GameState) { return }
    Ensure-Contracts
    $c = Get-Contracts
    for ($i = 1; $i -le 3; $i++) {
        $m = $c.PSObject.Properties[("M" + $i)].Value
        $lbl = Get-Variable -Name ("lblContract" + $i) -ValueOnly
        $btn = Get-Variable -Name ("btnClaim" + $i) -ValueOnly
        $desc = switch ([string]$m.Type) {
            'MathCorrect' { "Jawab soal matematika" }
            'TypeDone' { "Selesaikan Ketik Ulang" }
            default { "Bangun rumah" }
        }
        $lbl.Text = "{0}: {1}/{2}" -f $desc, [int]$m.Progress, $m.Target
        $reward = Get-ContractReward $m
        if ($m.Claimed) {
            $lbl.ForeColor = [System.Drawing.Color]::Gray
            $btn.Text = "Selesai"
            $btn.Enabled = $false
        } elseif ($m.Progress -ge $m.Target) {
            $lbl.ForeColor = $ColorSuccess
            $btn.Text = "Klaim Rp {0:N0}" -f $reward
            $btn.Enabled = $true
        } else {
            $lbl.ForeColor = $ColorText
            $btn.Text = "Klaim Rp {0:N0}" -f $reward
            $btn.Enabled = $false
        }
    }
}

function Get-Workers {
    if ($null -eq $Global:GameState.PSObject.Properties['Workers'] -or $null -eq $Global:GameState.Workers) {
        $Global:GameState | Add-Member -MemberType NoteProperty -Name "Workers" -Value ([PSCustomObject]@{ Count = 0; Xp = 0.0 }) -Force
    }
    return $Global:GameState.Workers
}

function Add-WorkerXp([double]$amount) {
    $w = Get-Workers
    $w | Add-Member -MemberType NoteProperty -Name Xp -Value (([double]$w.Xp) + $amount) -Force
}

function Get-WorkerLevel {
    $w = Get-Workers
    $xpPer = (Get-Cfg 'WorkerXpPerLevel' 10.0)
    if ($xpPer -le 0) { $xpPer = 10.0 }
    return ([int][Math]::Floor(([double]$w.Xp) / $xpPer) + 1)
}

function Get-WorkerRate {
    $w = Get-Workers
    if ([int]$w.Count -le 0) { return 0.0 }
    return ([int]$w.Count) * (Get-Cfg 'WorkerBaseIncome' 1.0) * (Get-WorkerLevel)
}

function Get-WorkerHireCost {
    $w = Get-Workers
    return (Get-Cfg 'WorkerBaseCost' 25000.0) * [Math]::Pow((Get-Cfg 'WorkerCostGrowth' 1.35), [int]$w.Count)
}

function Update-WorkerUI {
    if ($null -eq $Global:GameState) { return }
    $w = Get-Workers
    $lvl = Get-WorkerLevel
    $xpPer = (Get-Cfg 'WorkerXpPerLevel' 10.0)
    if ($xpPer -le 0) { $xpPer = 10.0 }
    $xpInLvl = ([double]$w.Xp) - (($lvl - 1) * $xpPer)
    $lblWorkerInfo.Text = "Pekerja: {0} | Level {1} | XP {2:N0}/{3:N0} | Income: Rp {4:N2}/dtk" -f [int]$w.Count, $lvl, $xpInLvl, $xpPer, (Get-WorkerRate)
    $cost = Get-WorkerHireCost
    $btnWorkerHire.Text = "Rekrut Pekerja (Rp {0:N0})" -f $cost
    $btnWorkerHire.Enabled = ([double]$Global:GameState.Player.Money -ge $cost)
}

$btnWorkerHire.Add_Click({
    $cost = Get-WorkerHireCost
    if ([double]$Global:GameState.Player.Money -lt $cost) {
        [System.Windows.Forms.MessageBox]::Show(("Uang tidak cukup! Butuh Rp {0:N0}" -f $cost))
        return
    }
    $Global:GameState.Player.Money -= $cost
    $w = Get-Workers
    $w | Add-Member -MemberType NoteProperty -Name Count -Value (([int]$w.Count) + 1) -Force
    Update-WorkerUI
    Update-AllUI
})

$btnClaim1.Add_Click({ Claim-Contract 1 })
$btnClaim2.Add_Click({ Claim-Contract 2 })
$btnClaim3.Add_Click({ Claim-Contract 3 })

function Update-WorkStatsUI {
    if ($null -eq $Global:GameState) { return }
    $lblStatMath.Text = ("Matematika: {0} benar, {1} salah, {2} skip | Reward Rp {3:N0}" -f (Get-WorkStat 'MathCorrect'), (Get-WorkStat 'MathWrong'), (Get-WorkStat 'MathSkip'), (Get-WorkStat 'MathReward'))
    $done = Get-WorkStat 'TypeDone'
    $avgSim = 0.0
    if ($done -gt 0) { $avgSim = (Get-WorkStat 'TypeSimilaritySum') / $done * 100 }
    $lblStatType.Text = ("Ketik Ulang: {0} selesai | Kemiripan rata-rata {1:N0}% | Cash Rp {2:N0}" -f $done, $avgSim, (Get-WorkStat 'TypeCash'))
    $lblStatBuild.Text = ("Bangunan: {0} dibangun, {1} terjual | Belanja Rp {2:N0} | Pendapatan jual Rp {3:N0}" -f (Get-WorkStat 'HouseBuilt'), (Get-WorkStat 'HouseSold'), (Get-WorkStat 'HouseSpend'), (Get-WorkStat 'HouseIncome'))
    $total = (Get-WorkStat 'MathReward') + (Get-WorkStat 'TypeCash') + (Get-WorkStat 'HouseIncome') + (Get-WorkStat 'ContractReward')
    $lblStatTotal.Text = "Total penghasilan kerja: Rp {0:N0}" -f $total
}

$btnMenuStat.Add_Click({ Show-WorkPanel $panelStat; Update-WorkStatsUI })
$btnMenuMath.Add_Click({ Show-WorkPanel $panelMath; Generate-MathQuestion })
$btnMenuType.Add_Click({ Show-WorkPanel $panelType; Generate-TypeQuestion })
$btnMenuBuild.Add_Click({ Show-WorkPanel $panelBuild; Update-BuildUI })
$btnMenuContract.Add_Click({ Show-WorkPanel $panelContract; Update-ContractsUI })
$btnMenuWorker.Add_Click({ Show-WorkPanel $panelWorker; Update-WorkerUI })

function Generate-MathQuestion {
    $lim = [Math]::Min(4 + [int]$Global:GameState.Sectors.Clicker.Level, 12)
    $op = Get-Random -Minimum 0 -Maximum 4
    switch ($op) {
        0 {
            $a = Get-Random -Minimum 2 -Maximum ($lim + 1); $b = Get-Random -Minimum 2 -Maximum ($lim + 1)
            $ans = $a + $b; $sym = "+"
        }
        1 {
            $a = Get-Random -Minimum 2 -Maximum ($lim + 1); $b = Get-Random -Minimum 2 -Maximum ($lim + 1)
            if ($b -gt $a) { $t = $a; $a = $b; $b = $t }
            $ans = $a - $b; $sym = "-"
        }
        2 {
            $a = Get-Random -Minimum 2 -Maximum 10; $b = Get-Random -Minimum 2 -Maximum 10
            $ans = $a * $b; $sym = "x"
        }
        3 {
            $b = Get-Random -Minimum 2 -Maximum 10; $ans = Get-Random -Minimum 2 -Maximum 10
            $a = $b * $ans; $sym = ":"
        }
    }
    $Global:MathCurrentAnswer = $ans
    $lblMathSoal.Text = "Soal: $a $sym $b = ?"
    $txtMathAnswer.Text = ""
    $Global:MathStartTime = [DateTime]::UtcNow
}

$btnMathSkip.Add_Click({ Add-WorkStat 'MathSkip' 1; Generate-MathQuestion })

$btnMathSubmit.Add_Click({
    try {
        if ([int]$txtMathAnswer.Text -eq $Global:MathCurrentAnswer) {
            $elapsed = ([DateTime]::UtcNow - $Global:MathStartTime).TotalSeconds
            $lvl = [int]$Global:GameState.Sectors.Clicker.Level
            $reward = $Global:Config.MathWorkRewardBase * $lvl
            $Global:GameState.Player.Money += $reward
            
            $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "StockBuffUntil" -Value ([DateTime]::UtcNow.AddSeconds($Global:Config.MathWorkAutoSec).ToString('o')) -Force
            $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "StockBuffMult" -Value $Global:Config.MathWorkAutoMult -Force
            Add-WorkStat 'MathCorrect' 1
            Add-WorkStat 'MathReward' $reward
            
            $msg = "BENAR! +Rp $reward, Auto x$($Global:Config.MathWorkAutoMult) selama $($Global:Config.MathWorkAutoSec)s."
            if ($elapsed -lt 5) {
                $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "ClickBuffUntil" -Value ([DateTime]::UtcNow.AddSeconds($Global:Config.MathWorkFastBonusClickSec).ToString('o')) -Force
                $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "ClickBuffMult" -Value $Global:Config.MathWorkFastBonusClickMult -Force
                $msg += " CEPAT! Click x$($Global:Config.MathWorkFastBonusClickMult) selama $($Global:Config.MathWorkFastBonusClickSec)s."
            }
            [System.Windows.Forms.MessageBox]::Show($msg)
            Generate-MathQuestion
            Update-AllUI
        } else {
            [System.Windows.Forms.MessageBox]::Show("Salah! Jawaban: $($Global:MathCurrentAnswer)")
            Add-WorkStat 'MathWrong' 1
            Generate-MathQuestion
        }
    } catch {}
})

function New-PseudoWord {
    $cons = @('b','c','d','f','g','h','j','k','l','m','n','p','r','s','t','v','z')
    $vows = @('a','e','i','o','u')
    $w = ""
    $syl = Get-Random -Minimum 2 -Maximum 4
    for ($i = 0; $i -lt $syl; $i++) { $w += ($cons | Get-Random) + ($vows | Get-Random) }
    if ((Get-Random -Minimum 0 -Maximum 3) -eq 0) { $w += ($cons | Get-Random) }
    return $w
}

function Generate-TypeQuestion {
    $n = Get-Random -Minimum 5 -Maximum 11
    $words = @(1..$n | ForEach-Object { New-PseudoWord })
    $target = $words -join " "
    $lblTypeText.Text = "Ketik: $target"
    $Global:TypeTarget = $target
    $txtTypeInput.Text = ""
}

$btnTypeSubmit.Add_Click({
    $inputText = $txtTypeInput.Text
    $target = $Global:TypeTarget
    $lvl = [int]$Global:GameState.Sectors.Clicker.Level
    
    $matches = 0
    $len = [Math]::Min($inputText.Length, $target.Length)
    for ($i = 0; $i -lt $len; $i++) { if ($inputText[$i] -eq $target[$i]) { $matches++ } }
    $similarity = if ($target.Length -gt 0) { $matches / $target.Length } else { 0 }
    
    $nilai = $similarity * 10 * $lvl
    $cash = $nilai + 1000
    $Global:GameState.Player.Money += $cash
    Add-WorkStat 'TypeDone' 1
    Add-WorkStat 'TypeSimilaritySum' $similarity
    Add-WorkStat 'TypeCash' $cash
    [System.Windows.Forms.MessageBox]::Show("Selesai! Kemiripan: $([Math]::Round($similarity*100))%`nCash didapat: Rp $cash")
    Generate-TypeQuestion
    Update-AllUI
})

function Parse-UtcSafe([string]$s) {
    return [DateTime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-Houses {
    if ($null -eq $Global:GameState.PSObject.Properties['Houses']) {
        $Global:GameState | Add-Member -MemberType NoteProperty -Name "Houses" -Value @() -Force
    }
    return @($Global:GameState.Houses)
}

function Test-HouseDone($h) {
    try { return ([DateTime]::UtcNow -ge (Parse-UtcSafe $h.EndUtc)) } catch { return $true }
}

function Get-HouseById($id) {
    foreach ($h in @(Get-Houses)) { if ($h.Id -eq $id) { return $h } }
    return $null
}

function Get-HouseSellPrice($h) {
    $markup = (Get-Cfg 'BuildSellMarkupPct' 50.0)
    return [double]$h.Cost * (1 + ($markup / 100))
}

function Get-Auction {
    if ($null -eq $Global:GameState.PSObject.Properties['Auction']) { return $null }
    return $Global:GameState.Auction
}

function Test-AuctionAlive($a) {
    if ($null -eq $a) { return $false }
    try { return ((Parse-UtcSafe $a.EndUtc) -gt [DateTime]::UtcNow) } catch { return $false }
}

function Get-AuctionPct($a) {
    $dur = (Get-Cfg 'AuctionDurationSec' 30.0)
    if ($dur -le 0) { $dur = 30.0 }
    $end = Parse-UtcSafe $a.EndUtc
    $prog = 1.0 - (($end - [DateTime]::UtcNow).TotalSeconds / $dur)
    if ($prog -lt 0) { $prog = 0.0 }
    if ($prog -gt 1) { $prog = 1.0 }
    return ([double]$a.StartPct + (([double]$a.EndPct) - ([double]$a.StartPct)) * $prog)
}

function Get-AuctionSellPrice($a, $h) {
    return [double]$h.Cost * (1 + (Get-AuctionPct $a) / 100)
}

function Build-House([string]$typeName, [double]$cost, [double]$waitMin) {
    if ($Global:GameState.Player.Money -lt $cost) {
        [System.Windows.Forms.MessageBox]::Show("Uang tidak cukup! Butuh Rp $cost")
        return
    }
    $Global:GameState.Player.Money -= $cost
    $house = [PSCustomObject]@{
        Id     = [Guid]::NewGuid().ToString("N")
        Type   = $typeName
        EndUtc = [DateTime]::UtcNow.AddMinutes($waitMin).ToString('o')
        Cost   = $cost
    }
    $Global:GameState.Houses = @(@(Get-Houses) + @($house))
    Add-WorkStat 'HouseBuilt' 1
    Add-WorkStat 'HouseSpend' $cost
    Update-BuildUI
    Update-WorkStatsUI
    Update-AllUI
}

function Update-BuildUI {
    $lvBuilds.Width = [Math]::Max(400, [int]($panelBuild.ClientSize.Width * 0.9))
    if ($null -ne $Global:BuildEndTime) {
        $old = [PSCustomObject]@{ Id = [Guid]::NewGuid().ToString("N"); EndUtc = $Global:BuildEndTime.ToString('o'); Cost = ($Global:Config.BuildMaterialCost + $Global:Config.BuildLaborCost) }
        $Global:GameState.Houses = @(@(Get-Houses) + @($old))
        $Global:BuildEndTime = $null
    }
    $houses = @(Get-Houses)
    $selId = $null
    if ($lvBuilds.SelectedItems.Count -gt 0) { $selId = $lvBuilds.SelectedItems[0].Tag }
    $lvBuilds.BeginUpdate()
    $lvBuilds.Items.Clear()
    $i = 1
    $nBuilding = 0; $nDone = 0
    foreach ($h in $houses) {
        $done = Test-HouseDone $h
        $sisa = "-"
        if (-not $done) {
            $nBuilding++
            $ts = (Parse-UtcSafe $h.EndUtc) - [DateTime]::UtcNow
            if ($ts.TotalSeconds -lt 60) { $sisa = "$([int][Math]::Ceiling($ts.TotalSeconds))s" } else { $sisa = "{0}m {1:00}s" -f [int]$ts.TotalMinutes, $ts.Seconds }
        } else { $nDone++ }
        $hType = "Rumah"
        $tProp = $h.PSObject.Properties['Type']
        if ($null -ne $tProp) { $hType = [string]$tProp.Value }
        $price = Get-HouseSellPrice $h
        $profit = $price - [double]$h.Cost
        $item = New-Object System.Windows.Forms.ListViewItem($i.ToString())
        [void]$item.SubItems.Add($hType)
        [void]$item.SubItems.Add($(if ($done) { "Selesai" } else { "Membangun" }))
        [void]$item.SubItems.Add($sisa)
        [void]$item.SubItems.Add(("Rp {0:N0}" -f $h.Cost))
        [void]$item.SubItems.Add(("+Rp {0:N0}" -f $profit))
        [void]$item.SubItems.Add(("Rp {0:N0}" -f $price))
        $item.Tag = $h.Id
        if ($done) { $item.ForeColor = [System.Drawing.Color]::Green; $item.SubItems[5].ForeColor = [System.Drawing.Color]::Green }
        [void]$lvBuilds.Items.Add($item)
        $i++
    }
    $lvBuilds.EndUpdate()
    if ($selId) { foreach ($it in $lvBuilds.Items) { if ($it.Tag -eq $selId) { $it.Selected = $true; break } } }
    $selDone = $false
    if ($lvBuilds.SelectedItems.Count -gt 0) {
        $h = Get-HouseById $lvBuilds.SelectedItems[0].Tag
        if ($null -ne $h -and (Test-HouseDone $h)) { $selDone = $true }
    }
    $btnBuildSell.Enabled = $selDone

    $a = Get-Auction
    if (-not (Test-AuctionAlive $a)) {
        if ($null -ne $a) { $Global:GameState | Add-Member -MemberType NoteProperty -Name Auction -Value $null -Force }
        $a = $null
    }
    if ($null -ne $a) {
        $ah = Get-HouseById $a.HouseId
        $pct = Get-AuctionPct $a
        $aPrice = 0.0
        if ($null -ne $ah) { $aPrice = Get-AuctionSellPrice $a $ah }
        $left = [int]((Parse-UtcSafe $a.EndUtc) - [DateTime]::UtcNow).TotalSeconds
        if ($left -lt 0) { $left = 0 }
        $lblAuction.Text = "Lelang aktif: +{0:N1}% = Rp {1:N0} ({2} dtk)" -f $pct, $aPrice, $left
        $lblAuction.ForeColor = [System.Drawing.Color]::Orange
    } else {
        $lblAuction.Text = "Lelang: tidak aktif"
        $lblAuction.ForeColor = [System.Drawing.Color]::Gray
    }
    $btnBuildAuction.Enabled = ($null -eq $a) -and $selDone

    if ($houses.Count -eq 0) { $lblBuildStatus.Text = "Status: Belum ada bangunan." }
    else { $lblBuildStatus.Text = "Status: $nBuilding membangun, $nDone selesai" }
}

$btnBuildT21.Add_Click({ Build-House "Type 21" $Global:Config.HouseType21_Cost $Global:Config.HouseType21_Wait })
$btnBuildT45.Add_Click({ Build-House "Type 45" $Global:Config.HouseType45_Cost $Global:Config.HouseType45_Wait })
$btnBuildT90.Add_Click({ Build-House "Type 90" $Global:Config.HouseType90_Cost $Global:Config.HouseType90_Wait })
$btnBuildT120.Add_Click({ Build-House "Type 120" $Global:Config.HouseType120_Cost $Global:Config.HouseType120_Wait })

$btnBuildSell.Add_Click({
    if ($lvBuilds.SelectedItems.Count -eq 0) { return }
    $id = $lvBuilds.SelectedItems[0].Tag
    $h = Get-HouseById $id
    if ($null -eq $h -or -not (Test-HouseDone $h)) {
        [System.Windows.Forms.MessageBox]::Show("Rumah itu belum selesai dibangun.")
        return
    }
    $sellPrice = Get-HouseSellPrice $h
    $a = Get-Auction
    if ((Test-AuctionAlive $a) -and [string]$a.HouseId -eq [string]$id) {
        $sellPrice = Get-AuctionSellPrice $a $h
        $Global:GameState | Add-Member -MemberType NoteProperty -Name Auction -Value $null -Force
    }
    $Global:GameState.Player.Money += $sellPrice
    $Global:GameState.Houses = @(@(Get-Houses) | Where-Object { $_.Id -ne $id })
    Add-WorkStat 'HouseSold' 1
    Add-WorkStat 'HouseIncome' $sellPrice
    Update-BuildUI
    Update-WorkStatsUI
    Update-AllUI
    [System.Windows.Forms.MessageBox]::Show("Rumah terjual! +Rp $sellPrice")
})

$btnBuildAuction.Add_Click({
    if ($lvBuilds.SelectedItems.Count -eq 0) { return }
    $id = $lvBuilds.SelectedItems[0].Tag
    $h = Get-HouseById $id
    if ($null -eq $h -or -not (Test-HouseDone $h)) {
        [System.Windows.Forms.MessageBox]::Show("Rumah itu belum selesai dibangun.")
        return
    }
    if (Test-AuctionAlive (Get-Auction)) {
        [System.Windows.Forms.MessageBox]::Show("Sudah ada lelang berjalan. Tunggu selesai atau jual dulu.")
        return
    }
    $markup = (Get-Cfg 'BuildSellMarkupPct' 50.0)
    $maxPct = (Get-Cfg 'AuctionMaxMarkupPct' 120.0)
    if ($maxPct -le $markup) { $maxPct = $markup + 20.0 }
    $endPct = $markup + (Get-Random -Minimum 0 -Maximum ([int](($maxPct - $markup) * 10) + 1)) / 10.0
    $auction = [PSCustomObject]@{ HouseId = [string]$id; EndUtc = [DateTime]::UtcNow.AddSeconds((Get-Cfg 'AuctionDurationSec' 30.0)).ToString('o'); StartPct = $markup; EndPct = $endPct }
    $Global:GameState | Add-Member -MemberType NoteProperty -Name Auction -Value $auction -Force
    Update-BuildUI
})

$lvBuilds.Add_SelectedIndexChanged({
    if ($lvBuilds.SelectedItems.Count -eq 0) { $btnBuildSell.Enabled = $false; return }
    $h = Get-HouseById $lvBuilds.SelectedItems[0].Tag
    $btnBuildSell.Enabled = ($null -ne $h -and (Test-HouseDone $h))
})
# --- FUNGSI UPDATE UI UTAMA ---
function Update-AllUI {
    if ($null -ne $Global:GameState) {
        $lblCashDash.Text = "Cash: Rp " + ("{0:N2}" -f [double]$Global:GameState.Player.Money)
        $lblMenuCash.Text = "Cash: Rp " + ("{0:N0}" -f [double]$Global:GameState.Player.Money)
        $lvl = [int]$Global:GameState.Sectors.Clicker.Level
        $lblClickLvl.Text = "Clicker Level: $lvl"
        $lblClickVal.Text = "Click Value: Rp " + ("{0:N2}" -f [Math]::Max(1.0, [double]$lvl))
        
        $baseRate = [double]$Global:GameState.Sectors.Clicker.AutoRate
        $buffMult = 1.0
        $buffActive = $false
        $timeStr = ""
        $stockSecLeft = 0
        
        if ($Global:GameState.Flags.PSObject.Properties.Name -contains 'StockBuffUntil') {
            try {
                $until = [DateTime]::Parse($Global:GameState.Flags.StockBuffUntil, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ([DateTime]::UtcNow -lt $until) {
                    $buffActive = $true
                    $buffMult = [double]$Global:GameState.Flags.StockBuffMult
                    $stockSecLeft = [int](($until - [DateTime]::UtcNow).TotalSeconds)
                    if ($stockSecLeft -lt 60) { $timeStr = "${stockSecLeft}s" } else { $ts = [TimeSpan]::FromSeconds($stockSecLeft); $timeStr = ("{0}m {1:00}s" -f [int]$ts.TotalMinutes, $ts.Seconds) }
                }
            } catch {}
        }
        
        $clickBuffMult = 1.0
        $clickSecLeft = 0
        if ($Global:GameState.Flags.PSObject.Properties.Name -contains 'ClickBuffUntil') {
            try {
                $untilC = [DateTime]::Parse($Global:GameState.Flags.ClickBuffUntil, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ([DateTime]::UtcNow -lt $untilC) {
                    $clickBuffMult = [double]$Global:GameState.Flags.ClickBuffMult
                    $clickSecLeft = [int](($untilC - [DateTime]::UtcNow).TotalSeconds)
                }
            } catch {}
        }
        
        if ($buffActive) {
            $totalRate = $baseRate * $buffMult
            $lblAutoRate.Text = "Auto Income: Rp {0:N2}/s (Buff {1}x => Rp {2:N2}/s)" -f $baseRate, $buffMult, $totalRate
            $lblAutoRate.ForeColor = [System.Drawing.Color]::Orange
            $lblBuffInfo.Text = "Stock Buff: " + $buffMult + "x (" + $timeStr + ")"
            $lblBuffStock.Text = "Buff: " + $buffMult + "x (" + $timeStr + ")"
        } else {
            $lblAutoRate.Text = "Auto Income: Rp {0:N2}/s" -f $baseRate
            $lblAutoRate.ForeColor = $ColorText
            $lblBuffInfo.Text = "Stock Buff: Tidak Ada"
            $lblBuffStock.Text = "Stock Buff: -"
        }
        $effClickMult = $clickBuffMult * $buffMult
        $effClickLeft = [Math]::Max($clickSecLeft, $stockSecLeft)
        if ($effClickMult -gt 1.0 -and $effClickLeft -gt 0) {
            if ($effClickLeft -lt 60) { $effTime = "${effClickLeft}s" } else { $tsE = [TimeSpan]::FromSeconds($effClickLeft); $effTime = ("{0}m {1:00}s" -f [int]$tsE.TotalMinutes, $tsE.Seconds) }
            $lblClickBuffInfo.Text = "Click Buff: " + $effClickMult + "x (" + $effTime + ")"
            $lblClickBuffInfo.ForeColor = [System.Drawing.Color]::Orange
        } else {
            $lblClickBuffInfo.Text = "Click Buff: Tidak Ada"
            $lblClickBuffInfo.ForeColor = [System.Drawing.Color]::Gray
        }
    }
    
    $stocks = Load-StocksData
    $totalVal = 0.0; $totalCost = 0.0
    
    foreach ($row in $dgvStocks.Rows) {
        $ticker = $row.Tag
        if (-not $ticker) { continue }
        
        $s = $stocks | Where-Object { $_.Ticker -eq $ticker } | Select-Object -First 1
        if (-not $s) { continue }
        
        $owned = 0; $avg = 0.0; $plVal = 0.0
        if ($Global:GameState.PSObject.Properties.Name -contains 'Portfolio' -and $Global:GameState.Portfolio.PSObject.Properties.Name -contains $ticker) {
            $p = $Global:GameState.Portfolio.$ticker
            $owned = [int]$p.Shares; $avg = [double]$p.AvgPrice
            if ($owned -gt 0) { 
                $totalVal += ($s.Price * $owned)
                $totalCost += ($avg * $owned)
                $plVal = ($s.Price - $avg) * $owned
            }
        }
        
        $trendPct = 0.0
        if ($s.History -and $s.History.Count -gt 1) { $trendPct = (($s.Price - $s.History[0].Price) / $s.History[0].Price) * 100 }
        $trendStr = "{0:F2}%" -f $trendPct
        if ($trendPct -gt 0) { $trendStr = "+$trendStr" }
        
        $sinyal = "[TUNGGU]"
        if ($trendPct -gt 1.5) { $sinyal = "[BELI]" } elseif ($trendPct -lt -1.5) { $sinyal = "[JUAL]" }
        
        $avgStr = if ($owned -gt 0) { "Rp " + ("{0:N2}" -f $avg) } else { "-" }
        $plStr = if ($owned -gt 0) { "Rp " + ("{0:N2}" -f $plVal) } else { "-" }

        $row.Cells["HargaSkrg"].Value = "Rp " + ("{0:N2}" -f $s.Price)
        $row.Cells["HargaBeli"].Value = $avgStr
        $row.Cells["Dimiliki"].Value = $owned
        
        $nilaiSaham = $s.Price * $owned
        $nilaiStr = if ($owned -gt 0) { "Rp " + ("{0:N2}" -f $nilaiSaham) } else { "-" }
        $row.Cells["NilaiSaham"].Value = $nilaiStr
        $row.Cells["PL"].Value = $plStr
        
        if ($owned -gt 0) {
            if ($plVal -gt 0) { $row.Cells["PL"].Style.ForeColor = $ColorSuccess }
            elseif ($plVal -lt 0) { $row.Cells["PL"].Style.ForeColor = $ColorDanger }
            else { $row.Cells["PL"].Style.ForeColor = $ColorText }
        } else { $row.Cells["PL"].Style.ForeColor = $ColorText }

        $row.Cells["Tren"].Value = $trendStr
        $row.Cells["Sinyal"].Value = $sinyal
    }

    $lblCashInfo.Text = "Cash: Rp " + ("{0:N2}" -f [double]$Global:GameState.Player.Money)
    $lblStockVal.Text = "Nilai Saham: Rp " + ("{0:N2}" -f $totalVal)
    $pl = $totalVal - $totalCost
    $lblPL.Text = "Total P/L: Rp " + ("{0:N2}" -f $pl)
    if ($pl -gt 0) { $lblPL.ForeColor = $ColorSuccess } elseif ($pl -lt 0) { $lblPL.ForeColor = $ColorDanger } else { $lblPL.ForeColor = $ColorText }
    
    $netWorth = [double]$Global:GameState.Player.Money + $totalVal
    $lblAssets.Text = "Assets: Rp " + ("{0:N2}" -f $totalVal)
    $lblNetWorth.Text = "Net Worth: Rp " + ("{0:N2}" -f $netWorth)
}

function Initialize-Table {
    $stocks = Load-StocksData
    $dgvStocks.Rows.Clear()
    foreach ($s in $stocks) {
        $rowIndex = $dgvStocks.Rows.Add($s.Ticker, "", "", "", "", "", "", "")
        $dgvStocks.Rows[$rowIndex].Tag = $s.Ticker
    }
    if ($dgvStocks.Rows.Count -gt 0) { $dgvStocks.Rows[0].Selected = $true }
}

function Update-Chart {
    if ($dgvStocks.SelectedRows.Count -gt 0) {
        $selTicker = $dgvStocks.SelectedRows[0].Tag
        if ($Global:SelectedTicker -ne $selTicker) { 
            $Global:SelectedTicker = $selTicker 
            $Global:IsZoomed = $false
            $Global:ZoomLevel = 1.0
        }
    }
    if ($Global:SelectedTicker -eq "") { return }

    $stocks = Load-StocksData
    $selData = $stocks | Where-Object { $_.Ticker -eq $Global:SelectedTicker } | Select-Object -First 1
    
    if ($selData -and $selData.History) {
        $chart.Series[0].Points.Clear()
        
        $minPrice = [double]::MaxValue
        $maxPrice = [double]::MinValue
        $idx = 0
        $now = [DateTime]::Now
        $cutoff = $now.AddMinutes(-$Global:CurrentTimeframe)

        foreach ($pt in $selData.History) {
            try {
                $price = 0.0
                if ($null -ne $pt.Price) { $price = [double]$pt.Price }
                elseif ($pt -is [double] -or $pt -is [int]) { $price = [double]$pt }
                
                $dt = [DateTime]::Now.AddSeconds($idx - $selData.History.Count)
                if ($null -ne $pt.Time) {
                    $timeStr = [string]$pt.Time
                    if ($timeStr -match '^\d{10,13}$') {
                        if ($timeStr.Length -eq 13) { $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$timeStr).LocalDateTime }
                        else { $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$timeStr).LocalDateTime }
                    } elseif ($timeStr -match '^\d{4}-\d{2}-\d{2}T') {
                        $dt = [DateTime]::Parse($timeStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    } else {
                        $dt = [DateTime]::Parse($timeStr)
                    }
                }

                if ($dt -ge $cutoff) {
                    if ($price -lt $minPrice) { $minPrice = $price }
                    if ($price -gt $maxPrice) { $maxPrice = $price }
                    [void]$chart.Series[0].Points.AddXY($dt, $price)
                }
                $idx++
            } catch {}
        }

        if ($chart.Series[0].Points.Count -gt 0) {
            $chartArea.AxisX.LabelStyle.Format = "HH:mm:ss"
            
            if ($Global:IsZoomed) {
                $firstPt = $chart.Series[0].Points[0].XValue
                $lastPt = $chart.Series[0].Points[$chart.Series[0].Points.Count - 1].XValue
                $fullRange = $lastPt - $firstPt
                $newRange = $fullRange * $Global:ZoomLevel
                
                $center = ($firstPt + $lastPt) / 2
                $newMin = $center - ($newRange / 2)
                $newMax = $center + ($newRange / 2)
                
                if ($newMin -lt $firstPt) { $newMin = $firstPt }
                if ($newMax -gt $lastPt) { $newMax = $lastPt }

                $chartArea.AxisX.Minimum = $newMin
                $chartArea.AxisX.Maximum = $newMax
                
                $visibleMin = [double]::MaxValue
                $visibleMax = [double]::MinValue
                foreach ($pt in $chart.Series[0].Points) {
                    if ($pt.XValue -ge $newMin -and $pt.XValue -le $newMax) {
                        if ($pt.YValues[0] -lt $visibleMin) { $visibleMin = $pt.YValues[0] }
                        if ($pt.YValues[0] -gt $visibleMax) { $visibleMax = $pt.YValues[0] }
                    }
                }
                if ($visibleMin -ne [double]::MaxValue -and $visibleMax -ne [double]::MinValue) {
                    $vMargin = ($visibleMax - $visibleMin) * 0.1
                    if ($vMargin -eq 0) { $vMargin = 1.0 }
                    $chartArea.AxisY.Minimum = [Math]::Floor($visibleMin - $vMargin)
                    $chartArea.AxisY.Maximum = [Math]::Ceiling($visibleMax + $vMargin)
                }
                $lblZoomRatio.Text = "{0:N0}%" -f (1.0 / $Global:ZoomLevel * 100)
            } else {
                $firstPt = $chart.Series[0].Points[0].XValue
                $lastPt = $chart.Series[0].Points[$chart.Series[0].Points.Count - 1].XValue
                $chartArea.AxisX.Minimum = $firstPt
                $chartArea.AxisX.Maximum = $lastPt
                
                if ($minPrice -ne [double]::MaxValue -and $maxPrice -ne [double]::MinValue) {
                    $margin = ($maxPrice - $minPrice) * 0.1
                    if ($margin -eq 0) { $margin = 1.0 }
                    $chartArea.AxisY.Minimum = [Math]::Floor($minPrice - $margin)
                    $chartArea.AxisY.Maximum = [Math]::Ceiling($maxPrice + $margin)
                }
                $lblZoomRatio.Text = "100%"
            }
        }

        $chart.Titles.Clear()
        $title = New-Object System.Windows.Forms.DataVisualization.Charting.Title
        $title.Text = "Grafik $Global:SelectedTicker ($($Global:CurrentTimeframe) Mnt)"
        $title.ForeColor = $ColorText
        $title.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        [void]$chart.Titles.Add($title)
    }
}

function Do-Buy([int]$qty, [string]$tickerOverride = "") {
    $target = if ($tickerOverride -ne "") { $tickerOverride } else { $Global:SelectedTicker }
    if ($target -eq "") { return $false }
    $stocks = Load-StocksData
    $stock = $stocks | Where-Object { $_.Ticker -eq $target } | Select-Object -First 1
    if (-not $stock) { return $false }
    
    $cost = $stock.Price * $qty
    if ($Global:GameState.Player.Money -ge $cost) {
        $Global:GameState.Player.Money -= $cost
        if ($Global:GameState.PSObject.Properties.Name -notcontains 'Portfolio') {
            $Global:GameState | Add-Member -MemberType NoteProperty -Name "Portfolio" -Value (New-Object PSObject)
        }
        if ($Global:GameState.Portfolio.PSObject.Properties.Name -notcontains $target) {
            $Global:GameState.Portfolio | Add-Member -MemberType NoteProperty -Name $target -Value ([PSCustomObject]@{ Shares = 0; AvgPrice = 0.0 })
        }
        $port = $Global:GameState.Portfolio.$target
        $oldTotal = $port.AvgPrice * $port.Shares
        $port.Shares += $qty
        $port.AvgPrice = ($oldTotal + $cost) / $port.Shares
        
        $buffMult = 1.0; $buffSec = 0
        if ($qty -ge $Global:Config.StockBuyBuff400_Qty) { 
            $buffMult = $Global:Config.StockBuyBuff400_Mult; $buffSec = $Global:Config.StockBuyBuff400_Sec 
        } elseif ($qty -ge $Global:Config.StockBuyBuff200_Qty) { 
            $buffMult = $Global:Config.StockBuyBuff200_Mult; $buffSec = $Global:Config.StockBuyBuff200_Sec 
        } elseif ($qty -ge $Global:Config.StockBuyBuff100_Qty) { 
            $buffMult = $Global:Config.StockBuyBuff100_Mult; $buffSec = $Global:Config.StockBuyBuff100_Sec 
        } elseif ($qty -ge $Global:Config.StockBuyBuff50_Qty) { 
            $buffMult = $Global:Config.StockBuyBuff50_Mult; $buffSec = $Global:Config.StockBuyBuff50_Sec 
        } elseif ($qty -ge $Global:Config.StockBuyBuff10_Qty) { 
            $buffMult = $Global:Config.StockBuyBuff10_Mult; $buffSec = $Global:Config.StockBuyBuff10_Sec 
        }
        
        if ($buffSec -gt 0) {
            $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "StockBuffUntil" -Value ([DateTime]::UtcNow.AddSeconds($buffSec).ToString('o')) -Force
            $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "StockBuffMult" -Value $buffMult -Force
        }
        
        Update-AllUI
        return $true
    }
    return $false
}

function Add-Receipt($id, $status, $message) {
    try {
        $receipts = @()
        try {
            if (Test-Path $Global:ReceiptsPath) {
                $rawR = [System.IO.File]::ReadAllText($Global:ReceiptsPath)
                if (-not [string]::IsNullOrWhiteSpace($rawR)) {
                    try { $receipts = @($rawR -replace "^\uFEFF", "" | ConvertFrom-Json) } catch { $receipts = @() }
                }
            }
        } catch {
            Write-Host ("[WEB BELI][WARN] Gagal baca receipts.json (lanjut dgn daftar baru): " + $_.Exception.Message) -ForegroundColor Yellow
            $receipts = @()
        }
        $cutoff = [DateTime]::UtcNow.AddMinutes(-15).ToString('o')
        $kept = @()
        foreach ($r in $receipts) {
            $rId = $r.PSObject.Properties['Id']
            if ($null -ne $rId -and $rId.Value -eq $id) { continue }
            $tProp = $r.PSObject.Properties['Time']
            if ($null -ne $tProp -and $tProp.Value -and ([string]$tProp.Value) -ge $cutoff) { $kept += $r }
        }
        $receipts = @($kept)
        $receipts += @{ Id = $id; Status = $status; Message = $message; Time = [DateTime]::UtcNow.ToString('o') }
        if ($receipts.Count -gt 50) { $receipts = @($receipts | Select-Object -Last 50) }
        $lastErr = $null
        for ($i = 0; $i -lt 10; $i++) {
            try {
                $tmp = $Global:ReceiptsPath + ".tmp"
                ConvertTo-Json -InputObject @($receipts) -Depth 5 -Compress | Set-Content $tmp -Encoding UTF8
                Move-Item $tmp $Global:ReceiptsPath -Force
                return
            } catch { $lastErr = $_; Start-Sleep -Milliseconds 100 }
        }
        Write-Host ("[WEB BELI][ERROR] GAGAL menulis kuitansi " + $id + ": " + $lastErr.Exception.Message) -ForegroundColor Red
    } catch {
        Write-Host ("[WEB BELI][ERROR] Add-Receipt exception: " + $_.Exception.Message) -ForegroundColor Red
    }
}

function Get-OrderId($o) {
    if ($o.PSObject.Properties.Name -contains 'Id' -and $o.Id) { return [string]$o.Id }
    return ([string]$o.Ticker) + "|" + [string]$o.Qty + "|" + [string]$o.Time
}

function Write-QueueSafe($orders) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if ($orders.Count -eq 0) { "[]" | Set-Content $Global:QueuePath -Encoding UTF8 }
            else { ConvertTo-Json -InputObject @($orders) -Depth 5 -Compress | Set-Content $Global:QueuePath -Encoding UTF8 }
            return $true
        } catch { Start-Sleep -Milliseconds 50 }
    }
    return $false
}

function Enter-QueueLock {
    for ($i = 0; $i -lt 60; $i++) {
        try { return [System.IO.File]::Open($Global:QueueLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
        catch { Start-Sleep -Milliseconds 50 }
    }
    return $null
}

function Process-WebQueue {
    if ($Global:ActiveProfileName -eq "" -or $null -eq $Global:GameState) { return }
    $toExecute = @()
    $lockFs = Enter-QueueLock
    if ($null -eq $lockFs) { Write-Host "[WEB BELI][WARN] Kunci antrian tidak tersedia (tunggu 3 detik habis) - tick ini dilewati" -ForegroundColor Yellow; return }
    try {
        if (-not (Test-Path $Global:QueuePath)) { return }
        $fs = [System.IO.File]::Open($Global:QueuePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fs)
        $raw = $reader.ReadToEnd()
        $reader.Close(); $fs.Close()
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $script:collected = @()
        try { Collect-Orders ($raw -replace "^\uFEFF", "" | ConvertFrom-Json) }
        catch { Write-Host ("[WEB BELI][WARN] Antrian tidak bisa dibaca (JSON parsial?): " + $_.Exception.Message) -ForegroundColor Yellow; return }
        $orders = @($script:collected)
        if ($orders.Count -eq 0) { return }

        $stocks = Load-StocksData
        if ($stocks.Count -eq 0) { return }

        $executeIds = @()
        foreach ($o in $orders) {
            if ($o.Action -ne "BUY") { continue }
            $oid = Get-OrderId $o
            if ($Global:ProcessedOrderIds -contains $oid) { continue }
            if ($o.Profile -ieq $Global:ActiveProfileName) {
                $qty = 0
                try { $qty = [int]$o.Qty } catch { $qty = 0 }
                $stock = $stocks | Where-Object { $_.Ticker -eq [string]$o.Ticker } | Select-Object -First 1
                if (-not $stock -or $qty -lt 1 -or $qty -gt 1000) {
                    $Global:ProcessedOrderIds.Add($oid)
                    Add-Receipt $oid "Failed" "Ticker/qty tidak valid"
                    Write-Host "[WEB BELI] Order dibatalkan (ticker/qty tidak valid)" -ForegroundColor Yellow
                    continue
                }
                $cost = $stock.Price * $qty
                if ($Global:GameState.Player.Money -ge $cost) {
                    $executeIds += $oid
                    $toExecute += , @{ o = $o; qty = $qty }
                } elseif (-not ($Global:QueueSeenIds -contains $oid)) {
                    $Global:QueueSeenIds.Add($oid)
                    Add-Receipt $oid "Held" "Uang belum cukup - order ditahan sampai uang cukup"
                    Write-Host ("[WEB BELI] Uang belum cukup untuk {0} x{1}. Order ditahan." -f $o.Ticker, $qty) -ForegroundColor Yellow
                }
            }
            elseif (-not ($Global:QueueSeenIds -contains $oid)) {
                $Global:QueueSeenIds.Add($oid)
                Write-Host ("[WEB BELI] Order untuk profil '{0}' menunggu (GUI ini: '{1}')" -f $o.Profile, $Global:ActiveProfileName) -ForegroundColor DarkGray
            }
        }

        if ($executeIds.Count -gt 0 -or $Global:ProcessedOrderIds.Count -gt 0) {
            $remaining = @($orders | Where-Object { $executeIds -notcontains (Get-OrderId $_) -and -not ($Global:ProcessedOrderIds -contains (Get-OrderId $_)) })
            Write-QueueSafe $remaining | Out-Null
            if ($remaining.Count -eq 0 -and $Global:ProcessedOrderIds.Count -gt 0) {
                $Global:ProcessedOrderIds.Clear()
                $Global:QueueSeenIds.Clear()
            }
        }
    } catch { Write-Host ("[WEB BELI][ERROR] Process-WebQueue: " + $_.Exception.Message) -ForegroundColor Red }
    finally { if ($lockFs) { try { $lockFs.Close() } catch {} } }

    foreach ($x in $toExecute) {
        $o = $x.o
        $oid = Get-OrderId $o
        if (Do-Buy $x.qty $o.Ticker) {
            $Global:ProcessedOrderIds.Add($oid)
            Add-Receipt $oid "Executed" "Beli tercatat di dashboard"
            Write-Host ("[WEB BELI] Profil '{0}' membeli {1} lembar {2} (order {3})" -f $Global:ActiveProfileName, $x.qty, $o.Ticker, $oid.Substring(0, 8)) -ForegroundColor Green
        } else {
            Add-Receipt $oid "Held" "GUI menunda eksekusi (harga/uang berubah) - order tetap ditahan"
            Write-Host ("[WEB BELI][WARN] Eksekusi tertunda utk {0} x{1} - order dikembalikan ke antrian" -f $o.Ticker, $x.qty) -ForegroundColor Yellow
            $lockFs2 = Enter-QueueLock
            try {
                $q = @()
                if (Test-Path $Global:QueuePath) {
                    $rawQ = [System.IO.File]::ReadAllText($Global:QueuePath)
                    if (-not [string]::IsNullOrWhiteSpace($rawQ)) { $q = @($rawQ -replace "^\uFEFF", "" | ConvertFrom-Json) }
                }
                $q += $o
                ConvertTo-Json -InputObject @($q) -Depth 5 -Compress | Set-Content $Global:QueuePath -Encoding UTF8
            } catch { Write-Host ("[WEB BELI][ERROR] Gagal mengembalikan order ke antrian: " + $_.Exception.Message) -ForegroundColor Red } finally { if ($lockFs2) { try { $lockFs2.Close() } catch {} } }
        }
    }
}

function Collect-Orders($node) {
    if ($node -is [System.Array]) { foreach ($i in $node) { Collect-Orders $i }; return }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        if ($node.PSObject.Properties.Name -contains 'Ticker') { $script:collected += , $node; return }
        foreach ($p in $node.PSObject.Properties) { Collect-Orders $p.Value }
    }
}

function Do-Sell($qty) {
    if ($Global:SelectedTicker -eq "") { return }
    $stocks = Load-StocksData
    $stock = $stocks | Where-Object { $_.Ticker -eq $Global:SelectedTicker } | Select-Object -First 1
    if (-not $stock) { return }
    
    $port = $Global:GameState.Portfolio.$($Global:SelectedTicker)
    if ($null -eq $port) { return }
    
    if ($qty -eq -1) { $qty = [Math]::Floor($port.Shares / 2) }
    if ($qty -eq 0) { $qty = $port.Shares }
    
    if ($port.Shares -lt $qty) { $qty = $port.Shares }
    
    if ($qty -gt 0) {
        $earn = $stock.Price * $qty
        $Global:GameState.Player.Money += $earn
        $port.Shares -= $qty
        if ($port.Shares -eq 0) { $port.AvgPrice = 0 }
        Update-AllUI
    }
}

function Do-SellGlobal() {
    $totalEarn = 0
    $stocks = Load-StocksData
    if ($Global:GameState.PSObject.Properties.Name -contains 'Portfolio') {
        foreach ($ticker in $Global:GameState.Portfolio.PSObject.Properties.Name) {
            $port = $Global:GameState.Portfolio.$ticker
            if ($port.Shares -gt 0) {
                $s = $stocks | Where-Object { $_.Ticker -eq $ticker } | Select-Object -First 1
                if ($s) {
                    $earn = $s.Price * $port.Shares
                    $Global:GameState.Player.Money += $earn
                    $totalEarn += $earn
                    $port.Shares = 0; $port.AvgPrice = 0
                }
            }
        }
    }
    Update-AllUI
    [System.Windows.Forms.MessageBox]::Show("Semua saham berhasil dijual. Total didapat: Rp " + ("{0:N2}" -f $totalEarn))
}

# --- EVENT HANDLERS ---
$btnBuy1.Add_Click({ Do-Buy 1 })
$btnBuy10.Add_Click({ Do-Buy 10 })
$btnBuy50.Add_Click({ Do-Buy 50 })
$btnBuy100.Add_Click({ Do-Buy 100 })
$btnBuy200.Add_Click({ Do-Buy 200 })
$btnBuy400.Add_Click({ Do-Buy 400 })

$btnSell1.Add_Click({ Do-Sell 1 })
$btnSell50.Add_Click({ Do-Sell -1 })
$btnSellTicker.Add_Click({ Do-Sell 0 })
$btnSellAll.Add_Click({ Do-SellGlobal })

$dgvStocks.Add_SelectionChanged({ Update-Chart })

# --- TIMER ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($null -ne $Global:GameState) {
        Process-WebQueue
        $rate = [double]$Global:GameState.Sectors.Clicker.AutoRate
        $buff = 1.0
        
        if ($Global:GameState.Flags.PSObject.Properties.Name -contains 'StockBuffUntil') {
            try { $until = [DateTime]::Parse($Global:GameState.Flags.StockBuffUntil, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); if ([DateTime]::UtcNow -lt $until) { $buff = [double]$Global:GameState.Flags.StockBuffMult } } catch {}
        }
        
        $Global:GameState.Player.Money += $rate * $buff + (Get-WorkerRate)
        $Global:GameState.Player.PlaytimeSec += 1
        
        $Global:SaveCounter++
        if ($Global:SaveCounter -ge 30) {
            $Global:SaveCounter = 0
            Save-GameData
        }
        
        Update-AllUI
        Update-Chart
        if ($panelBuild.Visible) { Update-BuildUI }
        if ($panelStat.Visible) { Update-WorkStatsUI }
        if ($panelContract.Visible) { Update-ContractsUI }
        if ($panelWorker.Visible) { Update-WorkerUI }
        Ensure-Contracts
        $Global:EngineCheckCounter++
        if ($Global:EngineCheckCounter -ge 15) { $Global:EngineCheckCounter = 0; Ensure-MarketEngine }
    }
})

Ensure-MarketEngine
$waitLoops = 0
while (-not (Test-MarketEngineAlive) -and $waitLoops -lt 50) { Start-Sleep -Milliseconds 100; $waitLoops++ }
Initialize-Table
Update-AllUI
Update-Chart
Show-WorkPanel $panelStat
Update-WorkStatsUI
Update-BuildUI
Update-ContractsUI
Update-WorkerUI
$timer.Start()

$form.Add_FormClosing({
    [SleepPreventer]::AllowSleep()
    Save-GameData
    Unlock-GuiProfile
    $timer.Stop()
})

[void]$form.ShowDialog()

if ($Global:ActiveProfileName -eq "") {
    $scriptPath = $MyInvocation.MyCommand.Path
    & powershell -ExecutionPolicy Bypass -File $scriptPath
}