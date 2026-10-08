#Requires -Version 5.1
<#
.SYNOPSIS
    Індикатор стану rclone-монтування в системному треї.

.DESCRIPTION
    Кольорова іконка в треї + контекстне меню керування монтуванням.

      Сірий кільцем     - не змонтовано
      Сірий заповнений  - підключення (процес стартує)
      Зелений           - підключено, простій
      Синій  ↓          - читання з сервера
      Помаранчевий ↑    - є невідвантажені зміни / іде відвантаження (пульсує)
      Червоний !        - помилка

    Стан береться з rclone remote control (vfs/stats + core/stats), який
    слухає лише 127.0.0.1. Опитування йде у фоновому runspace, тому завислий
    rclone чи мертвий WinFsp-том не морозять інтерфейс.

.PARAMETER ProfileName
    Ім'я профілю (= ім'я remote). За замовчуванням 'synology'.

.PARAMETER Install
    Встановити індикатор для наявного монтування: увімкнути rc у лаунчері
    (якщо вимкнено), зареєструвати автозапуск при вході, запустити.
    Пароль повторно не потрібен.

.PARAMETER Uninstall
    Зняти автозапуск і зупинити індикатор. Монтування не чіпає.

.PARAMETER NoPause
    Не чекати Enter наприкінці -Install / -Uninstall (для виклику з інсталятора).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\RcloneTray.ps1 -Install

.NOTES
    Файл має бути збережений у UTF-8 з BOM.
#>

[CmdletBinding()]
param(
    [string] $ProfileName = 'synology',
    [switch] $Install,
    [switch] $Uninstall,
    [switch] $NoPause
)

$InstallRoot = 'C:\rclone'
$StateFile   = Join-Path $InstallRoot "$ProfileName.state.json"
$TrayTask    = "rclone-$ProfileName-tray"
$TrayVbs     = Join-Path $InstallRoot "$ProfileName.tray.vbs"
$TrayDst     = Join-Path $InstallRoot 'RcloneTray.ps1'

# ===========================================================================
# Спільні хелпери
# ===========================================================================
function Read-LaunchCmd {
    # Витягує командний рядок rclone з VBS-лаунчера: sh.Run "<cmd>", 0, False
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding Default
    if ($raw -match '(?m)^sh\.Run\s+"(.*)",\s*0,\s*False\s*$') { return ($Matches[1] -replace '""','"') }
    return $null
}

function Write-LaunchVbs {
    # wscript читає .vbs як ANSI: UTF-8 з BOM дасть "Invalid character"
    param([string]$Path, [string]$CmdLine, [string]$Note)
    $esc = $CmdLine -replace '"','""'
    $body = @"
' $Note
' intWindowStyle = 0     -> no window
' bWaitOnReturn  = False -> wscript exits at once, child keeps running detached
Set sh = CreateObject("WScript.Shell")
sh.Run "$esc", 0, False
"@
    Set-Content -LiteralPath $Path -Value $body -Encoding Default
}

