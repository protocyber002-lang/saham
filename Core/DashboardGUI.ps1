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
else { $Global:Config = @{ MathWorkAutoMult=3.0; MathWorkAutoSec=20.0; MathWorkFastBonusClickMult=5.0; MathWorkFastBonusClickSec=15.0; MathWorkRewardBase=1000.0; BuildMaterialCost=500000; BuildLaborCost=200000; BuildWaitMinutes=30; BuildSellMarkupPct=50 } }

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

$btnMenuMath = Create-ActionButton "1. Matematika" 10 10 180 50 $ColorAccent
$btnMenuType = Create-ActionButton "2. Ketik Ulang" 10 70 180 50 $ColorAccent
$btnMenuBuild = Create-ActionButton "3. Developer Bangunan" 10 130 180 50 $ColorAccent
$panelMenu.Controls.Add($btnMenuMath)
$panelMenu.Controls.Add($btnMenuType)
$panelMenu.Controls.Add($btnMenuBuild)

# --- PANEL KANAN: KONTEN ---
$panelContent = New-Object System.Windows.Forms.Panel
$panelContent.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelContent.BackColor = $ColorPanel
$splitWork.Panel2.Controls.Add($panelContent)

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
$lblBuildInfo.Text = "Bahan: Rp 500.000 | Jasa: Rp 200.000 | Waktu: 30 Menit"
$lblBuildInfo.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblBuildInfo.Location = New-Object System.Drawing.Point(20, 30)
$lblBuildInfo.AutoSize = $true
$panelBuild.Controls.Add($lblBuildInfo)

$btnBuildStart = Create-ActionButton "Bangun Rumah" 20 70 200 40 $ColorAccent
$panelBuild.Controls.Add($btnBuildStart)

$lblBuildStatus = New-Object System.Windows.Forms.Label
$lblBuildStatus.Text = "Status: Belum ada bangunan."
$lblBuildStatus.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$lblBuildStatus.Location = New-Object System.Drawing.Point(20, 130)
$lblBuildStatus.AutoSize = $true
$panelBuild.Controls.Add($lblBuildStatus)

$btnBuildSell = Create-ActionButton "Jual Rumah" 20 170 200 40 $ColorSuccess
$btnBuildSell.Enabled = $false
$panelBuild.Controls.Add($btnBuildSell)

# --- LOGIKA TAB KERJA ---
$Global:MathCurrentAnswer = 0
$Global:MathStartTime = $null
$Global:BuildEndTime = $null

function Show-WorkPanel($panel) {
    $panelMath.Visible = $false
    $panelType.Visible = $false
    $panelBuild.Visible = $false
    $panel.Visible = $true
}

$btnMenuMath.Add_Click({ Show-WorkPanel $panelMath; Generate-MathQuestion })
$btnMenuType.Add_Click({ Show-WorkPanel $panelType; Generate-TypeQuestion })
$btnMenuBuild.Add_Click({ Show-WorkPanel $panelBuild; Update-BuildUI })

function Generate-MathQuestion {
    $lvl = [int]$Global:GameState.Sectors.Clicker.Level
    $a = Get-Random -Minimum 5 -Maximum (10 + $lvl * 5)
    $b = Get-Random -Minimum 5 -Maximum (10 + $lvl * 5)
    $Global:MathCurrentAnswer = $a + $b
    $lblMathSoal.Text = "Soal: $a + $b = ?"
    $txtMathAnswer.Text = ""
    $Global:MathStartTime = [DateTime]::UtcNow
}

$btnMathSkip.Add_Click({ Generate-MathQuestion })

$btnMathSubmit.Add_Click({
    try {
        if ([int]$txtMathAnswer.Text -eq $Global:MathCurrentAnswer) {
            $elapsed = ([DateTime]::UtcNow - $Global:MathStartTime).TotalSeconds
            $lvl = [int]$Global:GameState.Sectors.Clicker.Level
            $reward = $Global:Config.MathWorkRewardBase * $lvl
            $Global:GameState.Player.Money += $reward
            
            $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "StockBuffUntil" -Value ([DateTime]::UtcNow.AddSeconds($Global:Config.MathWorkAutoSec).ToString('o')) -Force
            $Global:GameState.Flags | Add-Member -MemberType NoteProperty -Name "StockBuffMult" -Value $Global:Config.MathWorkAutoMult -Force
            
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
            Generate-MathQuestion
        }
    } catch {}
})

function Generate-TypeQuestion {
    $texts = @("ClickTycoonIdle adalah game seru", "Saya sedang belajar PowerShell", "Pasar saham naik turun setiap detik")
    $target = $texts | Get-Random
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
    [System.Windows.Forms.MessageBox]::Show("Selesai! Kemiripan: $([Math]::Round($similarity*100))%`nCash didapat: Rp $cash")
    Generate-TypeQuestion
    Update-AllUI
})

