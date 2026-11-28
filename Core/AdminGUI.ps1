# AdminGUI.ps1 - Admin ClickTycoonIdle: atur Tab Kerja via Data\work_config.json
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AdminRoot = Split-Path -Parent $PSScriptRoot
$AdminWorkCfgPath = Join-Path $AdminRoot "Data\work_config.json"
$AdminConfigPath = Join-Path $AdminRoot "Core\Config.ps1"

$Global:Config = @{}
if (Test-Path $AdminConfigPath) { . $AdminConfigPath }

$ColorBg      = [System.Drawing.Color]::FromArgb(24, 24, 28)
$ColorPanel   = [System.Drawing.Color]::FromArgb(36, 36, 42)
$ColorText    = [System.Drawing.Color]::FromArgb(220, 220, 225)
$ColorAccent  = [System.Drawing.Color]::FromArgb(0, 150, 255)
$ColorSuccess = [System.Drawing.Color]::FromArgb(0, 200, 100)
$ColorWarn    = [System.Drawing.Color]::FromArgb(255, 190, 80)

$GroupDefs = @(
    @{ Nama = "Matematika"; Baris = @(
        @{ K = 'MathWorkRewardBase'; D = 'Hadiah dasar jawaban benar (Rp)' }
        @{ K = 'MathWorkAutoMult'; D = 'Pengganda auto-click setelah menjawab' }
        @{ K = 'MathWorkAutoSec'; D = 'Durasi auto-click (detik)' }
        @{ K = 'MathWorkFastBonusClickMult'; D = 'Bonus klik jawaban cepat (x)' }
        @{ K = 'MathWorkFastBonusClickSec'; D = 'Durasi bonus klik cepat (detik)' }
    ) }
    @{ Nama = "Bangunan"; Baris = @(
        @{ K = 'BuildSellMarkupPct'; D = 'Markup harga jual rumah (%)' }
        @{ K = 'SellTaxPct'; D = 'Pajak jual rumah (%)' }
        @{ K = 'SellMaterialBonusPct'; D = 'Bonus bahan tiap jual rumah (%)' }
        @{ K = 'HebelPrice'; D = 'Harga hebel (Rp/pcs)' }
        @{ K = 'SemenPrice'; D = 'Harga semen (Rp/sak)' }
        @{ K = 'PasirPrice'; D = 'Harga pasir (Rp/m3)' }
    ) }
    @{ Nama = "Rumah"; Baris = @() }
    @{ Nama = "Pekerja"; Baris = @(
        @{ K = 'WorkerBaseCost'; D = 'Upah rekrut pekerja pertama (Rp)' }
        @{ K = 'WorkerCostGrowth'; D = 'Pengali harga rekrut berikutnya (x)' }
        @{ K = 'WorkerXpPerLevel'; D = 'XP untuk naik 1 level' }
        @{ K = 'WorkerSpeedBonusPerLvl'; D = 'Bonus kecepatan per level (0.02 = +2%)' }
    ) }
    @{ Nama = "Kontrak & Lelang"; Baris = @(
        @{ K = 'ContractRewardBase'; D = 'Hadiah dasar kontrak (Rp)' }
        @{ K = 'AuctionDurationSec'; D = 'Durasi lelang (detik)' }
        @{ K = 'AuctionMaxMarkupPct'; D = 'Markup maksimum lelang (%)' }
    ) }
    @{ Nama = "Sewa & Fasilitas"; Baris = @(
        @{ K = 'RentYieldPctPerHour'; D = 'Sewa dasar per jam (% nilai rumah)' }
        @{ K = 'Facility_Carport_Cost'; D = 'Carport: biaya pasang (Rp)' }
        @{ K = 'Facility_Carport_RentPct'; D = 'Carport: sewa naik (%)' }
        @{ K = 'Facility_Taman_Cost'; D = 'Taman: biaya pasang (Rp)' }
        @{ K = 'Facility_Taman_RentPct'; D = 'Taman: sewa naik (%)' }
        @{ K = 'Facility_Kolam_Cost'; D = 'Kolam: biaya pasang (Rp)' }
        @{ K = 'Facility_Kolam_RentPct'; D = 'Kolam: sewa naik (%)' }
        @{ K = 'Facility_Rooftop_Cost'; D = 'Rooftop: biaya pasang (Rp)' }
        @{ K = 'Facility_Rooftop_RentPct'; D = 'Rooftop: sewa naik (%)' }
    ) }
)