function Stop-TrayInstances {
    # Зупиняє запущені індикатори цього профілю, але не поточний процес
    # і не процеси -Install/-Uninstall.
    param([string]$Profile)
    $rx = '-ProfileName\s+"?' + [regex]::Escape($Profile) + '"?(\s|$)'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and
            $_.CommandLine -like '*RcloneTray.ps1*' -and
            $_.CommandLine -match $rx -and
            $_.CommandLine -notmatch '-(Install|Uninstall)\b'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# РЕЖИМ ВСТАНОВЛЕННЯ / ВИДАЛЕННЯ (елевований, консольний)
# ===========================================================================
if ($Install -or $Uninstall) {
    $ErrorActionPreference = 'Stop'
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

    function Write-Ok    { param($m) Write-Host "[ok] $m" -ForegroundColor Green }
    function Write-Err   { param($m) Write-Host "[XX] $m" -ForegroundColor Red }
    function Write-Info  { param($m) Write-Host "     $m" -ForegroundColor Gray }
    function Write-Warn2 { param($m) Write-Host "[!!] $m" -ForegroundColor Yellow }
    function Read-YesNo {
        param([string]$Prompt, [bool]$Default = $true)
        if ($Default) { $hint = 'Y/n' } else { $hint = 'y/N' }
        while ($true) {
            $t = Read-Host "$Prompt [$hint]"
            if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
            switch -Regex ($t.Trim()) {
                '^(y|yes|т|так)$' { return $true }
                '^(n|no|н|ні)$'   { return $false }
            }
        }
    }
    function Exit-Install { param([int]$Code = 0) if (-not $NoPause) { Read-Host "`nEnter для виходу" | Out-Null }; exit $Code }

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
              [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warn2 'Потрібні права адміністратора. Перезапуск через UAC...'
        $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-ProfileName',$ProfileName)
        if ($Install)   { $a += '-Install' }
        if ($Uninstall) { $a += '-Uninstall' }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $a
        exit
    }

    # ---------------------------- UNINSTALL ----------------------------------
    if ($Uninstall) {
        Write-Host "`n[==] Видалення індикатора '$ProfileName'" -ForegroundColor Cyan
        if (Get-ScheduledTask -TaskName $TrayTask -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TrayTask -Confirm:$false
            Write-Ok "Знято завдання: $TrayTask"
        }
        Stop-TrayInstances -Profile $ProfileName
        Write-Ok 'Індикатор зупинено'
        if (Test-Path $TrayVbs) { Remove-Item $TrayVbs -Force; Write-Ok "Видалено: $TrayVbs" }
        Write-Info 'Монтування і rc не змінювались.'
        Exit-Install 0
    }

    # ----------------------------- INSTALL -----------------------------------
    Write-Host "`n[==] Встановлення індикатора '$ProfileName'" -ForegroundColor Cyan

    if (-not (Test-Path $StateFile)) {
        Write-Err "Не знайдено $StateFile"
        Write-Info 'Спершу виконайте Install-RcloneMount.ps1.'
        Exit-Install 1
    }
    $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

    $launchVbs = $state.LaunchVbs
    if (-not $launchVbs) { $launchVbs = Join-Path $InstallRoot "$ProfileName.launch.vbs" }
    $cmd = Read-LaunchCmd -Path $launchVbs
    if (-not $cmd) { Write-Err "Не вдалося прочитати лаунчер: $launchVbs"; Exit-Install 1 }

    # --- rc: індикатор без нього бачить лише "є диск / нема диска" -----------
    $patched = $false
    if ($cmd -match '(^|\s)--rc(\s|$)') {
        if ($cmd -match '--rc-addr\s+"?([^\s"]+)') { $rcAddr = $Matches[1] }
        else { $rcAddr = '127.0.0.1:5572' }          # дефолт rclone
        Write-Ok "rc вже увімкнено: $rcAddr"
    } else {
        # 5572 — дефолт rclone; його часто тримає Rclone UI. Зайнятий порт
        # = фатальна помилка старту монтування, тому шукаємо вільний.
        $port = $null
        foreach ($p in 5582..5631) {
            try {
                $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
                $l.Start(); $l.Stop(); $port = $p; break
            } catch { }
        }
        if (-not $port) { Write-Err 'Не знайдено вільного порту 5582..5631.'; Exit-Install 1 }
        $rcAddr = "127.0.0.1:$port"
        # rc слухає лише loopback, тож --rc-no-auth безпечний
        $cmd = "$cmd --rc --rc-addr $rcAddr --rc-no-auth"
        Write-LaunchVbs -Path $launchVbs -CmdLine $cmd `
            -Note "Hidden launcher for rclone mount. Profile: $ProfileName. rc added by RcloneTray.ps1"
        $patched = $true
        Write-Ok "rc додано в лаунчер: $rcAddr"
    }

    # --- state.json ----------------------------------------------------------
    $state | Add-Member -NotePropertyName RcAddr   -NotePropertyValue $rcAddr   -Force
    $state | Add-Member -NotePropertyName TrayTask -NotePropertyValue $TrayTask -Force
    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

    # --- копіювання скриптів у C:\rclone -------------------------------------
    if ($PSCommandPath -ne $TrayDst) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $TrayDst -Force
        Write-Ok "Скопійовано: $TrayDst"
    }
    $modeSrc = Join-Path $PSScriptRoot 'Set-RcloneMountMode.ps1'
    $modeDst = Join-Path $InstallRoot  'Set-RcloneMountMode.ps1'
    if ((Test-Path $modeSrc) -and ($modeSrc -ne $modeDst)) {
        Copy-Item -LiteralPath $modeSrc -Destination $modeDst -Force
        Write-Ok "Скопійовано: $modeDst  (перемикання режиму з меню)"
    }

    # --- лаунчер індикатора --------------------------------------------------
    $trayCmd = "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass " +
               "-File `"$TrayDst`" -ProfileName `"$ProfileName`""
    Write-LaunchVbs -Path $TrayVbs -CmdLine $trayCmd -Note "Hidden launcher for RcloneTray. Profile: $ProfileName"
    Write-Ok "Лаунчер: $TrayVbs"

    # --- завдання автозапуску ------------------------------------------------
    $user = $state.TargetUser
    if (-not $user) { $user = "$env:USERDOMAIN\$env:USERNAME" }

    if (Get-ScheduledTask -TaskName $TrayTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TrayTask -Confirm:$false
    }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -MultipleInstances IgnoreNew
    $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$TrayVbs`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    Register-ScheduledTask -TaskName $TrayTask -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    $t = Get-ScheduledTask -TaskName $TrayTask
    $t.Triggers[0].Delay = 'PT10S'
    Set-ScheduledTask -InputObject $t | Out-Null
    Write-Ok "$TrayTask  (при вході, затримка 10s)"

    # --- перезапуск rclone, якщо rc щойно додано -----------------------------
    if ($patched) {
        $rc = $state.RclonePath
        $running = @(Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $rc })
        if ($running.Count -gt 0) {
            Write-Warn2 "rc почне працювати лише після перезапуску rclone: диск $($state.Drive) зникне на кілька секунд."
            Write-Info  'Закрийте відкриті файли на цьому диску. Незалиті зміни лишаються в кеші'
            Write-Info  'і будуть відвантажені після перезапуску.'
            if (Read-YesNo 'Перезапустити rclone зараз?' $true) {
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep 3
                Start-ScheduledTask -TaskName $state.TaskMount
                Write-Ok 'rclone перезапущено'
            } else {
                Write-Info 'Застосується при наступному вході. До того індикатор покаже лише наявність диска.'
            }
        }
    }

    # --- запуск індикатора в сесії користувача -------------------------------
    Stop-TrayInstances -Profile $ProfileName
    Start-ScheduledTask -TaskName $TrayTask
    Write-Ok 'Індикатор запущено — шукайте іконку в треї (можливо, під стрілкою ^).'
    Write-Info 'Щоб іконка була видима завжди: Параметри → Персоналізація → Панель завдань →'
    Write-Info 'Інші піктограми в області сповіщень → увімкнути PowerShell / RcloneTray.'
    Exit-Install 0
}

# ===========================================================================
# РЕЖИМ ІНДИКАТОРА (запускається прихованим, у сесії користувача)
# ===========================================================================
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace RcTray -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@

# Без DPI-awareness на масштабованому екрані SmallIconSize повертає 16
# і Windows розтягує іконку — вона розмита.
[void][RcTray.Native]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

$TrayLog = Join-Path $InstallRoot "logs\$ProfileName.tray.log"
function Write-TrayLog {
    param([string]$m)
    try { "$(Get-Date -f s)  $m" | Add-Content -LiteralPath $TrayLog -Encoding UTF8 } catch { }
}

# --- один екземпляр на профіль ----------------------------------------------
$created = $false
# ::new, а не New-Object: New-Object не передає [ref]-аргументи коректно
$mutex = [Threading.Mutex]::new($true, "Local\RcloneTray-$ProfileName", [ref]$created)
if (-not $created) { exit }

# --- конфігурація -----------------------------------------------------------
if (-not (Test-Path $StateFile)) {
    [Windows.Forms.MessageBox]::Show("Не знайдено $StateFile.`nСпершу виконайте Install-RcloneMount.ps1.",
        'RcloneTray', 'OK', 'Error') | Out-Null
    exit 1
}
$state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

$launchVbs = $state.LaunchVbs
if (-not $launchVbs) { $launchVbs = Join-Path $InstallRoot "$ProfileName.launch.vbs" }

$rcAddr = $state.RcAddr
if (-not $rcAddr) {
    $c = Read-LaunchCmd -Path $launchVbs
    if ($c -and $c -match '(^|\s)--rc(\s|$)') {
        if ($c -match '--rc-addr\s+"?([^\s"]+)') { $rcAddr = $Matches[1] } else { $rcAddr = '127.0.0.1:5572' }
    }
}

$drive = ([string]$state.Drive).TrimEnd('\').TrimEnd(':') + ':'
$cfg = @{
    Drive      = $drive
    RclonePath = [string]$state.RclonePath
    RcAddr     = $rcAddr
}

$modeScript = Join-Path $InstallRoot 'Set-RcloneMountMode.ps1'
$logFile    = [string]$state.LogFile

# --- налаштування сповіщень (HKCU, per-profile) -----------------------------
$regPath = "HKCU:\Software\RcloneTray\$ProfileName"
function Get-Setting {
    param([string]$Name, [bool]$Default)
    try { return [bool](Get-ItemProperty -Path $regPath -Name $Name -ErrorAction Stop).$Name } catch { return $Default }
}
function Set-Setting {
    param([string]$Name, [bool]$Value)
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name $Name -Value ([int]$Value) -Type DWord
}

# --- rc-запит (POST, без проксі, з жорстким таймаутом) ----------------------
# Invoke-RestMethod у PS 5.1 ходить через системний проксі: localhost може
# піти на корпоративний проксі і зависнути. HttpWebRequest з Proxy=$null — ні.
$rcFunc = @'
function Invoke-Rc {
    param([string]$Addr, [string]$Path, [string]$Body = '{}', [int]$TimeoutMs = 1500)
    $req = [Net.HttpWebRequest]::Create("http://$Addr/$Path")
    $req.Method = 'POST'; $req.ContentType = 'application/json'
    $req.Proxy = $null; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $req.ContentLength = $bytes.Length
    $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    $resp = $req.GetResponse()
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd(); $sr.Close()
    } finally { $resp.Close() }
    if ($txt) { return ($txt | ConvertFrom-Json) }
}
'@
. ([scriptblock]::Create($rcFunc))

# ===========================================================================
# Іконки: малюються в рантаймі під реальний розмір іконки трею
# ===========================================================================
function New-StateIcon {
    param([Drawing.Color]$Color, [string]$Glyph = '', [switch]$Hollow)

    $s = [Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($s -lt 16) { $s = 16 }
    $u = $s / 16.0

    function RF { param($x,$y,$w,$h) New-Object Drawing.RectangleF ([single]($x*$u)),([single]($y*$u)),([single]($w*$u)),([single]($h*$u)) }
    function PF { param($x,$y) New-Object Drawing.PointF ([single]($x*$u)),([single]($y*$u)) }

    $bmp = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)

    if ($Hollow) {
        # Кільце = "нічого не підключено"
        $pen = New-Object Drawing.Pen($Color, [single](2.2*$u))
        $g.DrawEllipse($pen, (RF 1.9 1.9 12.2 12.2))
        $pen.Dispose()
    } else {
        $br = New-Object Drawing.SolidBrush($Color)
        $g.FillEllipse($br, (RF 0.75 0.75 14.5 14.5))
        $br.Dispose()
        # Тонкий темний обвід: контраст на світлій панелі завдань
        $edge = New-Object Drawing.Pen([Drawing.Color]::FromArgb(80,0,0,0), [single][Math]::Max(1.0,$u))
        $g.DrawEllipse($edge, (RF 0.75 0.75 14.5 14.5))
        $edge.Dispose()
    }

    # Гліфи дублюють колір формою — розрізнення при дальтонізмі
    $w = [Drawing.Brushes]::White
    switch ($Glyph) {
        'down' {
            $g.FillRectangle($w, (RF 6.6 3.2 2.8 5.4))
            $g.FillPolygon($w, [Drawing.PointF[]]@((PF 3.5 8.0), (PF 12.5 8.0), (PF 8.0 12.7)))
        }
        'up' {
            $g.FillPolygon($w, [Drawing.PointF[]]@((PF 8.0 3.3), (PF 3.5 8.0), (PF 12.5 8.0)))
            $g.FillRectangle($w, (RF 6.6 7.6 2.8 5.2))
        }
        'bang' {
            $g.FillRectangle($w, (RF 6.9 3.0 2.2 6.6))
            $g.FillEllipse($w,   (RF 6.8 10.4 2.4 2.4))
        }
    }
    $g.Dispose()

    # Icon.FromHandle не володіє хендлом: клонуємо і звільняємо оригінал
    $h = $bmp.GetHicon()
    $ico = ([Drawing.Icon]::FromHandle($h)).Clone()
    [void][RcTray.Native]::DestroyIcon($h)
    $bmp.Dispose()
    return $ico
}

$cGray   = [Drawing.Color]::FromArgb(138,143,152)
$cGreen  = [Drawing.Color]::FromArgb( 46,160, 67)
$cBlue   = [Drawing.Color]::FromArgb( 47,129,247)
$cOrange = [Drawing.Color]::FromArgb(227,131, 11)
$cOrLite = [Drawing.Color]::FromArgb(246,178, 82)
$cRed    = [Drawing.Color]::FromArgb(218, 54, 51)

$icons = @{
    off      = New-StateIcon -Color $cGray -Hollow
    starting = New-StateIcon -Color $cGray
    idle     = New-StateIcon -Color $cGreen
    read     = New-StateIcon -Color $cBlue   -Glyph 'down'
    writeA   = New-StateIcon -Color $cOrange -Glyph 'up'
    writeB   = New-StateIcon -Color $cOrLite -Glyph 'up'
    error    = New-StateIcon -Color $cRed    -Glyph 'bang'
}

# ===========================================================================
# Фоновий опитувач
# ---------------------------------------------------------------------------
# Окремий runspace: Get-Process і HTTP-запити не блокують UI-потік, навіть
# якщо rclone завис. UI лише читає синхронізовану хеш-таблицю.
# ===========================================================================
$sync = [hashtable]::Synchronized(@{
    Stop = $false; State = 'off'; Detail = 'Запуск…'; Rate = 0.0
    Pending = 0; Hard = $false; BatchSeq = 0
})

$worker = $rcFunc + @'

$prevBytes = -1.0; $prevT = [datetime]::UtcNow; $prevErr = -1
$rcFail = 0; $errUntil = [datetime]::MinValue; $lastErr = ''
$inBatch = $false; $calm = 0; $prevPend = 0
$root = $cfg.Drive + '\'

while (-not $sync.Stop) {
    $now = [datetime]::UtcNow
    $st = 'off'; $detail = 'Не змонтовано'; $rate = 0.0; $pend = 0; $hard = $false; $alive = $false
    try {
        $procs = @(Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $cfg.RclonePath })
        $alive = $procs.Count -gt 0
        # GetLogicalDrives - лише бітова маска, том не чіпає, не зависає
        $mapped = [Environment]::GetLogicalDrives() -contains $root

        if ($alive) {
            $age = 999.0
            try { $age = ((Get-Date) - $procs[0].StartTime).TotalSeconds } catch { }

            $vfs = $null; $core = $null
            if ($cfg.RcAddr) {
                try {
                    $vfs  = Invoke-Rc -Addr $cfg.RcAddr -Path 'vfs/stats'
                    $core = Invoke-Rc -Addr $cfg.RcAddr -Path 'core/stats'
                    $rcFail = 0
                } catch { $rcFail++ }
            }

            $errFiles = 0
            if ($vfs -and $vfs.diskCache) {
                $pend = [int]$vfs.diskCache.uploadsInProgress + [int]$vfs.diskCache.uploadsQueued
                if ($vfs.diskCache.erroredFiles) { $errFiles = [int]$vfs.diskCache.erroredFiles }
            }
            if ($core) {
                $b  = [double]$core.bytes
                $dt = ($now - $prevT).TotalSeconds
                if ($prevBytes -ge 0 -and $b -ge $prevBytes -and $dt -gt 0) { $rate = ($b - $prevBytes) / $dt }
                $prevBytes = $b; $prevT = $now
                $e = [int]$core.errors
                if ($prevErr -ge 0 -and $e -gt $prevErr) {
                    $errUntil = $now.AddSeconds(20)
                    $lastErr  = [string]$core.lastError
                }
                $prevErr = $e
            }

            if ($cfg.RcAddr -and $rcFail -ge 3 -and $age -gt 20) {
                $st = 'error'; $hard = $true; $detail = 'rclone не відповідає на запити'
            } elseif (-not $mapped) {
                if ($age -lt 30) { $st = 'starting'; $detail = 'Підключення…' }
                else { $st = 'error'; $hard = $true; $detail = "Процес працює, але диска $($cfg.Drive) немає" }
            } elseif ($errFiles -gt 0) {
                $st = 'error'; $hard = $true; $detail = "Не вдалося відвантажити файлів: $errFiles"
            } elseif ($now -lt $errUntil) {
                $st = 'error'; $detail = $(if ($lastErr) { $lastErr } else { 'Помилка передачі' })
            } elseif ($pend -gt 0) {
                $st = 'write'; $detail = 'Відвантаження на сервер'
            } elseif ($rate -gt 2048 -and $prevPend -eq 0) {
                # core/stats.bytes рахує і вивантаження: у першому опитуванні після
                # спорожніння черги дельта - це хвіст upload, а не читання
                $st = 'read'; $detail = 'Читання з сервера'
            } else {
                $st = 'idle'
                if ($cfg.RcAddr) { $detail = 'Підключено' } else { $detail = 'Підключено (rc вимкнено — лише статус диска)' }
            }
        } else {
            $prevBytes = -1.0; $prevErr = -1; $rcFail = 0
        }

        # Пакет відвантаження завершено: 2 поспіль опитування без черги.
        # Дебаунс потрібен, бо між файлами черга може на мить спорожніти.
        if ($pend -gt 0) { $inBatch = $true; $calm = 0 }
        elseif ($inBatch) {
            $calm++
            if ($calm -ge 2) {
                $inBatch = $false; $calm = 0
                if ($alive -and $st -ne 'error') { $sync.BatchSeq = $sync.BatchSeq + 1 }
            }
        }
    } catch {
        $st = 'error'; $detail = $_.Exception.Message
    }

    $prevPend = $pend
    $sync.State = $st; $sync.Detail = $detail; $sync.Rate = $rate
    $sync.Pending = $pend; $sync.Hard = $hard
    Start-Sleep -Milliseconds 1000
}
'@

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$rs.SessionStateProxy.SetVariable('cfg',  $cfg)
$bg = [powershell]::Create()
$bg.Runspace = $rs
[void]$bg.AddScript($worker)
[void]$bg.BeginInvoke()

