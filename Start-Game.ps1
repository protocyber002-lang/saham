# Start-Game.ps1 - entry point + menu profil + loop
param(
    [switch]$saham,
    [string]$profile,
    [switch]$TUI
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- ANTI-SLEEP (MENCEGAH PC/LAPTOP SLEEP) ---
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
    public static void PreventSleep() {
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
    }
    public static void AllowSleep() {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
}
"@
}
[SleepPreventer]::PreventSleep()

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'Core\Compat.ps1')
. (Join-Path $root 'Core\Config.ps1')
. (Join-Path $root 'Core\Capability.ps1')
. (Join-Path $root 'Core\Engine.ps1')
. (Join-Path $root 'Core\SaveSystem.ps1')
. (Join-Path $root 'UI\Render.ps1')
. (Join-Path $root 'UI\Input.ps1')
. (Join-Path $root 'Modules\MathChallenge.ps1')
. (Join-Path $root 'Modules\StockMarket.ps1')

# --- AUTO-START MARKET ENGINE ---
$engineJob = Get-Job -Name 'MarketEngine' -ErrorAction SilentlyContinue
if ($null -eq $engineJob -or $engineJob.State -ne 'Running') {
    if ($null -ne $engineJob) { Remove-Job $engineJob -Force -ErrorAction SilentlyContinue }
    try {
        Start-Job -FilePath (Join-Path $PSScriptRoot 'Core\MarketEngine.ps1') -Name 'MarketEngine' | Out-Null
        Write-Host "[INFO] Market Engine berjalan di background." -ForegroundColor DarkCyan
    } catch {
        Write-Host "[WARN] Gagal start background job. Menjalankan di foreground." -ForegroundColor Yellow
        & (Join-Path $root 'Core\MarketEngine.ps1')
    }
} else {
    Write-Host "[INFO] Market Engine sudah berjalan." -ForegroundColor DarkCyan
}

# --- LOAD STOCK VIEWER SETELAH SEMUA MODUL SIAP ---
. (Join-Path $root 'Modules\StockViewer.ps1')

if ($saham) {
    Start-StockViewer
    [SleepPreventer]::AllowSleep()
    return
}

# --- INISIALISASI PAIRING CODE ---
if (-not (Test-Path "D:\POWERSHELL\CLICKTYCOONIDLE\Data")) {
    New-Item -ItemType Directory -Path "D:\POWERSHELL\CLICKTYCOONIDLE\Data" -Force | Out-Null
}
$Global:PairingCode = $null
try {
    if ($null -ne $Global:PairingCode -and $Global:PairingCode -ne "") { }
} catch { }
$pairFile = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\pairing.txt"
if (Test-Path $pairFile) {
    $Global:PairingCode = (Get-Content $pairFile -Raw).Trim()
} else {
    $Global:PairingCode = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
    [System.IO.File]::WriteAllText($pairFile, $Global:PairingCode)
}
$caps = Get-Capabilities
Show-CapabilityReport $caps

$mode = 'TUI'
if ($TUI) {
    Write-Host "Mode dipaksa: TUI (melalui argumen -TUI)" -ForegroundColor Cyan
} elseif ($caps.IsGuiReady) {
    Write-Host "Sistem memenuhi syarat GUI." -ForegroundColor Green
    Write-Host "Pilih mode: [1] TUI  [2] GUI (belum tersedia - fallback TUI)" -ForegroundColor Cyan
    try { $choice = [Console]::ReadKey($true); if ($choice.KeyChar -eq '2') { $mode = 'GUI' } } catch {}
} else {
    Write-Host "Mode: TUI (GUI tidak tersedia)." -ForegroundColor Yellow
}
if ($mode -eq 'GUI') {
    Write-Host "GUI belum diimplementasikan. Fallback TUI." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 700
    $mode = 'TUI'
}
Write-Host ("Menjalankan mode: {0}" -f $mode) -ForegroundColor Cyan