function Update-BuildUI {
    if ($null -ne $Global:BuildEndTime -and [DateTime]::UtcNow -lt $Global:BuildEndTime) {
        $ts = $Global:BuildEndTime - [DateTime]::UtcNow
        $lblBuildStatus.Text = "Status: Membangun... ($([int]$ts.TotalMinutes) mnt $($ts.Seconds) dtk)"
        $btnBuildSell.Enabled = $false
        $btnBuildStart.Enabled = $false
    } elseif ($null -ne $Global:BuildEndTime -and [DateTime]::UtcNow -ge $Global:BuildEndTime) {
        $lblBuildStatus.Text = "Status: Rumah Siap Dijual!"
        $btnBuildSell.Enabled = $true
        $btnBuildStart.Enabled = $false
    } else {
        $lblBuildStatus.Text = "Status: Belum ada bangunan."
        $btnBuildSell.Enabled = $false
        $btnBuildStart.Enabled = $true
    }
}

$btnBuildStart.Add_Click({
    $cost = $Global:Config.BuildMaterialCost + $Global:Config.BuildLaborCost
    if ($Global:GameState.Player.Money -ge $cost) {
        $Global:GameState.Player.Money -= $cost
        $Global:BuildEndTime = [DateTime]::UtcNow.AddMinutes($Global:Config.BuildWaitMinutes)
        Update-BuildUI
        Update-AllUI
    } else {
        [System.Windows.Forms.MessageBox]::Show("Uang tidak cukup! Butuh Rp $cost")
    }
})

$btnBuildSell.Add_Click({
    $baseCost = $Global:Config.BuildMaterialCost + $Global:Config.BuildLaborCost
    $sellPrice = $baseCost + ($baseCost * ($Global:Config.BuildSellMarkupPct / 100))
    $Global:GameState.Player.Money += $sellPrice
    $Global:BuildEndTime = $null
    Update-BuildUI
    Update-AllUI
    [System.Windows.Forms.MessageBox]::Show("Rumah terjual! +Rp $sellPrice")
})
# --- FUNGSI UPDATE UI UTAMA ---
function Update-AllUI {
    if ($null -ne $Global:GameState) {
        $lblCashDash.Text = "Cash: Rp " + ("{0:N2}" -f [double]$Global:GameState.Player.Money)
        $lvl = [int]$Global:GameState.Sectors.Clicker.Level
        $lblClickLvl.Text = "Clicker Level: $lvl"
        $lblClickVal.Text = "Click Value: Rp " + ("{0:N2}" -f [Math]::Max(1.0, [double]$lvl))
        
        $baseRate = [double]$Global:GameState.Sectors.Clicker.AutoRate
        $buffMult = 1.0
        $buffActive = $false
        $timeStr = ""
        
        if ($Global:GameState.Flags.PSObject.Properties.Name -contains 'StockBuffUntil') {
            try {
                $until = [DateTime]::Parse($Global:GameState.Flags.StockBuffUntil, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ([DateTime]::UtcNow -lt $until) {
                    $buffActive = $true
                    $buffMult = [double]$Global:GameState.Flags.StockBuffMult
                    $secLeft = [int](($until - [DateTime]::UtcNow).TotalSeconds)
                    $ts = [TimeSpan]::FromSeconds($secLeft)
                    $timeStr = "{0:00}:{1:00}:{2:00}" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
                }
            } catch {}
        }
        
        if ($buffActive) {
            $totalRate = $baseRate * $buffMult
            $lblAutoRate.Text = "Auto Income: Rp {0:N2}/s (Buff {1}x => Rp {2:N2}/s)" -f $baseRate, $buffMult, $totalRate
            $lblAutoRate.ForeColor = [System.Drawing.Color]::Orange
            $lblBuffInfo.Text = "Stock Buff: Aktif (" + $buffMult + "x) - " + $timeStr
            $lblBuffStock.Text = "Buff: " + $buffMult + "x (" + $timeStr + ")"
        } else {
            $lblAutoRate.Text = "Auto Income: Rp {0:N2}/s" -f $baseRate
            $lblAutoRate.ForeColor = $ColorText
            $lblBuffInfo.Text = "Stock Buff: Tidak Ada"
            $lblBuffStock.Text = "Stock Buff: -"
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
        
        $Global:GameState.Player.Money += $rate * $buff
        $Global:GameState.Player.PlaytimeSec += 1
        
        $Global:SaveCounter++
        if ($Global:SaveCounter -ge 30) {
            $Global:SaveCounter = 0
            Save-GameData
        }
        
        Update-AllUI
        Update-Chart
        if ($panelBuild.Visible) { Update-BuildUI }
    }
})

Initialize-Table
Update-AllUI
Update-Chart
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