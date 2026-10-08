#Requires -Version 5.1
<#
.SYNOPSIS
    Інтерактивний інсталятор постійного rclone-монтування (WebDAV / SFTP) у Windows.

.DESCRIPTION
    Повний цикл: перевірка та встановлення залежностей (WinFsp, rclone),
    інтерактивний збір параметрів, генерація секції rclone.conf з obscured-паролем,
    перевірка з'єднання, створення робочих тек, прихований VBS-лаунчер,
    реєстрація завдань Планувальника (монтування при вході + watchdog),
    запуск і верифікація.

.PARAMETER Uninstall
    Видалення: зупинка процесів, зняття завдань, опційне очищення конфігу і кешу.

.PARAMETER ProfileName
    Ім'я профілю = ім'я remote у rclone.conf. За замовчуванням 'synology'.

.PARAMETER TargetUser
    DOMAIN\User, під яким виконується завдання. Визначається автоматично.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1 -Uninstall -ProfileName synology

.NOTES
    Файл має бути збережений у UTF-8 з BOM — PS 5.1 читає .ps1 без BOM як ANSI.
#>

[CmdletBinding()]
param(
    [switch] $Uninstall,
    [string] $ProfileName = 'synology',
    [string] $TargetUser
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------------------
# Константи
# ---------------------------------------------------------------------------
$InstallRoot = 'C:\rclone'
$StateFile   = Join-Path $InstallRoot "$ProfileName.state.json"
$WinFspUrl   = 'https://winfsp.dev/rel/'
$RcloneDlUrl = 'https://downloads.rclone.org/rclone-current-windows-amd64.zip'

# ---------------------------------------------------------------------------
# Вивід
# ---------------------------------------------------------------------------
function Write-Step  { param($m) Write-Host "`n[==] $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "[ok] $m"   -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[!!] $m"   -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host "[XX] $m"   -ForegroundColor Red }
function Write-Info  { param($m) Write-Host "     $m"   -ForegroundColor Gray }

function Read-Default {
    param([string]$Prompt, [string]$Default)
    if ($Default) { $t = Read-Host "$Prompt [$Default]" } else { $t = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    if ($Default) { $hint = 'Y/n' } else { $hint = 'y/N' }
    while ($true) {
        $t = Read-Host "$Prompt [$hint]"
        if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
        switch -Regex ($t.Trim()) {
            '^(y|yes|t|т|так)$' { return $true }
            '^(n|no|н|ні)$'     { return $false }
            default { Write-Warn2 'Введіть y або n.' }
        }
    }
}

# ---------------------------------------------------------------------------
# UAC self-elevation. Оригінального користувача передаємо явно:
# після елевації $env:USERNAME може вказувати на інший акаунт.
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $TargetUser) { $TargetUser = "$env:USERDOMAIN\$env:USERNAME" }

if (-not (Test-Admin)) {
    Write-Warn2 'Потрібні права адміністратора. Перезапуск через UAC...'
    $psArgs = @(
        '-NoProfile','-ExecutionPolicy','Bypass'
        '-File', "`"$PSCommandPath`""
        '-ProfileName', $ProfileName
        '-TargetUser', "`"$TargetUser`""
    )
    if ($Uninstall) { $psArgs += '-Uninstall' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $psArgs
    exit
}

# ---------------------------------------------------------------------------
# rclone.conf: шлях цільового користувача + злиття секції
# ---------------------------------------------------------------------------
function Get-RcloneConfPath {
    param([string]$User)
    try {
        $sid = (New-Object Security.Principal.NTAccount($User)).Translate(
                 [Security.Principal.SecurityIdentifier]).Value
        $key  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $prof = (Get-ItemProperty -Path $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        $prof = [Environment]::ExpandEnvironmentVariables($prof)   # часто містить %SystemDrive%
        if (Test-Path $prof) { return (Join-Path $prof 'AppData\Roaming\rclone\rclone.conf') }
    } catch { }
    Write-Warn2 "Не вдалося визначити профіль '$User'. Використано поточний."
    return (Join-Path $env:APPDATA 'rclone\rclone.conf')
}

function Set-RcloneSection {
    # Замінює або додає секцію [name], зберігаючи решту remote
    param([string]$Path, [string]$Name, [System.Collections.IDictionary]$Values)

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $lines = @()
    if (Test-Path $Path) { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 }

    $out  = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') { $skip = ($Matches[1] -eq $Name) }
        if (-not $skip) { $out.Add($l) }
    }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count-1])) {
        $out.RemoveAt($out.Count-1)
    }
    if ($out.Count -gt 0) { $out.Add('') }

    $out.Add("[$Name]")
    foreach ($k in $Values.Keys) { $out.Add("$k = $($Values[$k])") }
    $out.Add('')

    # rclone очікує UTF-8 БЕЗ BOM
    [IO.File]::WriteAllLines($Path, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

function Remove-RcloneSection {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return }
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $out   = New-Object System.Collections.Generic.List[string]
    $skip  = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') { $skip = ($Matches[1] -eq $Name) }
        if (-not $skip) { $out.Add($l) }
    }
    [IO.File]::WriteAllLines($Path, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

function Stop-RcloneByPath {
    # Get-Process не має CommandLine у PS 5.1 -> фільтруємо за шляхом бінарника,
    # щоб не вбити чужі екземпляри rclone (Rclone UI тощо).
    param([string]$ExePath)
    $p = @(Get-Process rclone -ErrorAction SilentlyContinue |
           Where-Object { -not $ExePath -or $_.Path -eq $ExePath })
    if ($p.Count -gt 0) {
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
    }
    return $p.Count
}

# ===========================================================================
# ГІЛКА ВИДАЛЕННЯ
# ===========================================================================
if ($Uninstall) {
    Write-Step "Видалення профілю '$ProfileName'"

    $state = $null
    if (Test-Path $StateFile) {
        try { $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }

    # Індикатор у треї: процес powershell з RcloneTray.ps1 цього профілю
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*RcloneTray.ps1*' -and
                       $_.CommandLine -like "*$ProfileName*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    foreach ($suffix in @('mount','watchdog','tray')) {
        $tn = "rclone-$ProfileName-$suffix"
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false
            Write-Ok "Знято завдання: $tn"
        }
    }

    # Завдання запускає wscript, тому Stop-ScheduledTask не вбиває rclone
    $exeFromState = $null
    if ($state) { $exeFromState = $state.RclonePath }
    $killed = Stop-RcloneByPath -ExePath $exeFromState
    Write-Ok "Зупинено процесів rclone: $killed"

    foreach ($f in @(
        (Join-Path $InstallRoot "$ProfileName.launch.vbs"),
        (Join-Path $InstallRoot "$ProfileName.watchdog.ps1"),
        (Join-Path $InstallRoot "$ProfileName.stop.ps1"),
        (Join-Path $InstallRoot "$ProfileName.refresh.ps1"),
        (Join-Path $InstallRoot "$ProfileName.tray.vbs")
    )) {
        if (Test-Path $f) { Remove-Item $f -Force; Write-Ok "Видалено: $f" }
    }

    if ($state) {
        if ($state.CacheDir -and (Test-Path $state.CacheDir) -and
            (Read-YesNo "Видалити кеш '$($state.CacheDir)'?" $false)) {
            Remove-Item $state.CacheDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok 'Кеш видалено'
        }
        if ($state.ConfPath -and (Read-YesNo "Видалити секцію [$ProfileName] з rclone.conf?" $false)) {
            Remove-RcloneSection -Path $state.ConfPath -Name $ProfileName
            Write-Ok 'Секцію видалено'
        }
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }

    Write-Ok 'Готово.'
    Read-Host "`nEnter для виходу"
    exit
}