# ===========================================================================
# UI
# ===========================================================================
function Format-Rate {
    param([double]$r)
    if ($r -ge 1MB) { return ('{0:N1} МБ/с' -f ($r / 1MB)) }
    if ($r -ge 1KB) { return ('{0:N0} КБ/с' -f ($r / 1KB)) }
    return ''
}

function Get-StatusText {
    $st = $sync.State; $rate = Format-Rate $sync.Rate
    switch ($st) {
        'off'      { 'не змонтовано' }
        'starting' { 'підключення…' }
        'idle'     { 'підключено' }
        'read'     { ('читання ' + $rate).Trim() }
        'write'    { ("запис: $($sync.Pending) ф. " + $rate).Trim() }
        'error'    { 'помилка: ' + $sync.Detail }
        default    { $st }
    }
}

function Get-RcloneProcs {
    @(Get-Process rclone -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $cfg.RclonePath })
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    $ni.ShowBalloonTip(6000, $Title, $Text, [Windows.Forms.ToolTipIcon]::$Kind)
}

function Invoke-Safe {
    param([scriptblock]$Action)
    try { & $Action } catch {
        Write-TrayLog "ERROR: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RcloneTray', 'OK', 'Error') | Out-Null
    }
}

$ni = New-Object Windows.Forms.NotifyIcon
$ni.Icon = $icons.off
$ni.Text = "$ProfileName $drive"
$ni.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip

