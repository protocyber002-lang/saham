# Capability.ps1 - deteksi kelayakan TUI vs GUI (ASCII-safe)
Set-StrictMode -Version 2.0

function Get-Capabilities {
    $caps = @{
        PSVersion     = $PSVersionTable.PSVersion
        NetRelease    = 0
        HasWinForms   = $false
        HasWpf        = $false
        HasAnsi       = $false
        ScreenW       = 0
        ScreenH       = 0
        IsInteractive = $false
        IsGuiReady    = $false
        GuiReasons    = @()
    }

    if ($caps.PSVersion.Major -lt 5) {
        $caps.GuiReasons += "PowerShell < 5.0"
    }

    try {
        $ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $caps.NetRelease = [int]$ndp.Release
    } catch {
        $caps.NetRelease = 0
        $caps.GuiReasons += ".NET Framework 4.x tidak terdeteksi"
    }
    if ($caps.NetRelease -lt 378389) {
        $caps.GuiReasons += ".NET Framework < 4.5"
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $caps.HasWinForms = $true
    } catch {
        $caps.GuiReasons += "System.Windows.Forms tidak bisa di-load"
    }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $caps.HasWpf = $true
    } catch {}

    try {
        $os = [System.Environment]::OSVersion.Version
        if ($os.Major -ge 10) { $caps.HasAnsi = $true }
    } catch {}

    if ($caps.HasWinForms) {
        try {
            $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $caps.ScreenW = $b.Width
            $caps.ScreenH = $b.Height
            if ($b.Width -lt 1024 -or $b.Height -lt 600) {
                $caps.GuiReasons += "Resolusi < 1024x600"
            }
        } catch {
            $caps.GuiReasons += "Screen bounds tidak terbaca"
        }
    }

    try {
        [void][Console]::KeyAvailable
        $caps.IsInteractive = $true
    } catch {
        $caps.IsInteractive = $false
        $caps.GuiReasons += "Console tidak interaktif"
    }

    $caps.IsGuiReady = ($caps.GuiReasons.Count -eq 0)
    return $caps
}

function Show-CapabilityReport($caps) {
    Write-Host "=== Deteksi Sistem ===" -ForegroundColor Cyan
    Write-Host ("PowerShell  : {0}" -f $caps.PSVersion)
    Write-Host ("NET Release : {0}" -f $caps.NetRelease)
    Write-Host ("WinForms    : {0}" -f $caps.HasWinForms)
    Write-Host ("WPF         : {0}" -f $caps.HasWpf)
    Write-Host ("ANSI        : {0}" -f $caps.HasAnsi)
    Write-Host ("Screen      : {0}x{1}" -f $caps.ScreenW, $caps.ScreenH)
    Write-Host ("Interaktif  : {0}" -f $caps.IsInteractive)
    if ($caps.IsGuiReady) {
        Write-Host "GUI         : DIIZINKAN" -ForegroundColor Green
    } else {
        Write-Host "GUI         : DITOLAK (TUI dipaksa)" -ForegroundColor Yellow
        foreach ($r in $caps.GuiReasons) {
            Write-Host ("  - {0}" -f $r) -ForegroundColor DarkYellow
        }
    }
    Write-Host ""
}