# ===========================================================================
# 1. ЗАЛЕЖНОСТІ
# ===========================================================================
Write-Step 'Перевірка залежностей'

$winfsp = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
if (-not $winfsp) {
    Write-Warn2 'WinFsp не знайдено — без нього монтування в літеру диска неможливе.'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (Read-YesNo 'Встановити WinFsp через winget?' $true) {
            winget install -e --id WinFsp.WinFsp --accept-package-agreements --accept-source-agreements
            Start-Sleep 3
            $winfsp = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
        }
    }
    if (-not $winfsp) {
        Write-Err "Встановіть WinFsp вручну: $WinFspUrl , потім перезапустіть скрипт."
        Read-Host 'Enter для виходу'; exit 1
    }
}
Write-Ok 'WinFsp присутній'

function Install-RclonePortable {
    param([string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $zip = Join-Path $env:TEMP 'rclone-dl.zip'
    $tmp = Join-Path $env:TEMP 'rclone-unzip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Info 'Завантаження rclone...'
    Invoke-WebRequest -Uri $RcloneDlUrl -OutFile $zip -UseBasicParsing
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1
    Copy-Item $src.FullName (Join-Path $Dest 'rclone.exe') -Force
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return (Join-Path $Dest 'rclone.exe')
}

$rclone = $null
if (Test-Path "$InstallRoot\rclone.exe") { $rclone = "$InstallRoot\rclone.exe" }
if (-not $rclone) {
    $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($cmd) { $rclone = $cmd.Source }
}

# Бінарник із стороннього GUI зникне при його оновленні/видаленні,
# а в завданні Планувальника шлях зашитий абсолютний.
if ($rclone -and $rclone -match 'com\.rclone\.ui|rcloneview|RcloneBrowser') {
    Write-Warn2 'Знайдений rclone належить сторонньому GUI:'
    Write-Info  $rclone
    Write-Warn2 'При оновленні/видаленні того GUI завдання зламається.'
    if (Read-YesNo "Поставити незалежний rclone у $InstallRoot ?" $true) {
        $rclone = Install-RclonePortable -Dest $InstallRoot
    }
}

if (-not $rclone) {
    Write-Warn2 'rclone не знайдено.'
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and
        (Read-YesNo 'Встановити rclone через winget?' $true)) {
        winget install -e --id Rclone.Rclone --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
        $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }
    if (-not $rclone -and (Read-YesNo "Завантажити портативний rclone у $InstallRoot ?" $true)) {
        $rclone = Install-RclonePortable -Dest $InstallRoot
    }
}
if (-not $rclone) { Write-Err 'rclone відсутній.'; Read-Host 'Enter'; exit 1 }

Write-Ok (& $rclone version | Select-Object -First 1)
Write-Info "Шлях: $rclone"

# ===========================================================================
# 2. ПАРАМЕТРИ ПІДКЛЮЧЕННЯ
# ===========================================================================
Write-Step 'Параметри підключення'

$proto = (Read-Default 'Протокол (webdav / sftp)' 'webdav').ToLower()
if ($proto -notin @('webdav','sftp')) { Write-Err 'Лише webdav або sftp.'; exit 1 }

$srvHost = Read-Default 'Хост (без схеми), напр. fs.example.com' ''
if (-not $srvHost) { Write-Err 'Хост обовʼязковий.'; exit 1 }

$useTls = $false
$url    = $null
$vendor = $null
if ($proto -eq 'webdav') {
    $port   = Read-Default 'Порт (Synology WebDAV over HTTPS = 5006, reverse proxy = 443)' '5006'
    $useTls = Read-YesNo 'HTTPS?' $true
    if ($useTls) { $scheme = 'https' } else { $scheme = 'http' }
    if (($useTls -and $port -eq '443') -or ((-not $useTls) -and $port -eq '80')) {
        $url = "${scheme}://${srvHost}/"
    } else {
        $url = "${scheme}://${srvHost}:${port}/"
    }
    Write-Info "URL: $url"
    $vendor = Read-Default 'Vendor (для Synology DSM = other)' 'other'
} else {
    $port = Read-Default 'Порт SFTP' '22'
}

$user = Read-Default 'Логін' $env:USERNAME

$sec  = Read-Host 'Пароль' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try     { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

# obscure через stdin: пароль не потрапляє в командний рядок і в історію
$obscured = ($plain | & $rclone obscure -).Trim()
$plain = $null
if (-not $obscured) { Write-Err 'Не вдалося обфускувати пароль.'; exit 1 }
Write-Ok 'Пароль обфусковано'

$skipCert = $false
if ($proto -eq 'webdav' -and $useTls) {
    $skipCert = Read-YesNo 'Сертифікат самопідписаний (вимкнути перевірку TLS)?' $false
    if ($skipCert) { Write-Warn2 'Перевірку сертифіката вимкнено — канал вразливий до MITM.' }
}

# ===========================================================================
# 3. ПАРАМЕТРИ МОНТУВАННЯ
# ===========================================================================
Write-Step 'Параметри монтування'

$busy = @()
$busy += (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
$busy += (Get-CimInstance Win32_NetworkConnection -ErrorAction SilentlyContinue |
          ForEach-Object { $_.LocalName -replace ':','' })
$busy = $busy | Where-Object { $_ -match '^[A-Za-z]$' } | ForEach-Object { $_.ToUpper() } |
        Sort-Object -Unique

$free = [char[]](68..90) | Where-Object { $busy -notcontains [string]$_ }   # D..Z

Write-Info "Зайняті: $($busy -join ' ')"
Write-Info "Вільні:  $($free -join ' ')"
if (-not $free) { Write-Err 'Немає вільних літер у діапазоні D..Z.'; exit 1 }

# Дефолту навмисно немає: вибір літери має бути свідомим
$drive = $null
while (-not $drive) {
    $in = (Read-Host 'Літера диска (обовʼязково)').Trim().TrimEnd(':').ToUpper()
    if ([string]::IsNullOrWhiteSpace($in)) { Write-Warn2 'Значення обовʼязкове — дефолту немає.' }
    elseif ($in -notmatch '^[D-Z]$')       { Write-Warn2 'Одна літера D..Z (A-C зарезервовані).' }
    elseif ($busy -contains $in)           { Write-Warn2 "Літера ${in}: вже зайнята." }
    else                                   { $drive = $in }
}
Write-Ok "Обрано ${drive}:"

$subPath = Read-Default 'Підтека на сервері (порожньо = корінь)' ''
if ($subPath) { $remoteSpec = "${ProfileName}:$($subPath.Trim('/'))" }
else          { $remoteSpec = "${ProfileName}:" }

$volName  = Read-Default 'Мітка тому в Провіднику' $ProfileName
$cacheDir = Read-Default 'Тека VFS-кешу (бажано окремий SSD)' 'D:\rclone-cache'
$cacheMax = Read-Default 'Ліміт кешу' '20G'
$readOnly = Read-YesNo 'Режим "лише читання"?' $false

# ---------------------------------------------------------------------------
# Профіль узгодженості кешу
# ---------------------------------------------------------------------------
# SOLO - сховищем користується лише ця машина. Довгі TTL, --no-modtime
#   (Synology WebDAV усе одно не приймає PROPPATCH, тож кожна спроба
#   виставити дату - марний round-trip).
#
# SHARED - з тими самими файлами працюють інші (RaiDrive, інший rclone, DSM).
#   --no-modtime ТУТ НЕДОПУСТИМИЙ: він вимикає не лише запис, а й ЧИТАННЯ
#   modtime, а саме за ним VFS вирішує, чи актуальна локальна копія. Без
#   нього змінений кимось файл того ж розміру віддаватиметься зі старого
#   кешу до кінця --vfs-cache-max-age.
#   Короткий --vfs-write-back публікує закритий файл майже одразу.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  1. SOLO     — сховищем користується лише ця машина.' -ForegroundColor Gray
Write-Host '                Довгі TTL, повний кеш читання. Найшвидше відкриття файлів.' -ForegroundColor DarkGray
Write-Host '  2. SHARED   — з файлами працює ще хтось. Повний кеш + відстеження modtime.' -ForegroundColor Gray
Write-Host '                Компроміс: швидко і при цьому бачить чужі зміни.' -ForegroundColor DarkGray
Write-Host '  3. RAIDRIVE — поведінка один-в-один як у RaiDrive колеги.' -ForegroundColor Gray
Write-Host '                Кешу читання НЕМАЄ взагалі, тому застарілих даних не буває' -ForegroundColor DarkGray
Write-Host '                в принципі. Ціна: кожне читання йде по мережі.' -ForegroundColor DarkGray
Write-Host ''

$mode = $null
while (-not $mode) {
    $m = Read-Default 'Режим (1/2/3)' '2'
    switch ($m) {
        '1'        { $mode = 'SOLO' }
        'solo'     { $mode = 'SOLO' }
        '2'        { $mode = 'SHARED' }
        'shared'   { $mode = 'SHARED' }
        '3'        { $mode = 'RAIDRIVE' }
        'raidrive' { $mode = 'RAIDRIVE' }
        default    { Write-Warn2 'Введіть 1, 2 або 3.' }
    }
}
$shared = ($mode -ne 'SOLO')

if ($mode -eq 'RAIDRIVE') {
    # Відтворення поведінки RaiDrive зі скріншота колеги:
    #   "Дата зміни" OFF            -> --no-modtime
    #   "Миттєво властивості файлу" -> --attr-timeout 0s (WinFsp нічого не кешує)
    #   "Асинхр. оновлення" auto    -> короткий --dir-cache-time
    #   завантаження на закритті    -> --vfs-write-back 0s
    #
    # Головне: cache-mode writes замість full. RaiDrive не тримає постійного
    # кешу читання — кожне відкриття тягне дані з сервера. Саме тому в нього
    # немає проблеми застарілих читань, попри вимкнений modtime: нема що
    # застарівати. Кешується лише запис, як у RaiDrive.
    $vfsMode     = 'writes'
    $cacheAge    = '1h'
    $dirCache    = '10s'
    $attrTimeout = '0s'
    $writeBack   = '0s'
    $cachePoll   = '30s'
    $readAhead   = '0'
    $noModTime   = $true
    Write-Ok 'Профіль RAIDRIVE: cache-mode writes, attr-timeout 0s, write-back 0s'
    Write-Warn2 'ПОВІЛЬНО. Кешу читання немає, атрибути не кешуються взагалі:'
    Write-Warn2 'Провідник робить тисячі синхронних запитів на теку, SOLIDWORKS'
    Write-Warn2 'читає збірки стрибками по мережі. Не прискорює появу файлів у колег —'
    Write-Warn2 'це визначає їхній клієнт. Беріть лише для діагностики.'
} elseif ($mode -eq 'SHARED') {
    # Ключ до коректності тут не короткий TTL, а modtime. З cache-mode full
    # rclone звіряє дату при КОЖНОМУ відкритті файлу: новіша на сервері -
    # перезавантажує. Тому довгий --vfs-cache-max-age нічого не псує, а
    # повторні відкриття лишаються миттєвими.
    # attr-timeout 1s і dir-cache 5s давали шквал PROPFIND з Провідника
    # (атрибути запитуються десятки разів на файл) - звідси були гальма.
    $vfsMode     = 'full'
    $cacheAge    = '24h'
    $dirCache    = '30s'
    $attrTimeout = '3s'
    $writeBack   = '2s'
    $cachePoll   = '1m'
    $readAhead   = '128M'
    $noModTime   = $false
    Write-Ok 'Профіль SHARED: cache-mode full, dir-cache 30s, attr-timeout 3s, write-back 2s'
    Write-Info 'Чужі зміни видно протягом 30 с, або негайно через refresh-скрипт.'
} else {
    $vfsMode     = 'full'
    $cacheAge    = Read-Default 'Час життя кешу' '72h'
    $dirCache    = Read-Default 'TTL кешу директорій' '20s'
    $attrTimeout = '5s'
    $writeBack   = '5s'
    $cachePoll   = '1m'
    $readAhead   = '128M'
    $noModTime   = Read-YesNo 'Ігнорувати modtime (прискорює; Synology все одно не приймає PROPPATCH)?' ($proto -eq 'webdav')
    Write-Ok "Профіль SOLO: cache-mode full, dir-cache $dirCache, attr-timeout 5s"
}

if ($shared) {
    Write-Info 'Блокувань файлів WebDAV не дає за жодних налаштувань: rclone не шле LOCK,'
    Write-Info 'тож одночасне редагування одного файлу вдвох мовчки втратить одну версію.'
}

# Індикатор у треї (окремий скрипт поруч з інсталятором)
$trayScript = Join-Path $PSScriptRoot 'RcloneTray.ps1'
$wantTray = $false
if (Test-Path $trayScript) {
    $wantTray = Read-YesNo 'Індикатор стану в треї (сірий/зелений/синій/помаранчевий/червоний)?' $true
}

# Remote control: скид кешу без перезапуску + джерело даних для індикатора
if ($wantTray) {
    $useRc = $true
    Write-Info 'Індикатор читає стан через rc — remote control увімкнено автоматично.'
} else {
    $useRc = Read-YesNo 'Увімкнути remote control (ручний скид кешу через rclone rc)?' $shared
}

# 5572 — дефолт rclone, його часто тримає Rclone UI. Зайнятий порт = фатальна
# помилка старту rclone mount, тому перевіряємо одразу.
$rcPort = '5582'
if ($useRc) {
    while ($true) {
        $rcPort = Read-Default 'Порт rc (лише 127.0.0.1)' $rcPort
        try {
            $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int]$rcPort)
            $l.Start(); $l.Stop(); break
        } catch {
            Write-Warn2 "Порт $rcPort зайнятий — rclone з ним не стартує. Оберіть інший."
            $rcPort = [string]([int]$rcPort + 1)
        }
    }
}

# Synology віддає в корені елементи, які rclone бачить як symlink -> ERROR у лозі
$useLinks = Read-YesNo 'Обробляти symlink як .rclonelink (прибирає помилку в корені)?' ($proto -eq 'webdav')
$bwLimit  = Read-Default 'Обмеження швидкості (10M або 10M:5M, порожньо = без ліміту)' ''
$startDelay   = Read-Default 'Затримка старту після входу, секунд' '15'
$wantWatchdog = Read-YesNo 'Створити watchdog (перевірка живості кожні 5 хв)?' $true

$logDir  = Join-Path $InstallRoot 'logs'
$logFile = Join-Path $logDir "$ProfileName.mount.log"
$wdLog   = Join-Path $logDir "$ProfileName.watchdog.log"

# ===========================================================================
# 4. ЗАПИС rclone.conf
# ===========================================================================
Write-Step 'Запис конфігурації'

$confPath = Get-RcloneConfPath -User $TargetUser
Write-Info "rclone.conf: $confPath"

if (Test-Path $confPath) {
    $bak = "$confPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $confPath $bak -Force
    Write-Ok "Резервна копія: $bak"
}

$section = [ordered]@{}
if ($proto -eq 'webdav') {
    $section['type']   = 'webdav'
    $section['url']    = $url
    $section['vendor'] = $vendor
    $section['user']   = $user
    $section['pass']   = $obscured
} else {
    $section['type']            = 'sftp'
    $section['host']            = $srvHost
    $section['port']            = $port
    $section['user']            = $user
    $section['pass']            = $obscured
    $section['shell_type']      = 'unix'
    $section['md5sum_command']  = 'md5sum'
    $section['sha1sum_command'] = 'sha1sum'
}
Set-RcloneSection -Path $confPath -Name $ProfileName -Values $section
Write-Ok "Секцію [$ProfileName] записано"

# ===========================================================================
# 5. ПЕРЕВІРКА ЗʼЄДНАННЯ
# ===========================================================================
Write-Step 'Перевірка зʼєднання'

$testArgs = @('lsd', $remoteSpec, '--config', $confPath, '--timeout','30s','--contimeout','15s')
if ($skipCert) { $testArgs += '--no-check-certificate' }
if ($useLinks) { $testArgs += '--links' }

$test = & $rclone @testArgs 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok 'Зʼєднання встановлено. Каталоги верхнього рівня:'
    $test | Select-Object -First 15 | ForEach-Object { Write-Info $_ }
} else {
    Write-Err 'Зʼєднання не вдалося:'
    $test | ForEach-Object { Write-Info $_ }
    if (-not (Read-YesNo 'Продовжити попри помилку?' $false)) { Read-Host 'Enter'; exit 1 }
}

