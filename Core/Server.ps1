# Server.ps1 - API Gateway (Port 9000)
$root = Split-Path -Parent $PSScriptRoot
$port = 9000
$listener = $null
try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:$port/")
    $listener.Start()
} catch {
    Write-Host "[ERROR] Gagal membuka port 9000. Pastikan tidak ada aplikasi lain yang memakainya." -ForegroundColor Red
    return
}

$Global:PairingCode = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$devicesPath = Join-Path $root "Data\devices.json"
$stocksPath  = Join-Path $root "Data\stocks.json"
$queuePath   = Join-Path $root "Data\queue.json"
$webRoot     = Join-Path $root "web"

if (-not (Test-Path (Join-Path $root "Data"))) { New-Item -ItemType Directory -Path (Join-Path $root "Data") -Force | Out-Null }
$Global:PairingCode | Set-Content (Join-Path $root "Data\pairing.txt") -Encoding UTF8

if (-not (Test-Path $devicesPath)) { "{}" | Set-Content $devicesPath -Encoding UTF8 }
if (-not (Test-Path $queuePath)) { "[]" | Set-Content $queuePath -Encoding UTF8 }

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " SERVER BERJALAN DI http://+:$port/" -ForegroundColor Cyan
Write-Host " PAIRING CODE: $Global:PairingCode" -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Cyan

function Get-Devices { 
    if (-not (Test-Path $devicesPath)) { return @{} }
    $raw = Get-Content $devicesPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return $raw | ConvertFrom-Json 
}
function Save-Devices($devs) { $devs | ConvertTo-Json -Depth 5 | Set-Content $devicesPath -Encoding UTF8 }

