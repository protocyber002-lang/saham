# MathChallenge.ps1 - soal matematika, reward + buff (Fase 2)
Set-StrictMode -Version 2.0

$Global:MathState = @{
    LastSkipTime = [DateTime]::MinValue
    Active     = $false
    Question   = ""
    Answer     = 0
    Buffer     = ""
    StartedUtc = $null
    TimeoutSec = $Global:Config.MathTimeoutSec
    BuffUntil  = $null
    BuffMult   = 1.0
}

function Math-GenerateQuestion($level) {
    $ops = @('+','-')
    if ($level -ge 2) { $ops += '*' }
    if ($level -ge 3) { $ops += '/' }
    $op = $ops[(Get-Random -Maximum $ops.Count)]

    $a = Get-Random -Minimum 2 -Maximum (10 + $level * 5)
    $b = Get-Random -Minimum 2 -Maximum (10 + $level * 5)

    switch ($op) {
        '+' { $ans = $a + $b; $q = "$a + $b" }
        '-' { if ($b -gt $a) { $t=$a;$a=$b;$b=$t }; $ans = $a - $b; $q = "$a - $b" }
        '*' { $a = Get-Random -Minimum 2 -Maximum (5 + $level * 3)
              $b = Get-Random -Minimum 2 -Maximum (5 + $level * 3)
              $ans = $a * $b; $q = "$a x $b" }
        '/' { $b = Get-Random -Minimum 2 -Maximum (5 + $level)
              $ans = Get-Random -Minimum 2 -Maximum (10 + $level * 3)
              $a = $ans * $b; $q = "$a / $b" }
    }
    return @{ Question = $q; Answer = [int]$ans }
}

function Math-StartChallenge {
    $lvl = 1
    if ($Global:GameState.Flags.ContainsKey('MathLevel')) { $lvl = [int]$Global:GameState.Flags['MathLevel'] }
    $gen = Math-GenerateQuestion $lvl
    $Global:MathState.Active     = $true
    $Global:MathState.Question   = $gen.Question
    $Global:MathState.Answer     = $gen.Answer
    $Global:MathState.Buffer     = ""
    $Global:MathState.StartedUtc = [DateTime]::UtcNow
}

function Math-SubmitAnswer {
    $s = $Global:MathState
    if (-not $s.Active) { return }
    $elapsed = ([DateTime]::UtcNow - $s.StartedUtc).TotalSeconds
    $correct = $false
    if ($s.Buffer -ne "" -and $elapsed -le $s.TimeoutSec) {
        try { if ([int]$s.Buffer -eq $s.Answer) { $correct = $true } } catch {}
    }

    if ($correct) {
        $lvl = 1
        if ($Global:GameState.Flags.ContainsKey('MathLevel')) { $lvl = [int]$Global:GameState.Flags['MathLevel'] }
        $baseReward = 5.0 * [Math]::Pow(1.5, $lvl - 1)

        # --- BONUS FAST ANSWER ---
        $fast = ($elapsed -lt $Global:Config.MathFastBonusSec)
        $mult = 1.0
        if ($fast) { $mult = $Global:Config.MathFastBonusMult }
        $reward = $baseReward * $mult

        $Global:GameState.Player.Money      += $reward
        $Global:GameState.Player.MathSolved += 1
        $Global:MathState.BuffMult  = 1.0 + ($Global:Config.MathBuffPerLevel * $lvl)
        $Global:MathState.BuffUntil = [DateTime]::UtcNow.AddSeconds($Global:Config.MathBuffDurationSec)

        # --- BUFF KLIK MANUAL (MATH) ---
        $Global:GameState.Flags['ClickBuffUntil'] = [DateTime]::UtcNow.AddSeconds($Global:Config.MathClickBuffDurationSec).ToString('o')
        $Global:GameState.Flags['ClickBuffMult']  = $Global:Config.MathClickBuffMult
        
        if (($Global:GameState.Player.MathSolved % 5) -eq 0) {
            $Global:GameState.Flags['MathLevel'] = $lvl + 1
        }

        if ($fast) {
            $Global:GameState.Flags['LastMathMsg'] = ("BENAR! CEPAT ({0:N1}s) +{1:N2} money (BONUS x{2}), buff x{3:N2}" -f $elapsed, $reward, $Global:Config.MathFastBonusMult, $Global:MathState.BuffMult)
        } else {
            $Global:GameState.Flags['LastMathMsg'] = ("BENAR! ({0:N1}s) +{1:N2} money, buff x{2:N2}" -f $elapsed, $reward, $Global:MathState.BuffMult)
        }
    } else {
        $Global:GameState.Flags['LastMathMsg'] = ("SALAH. Jawaban: {0}" -f $s.Answer)
    }
    $Global:MathState.Active = $false
}

function Math-GetBuffMultiplier {
    $s = $Global:MathState
    if ($null -eq $s.BuffUntil) { return 1.0 }
    if ([DateTime]::UtcNow -lt $s.BuffUntil) { return $s.BuffMult }
    return 1.0
}

function Math-CheckTimeout {
    $s = $Global:MathState
    if (-not $s.Active) { return }
    $elapsed = ([DateTime]::UtcNow - $s.StartedUtc).TotalSeconds
    if ($elapsed -gt $s.TimeoutSec) {
        $Global:GameState.Flags['LastMathMsg'] = ("WAKTU HABIS. Jawaban: {0}" -f $s.Answer)
        $s.Active = $false
    }
}

$mathHooks = @{
    OnInput = {
        param($key)
        $s = $Global:MathState

        # 1. Jika soal BELUM aktif, cek apakah tombol M ditekan
        if (-not $s.Active) {
            if ($key.Key -eq 'M') { Math-StartChallenge }
            return
        }

        # 2. Jika soal AKTIF, proses input jawaban
        if ($key.Key -eq 'Escape') {
            $s.Active = $false
            return
        }

        if ($key.Key -eq 'S' -or $key.KeyChar -eq 's' -or $key.KeyChar -eq 'S') {
            # Cegah key-repeat dengan jeda 0.5 detik
            if (([DateTime]::UtcNow - $s.LastSkipTime).TotalMilliseconds -gt 500) {
                $Global:GameState.Flags['LastMathMsg'] = "Soal dilewati."
                Math-StartChallenge
                $s.LastSkipTime = [DateTime]::UtcNow
            }
            return
        }

        if ($key.Key -eq 'Enter') {
            Math-SubmitAnswer
            return
        }

        if ($key.Key -eq 'Backspace') {
            if ($s.Buffer.Length -gt 0) {
                $s.Buffer = $s.Buffer.Substring(0, $s.Buffer.Length - 1)
            }
            return
        }

        $c = $key.KeyChar
        if ($c -ge '0' -and $c -le '9') {
            if ($s.Buffer.Length -lt 7) { $s.Buffer += [string]$c }
        }
        if ($c -eq '-' -and $s.Buffer.Length -eq 0) {
            $s.Buffer = '-'
        }
    }
    
    OnTick = { 
        param($dt) 
        Math-CheckTimeout 
    }
}
Register-Module 'MathChallenge' $mathHooks