# ===========================================================================
# 6. ТЕКИ ТА ПРАВА
# ===========================================================================
Write-Step 'Створення робочих тек'
foreach ($d in @($InstallRoot, $logDir, $cacheDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Write-Ok $d
}
foreach ($d in @($logDir, $cacheDir)) {
    try {
        $acl = Get-Acl $d
        $ace = New-Object Security.AccessControl.FileSystemAccessRule(
                 $TargetUser,'Modify','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($ace); Set-Acl $d $acl
    } catch { Write-Warn2 "ACL на $d не змінено: $($_.Exception.Message)" }
}
Write-Ok "Права на запис надано: $TargetUser"

# ===========================================================================
# 7. АРГУМЕНТИ MOUNT
# ===========================================================================
$mountArgs = @(
    'mount', "`"$remoteSpec`"", "${drive}:"
    '--config',                 "`"$confPath`""
    '--network-mode'
    '--volname',                "`"$volName`""
    '--vfs-cache-mode',         $vfsMode
    '--cache-dir',              "`"$cacheDir`""
    '--vfs-cache-max-size',     $cacheMax
    '--vfs-cache-max-age',      $cacheAge
    '--vfs-cache-poll-interval',$cachePoll
    '--vfs-read-ahead',         $readAhead
    '--vfs-write-back',         $writeBack
    '--buffer-size',            '32M'
    '--dir-cache-time',         $dirCache
    '--attr-timeout',           $attrTimeout
    '--transfers',              '8'
    '--checkers',               '8'
    '--timeout',                '120s'
    '--contimeout',             '30s'
    '--retries',                '5'
    '--low-level-retries',      '20'
    '--log-file',               "`"$logFile`""
    '--log-level',              'INFO'
)
if ($noModTime) { $mountArgs += '--no-modtime' }
if ($readOnly)  { $mountArgs += '--read-only' }
if ($skipCert)  { $mountArgs += '--no-check-certificate' }
if ($useLinks)  { $mountArgs += '--links' }
if ($bwLimit)   { $mountArgs += @('--bwlimit', $bwLimit) }
# rc слухає лише loopback, тому --rc-no-auth безпечний
if ($useRc)     { $mountArgs += @('--rc', '--rc-addr', "127.0.0.1:$rcPort", '--rc-no-auth') }

$argString = $mountArgs -join ' '

# ===========================================================================
# 8. ПРИХОВАНИЙ ЛАУНЧЕР + СКРИПТ ЗУПИНКИ
# ---------------------------------------------------------------------------
# rclone реалізує --no-console через FreeConsole(), тобто відвʼязується вже
# ПІСЛЯ того, як Windows створила вікно для console-app. Порожнє вікно лишається
# висіти, а його закриття шле CTRL_CLOSE_EVENT -> том розмонтовується.
# wscript.exe з intWindowStyle=0 не створює консоль взагалі.
# ===========================================================================
Write-Step 'Генерація лаунчера'

$launchVbs = Join-Path $InstallRoot "$ProfileName.launch.vbs"
$stopPs1   = Join-Path $InstallRoot "$ProfileName.stop.ps1"

# У VBS-літералі кожна лапка подвоюється
$cmdLine = ('"' + $rclone + '" ' + $argString) -replace '"','""'

$vbsBody = @"
' Hidden launcher for rclone mount. Profile: $ProfileName
' Generated by Install-RcloneMount.ps1 -- do not edit manually.
' intWindowStyle = 0     -> no console window
' bWaitOnReturn  = False -> wscript exits at once, rclone keeps running detached
Set sh = CreateObject("WScript.Shell")
sh.Run "$cmdLine", 0, False
"@
# wscript читає .vbs як ANSI: UTF-8 з BOM дасть "Invalid character"
Set-Content -LiteralPath $launchVbs -Value $vbsBody -Encoding Default
Write-Ok "Лаунчер: $launchVbs"

$stopBody = @"
# Розмонтування профілю '$ProfileName'.
# Stop-ScheduledTask тут не діє: завдання запускає wscript, який одразу
# завершується, а rclone лишається окремим відвʼязаним процесом.
`$p = @(Get-Process rclone -ErrorAction SilentlyContinue |
        Where-Object { `$_.Path -eq '$rclone' })
if (`$p.Count -gt 0) { `$p | Stop-Process -Force; "Зупинено процесів: `$(`$p.Count)" }
else { 'Процесів rclone не знайдено.' }
"@
[IO.File]::WriteAllText($stopPs1, $stopBody, (New-Object Text.UTF8Encoding($true)))
Write-Ok "Скрипт зупинки: $stopPs1"

# Скид кешу на вимогу: коли треба побачити чужі зміни швидше за dir-cache-time
$refreshPs1 = $null
if ($useRc) {
    $refreshPs1 = Join-Path $InstallRoot "$ProfileName.refresh.ps1"
    $refreshBody = @"
<#
.SYNOPSIS
    Негайний скид кешу директорій профілю '$ProfileName' (${drive}:).
.DESCRIPTION
    vfs/forget викидає закешований лістинг, тож наступне звернення тягне
    свіжий PROPFIND з сервера. Потрібно, коли чужу зміну треба побачити
    швидше, ніж спливе --dir-cache-time ($dirCache).
.PARAMETER Dir
    Шлях ВІДНОСНО кореня монтування (Projects/2026). Порожньо = весь кеш.
.PARAMETER Stats
    Показати стан VFS: скільки файлів у черзі на відвантаження.
#>
param([string]`$Dir, [switch]`$Stats)

`$rc   = '$rclone'
`$addr = '127.0.0.1:$rcPort'

if (`$Stats) {
    & `$rc rc vfs/stats --rc-addr `$addr --rc-no-auth
    return
}
if (`$Dir) { & `$rc rc vfs/forget dir=`$Dir --rc-addr `$addr --rc-no-auth }
else       { & `$rc rc vfs/forget            --rc-addr `$addr --rc-no-auth }
"@
    [IO.File]::WriteAllText($refreshPs1, $refreshBody, (New-Object Text.UTF8Encoding($true)))
    Write-Ok "Скид кешу: $refreshPs1"
}

$wdPath = Join-Path $InstallRoot "$ProfileName.watchdog.ps1"
if ($wantWatchdog) {
    $wdBody = @"
# Watchdog для rclone-mount '$ProfileName' (${drive}:)
# Test-Path на мертвому WinFsp-томі блокується намертво -> ізолюємо в Job.
`$ErrorActionPreference = 'SilentlyContinue'
`$log = '$wdLog'

`$alive = `$false
`$job = Start-Job { Test-Path '${drive}:\' }
if (Wait-Job `$job -Timeout 15) { `$alive = [bool](Receive-Job `$job) }
Remove-Job `$job -Force

# Процес може жити, але том вже мертвий -> перезапуск у будь-якому разі
if (-not `$alive) {
    "`$(Get-Date -f s)  mount dead -> restart" | Add-Content `$log
    Get-Process rclone | Where-Object { `$_.Path -eq '$rclone' } | Stop-Process -Force
    Start-Sleep 3
    Start-ScheduledTask -TaskName 'rclone-$ProfileName-mount'
}
"@
    [IO.File]::WriteAllText($wdPath, $wdBody, (New-Object Text.UTF8Encoding($true)))
    Write-Ok "Watchdog: $wdPath"
}

