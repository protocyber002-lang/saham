# AdminGUI.ps1 - Admin ClickTycoonIdle: atur Tab Kerja via Data\work_config.json
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AdminRoot = Split-Path -Parent $PSScriptRoot
$AdminWorkCfgPath = Join-Path $AdminRoot "Data\work_config.json"
$AdminConfigPath = Join-Path $AdminRoot "Core\Config.ps1"
$AdminStocksPath = Join-Path $AdminRoot "Data\stocks.json"
$AdminVotesPath = Join-Path $AdminRoot "Data\stock_votes.json"
$AdminAnnouncePath = Join-Path $AdminRoot "Data\announcements.json"
$AdminProfilesDir = Join-Path $AdminRoot "Data\profiles"

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
    @{ Nama = "Saham"; Baris = @() }
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

function Format-AdminNumber([double]$v) {
    return $v.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Convert-AdminNumber([string]$txt) {
    $val = [double]::NaN
    if ([double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) { return $val }
    $txt2 = $txt -replace ',', '.'
    if ([double]::TryParse($txt2, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) { return $val }
    return [double]::NaN
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

function Read-AdminStocksRaw {
    try {
        if (Test-Path $AdminStocksPath) {
            $raw = [System.IO.File]::ReadAllText($AdminStocksPath) -replace "^\uFEFF", ""
            if (-not [string]::IsNullOrWhiteSpace($raw)) { return @($raw | ConvertFrom-Json) }
        }
    } catch { }
    return @()
}

function Save-AdminStocksRaw($arr) {
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $tmp = "$AdminStocksPath.tmp"
            [System.IO.File]::WriteAllText($tmp, ($arr | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path $AdminStocksPath) { Remove-Item $AdminStocksPath -Force -ErrorAction SilentlyContinue }
            Move-Item $tmp $AdminStocksPath -Force
            return $true
        } catch { Start-Sleep -Milliseconds 100 }
    }
    return $false
}

function Get-AdminStocks {
    $arr = @()
    foreach ($s in (Read-AdminStocksRaw)) {
        $arr += @{ Ticker = [string]$s.Ticker; Name = [string]$s.Name; Price = [double]$s.Price }
    }
    return $arr
}

function Add-AdminAnnounce($msg) {
    try {
        $items = @()
        if (Test-Path $AdminAnnouncePath) {
            $raw = [System.IO.File]::ReadAllText($AdminAnnouncePath) -replace "^\uFEFF", ""
            if (-not [string]::IsNullOrWhiteSpace($raw)) { try { $items = @($raw | ConvertFrom-Json) } catch { $items = @() } }
        }
        $items += @{ Time = [DateTime]::UtcNow.ToString("o"); Message = $msg }
        while (@($items).Count -gt 50) { $items = @($items[1..(@($items).Count - 1)]) }
        $tmp = "$AdminAnnouncePath.tmp"
        [System.IO.File]::WriteAllText($tmp, ($items | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $AdminAnnouncePath) { Remove-Item $AdminAnnouncePath -Force -ErrorAction SilentlyContinue }
        Move-Item $tmp $AdminAnnouncePath -Force
    } catch { }
}

function Fill-Boxes {
    $ov = Get-OverrideKeys
    foreach ($k in $Global:AdminBoxes.Keys) {
        $box = $Global:AdminBoxes[$k]
        $lbl = $box.Tag
        if ($Global:Config.ContainsKey($k)) { $box.Text = Format-AdminNumber ([double]$Global:Config[$k]) }
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
        $val = Convert-AdminNumber $txt
        if ([double]::IsNaN($val)) {
            [System.Windows.Forms.MessageBox]::Show(("Nilai tidak valid untuk " + $k + ": '" + $txt + "'. Harus angka (titik atau koma = desimal)."))
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
$form.Text = "Admin ClickTycoonIdle - Tab Kerja & Saham"
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

$pageSaham = $null

foreach ($g in $GroupDefs) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $g.Nama
    $page.BackColor = $ColorPanel
    $tabs.TabPages.Add($page)

    if ($g.Nama -eq "Saham") {
        $pageSaham = $page

        $lblAt = New-Object System.Windows.Forms.Label
        $lblAt.Text = "Ticker:"
        $lblAt.Location = New-Object System.Drawing.Point(15, 21)
        $lblAt.AutoSize = $true
        $page.Controls.Add($lblAt)
        $txtNewTicker = New-Object System.Windows.Forms.TextBox
        $txtNewTicker.Location = New-Object System.Drawing.Point(70, 15)
        $txtNewTicker.Size = New-Object System.Drawing.Size(70, 24)
        $txtNewTicker.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Upper
        $page.Controls.Add($txtNewTicker)

        $lblAn = New-Object System.Windows.Forms.Label
        $lblAn.Text = "Nama:"
        $lblAn.Location = New-Object System.Drawing.Point(160, 21)
        $lblAn.AutoSize = $true
        $page.Controls.Add($lblAn)
        $txtNewName = New-Object System.Windows.Forms.TextBox
        $txtNewName.Location = New-Object System.Drawing.Point(210, 15)
        $txtNewName.Size = New-Object System.Drawing.Size(220, 24)
        $page.Controls.Add($txtNewName)

        $lblAp = New-Object System.Windows.Forms.Label
        $lblAp.Text = "Harga awal (Rp):"
        $lblAp.Location = New-Object System.Drawing.Point(445, 21)
        $lblAp.AutoSize = $true
        $page.Controls.Add($lblAp)
        $txtNewPrice = New-Object System.Windows.Forms.TextBox
        $txtNewPrice.Location = New-Object System.Drawing.Point(555, 15)
        $txtNewPrice.Size = New-Object System.Drawing.Size(90, 24)
        $page.Controls.Add($txtNewPrice)

        $btnAddStock = New-Object System.Windows.Forms.Button
        $btnAddStock.Text = "Tambah Saham"
        $btnAddStock.Location = New-Object System.Drawing.Point(15, 48)
        $btnAddStock.Size = New-Object System.Drawing.Size(140, 30)
        $btnAddStock.BackColor = $ColorSuccess
        $btnAddStock.ForeColor = [System.Drawing.Color]::White
        $btnAddStock.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $page.Controls.Add($btnAddStock)

        $lblStockNote = New-Object System.Windows.Forms.Label
        $lblStockNote.Text = "Saham baru langsung aktif di MarketEngine (±1 detik) dan diumumkan di Dashboard Utama tiap profil."
        $lblStockNote.Font = New-Object System.Drawing.Font("Segoe UI", 8)
        $lblStockNote.ForeColor = [System.Drawing.Color]::Gray
        $lblStockNote.Location = New-Object System.Drawing.Point(170, 56)
        $lblStockNote.AutoSize = $true
        $page.Controls.Add($lblStockNote)

        $lblList = New-Object System.Windows.Forms.Label
        $lblList.Text = "Daftar saham (pilih utk edit nama):"
        $lblList.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $lblList.ForeColor = $ColorAccent
        $lblList.Location = New-Object System.Drawing.Point(15, 95)
        $lblList.AutoSize = $true
        $page.Controls.Add($lblList)

        $lstStocks = New-Object System.Windows.Forms.ListBox
        $lstStocks.Location = New-Object System.Drawing.Point(15, 118)
        $lstStocks.Size = New-Object System.Drawing.Size(280, 240)
        $page.Controls.Add($lstStocks)

        $lblRen = New-Object System.Windows.Forms.Label
        $lblRen.Text = "Saham yang sudah ada HANYA bisa edit NAMA:"
        $lblRen.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $lblRen.ForeColor = $ColorText
        $lblRen.Location = New-Object System.Drawing.Point(315, 121)
        $lblRen.AutoSize = $true
        $page.Controls.Add($lblRen)

        $txtRename = New-Object System.Windows.Forms.TextBox
        $txtRename.Location = New-Object System.Drawing.Point(315, 145)
        $txtRename.Size = New-Object System.Drawing.Size(220, 24)
        $page.Controls.Add($txtRename)

        $btnRenameStock = New-Object System.Windows.Forms.Button
        $btnRenameStock.Text = "Simpan Nama"
        $btnRenameStock.Location = New-Object System.Drawing.Point(315, 178)
        $btnRenameStock.Size = New-Object System.Drawing.Size(140, 30)
        $btnRenameStock.BackColor = $ColorAccent
        $btnRenameStock.ForeColor = [System.Drawing.Color]::White
        $btnRenameStock.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $page.Controls.Add($btnRenameStock)

        $lblDelRule = New-Object System.Windows.Forms.Label
        $lblDelRule.Text = "Saham dihapus otomatis jika 51% semua profil memintanya\r\n(tombol 'Minta Hapus' di web, wajib login profil)."
        $lblDelRule.Font = New-Object System.Drawing.Font("Segoe UI", 8)
        $lblDelRule.ForeColor = [System.Drawing.Color]::Gray
        $lblDelRule.Location = New-Object System.Drawing.Point(315, 225)
        $lblDelRule.AutoSize = $true
        $page.Controls.Add($lblDelRule)

        $lblVotes = New-Object System.Windows.Forms.Label
        $lblVotes.Text = ""
        $lblVotes.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $lblVotes.ForeColor = $ColorWarn
        $lblVotes.Location = New-Object System.Drawing.Point(15, 375)
        $lblVotes.Size = New-Object System.Drawing.Size(660, 90)
        $page.Controls.Add($lblVotes)
    }
    elseif ($g.Nama -eq "Rumah") {
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

function Update-StockVotesUI {
    $profCount = 0
    try { $profCount = @(Get-ChildItem $AdminProfilesDir -Filter "*.json" -ErrorAction SilentlyContinue).Count } catch { }
    $threshold = 0
    if ($profCount -ge 1) { $threshold = [Math]::Ceiling(0.51 * $profCount) }
    $voteCounts = @{}
    try {
        if (Test-Path $AdminVotesPath) {
            $rawV = [System.IO.File]::ReadAllText($AdminVotesPath) -replace "^\uFEFF", ""
            if (-not [string]::IsNullOrWhiteSpace($rawV)) {
                $objV = $rawV | ConvertFrom-Json
                foreach ($p in $objV.PSObject.Properties) { $voteCounts[[string]$p.Name] = @($p.Value).Count }
            }
        }
    } catch { }
    $lines = @("Profil terdaftar: $profCount  |  Syarat hapus: $threshold suara (51%)")
    $hasVote = $false
    foreach ($k in $voteCounts.Keys) {
        if ($voteCounts[$k] -gt 0) { $hasVote = $true; $lines += ("- {0}: {1}/{2} suara" -f $k, $voteCounts[$k], $threshold) }
    }
    if (-not $hasVote) { $lines += "Belum ada permintaan hapus." }
    $lblVotes.Text = ($lines -join [Environment]::NewLine)
}

function Update-StockTabUI {
    $lstStocks.Items.Clear()
    foreach ($s in (Get-AdminStocks)) { [void]$lstStocks.Items.Add(($s.Ticker + "  -  " + $s.Name)) }
    Update-StockVotesUI
}

$btnAddStock.Add_Click({
    $ticker = $txtNewTicker.Text.Trim().ToUpper()
    $name = $txtNewName.Text.Trim()
    $price = Convert-AdminNumber $txtNewPrice.Text.Trim()
    if ($ticker -notmatch '^[A-Z0-9]{1,8}$') { [void][System.Windows.Forms.MessageBox]::Show("Ticker hanya huruf/angka, maks 8 karakter."); return }
    if (-not $name) { [void][System.Windows.Forms.MessageBox]::Show("Nama tidak boleh kosong."); return }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
    if ([double]::IsNaN($price) -or $price -le 0) { [void][System.Windows.Forms.MessageBox]::Show("Harga awal harus angka > 0 (terima titik/koma desimal)."); return }
    $stocks = Read-AdminStocksRaw
    foreach ($s in $stocks) { if ($s.Ticker.ToUpper() -eq $ticker) { [void][System.Windows.Forms.MessageBox]::Show("Saham $ticker sudah ada."); return } }
    $hist = @()
    $p = $price
    $nowS = [DateTime]::Now
    for ($i = 60; $i -ge 1; $i--) {
        $t = $nowS.AddSeconds(-$i * 5)
        $p = $p + ((Get-Random -Minimum -20 -Maximum 21) / 100.0)
        if ($p -lt 1.0) { $p = 1.0 }
        $hist += @{ Time = $t.ToString("o"); Price = [Math]::Round($p, 2) }
    }
    $newS = @{ Ticker = $ticker; Name = $name; Price = [Math]::Round($p, 2); History = $hist; Trend = 0; TrendTimeLeft = 0 }
    $saved = $false
    for ($tryI = 0; $tryI -lt 5 -and -not $saved; $tryI++) {
        if (Save-AdminStocksRaw (@($stocks) + @($newS))) {
            Start-Sleep -Milliseconds 300
            foreach ($s in (Read-AdminStocksRaw)) { if ($s.Ticker -eq $ticker) { $saved = $true } }
        }
    }
    if ($saved) {
        Add-AdminAnnounce ("Saham baru: {0} ({1}) - harga awal Rp {2}" -f $name, $ticker, [Math]::Round($p, 2))
        $txtNewTicker.Text = ""; $txtNewName.Text = ""; $txtNewPrice.Text = ""
        Update-StockTabUI
        [void][System.Windows.Forms.MessageBox]::Show("Saham $ticker ditambahkan. Pengumuman tampil di Dashboard Utama tiap profil.")
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("Gagal menulis stocks.json (bisa karena MarketEngine sedang menulis; coba lagi).")
    }
})

$btnRenameStock.Add_Click({
    $sel = $lstStocks.SelectedItem
    if (-not $sel) { [void][System.Windows.Forms.MessageBox]::Show("Pilih saham dulu di daftar."); return }
    $ticker = ([string]$sel).Split(" ")[0]
    $newName = $txtRename.Text.Trim()
    if (-not $newName) { [void][System.Windows.Forms.MessageBox]::Show("Nama baru tidak boleh kosong."); return }
    if ($newName.Length -gt 40) { $newName = $newName.Substring(0, 40) }
    $oldName = ""
    $found = $false
    foreach ($s in (Read-AdminStocksRaw)) { if ($s.Ticker -eq $ticker) { $oldName = [string]$s.Name; $found = $true } }
    if (-not $found) { [void][System.Windows.Forms.MessageBox]::Show("Saham $ticker tidak ditemukan."); return }
    if ($newName -eq $oldName) { [void][System.Windows.Forms.MessageBox]::Show("Nama tidak berubah."); return }
    $saved = $false
    for ($tryI = 0; $tryI -lt 5 -and -not $saved; $tryI++) {
        $cur = Read-AdminStocksRaw
        foreach ($s in $cur) { if ($s.Ticker -eq $ticker) { $s.Name = $newName } }
        if (Save-AdminStocksRaw $cur) {
            Start-Sleep -Milliseconds 300
            foreach ($s in (Read-AdminStocksRaw)) { if ($s.Ticker -eq $ticker -and $s.Name -eq $newName) { $saved = $true } }
        }
    }
    if ($saved) {
        Add-AdminAnnounce ("Saham {0} berganti nama: {1} -> {2}" -f $ticker, $oldName, $newName)
        Update-StockTabUI
        [void][System.Windows.Forms.MessageBox]::Show("Nama saham $ticker diperbarui. Pengumuman tampil di Dashboard Utama tiap profil.")
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("Gagal menulis stocks.json (bisa karena MarketEngine sedang menulis; coba lagi).")
    }
})

$lstStocks.Add_SelectedIndexChanged({
    $sel = $lstStocks.SelectedItem
    if ($sel) {
        $tk = ([string]$sel).Split(" ")[0]
        foreach ($s in (Get-AdminStocks)) { if ($s.Ticker -eq $tk) { $txtRename.Text = $s.Name } }
    }
})

$stockTimer = New-Object System.Windows.Forms.Timer
$stockTimer.Interval = 1000
$stockTimer.Add_Tick({
    try { if ($null -ne $pageSaham -and $tabs.SelectedTab -eq $pageSaham) { Update-StockVotesUI } } catch { }
})
$stockTimer.Start()

$btnReload = Create-AdminButton "Muat Ulang" 0 120 $ColorAccent
$btnReload.Add_Click({ Reload-Config; Update-StockTabUI })
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
Update-StockTabUI
[void]$form.ShowDialog()
$form.Dispose()