$miHeader = New-Object Windows.Forms.ToolStripMenuItem("$ProfileName  →  $drive")
$miHeader.Enabled = $false
$miHeader.Font = New-Object Drawing.Font($miHeader.Font, [Drawing.FontStyle]::Bold)
$miStatus = New-Object Windows.Forms.ToolStripMenuItem('Стан: …')
$miStatus.Enabled = $false

$miOpen    = New-Object Windows.Forms.ToolStripMenuItem("Відкрити $drive")
$miOpen.Font = New-Object Drawing.Font($miOpen.Font, [Drawing.FontStyle]::Bold)
$miRefresh = New-Object Windows.Forms.ToolStripMenuItem('Оновити вміст (скинути кеш тек)')
$miMount   = New-Object Windows.Forms.ToolStripMenuItem('Змонтувати')
$miUnmount = New-Object Windows.Forms.ToolStripMenuItem('Розмонтувати')
$miRestart = New-Object Windows.Forms.ToolStripMenuItem('Перезапустити')

$miMode = New-Object Windows.Forms.ToolStripMenuItem('Режим кешування')
$modeItems = @{}
foreach ($m in @(
    @{ Key = 'FAST';     Text = 'FAST — швидко, бачить чужі зміни (рекомендовано)' }
    @{ Key = 'STRICT';   Text = 'STRICT — чужі зміни за секунди, повільніше' }
    @{ Key = 'RAIDRIVE'; Text = 'RAIDRIVE — без кешу читання, найповільніше' }
)) {
    $it = New-Object Windows.Forms.ToolStripMenuItem($m.Text)
    $it.Tag = $m.Key
    [void]$miMode.DropDownItems.Add($it)
    $modeItems[$m.Key] = $it
}