# ===========================================================================
# 9. ЗАВДАННЯ ПЛАНУВАЛЬНИКА
# ---------------------------------------------------------------------------
# Служба не підходить: WinFsp-монтування зі служби потрапляє в сесію 0
# і не буде видимим у Провіднику користувача.
# ===========================================================================
Write-Step 'Реєстрація завдань Планувальника'

$taskMount = "rclone-$ProfileName-mount"
$taskWd    = "rclone-$ProfileName-watchdog"

foreach ($tn in @($taskMount, $taskWd)) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
    }
}

$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited

# ExecutionTimeLimit=0 не критичний (wscript завершується миттєво),
# але лишаємо для сумісності з ручним запуском rclone напряму.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable -MultipleInstances IgnoreNew

$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launchVbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser

Register-ScheduledTask -TaskName $taskMount -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

$t = Get-ScheduledTask -TaskName $taskMount
$t.Triggers[0].Delay = "PT${startDelay}S"        # час на підняття мережі
Set-ScheduledTask -InputObject $t | Out-Null
Write-Ok "$taskMount  (при вході, затримка ${startDelay}s)"

if ($wantWatchdog) {
    $wdAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wdPath`""
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Minutes 5)
    $wdSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskWd -Action $wdAction -Trigger $wdTrigger `
        -Settings $wdSettings -Principal $principal -Force | Out-Null
    Write-Ok "$taskWd  (кожні 5 хв)"
}