$Global:AdminBoxes = @{}

function Get-OverrideKeys {
    $set = @{}
    try {
        if (Test-Path $AdminWorkCfgPath) {
            $raw = [System.IO.File]::ReadAllText($AdminWorkCfgPath)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $wc = $raw -replace "^\uFEFF", "" | ConvertFrom-Json
                foreach ($p in $wc.PSObject.Properties) { $set[$p.Name] = $true }
            }
        }
    } catch { }
    return $set
}

function Save-WorkConfig([hashtable]$obj) {
    $lastErr = $null
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $tmp = $AdminWorkCfgPath + ".tmp"
            ConvertTo-Json -InputObject $obj -Depth 3 | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp $AdminWorkCfgPath -Force
            return
        } catch { $lastErr = $_; Start-Sleep -Milliseconds 100 }
    }
    [System.Windows.Forms.MessageBox]::Show(("Gagal menulis file: " + $lastErr.Exception.Message))
}

function Fill-Boxes {
    $ov = Get-OverrideKeys
    foreach ($k in $Global:AdminBoxes.Keys) {
        $box = $Global:AdminBoxes[$k]
        $lbl = $box.Tag
        if ($Global:Config.ContainsKey($k)) { $box.Text = "$($Global:Config[$k])" }
        if ($ov.ContainsKey($k)) {
            $box.BackColor = $ColorWarn
            if ($null -ne $lbl) {
                $lbl.Text = "* " + $lbl.Text.TrimStart("* ")
                $lbl.ForeColor = $ColorWarn
            }
        } else {
            $box.BackColor = [System.Drawing.Color]::White
            if ($null -ne $lbl) {
                $lbl.Text = $lbl.Text.TrimStart("* ")
                $lbl.ForeColor = $ColorText
            }
        }
    }
    $n = (Get-OverrideKeys).Count
    $lblStatus.Text = "Override aktif: $n  |  $AdminWorkCfgPath"
}

function Reload-Config {
    $Global:Config = @{}
    if (Test-Path $AdminConfigPath) { . $AdminConfigPath }
    Fill-Boxes
}