function Read-FileSafe {
    param([string]$Path, [int]$Retries = 3, [int]$DelayMs = 50)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path) } else { return $null }
        } catch { Start-Sleep -Milliseconds $DelayMs }
    }
    return $null
}

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $req = $context.Request
        $res = $context.Response
        $res.AddHeader("Access-Control-Allow-Origin", "*")
        $res.AddHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
        
        if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode = 200; $res.Close(); continue }

        $path = $req.Url.LocalPath
        $body = ""
        if ($req.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }

        $respJson = ""
        $contentType = "application/json"
        $res.StatusCode = 200

        # --- WEB PAGES ---
        if ($path -eq "/" -or $path -eq "/index.html") {
            $file = "$webRoot\index.html"
            if (Test-Path $file) { $respJson = [System.IO.File]::ReadAllText($file); $contentType = "text/html" }
        }
        # --- ADMIN API ---
        elseif ($path -eq "/api/admin/devices") { $respJson = Get-Content $devicesPath -Raw }
        elseif ($path -eq "/api/admin/pairing") { $respJson = '{"code":"' + $Global:PairingCode + '"}' }
        elseif ($path -eq "/api/admin/toggle" -and $req.HttpMethod -eq "POST") {
            $data = $body | ConvertFrom-Json
            $devs = Get-Devices
            if ($devs.PSObject.Properties.Name -contains $data.id) { $devs.$($data.id).Status = $data.status; Save-Devices $devs }
            $respJson = '{"status":"ok"}'
        }
        # --- PUBLIC API ---
        else {
            $auth = $req.Headers["Authorization"]
            $isValid = $false
            $devs = Get-Devices
            
            if ($auth -and $auth.StartsWith("Bearer ")) {
                $token = $auth.Substring(7)
                foreach ($d in $devs.PSObject.Properties) {
                    if ($d.Value.Token -eq $token -and $d.Value.Status -eq "Allowed") { $isValid = $true; break }
                }
            }

            if ($path -eq "/api/pair" -and $req.HttpMethod -eq "POST") {
                $data = $body | ConvertFrom-Json
                if ($data.code -eq $Global:PairingCode) {
                    $devId = [Guid]::NewGuid().ToString()
                    $token = [Guid]::NewGuid().ToString() + [Guid]::NewGuid().ToString()
                    $devs | Add-Member -MemberType NoteProperty -Name $devId -Value @{ Name = $data.name; Status = "Allowed"; Token = $token }
                    Save-Devices $devs
                    $respJson = '{"status":"ok","token":"' + $token + '"}'
                } else { $respJson = '{"status":"error","message":"Kode pairing salah"}'; $res.StatusCode = 401 }
            }
                        elseif ($path -eq "/api/history") {
                if ($isValid) {
                    $ticker = $req.QueryString["ticker"]
                    if (-not $ticker) { $ticker = "AAPL" }
                    
                    $histData = @()
                    if (Test-Path $stocksPath) {
                        $rawStocks = Read-FileSafe $stocksPath
                        if (-not [string]::IsNullOrWhiteSpace($rawStocks)) {
                            $stocks = $rawStocks | ConvertFrom-Json
                            foreach ($s in $stocks) {
                                if ($s.Ticker -eq $ticker) {
                                    if ($s.History) { $histData = $s.History }
                                    break
                                }
                            }
                        }
                    }
                    $respJson = @{ ticker = $ticker; history = $histData } | ConvertTo-Json -Depth 5 -Compress
                } else {
                    $respJson = '{"status":"error","message":"Unauthorized"}'
                    $res.StatusCode = 401
                }
            }
            elseif ($path -eq "/api/login_profile" -and $req.HttpMethod -eq "POST") {
                if (-not $isValid) { $respJson = '{"status":"error","message":"Unauthorized"}'; $res.StatusCode = 401 }
                else {
                    $data = $body | ConvertFrom-Json
                    $profName = ([string]$data.profile).Trim() 
                    $profilesDir = Join-Path $root "Data\profiles"
                    $profilePath = Join-Path $profilesDir ($profName + ".json")

                    if (-not (Test-Path $profilePath)) {
                        $found = Get-ChildItem -Path $profilesDir -Filter "*.json" | Where-Object { $_.BaseName -ieq $profName } | Select-Object -First 1
                        if ($found) { $profName = $found.BaseName; $profilePath = $found.FullName }
                    }

                    if (Test-Path $profilePath) {
                        foreach ($d in $devs.PSObject.Properties) {
                            if ($d.Value.Token -eq $auth.Substring(7)) { $d.Value | Add-Member -MemberType NoteProperty -Name "Profile" -Value $profName -Force; break }
                        }
                        Save-Devices $devs
                        $respJson = '{"status":"ok","profile":"' + $profName + '"}'
                    } else { $respJson = '{"status":"error","message":"Profil tidak ditemukan: ' + $profName + '"}'; $res.StatusCode = 404 }
                }
            }
            elseif ($path -eq "/api/logout" -and $req.HttpMethod -eq "POST") {
                if ($isValid) {
                    $token = $auth.Substring(7); $newDevs = @{}
                    foreach ($d in $devs.PSObject.Properties) { if ($d.Value.Token -ne $token) { $newDevs | Add-Member -MemberType NoteProperty -Name $d.Name -Value $d.Value } }
                    $newDevs | ConvertTo-Json -Depth 5 | Set-Content $devicesPath -Encoding UTF8
                }
                $respJson = '{"status":"ok","message":"Logout berhasil"}'
            }
            elseif ($path -eq "/api/stocks") {
                if ($isValid) { $raw = Read-FileSafe $stocksPath; if ($raw) { $respJson = $raw } else { $respJson = '[]' } }
                else { $respJson = '{"status":"error","message":"Unauthorized"}'; $res.StatusCode = 401 }
            }
            elseif ($path -eq "/api/buy" -and $req.HttpMethod -eq "POST") {
                if (-not $isValid) { $respJson = '{"status":"error","message":"Unauthorized"}'; $res.StatusCode = 401 }
                else {
                    $data = $body | ConvertFrom-Json
                    $ticker = $data.ticker; $qty = [int]$data.qty
                    
                    $queue = @()
                    if (Test-Path $queuePath) {
                        $rawQ = Read-FileSafe $queuePath
                        if (-not [string]::IsNullOrWhiteSpace($rawQ)) { $queue = @($rawQ | ConvertFrom-Json) }
                    }
                    
                    $profName = ""
                    foreach ($d in $devs.PSObject.Properties) {
                        if ($d.Value.Token -eq $auth.Substring(7)) { if ($d.Value.PSObject.Properties.Name -contains "Profile") { $profName = $d.Value.Profile }; break }
                    }
                    
                    $queue += @{ Action = "BUY"; Ticker = $ticker; Qty = $qty; Profile = $profName; Time = [DateTime]::UtcNow.ToString('o') }
                    $queue | ConvertTo-Json -Depth 5 | Set-Content $queuePath -Encoding UTF8
                    
                    Write-Host ("[LOG BELI] Profil '{0}' membeli {1} lembar {2}" -f $profName, $qty, $ticker) -ForegroundColor Green
                    $respJson = '{"status":"ok","message":"Perintah beli dikirim"}'
                }
            }
            else { $respJson = '{"status":"error","message":"Not Found"}'; $res.StatusCode = 404 }
        }

        # --- KIRIM RESPON (ANTI CRASH) ---
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($respJson)
        try {
            $res.ContentType = $contentType
            $res.ContentLength64 = $buffer.Length
            $res.OutputStream.Write($buffer, 0, $buffer.Length)
            $res.Close()
        } catch {
            if ($_.Exception.Message -notmatch "network name is no longer available") {
                Write-Host ("[WARNING] Gagal kirim respon: " + $_.Exception.Message) -ForegroundColor Yellow
            }
        } finally {
            try { $res.OutputStream.Close() } catch {}
            try { $res.Close() } catch {}
        }
    } catch {
        Write-Host ("[SERVER ERROR] " + $_.Exception.Message) -ForegroundColor Red
    }
}