# ===========================================================================
# 10. STATE
# ===========================================================================
$wdName = $null
if ($wantWatchdog) { $wdName = $taskWd }

[pscustomobject]@{
    ProfileName  = $ProfileName
    Protocol     = $proto
    Drive        = "${drive}:"
    RemoteSpec   = $remoteSpec
    ConfPath     = $confPath
    CacheDir     = $cacheDir
    LogFile      = $logFile
    RclonePath   = $rclone
    Mode         = $mode
    Shared       = $shared
    VfsCacheMode = $vfsMode
    LaunchVbs    = $launchVbs
    StopScript   = $stopPs1
    RefreshScript= $refreshPs1
    RcAddr       = $(if ($useRc) { "127.0.0.1:$rcPort" } else { $null })
    TargetUser   = $TargetUser
    TaskMount    = $taskMount
    TaskWatchdog = $wdName
    Installed    = (Get-Date -Format s)
} | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

# ===========================================================================
# 11. ЗАПУСК І ВЕРИФІКАЦІЯ
# ---------------------------------------------------------------------------
# Test-Path з ЕЛЕВОВАНОЇ сесії не бачить том, змонтований у --network-mode
# під звичайним токеном: мережеві підключення привʼязані до logon session,
# а UAC видає процесу токен з іншим LUID. Тому основний критерій —
# живий процес rclone + маркер WinFsp у лозі; Test-Path лише додатковий.
# ===========================================================================
Write-Step 'Запуск монтування'

