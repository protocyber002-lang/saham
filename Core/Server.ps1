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

# Kunci admin untuk melindungi /api/admin/* dari perangkat lain di jaringan
$adminKeyPath = Join-Path $root "Data\admin_key.txt"
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

function Read-FileSafe {
    param([string]$Path, [int]$Retries = 3, [int]$DelayMs = 50)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path) } else { return $null }
        } catch { Start-Sleep -Milliseconds $DelayMs }
    }
    return $null
}

$Global:PairFails = @{}

while ($listener.IsListening) {
    try {
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

        # --- WEB PAGES ---
        if ($path -eq "/" -or $path -eq "/index.html") {
            $file = Join-Path $webRoot "index.html"
            if (Test-Path $file) { $respJson = [System.IO.File]::ReadAllText($file); $contentType = "text/html" }
        }
        elseif ($path -eq "/admin" -or $path -eq "/admin.html") {
            $file = Join-Path $webRoot "admin.html"
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
                [System.IO.File]::WriteAllText((Join-Path $root "Data\pairing.txt"), $Global:PairingCode)
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
                $profDir = Join-Path $root "Data\profiles"
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
                    $stocks = Read-FileSafe $stocksPath | ConvertFrom-Json
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
                $rawQ = Read-FileSafe $queuePath
                if (-not [string]::IsNullOrWhiteSpace($rawQ)) { $respJson = $rawQ }
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
                        $devs | Add-Member -MemberType NoteProperty -Name $devId -Value @{ Name = $devName; Status = "Allowed"; Token = $token }
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
                    $profName = ([string]$data.profile) -replace '[^\w\- ]', ''
                    $profName = $profName.Trim()
                    if ($profName.Length -gt 32) { $profName = $profName.Substring(0, 32) }
                    $profilesDir = Join-Path $root "Data\profiles"
                    $profilePath = Join-Path $profilesDir ($profName + ".json")

                    if (-not [string]::IsNullOrWhiteSpace($profName) -and -not (Test-Path $profilePath)) {
                        $found = Get-ChildItem -Path $profilesDir -Filter "*.json" | Where-Object { $_.BaseName -ieq $profName } | Select-Object -First 1
                        if ($found) { $profName = $found.BaseName; $profilePath = $found.FullName }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($profName) -and (Test-Path $profilePath)) {
                        foreach ($d in $devs.PSObject.Properties) {
                            if ($d.Value.Token -eq $auth.Substring(7)) { $d.Value | Add-Member -MemberType NoteProperty -Name "Profile" -Value $profName -Force; break }
                        }
                        Save-Devices $devs
                        $respJson = @{ status = "ok"; profile = $profName } | ConvertTo-Json -Compress
                    } else {
                        $respJson = @{ status = "error"; message = "Profil tidak ditemukan" } | ConvertTo-Json -Compress
                        $res.StatusCode = 404
                    }
                }
            }
            elseif ($path -eq "/api/logout" -and $req.HttpMethod -eq "POST") {
                if ($isValid) {
                    $token = $auth.Substring(7); $newDevs = @{}
                    foreach ($d in $devs.PSObject.Properties) { if ($d.Value.Token -ne $token) { $newDevs[$d.Name] = $d.Value } }
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
                    $ticker = [string]$data.ticker
                    try { $qty = [int]$data.qty } catch { $qty = 0 }
                    
                    if (-not $ticker -or $ticker.Length -gt 10 -or $qty -lt 1 -or $qty -gt 1000) {
                        $respJson = '{"status":"error","message":"Input tidak valid"}'
                        $res.StatusCode = 400
                    } else {
                        $queue = @()
                        if (Test-Path $queuePath) {
                            $rawQ = Read-FileSafe $queuePath
                            if (-not [string]::IsNullOrWhiteSpace($rawQ)) { $queue = @($rawQ | ConvertFrom-Json) }
                        }
                        
                        $profName = ""
                        foreach ($d in $devs.PSObject.Properties) {
                            if ($d.Value.Token -eq $auth.Substring(7)) { if ($d.Value.PSObject.Properties.Name -contains "Profile") { $profName = $d.Value.Profile }; break }
                        }
                        
                        $queue += @{ Id = [Guid]::NewGuid().ToString("N"); Action = "BUY"; Ticker = $ticker; Qty = $qty; Profile = $profName; Time = [DateTime]::UtcNow.ToString('o') }
                        ConvertTo-Json -InputObject @($queue) -Depth 5 -Compress | Set-Content $queuePath -Encoding UTF8
                        
                        Write-Host ("[LOG BELI] Profil '{0}' membeli {1} lembar {2}" -f $profName, $qty, $ticker) -ForegroundColor Green
                        $respJson = '{"status":"ok","message":"Perintah beli dikirim"}'
                    }
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
