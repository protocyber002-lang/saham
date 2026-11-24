# Server.ps1 - API Gateway & Web Server (One-Stop)
$port = 8999
$listener = $null
$success = $false

# Coba bind ke port 8999, jika gagal coba port lain
$portsToTry = @(8999, 9000, 9001, 9002)
foreach ($p in $portsToTry) {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://+:$p/")
        $listener.Start()
        $port = $p
        $success = $true
        break
    } catch {
        $listener = $null
    }
}

if (-not $success) {
    Write-Host "[ERROR] Tidak bisa membuka port 8999-9002. Pastikan tidak ada server lain yang berjalan." -ForegroundColor Red
    return
}

$Global:PairingCode = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$devicesPath = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\devices.json"
$stocksPath = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\stocks.json"
$queuePath = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\queue.json"
$webRoot = "D:\POWERSHELL\CLICKTYCOONIDLE\web"

# Simpan kode pairing ke file agar dibaca Game TUI (jika perlu)
if (-not (Test-Path "D:\POWERSHELL\CLICKTYCOONIDLE\Data\pairing.txt")) {
    New-Item -ItemType Directory -Path "D:\POWERSHELL\CLICKTYCOONIDLE\Data" -Force | Out-Null
}
$Global:PairingCode | Set-Content "D:\POWERSHELL\CLICKTYCOONIDLE\Data\pairing.txt" -Encoding UTF8

if (-not (Test-Path $devicesPath)) { "{}" | Set-Content $devicesPath -Encoding UTF8 }
if (-not (Test-Path $queuePath)) { "[]" | Set-Content $queuePath -Encoding UTF8 }

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " SERVER BERJALAN DI http://+:$port/" -ForegroundColor Cyan
Write-Host " PAIRING CODE: $Global:PairingCode" -ForegroundColor Yellow
Write-Host " Buka: http://localhost:$port/" -ForegroundColor Cyan
Write-Host " Admin: http://localhost:$port/admin" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

function Get-Devices { 
    if (-not (Test-Path $devicesPath)) { return @{} }
    $raw = Get-Content $devicesPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return $raw | ConvertFrom-Json 
}
function Save-Devices($devs) { $devs | ConvertTo-Json -Depth 5 | Set-Content $devicesPath -Encoding UTF8 }

function Get-ContentType($file) {
    switch ([System.IO.Path]::GetExtension($file).ToLower()) {
        ".html" { return "text/html" }
        ".css"  { return "text/css" }
        ".js"   { return "application/javascript" }
        ".json" { return "application/json" }
        ".png"  { return "image/png" }
        ".jpg"  { return "image/jpeg" }
        default { return "text/plain" }
    }
}

$Global:LastBuyTime = @{}