Stop-RcloneByPath -ExePath $rclone | Out-Null
Start-ScheduledTask -TaskName $taskMount

$proc = @()
for ($i = 1; $i -le 25; $i++) {
    Start-Sleep 1
    $proc = @(Get-Process rclone -ErrorAction SilentlyContinue |
              Where-Object { $_.Path -eq $rclone })
    if ($proc.Count -gt 0) { break }
    Write-Host '.' -NoNewline
}
Write-Host ''

$svcStarted = $false
$fatal      = @()
if (Test-Path $logFile) {
    Start-Sleep 3                              # дати WinFsp дописати маркер
    $tail = Get-Content $logFile -Tail 80 -ErrorAction SilentlyContinue
    $svcStarted = [bool]($tail -match 'service rclone has been started')
    $fatal = $tail | Where-Object {
        $_ -match 'Fatal error|mount helper error|cannot mount|failed to mount'
    }
}
$visible = $false
try { $visible = Test-Path "${drive}:\" } catch { }

if ($fatal) {
    Write-Err 'Фатальна помилка монтування:'
    $fatal | ForEach-Object { Write-Info $_ }
} elseif ($proc.Count -gt 0 -and ($svcStarted -or $visible)) {
    Write-Ok "rclone працює (PID $($proc[0].Id)), том ${drive}: піднято"
    if ($visible) {
        Get-ChildItem "${drive}:\" -ErrorAction SilentlyContinue |
            Select-Object -First 10 | ForEach-Object { Write-Info $_.Name }
    } else {
        Write-Warn2 "З цієї (елевованої) сесії ${drive}: не видно — очікувано для --network-mode."
        Write-Info  "Перевірте у ЗВИЧАЙНОМУ PowerShell:  Test-Path ${drive}:\"
        Write-Info  'Щоб елевовані процеси теж бачили том (потребує перезавантаження):'
        Write-Info  "  New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'"
        Write-Info  '    -Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force'
    }
} else {
    Write-Err 'Процес rclone не запустився. Останні рядки логу:'
    if (Test-Path $logFile) { Get-Content $logFile -Tail 25 | ForEach-Object { Write-Info $_ } }
    Write-Info ''
    Write-Info 'Інтерактивний дебаг (у звичайному PowerShell):'
    Write-Info "  & `"$rclone`" $($argString -replace '--log-level INFO','--log-level DEBUG')"
}

# ===========================================================================
# 12. ІНДИКАТОР У ТРЕЇ
# ===========================================================================
if ($wantTray) {
    Write-Step 'Індикатор у треї'
    try {
        # rc уже в лаунчері, тож RcloneTray не патчитиме його і не перезапускатиме rclone
        & $trayScript -Install -ProfileName $ProfileName -NoPause
    } catch {
        Write-Err "Індикатор не встановлено: $($_.Exception.Message)"
        Write-Info "Повторіть окремо: powershell -ExecutionPolicy Bypass -File `"$trayScript`" -Install"
    }
}

