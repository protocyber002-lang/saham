# ServerGUI.ps1 - GUI Admin Server Monitor
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$form = New-Object System.Windows.Forms.Form
$form.Text = "ClickTycoonIdle - Server Monitor"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$form.ForeColor = [System.Drawing.Color]::White

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($tabControl)

# --- TAB 1: LOGS ---
$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text = "Server Logs"
$tabLogs.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$tabControl.TabPages.Add($tabLogs)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtLog.BackColor = [System.Drawing.Color]::Black
$txtLog.ForeColor = [System.Drawing.Color]::LimeGreen
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtLog.ReadOnly = $true
$tabLogs.Controls.Add($txtLog)

# --- TAB 2: CLIENTS ---
$tabClients = New-Object System.Windows.Forms.TabPage
$tabClients.Text = "Clients (Web)"
$tabClients.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$tabControl.TabPages.Add($tabClients)

$dgvClients = New-Object System.Windows.Forms.DataGridView
$dgvClients.Location = New-Object System.Drawing.Point(20, 20)
$dgvClients.Size = New-Object System.Drawing.Size(740, 500)
$dgvClients.BackgroundColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$dgvClients.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$dgvClients.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$dgvClients.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$tabClients.Controls.Add($dgvClients)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $logPath = Join-Path $root "Data\market.log"
    if (Test-Path $logPath) {
        $log = [System.IO.File]::ReadAllText($logPath)
        $txtLog.Text = $log
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }

    $devsPath = Join-Path $root "Data\devices.json"
    if (Test-Path $devsPath) {
        try {
            $rawDevs = [System.IO.File]::ReadAllText($devsPath)
            $devs = $rawDevs | ConvertFrom-Json
            $dt = New-Object System.Data.DataTable
            $dt.Columns.Add("Nama Device") | Out-Null
            $dt.Columns.Add("Status") | Out-Null
            $dt.Columns.Add("Profil") | Out-Null
            
            foreach ($prop in $devs.PSObject.Properties) {
                $d = $prop.Value
                $prof = "-"
                if ($d.PSObject.Properties.Name -contains "Profile") { $prof = $d.Profile }
                $dt.Rows.Add($d.Name, $d.Status, $prof) | Out-Null
            }
            $dgvClients.DataSource = $dt
        } catch {}
    }
})

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()