while ($listener.IsListening) {
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

    # --- WEB PAGES (Langsung dari folder web) ---
    if ($path -eq "/" -or $path -eq "/index.html") {
        $file = "$webRoot\index.html"
        if (Test-Path $file) { $respJson = [System.IO.File]::ReadAllText($file); $contentType = "text/html" }
    }
    elseif ($path -eq "/admin" -or $path -eq "/admin.html") {
        $file = "$webRoot\admin.html"
        if (Test-Path $file) { $respJson = [System.IO.File]::ReadAllText($file); $contentType = "text/html" }
    }
    # --- ADMIN API ---
    elseif ($path -eq "/api/admin/devices") {
        $respJson = Get-Content $devicesPath -Raw
    }
    elseif ($path -eq "/api/admin/pairing") {
        $respJson = '{"code":"' + $Global:PairingCode + '"}'
    }
    elseif ($path -eq "/api/admin/toggle" -and $req.HttpMethod -eq "POST") {
        $data = $body | ConvertFrom-Json
        $devs = Get-Devices
        if ($devs.PSObject.Properties.Name -contains $data.id) {
            $devs.$($data.id).Status = $data.status
            Save-Devices $devs
        }
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
                $devs | Add-Member -MemberType NoteProperty -Name $devId -Value @{
                    Name = $data.name; Status = "Allowed"; Token = $token
                }
                Save-Devices $devs
                $respJson = '{"status":"ok","token":"' + $token + '"}'
            } else {
                $respJson = '{"status":"error","message":"Kode pairing salah"}'
                $res.StatusCode = 401
            }
        }        elseif ($path -eq "/api/history") {
            if ($isValid) {
                $ticker = $req.QueryString["ticker"]
                if (-not $ticker) { $ticker = "AAPL" }
                $stocks = [System.IO.File]::ReadAllText($stocksPath) | ConvertFrom-Json
                $histData = @()
                foreach ($s in $stocks) {
                    if ($s.Ticker -eq $ticker) {
                        if ($s.History) { $histData = $s.History }
                        break
                    }
                }
                $respJson = @{ ticker = $ticker; history = $histData } | ConvertTo-Json -Depth 5 -Compress
            } else {
                $respJson = '{"status":"error","message":"Unauthorized"}'
                $res.StatusCode = 401
            }
        }        elseif ($path -eq "/api/login_profile" -and $req.HttpMethod -eq "POST") {
            if (-not $isValid) { $respJson = '{"status":"error","message":"Unauthorized"}'; $res.StatusCode = 401 }
            else {
                $data = $body | ConvertFrom-Json
                $profName = $data.profile
                $profilePath = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\profiles\$profName.json"
                if (Test-Path $profilePath) {
                    # Simpan profil ke devices.json
                    $devs = Get-Devices
                    foreach ($d in $devs.PSObject.Properties) {
                        if ($d.Value.Token -eq $auth.Substring(7)) {
                            $d.Value | Add-Member -MemberType NoteProperty -Name "Profile" -Value $profName -Force
                            break
                        }
                    }
                    Save-Devices $devs
                    $respJson = '{"status":"ok","profile":"' + $profName + '"}'
                } else {
                    $respJson = '{"status":"error","message":"Profil tidak ditemukan"}'
                    $res.StatusCode = 404
                }
            }
        }
        elseif ($path -eq "/api/stocks") {
            if ($isValid) { $respJson = [System.IO.File]::ReadAllText($stocksPath) }
            else { $respJson = '{"status":"error","message":"Unauthorized"}'; $res.StatusCode = 401 }
        }
        elseif ($path -eq "/api/buy" -and $req.HttpMethod -eq "POST") {
            if (-not $isValid) { $respJson = '{"status":"error","message":"Unauthorized"}'; $res.StatusCode = 401 }
            else {
                $data = $body | ConvertFrom-Json
                $ticker = $data.ticker
                $qty = [int]$data.qty
                
                $now = [DateTime]::UtcNow
                if ($Global:LastBuyTime.ContainsKey($ticker)) {
                    $diff = ($now - $Global:LastBuyTime[$ticker]).TotalSeconds
                    if ($diff -lt 60) {
                        $respJson = '{"status":"error","message":"Tunggu ' + [Math]::Ceiling(60 - $diff) + ' detik lagi"}'
                        $res.StatusCode = 429
                    }
                }
                
                if ($res.StatusCode -eq 200) {
                    $Global:LastBuyTime[$ticker] = $now
                    $queue = @()
                    if (Test-Path $queuePath) {
                        $rawQ = [System.IO.File]::ReadAllText($queuePath)
                        if (-not [string]::IsNullOrWhiteSpace($rawQ)) { $queue = @($rawQ | ConvertFrom-Json) }
                    }
                    # Ambil profil dari device token
                    $profName = ""
                    foreach ($d in $devs.PSObject.Properties) {
                        if ($d.Value.Token -eq $auth.Substring(7)) {
                            if ($d.Value.PSObject.Properties.Name -contains "Profile") { $profName = $d.Value.Profile }
                            break
                        }
                    }
                    $queue += @{ Action = "BUY"; Ticker = $ticker; Qty = $qty; Profile = $profName; Time = $now.ToString('o') }
                    $queue | ConvertTo-Json -Depth 5 | Set-Content $queuePath -Encoding UTF8
                    
                    $respJson = '{"status":"ok","message":"Perintah beli dikirim"}'
                }
            }
        }
        else {
            $respJson = '{"status":"error","message":"Not Found"}'
            $res.StatusCode = 404
        }
    }

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($respJson)
    $res.ContentType = $contentType
    $res.ContentLength64 = $buffer.Length
    $res.OutputStream.Write($buffer, 0, $buffer.Length)
    $res.Close()
}