function Save-FromBoxes {
    $obj = @{}
    foreach ($k in $Global:AdminBoxes.Keys) {
        $txt = $Global:AdminBoxes[$k].Text.Trim()
        $val = 0.0
        if (-not [double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
            [System.Windows.Forms.MessageBox]::Show(("Nilai tidak valid untuk " + $k + ": '" + $txt + "'. Harus angka (titik = desimal)."))
            return
        }
        if ($val -le 0) {
            [System.Windows.Forms.MessageBox]::Show(("Nilai untuk " + $k + " harus lebih dari 0 (ditemukan: " + $txt + ")."))
            return
        }
        $defVal = [double]$Global:ConfigDefaults[$k]
        if ([Math]::Abs($val - $defVal) -gt 0.000001) { $obj[$k] = $val }
    }
    Save-WorkConfig $obj
    Fill-Boxes
    [System.Windows.Forms.MessageBox]::Show(("Tersimpan! Override aktif: " + $obj.Count + " nilai. Game GUI/TUI yang sedang jalan akan memuatnya otomatis dalam 3 detik."))
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Admin ClickTycoonIdle - Atur Tab Kerja"
$form.Size = New-Object System.Drawing.Size(740, 640)
$form.BackColor = $ColorBg
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false

$lblHead = New-Object System.Windows.Forms.Label
$lblHead.Text = "Ubah nilai lalu klik Simpan. Tanda * kuning = nilai di-override dari work_config.json (beda dari default)."
$lblHead.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblHead.ForeColor = [System.Drawing.Color]::Gray
$lblHead.Location = New-Object System.Drawing.Point(12, 10)
$lblHead.AutoSize = $true
$form.Controls.Add($lblHead)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 34)
$tabs.Size = New-Object System.Drawing.Size(700, 500)
$form.Controls.Add($tabs)

foreach ($g in $GroupDefs) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $g.Nama
    $page.BackColor = $ColorPanel
    $tabs.TabPages.Add($page)

    if ($g.Nama -eq "Rumah") {
        $heads = @("Tipe", "Harga Jual", "Hebel", "Semen", "Pasir", "Jam Kerja", "Min Pekerja")
        $hx = @(15, 100, 195, 290, 385, 480, 575)
        for ($c = 0; $c -lt $heads.Count; $c++) {
            $hl = New-Object System.Windows.Forms.Label
            $hl.Text = $heads[$c]
            $hl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            $hl.ForeColor = $ColorAccent
            $hl.Location = New-Object System.Drawing.Point($hx[$c], 15)
            $hl.AutoSize = $true
            $page.Controls.Add($hl)
        }
        $row = 0
        foreach ($n in @(21, 45, 90, 120)) {
            $y = 42 + $row * 34
            $yy = $y + 3
            $rl = New-Object System.Windows.Forms.Label
            $rl.Text = "Type $n"
            $rl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            $rl.ForeColor = $ColorText
            $rl.Location = New-Object System.Drawing.Point(15, $yy)
            $rl.AutoSize = $true
            $page.Controls.Add($rl)
            $col = 0
            foreach ($s in @('Cost', 'Hebel', 'Semen', 'Pasir', 'WorkHours', 'MinWorkers')) {
                $key = ("HouseType{0}_{1}" -f $n, $s)
                $bx = $hx[$col + 1]
                $box = New-Object System.Windows.Forms.TextBox
                $box.Location = New-Object System.Drawing.Point($bx, $y)
                $box.Size = New-Object System.Drawing.Size(88, 24)
                $page.Controls.Add($box)
                $Global:AdminBoxes[$key] = $box
                $col++
            }
            $row++
        }
    } else {
        $i = 0
        foreach ($b in $g.Baris) {
            $y = 15 + $i * 36
            $yy = $y + 3
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text = ("{0}  [{1}]" -f $b.D, $b.K)
            $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
            $lbl.ForeColor = $ColorText
            $lbl.Location = New-Object System.Drawing.Point(15, $yy)
            $lbl.AutoSize = $true
            $page.Controls.Add($lbl)
            $box = New-Object System.Windows.Forms.TextBox
            $box.Location = New-Object System.Drawing.Point(540, $y)
            $box.Size = New-Object System.Drawing.Size(120, 24)
            $box.Tag = $lbl
            $page.Controls.Add($box)
            $Global:AdminBoxes[$b.K] = $box
            $i++
        }
    }
}

$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Location = New-Object System.Drawing.Point(12, 544)
$panelBottom.Size = New-Object System.Drawing.Size(700, 50)
$form.Controls.Add($panelBottom)

function Create-AdminButton($text, $x, $w, $bg) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point($x, 8)
    $btn.Size = New-Object System.Drawing.Size($w, 34)
    $btn.BackColor = $bg
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    return $btn
}

$btnReload = Create-AdminButton "Muat Ulang" 0 120 $ColorAccent
$btnReload.Add_Click({ Reload-Config })
$panelBottom.Controls.Add($btnReload)

$btnSave = Create-AdminButton "Simpan" 130 120 $ColorSuccess
$btnSave.Add_Click({ Save-FromBoxes })
$panelBottom.Controls.Add($btnSave)

$btnReset = Create-AdminButton "Hapus Semua Override" 260 190 ([System.Drawing.Color]::FromArgb(180, 60, 60))
$btnReset.Add_Click({
    Save-WorkConfig @{}
    Reload-Config
    [System.Windows.Forms.MessageBox]::Show("Semua override dihapus - kembali ke default Config.ps1.")
})
$panelBottom.Controls.Add($btnReset)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = ""
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$lblStatus.ForeColor = [System.Drawing.Color]::Gray
$lblStatus.Location = New-Object System.Drawing.Point(460, 18)
$lblStatus.AutoSize = $true
$panelBottom.Controls.Add($lblStatus)

Fill-Boxes
[void]$form.ShowDialog()
$form.Dispose()