# ===========================================================================
# ПІДСУМОК
# ===========================================================================
$taskList = $taskMount
if ($wantWatchdog) { $taskList = "$taskMount, $taskWd" }
switch ($mode) {
    'RAIDRIVE' { $modeLabel = 'RAIDRIVE (як у колеги, без кешу читання)' }
    'SHARED'   { $modeLabel = 'SHARED (спільний доступ)' }
    default    { $modeLabel = 'SOLO' }
}
$sep = '-' * 70

Write-Host ''
Write-Host $sep -ForegroundColor DarkGray
Write-Host " Профіль:     $ProfileName ($proto)"
Write-Host " Режим:       $modeLabel"
Write-Host " Диск:        ${drive}:  ->  $remoteSpec"
Write-Host " rclone:      $rclone"
Write-Host " Конфіг:      $confPath"
Write-Host " Кеш:         $cacheDir  (max $cacheMax / $cacheAge)"
Write-Host " Узгодження:  cache-mode $vfsMode, dir-cache $dirCache, attr-timeout $attrTimeout, write-back $writeBack"
Write-Host " Лог:         $logFile"
Write-Host " Завдання:    $taskList"
Write-Host $sep -ForegroundColor DarkGray
Write-Host @"

 Керування:

   Start-ScheduledTask $taskMount
       змонтувати (через прихований VBS-лаунчер, консольного вікна не буде)

   powershell -ExecutionPolicy Bypass -File "$stopPs1"
       розмонтувати. Stop-ScheduledTask тут НЕ працює: завдання запускає
       wscript, який завершується одразу, а rclone лишається окремим процесом.

   Get-Content "$logFile" -Tail 50 -Wait
       живий лог

"@ -ForegroundColor Gray

if ($useRc) {
    Write-Host @"
 Скид кешу (коли чужу зміну треба побачити негайно):

   powershell -File "$refreshPs1"
       забути весь кеш директорій

   powershell -File "$refreshPs1" -Dir "Projects/2026"
       забути одну теку (шлях відносно кореня монтування)

   powershell -File "$refreshPs1" -Stats
       стан VFS: uploadsInProgress / uploadsQueued = чи ваші зміни вже на сервері

"@ -ForegroundColor Gray
}

Write-Host @"
 Видалення:
   powershell -ExecutionPolicy Bypass -File "$PSCommandPath" -Uninstall -ProfileName $ProfileName

"@ -ForegroundColor Gray

Read-Host 'Enter для виходу'