function Show-ProfileMenu {
    $profiles = @(Get-ProfileList)
    Write-Host ""
    Write-Host "=== Pilih Profil ===" -ForegroundColor Cyan
    $i = 0
    foreach ($p in $profiles) {
        $i++
        $lastStr = ""
        if ($p.LastSaveUtc) {
            try {
                $t = [DateTime]::Parse($p.LastSaveUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                $lastStr = $t.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            } catch { $lastStr = "" }
        }
        
        $ts = [TimeSpan]::FromSeconds($p.Playtime)
        $ptStr = ("{0:00}:{1:00}:{2:00}" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)

        $lineStr = "[{0}] {1,-10} | Lvl {2,-3} | Cash {3,12:N2} | Net {4,12:N2} | PT {5} | {6}" -f `
            $i, $p.Name, $p.Level, $p.Money, $p.NetWorth, $ptStr, $lastStr
            
        $lock = Get-ProfileLockInfo $p.Name
        if ($lock) {
            Write-Host $lineStr -NoNewline
            Write-Host ("  [TERKUNCI - PID {0}]" -f $lock.Pid) -ForegroundColor Red
        } else {
            Write-Host $lineStr
        }
    }
    if ($profiles.Count -eq 0) {
        Write-Host "  (belum ada profil)" -ForegroundColor DarkGray
    }
    Write-Host "[N] Profil baru"
    Write-Host "[Q] Keluar"
    Write-Host ""
}

$globalQuit = $false
$autoProfileChecked = $false

while (-not $globalQuit) {
    $selectedProfile = $null
    
    if (-not $autoProfileChecked -and $profile) {
        $autoProfileChecked = $true
        $profiles = @(Get-ProfileList)
        $match = $null
        foreach ($p in $profiles) {
            if ($p.Name -eq $profile) { $match = $p; break }
        }
        
        if ($null -ne $match) {
            if (Get-ProfileLockInfo $profile) {
                Write-Host ("Profil '{0}' dari CLI sedang aktif di window lain." -f $profile) -ForegroundColor Red
            } else {
                $selectedProfile = $profile
                Write-Host ("Auto-select profil: {0}" -f $selectedProfile) -ForegroundColor Green
            }
        } else {
            Write-Host ("Profil '{0}' tidak ditemukan. Silakan pilih dari menu." -f $profile) -ForegroundColor Yellow
        }
    }

    while (-not $selectedProfile) {
        Show-ProfileMenu
        $key = $null
        try { $key = [Console]::ReadKey($true) } catch { return }
        $ch = $key.KeyChar
        $profiles = @(Get-ProfileList)

        if ($ch -match '^[Qq]$') {
            Write-Host "Keluar." -ForegroundColor Cyan
            $globalQuit = $true
            break
        }
        if ($ch -match '^[Nn]$') {
            Write-Host "Nama profil baru (huruf/angka/_/-): " -NoNewline -ForegroundColor Yellow
            $name = Read-Host
            try {
                New-Profile $name | Out-Null
                $selectedProfile = $name
                Write-Host ("Profil '{0}' dibuat." -f $name) -ForegroundColor Green
            } catch {
                Write-Host ("Gagal: " + $_.Exception.Message) -ForegroundColor Red
            }
            continue
        }

        $idx = 0
        [int]::TryParse([string]$ch, [ref]$idx) | Out-Null
        if ($idx -ge 1 -and $idx -le $profiles.Count) {
            $candidate = $profiles[$idx - 1].Name
            if (Get-ProfileLockInfo $candidate) {
                Write-Host ("Profil '{0}' sedang aktif." -f $candidate) -ForegroundColor Red
                Start-Sleep -Seconds 1
            } else {
                $selectedProfile = $candidate
            }
        }
    }
    if ($globalQuit) { break }

    Write-Host ("Profil aktif: {0}" -f $selectedProfile) -ForegroundColor Cyan
    if (-not $profile -or $selectedProfile -ne $profile) {
        Write-Host "Tekan tombol apa saja untuk mulai..." -ForegroundColor Cyan
        try { [Console]::ReadKey($true) | Out-Null } catch {}
    } else {
        Start-Sleep -Milliseconds 500
    }

    $exitReason = 'MENU'
    try {
        $exitReason = Start-Engine -ProfileName $selectedProfile
    } catch {
        Write-Host ""
        Write-Host "=== FATAL ERROR ===" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        Write-Host "Tekan Enter untuk kembali ke menu..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch { Start-Sleep -Seconds 3 }
        $exitReason = 'MENU'
    }

    if ($exitReason -eq 'QUIT') {
        $globalQuit = $true
    }
}
Write-Host "Sampai jumpa!" -ForegroundColor Cyan
[SleepPreventer]::AllowSleep()