$miNotifyUp  = New-Object Windows.Forms.ToolStripMenuItem('Сповіщати про завершення відвантаження')
$miNotifyUp.CheckOnClick = $true
$miNotifyUp.Checked = Get-Setting 'NotifyUpload' $true
$miNotifyErr = New-Object Windows.Forms.ToolStripMenuItem('Сповіщати про помилки й відключення')
$miNotifyErr.CheckOnClick = $true
$miNotifyErr.Checked = Get-Setting 'NotifyError' $true

$miLog  = New-Object Windows.Forms.ToolStripMenuItem('Відкрити лог')
$miExit = New-Object Windows.Forms.ToolStripMenuItem('Закрити індикатор (диск лишиться)')

[void]$menu.Items.AddRange(@(
    $miHeader, $miStatus,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miOpen, $miRefresh,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miMount, $miUnmount, $miRestart,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miMode, $miNotifyUp, $miNotifyErr, $miLog,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miExit
))
$ni.ContextMenuStrip = $menu

# --- дії --------------------------------------------------------------------
$script:userStop = $false

function Start-Mount {
    $script:userStop = $false
    # Лаунчер напряму, а не Start-ScheduledTask: те саме, але не залежить
    # від прав звичайного користувача на завдання, створене адміном.
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$launchVbs`""
}

function Stop-Mount {
    param([switch]$Quiet)
    $pend = [int]$sync.Pending
    if ($pend -gt 0 -and -not $Quiet) {
        $r = [Windows.Forms.MessageBox]::Show(
            "Ще не відвантажено файлів: $pend.`n`nВони лишаться в локальному кеші й будуть відвантажені " +
            "при наступному монтуванні, але до того колеги їх не побачать.`n`nРозмонтувати зараз?",
            'RcloneTray', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return $false }
    }
    $script:userStop = $true
    Get-RcloneProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    return $true
}

$ni.add_DoubleClick({ Invoke-Safe { if ($sync.State -ne 'off') { Start-Process explorer.exe "$drive\" } } })
$miOpen.add_Click({ Invoke-Safe { Start-Process explorer.exe "$drive\" } })

$miRefresh.add_Click({
    Invoke-Safe {
        if (-not $cfg.RcAddr) { throw 'rc вимкнено. Виконайте RcloneTray.ps1 -Install, щоб увімкнути.' }
        [void](Invoke-Rc -Addr $cfg.RcAddr -Path 'vfs/forget' -TimeoutMs 5000)
        Show-Balloon 'Кеш тек скинуто' "Наступне відкриття тек на $drive покаже актуальний стан сервера."
    }
})

$miMount.add_Click({ Invoke-Safe { Start-Mount } })
$miUnmount.add_Click({ Invoke-Safe { [void](Stop-Mount) } })
$miRestart.add_Click({
    Invoke-Safe {
        if (Stop-Mount) { Start-Sleep -Seconds 2; Start-Mount }
    }
})

foreach ($it in $modeItems.Values) {
    $it.add_Click({
        param($s, $e)
        Invoke-Safe {
            if (-not (Test-Path $modeScript)) { throw "Не знайдено $modeScript" }
            $pend = [int]$sync.Pending
            if ($pend -gt 0) {
                $r = [Windows.Forms.MessageBox]::Show(
                    "Зміна режиму перезапускає rclone, а ще не відвантажено файлів: $pend.`nПродовжити?",
                    'RcloneTray', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return }
            }
            $script:userStop = $true
            # Set-RcloneMountMode сам підніметься через UAC
            Start-Process powershell.exe -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$modeScript`"",
                '-Mode', $s.Tag, '-ProfileName', $ProfileName)
        }
    })
}

$miNotifyUp.add_CheckedChanged({  Set-Setting 'NotifyUpload' $miNotifyUp.Checked })
$miNotifyErr.add_CheckedChanged({ Set-Setting 'NotifyError'  $miNotifyErr.Checked })

$miLog.add_Click({
    Invoke-Safe {
        if (-not $logFile -or -not (Test-Path -LiteralPath $logFile)) { throw "Лог не знайдено: $logFile" }
        $cmdTail = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$Host.UI.RawUI.WindowTitle='rclone log: $ProfileName'; " +
                   "Get-Content -LiteralPath '$logFile' -Tail 60 -Wait -Encoding UTF8"
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-NoExit','-Command', $cmdTail)
    }
})

$miExit.add_Click({
    $timer.Stop()
    $sync.Stop = $true
    $ni.Visible = $false
    [Windows.Forms.Application]::Exit()
})

# Актуалізація меню при відкритті
$menu.add_Opening({
    $st = $sync.State
    $miStatus.Text = 'Стан: ' + (Get-StatusText)
    $mounted = ($st -ne 'off')
    $miOpen.Enabled    = $mounted -and $st -ne 'starting'
    $miRefresh.Enabled = $mounted -and [bool]$cfg.RcAddr
    $miMount.Enabled   = -not $mounted
    $miUnmount.Enabled = $mounted
    $miRestart.Enabled = $mounted

    $cur = $null
    try { $cur = (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).Mode } catch { }
    if ($cur -eq 'SHARED') { $cur = 'FAST' }       # профіль інсталятора = FAST
    foreach ($k in $modeItems.Keys) { $modeItems[$k].Checked = ($k -eq $cur) }
    $miMode.Enabled = Test-Path $modeScript
})

# --- цикл оновлення іконки --------------------------------------------------
$script:prevState = 'off'
$script:lastBatch = $sync.BatchSeq
$script:pulse     = $false
$script:curIcon   = 'off'

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    try {
        $st = $sync.State

        # Іконка (запис пульсує двома відтінками)
        if ($st -eq 'write') {
            $script:pulse = -not $script:pulse
            if ($script:pulse) { $key = 'writeA' } else { $key = 'writeB' }
        } else { $key = $st }
        if (-not $icons.ContainsKey($key)) { $key = 'error' }
        if ($key -ne $script:curIcon) { $ni.Icon = $icons[$key]; $script:curIcon = $key }

        # Підказка: у .NET Framework ліміт 63 символи, більше = виняток
        $tip = "$ProfileName $drive — " + (Get-StatusText)
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + '…' }
        if ($ni.Text -ne $tip) { $ni.Text = $tip }

        # Сповіщення: пакет відвантажено
        $seq = $sync.BatchSeq
        if ($seq -ne $script:lastBatch) {
            $script:lastBatch = $seq
            if ($miNotifyUp.Checked) {
                Show-Balloon 'Зміни відвантажено' "Усі файли на сервері. Колеги побачать їх після оновлення свого кешу."
            }
        }

        # Сповіщення: тривала помилка
        if ($st -eq 'error' -and $sync.Hard -and $script:prevState -ne 'error' -and $miNotifyErr.Checked) {
            Show-Balloon "Помилка: $drive" $sync.Detail 'Warning'
            Write-TrayLog "error: $($sync.Detail)"
        }

        # Сповіщення: несподіване відключення
        if ($st -eq 'off' -and $script:prevState -in @('idle','read','write','error') -and -not $script:userStop) {
            if ($miNotifyErr.Checked) {
                Show-Balloon "Диск $drive відключено" 'rclone зупинився. Watchdog перепідключить автоматично, або оберіть «Змонтувати».' 'Warning'
            }
            Write-TrayLog 'unexpected disconnect'
        }
        if ($st -ne 'off') { $script:userStop = $false }

        $script:prevState = $st
    } catch {
        Write-TrayLog "tick: $($_.Exception.Message)"
    }
})
$timer.Start()

Write-TrayLog "started (rc: $(if ($cfg.RcAddr) { $cfg.RcAddr } else { 'off' }))"

try {
    [Windows.Forms.Application]::Run()
} finally {
    $sync.Stop = $true
    $timer.Dispose()
    $ni.Visible = $false
    $ni.Dispose()
    foreach ($i in $icons.Values) { $i.Dispose() }
    try { $bg.Stop(); $bg.Dispose(); $rs.Close() } catch { }
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
    Write-TrayLog 'stopped'
}
