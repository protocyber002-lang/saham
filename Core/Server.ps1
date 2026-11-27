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

# Kunci admin untuk melindungi /api/admin/* dari perangkat lain di jaringan
$adminKeyPath = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\admin_key.txt"
$Global:AdminKey = $null
if (Test-Path $adminKeyPath) { $Global:AdminKey = (Get-Content $adminKeyPath -Raw).Trim() }
if ([string]::IsNullOrWhiteSpace($Global:AdminKey)) {
    $Global:AdminKey = [Guid]::NewGuid().ToString("N")
    [System.IO.File]::WriteAllText($adminKeyPath, $Global:AdminKey)
    Write-Host " ADMIN KEY BARU (simpan baik-baik, ada juga di Data\admin_key.txt): $Global:AdminKey" -ForegroundColor Magenta
}

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

function Test-AdminKey($req) {
    $key = $req.Headers["X-Admin-Key"]
    return ($null -ne $key -and $key.Length -gt 0 -and $key -ceq $Global:AdminKey)
}

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
$Global:PairFails = @{}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $req = $context.Request
    $res = $context.Response
    $res.AddHeader("Access-Control-Allow-Origin", "*")
    $res.AddHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Admin-Key")
    
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
    # --- ADMIN API (dilindungi header X-Admin-Key) ---
    elseif ($path -eq "/api/admin/auth" -and $req.HttpMethod -eq "POST") {
        $data = $body | ConvertFrom-Json
        if ($data.key -ceq $Global:AdminKey) {
            $respJson = '{"status":"ok"}'
        } else {
            $respJson = '{"status":"error","message":"Kunci admin salah"}'
            $res.StatusCode = 401
        }
    }
    elseif ($path.StartsWith("/api/admin")) {
        if (-not (Test-AdminKey $req)) {
            $respJson = '{"status":"error","message":"Unauthorized"}'
            $res.StatusCode = 401
        }
        elseif ($path -eq "/api/admin/devices") {
            $devs = Get-Devices
            $sanitized = @()
            foreach ($d in $devs.PSObject.Properties) {
                $prof = ""
                if ($d.Value.PSObject.Properties.Name -contains "Profile") { $prof = $d.Value.Profile }
                $sanitized += @{ id = $d.Name; name = $d.Value.Name; status = $d.Value.Status; profile = $prof }
            }
            $respJson = $sanitized | ConvertTo-Json -Depth 5 -Compress
        }
        elseif ($path -eq "/api/admin/pairing") {
            $respJson = @{ code = $Global:PairingCode } | ConvertTo-Json -Compress
        }
        elseif ($path -eq "/api/admin/regenerate_pairing" -and $req.HttpMethod -eq "POST") {
            $Global:PairingCode = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
            [System.IO.File]::WriteAllText("D:\POWERSHELL\CLICKTYCOONIDLE\Data\pairing.txt", $Global:PairingCode)
            $respJson = @{ status = "ok"; code = $Global:PairingCode } | ConvertTo-Json -Compress
        }
        elseif ($path -eq "/api/admin/toggle" -and $req.HttpMethod -eq "POST") {
            $data = $body | ConvertFrom-Json
            $devs = Get-Devices
            if ($devs.PSObject.Properties.Name -contains $data.id -and ($data.status -eq "Allowed" -or $data.status -eq "Denied")) {
                $devs.$($data.id).Status = $data.status
                Save-Devices $devs
            }
            $respJson = '{"status":"ok"}'
        }
        elseif ($path -eq "/api/admin/remove" -and $req.HttpMethod -eq "POST") {
            $data = $body | ConvertFrom-Json
            $devs = Get-Devices
            if ($devs.PSObject.Properties.Name -contains $data.id) {
                $devs.PSObject.Properties.Remove($data.id)
                Save-Devices $devs
            }
            $respJson = '{"status":"ok"}'
        }
        elseif ($path -eq "/api/admin/profiles") {
            $profDir = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\profiles"
            $list = @()
            if (Test-Path $profDir) {
                foreach ($f in Get-ChildItem $profDir -Filter "*.json") {
                    try {
                        $raw = [System.IO.File]::ReadAllText($f.FullName) -replace "^\uFEFF", ""
                        $d = $raw | ConvertFrom-Json
                        $money = 0
                        $lvl = 1
                        if ($d.Player -and $null -ne $d.Player.Money) { $money = $d.Player.Money }
                        if ($d.Sectors -and $d.Sectors.Clicker -and $d.Sectors.Clicker.Level) { $lvl = $d.Sectors.Clicker.Level }
                        $list += @{ name = $f.BaseName; money = $money; level = $lvl }
                    } catch { }
                }
            }
            $respJson = $list | ConvertTo-Json -Depth 5 -Compress
        }
        elseif ($path -eq "/api/admin/stocks") {
            $out = @()
            if (Test-Path $stocksPath) {
                $stocks = [System.IO.File]::ReadAllText($stocksPath) | ConvertFrom-Json
                foreach ($s in $stocks) {
                    $chg = 0
                    if ($s.History -and $s.History.Count -ge 2) {
                        $prev = $s.History[$s.History.Count - 2].Price
                        if ($prev -ne 0) { $chg = [Math]::Round((($s.Price - $prev) / $prev) * 100, 2) }
                    }
                    $out += @{ ticker = $s.Ticker; name = $s.Name; price = $s.Price; change = $chg }
                }
            }
            $respJson = $out | ConvertTo-Json -Depth 5 -Compress
        }
        elseif ($path -eq "/api/admin/queue") {
            $respJson = "[]"
            if (Test-Path $queuePath) {
                $rawQ = [System.IO.File]::ReadAllText($queuePath)
                if (-not [string]::IsNullOrWhiteSpace($rawQ)) { $respJson = $rawQ }
            }
        }
        else {
            $respJson = '{"status":"error","message":"Not Found"}'
            $res.StatusCode = 404
        }
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
            $ip = $req.RemoteEndPoint.Address.ToString()
            $nowT = [DateTime]::UtcNow
            if ($Global:PairFails.ContainsKey($ip)) {
                $fail = $Global:PairFails[$ip]
                if ($fail.Count -ge 10 -and ($nowT - $fail.Last).TotalSeconds -lt 300) {
                    $respJson = '{"status":"error","message":"Terlalu banyak percobaan. Coba lagi dalam beberapa menit."}'
                    $res.StatusCode = 429
                }
            }
            if ($res.StatusCode -eq 200) {
                if ($data.code -eq $Global:PairingCode) {
                    $Global:PairFails.Remove($ip)
                    $devName = ([string]$data.name) -replace '[\x00-\x1F]', ''
                    $devName = $devName.Trim()
                    if ($devName.Length -gt 40) { $devName = $devName.Substring(0, 40) }
                    if (-not $devName) { $devName = "Perangkat" }
                    $devId = [Guid]::NewGuid().ToString()
                    $token = [Guid]::NewGuid().ToString() + [Guid]::NewGuid().ToString()
                    $devs | Add-Member -MemberType NoteProperty -Name $devId -Value @{
                        Name = $devName; Status = "Allowed"; Token = $token
                    }
                    Save-Devices $devs
                    $respJson = @{ status = "ok"; token = $token } | ConvertTo-Json -Compress
                } else {
                    if ($Global:PairFails.ContainsKey($ip)) {
                        $fail = $Global:PairFails[$ip]
                        if (($nowT - $fail.Last).TotalSeconds -ge 300) { $Global:PairFails[$ip] = @{ Count = 1; Last = $nowT } }
                        else { $Global:PairFails[$ip] = @{ Count = $fail.Count + 1; Last = $nowT } }
                    } else {
                        $Global:PairFails[$ip] = @{ Count = 1; Last = $nowT }
                    }
                    $respJson = '{"status":"error","message":"Kode pairing salah"}'
                    $res.StatusCode = 401
                }
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
                $profName = ([string]$data.profile) -replace '[^\w\-]', ''
                if ($profName.Length -gt 32) { $profName = $profName.Substring(0, 32) }
                $profilePath = "D:\POWERSHELL\CLICKTYCOONIDLE\Data\profiles\$profName.json"
                if (-not $profName) {
                    $respJson = '{"status":"error","message":"Nama profil tidak valid"}'
                    $res.StatusCode = 400
                }
                elseif (Test-Path $profilePath) {
                    # Simpan profil ke devices.json
                    $devs = Get-Devices
                    foreach ($d in $devs.PSObject.Properties) {
                        if ($d.Value.Token -eq $auth.Substring(7)) {
                            $d.Value | Add-Member -MemberType NoteProperty -Name "Profile" -Value $profName -Force
                            break
                        }
                    }
                    Save-Devices $devs
                    $respJson = @{ status = "ok"; profile = $profName } | ConvertTo-Json -Compress
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
                $ticker = [string]$data.ticker
                try { $qty = [int]$data.qty } catch { $qty = 0 }
                if (-not $ticker -or $ticker.Length -gt 10 -or $qty -lt 1 -or $qty -gt 1000) {
                    $respJson = '{"status":"error","message":"Input tidak valid"}'
                    $res.StatusCode = 400
                }
                
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