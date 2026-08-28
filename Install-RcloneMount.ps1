#Requires -Version 5.1
<#
.SYNOPSIS
    Інтерактивний інсталятор постійного rclone-монтування (WebDAV / SFTP) у Windows.

.DESCRIPTION
    Виконує повний цикл: перевірка та встановлення залежностей (WinFsp, rclone),
    інтерактивний збір параметрів, генерація секції rclone.conf з obscured-паролем,
    перевірка з'єднання, створення робочих тек, реєстрація завдань Планувальника
    (монтування при вході + watchdog), запуск і верифікація.

.PARAMETER Uninstall
    Видалення: зупинка та зняття завдань, опційне очищення конфігурації і кешу.

.PARAMETER ProfileName
    Ім'я профілю = ім'я remote у rclone.conf. За замовчуванням 'synology'.

.PARAMETER TargetUser
    DOMAIN\User, під яким має виконуватись завдання. Визначається автоматично.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch] $Uninstall,
    [string] $ProfileName = 'synology',
    [string] $TargetUser
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Константи
# ---------------------------------------------------------------------------
$InstallRoot   = 'C:\rclone'
$StateFile     = Join-Path $InstallRoot "$ProfileName.state.json"
$WinFspUrl     = 'https://github.com/winfsp/winfsp/releases/latest'
$RcloneDlBase  = 'https://downloads.rclone.org/rclone-current-windows-amd64.zip'

# ---------------------------------------------------------------------------
# Хелпери виводу
# ---------------------------------------------------------------------------
function Write-Step  { param($m) Write-Host "`n[==] $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "[ok] $m"   -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[!!] $m"   -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host "[XX] $m"   -ForegroundColor Red }
function Write-Info  { param($m) Write-Host "     $m"   -ForegroundColor Gray }

function Read-Default {
    <# Запит значення з дефолтом; порожній ввід повертає дефолт #>
    param([string]$Prompt, [string]$Default)
    if ($Default) { $t = Read-Host "$Prompt [$Default]" } else { $t = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $t = Read-Host "$Prompt [$hint]"
        if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
        switch -Regex ($t.Trim()) {
            '^(y|yes|т|так)$' { return $true }
            '^(n|no|н|ні)$'   { return $false }
            default { Write-Warn2 'Введіть y або n.' }
        }
    }
}

# ---------------------------------------------------------------------------
# UAC self-elevation. Оригінального користувача передаємо явно —
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
# Робота з rclone.conf: злиття секції без руйнування інших remote
# ---------------------------------------------------------------------------
function Get-RcloneConfPath {
    <# Шлях до rclone.conf ЦІЛЬОВОГО користувача, а не адміна, що запустив UAC #>
    param([string]$User)
    try {
        $sid = (New-Object Security.Principal.NTAccount($User)).Translate(
                 [Security.Principal.SecurityIdentifier]).Value
        $key  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $prof = (Get-ItemProperty -Path $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        # ProfileImagePath часто містить %SystemDrive% — розгортаємо
        $prof = [Environment]::ExpandEnvironmentVariables($prof)
        if (Test-Path $prof) {
            return (Join-Path $prof 'AppData\Roaming\rclone\rclone.conf')
        }
    } catch { }
    Write-Warn2 "Не вдалося визначити профіль '$User'. Використано поточний."
    return (Join-Path $env:APPDATA 'rclone\rclone.conf')
}

function Set-RcloneSection {
    <# Замінює або додає секцію [name] у INI-файлі, зберігаючи решту #>
    param([string]$Path, [string]$Name, [System.Collections.IDictionary]$Values)

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $lines = @()
    if (Test-Path $Path) { $lines = Get-Content -LiteralPath $Path -Encoding UTF8 }

    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') {
            $skip = ($Matches[1] -eq $Name)   # входимо в цільову секцію -> пропускаємо
        }
        if (-not $skip) { $out.Add($l) }
    }

    # прибрати хвостові порожні рядки перед додаванням
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count-1])) {
        $out.RemoveAt($out.Count-1)
    }
    if ($out.Count -gt 0) { $out.Add('') }

    $out.Add("[$Name]")
    foreach ($k in $Values.Keys) { $out.Add("$k = $($Values[$k])") }
    $out.Add('')

    # rclone очікує UTF-8 без BOM
    [IO.File]::WriteAllLines($Path, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

function Remove-RcloneSection {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return }
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+?)\]\s*$') { $skip = ($Matches[1] -eq $Name) }
        if (-not $skip) { $out.Add($l) }
    }
    [IO.File]::WriteAllLines($Path, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Гілка видалення
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Step "Видалення профілю '$ProfileName'"

    $state = $null
    if (Test-Path $StateFile) { $state = Get-Content $StateFile -Raw | ConvertFrom-Json }

    foreach ($suffix in @('mount','watchdog')) {
        $tn = "rclone-$ProfileName-$suffix"
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if ($t) {
            Stop-ScheduledTask  -TaskName $tn -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false
            Write-Ok "Знято завдання: $tn"
        }
    }

    # Get-Process не має CommandLine у PS 5.1 -> звужуємо за шляхом бінарника зі state
    $procs = Get-Process rclone -ErrorAction SilentlyContinue
    if ($state -and $state.RclonePath) {
        $procs = $procs | Where-Object { $_.Path -eq $state.RclonePath }
    }
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "Зупинено процесів rclone: $($procs.Count)"
    }

    if ($state) {
        if ((Test-Path $state.CacheDir) -and (Read-YesNo "Видалити кеш '$($state.CacheDir)'?" $false)) {
            Remove-Item $state.CacheDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok 'Кеш видалено'
        }
        if (Read-YesNo "Видалити секцію [$ProfileName] з rclone.conf?" $false) {
            Remove-RcloneSection -Path $state.ConfPath -Name $ProfileName
            Write-Ok 'Секцію видалено'
        }
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }

    Write-Ok 'Готово.'
    Read-Host "`nEnter для виходу"
    exit
}

# ---------------------------------------------------------------------------
# 1. Залежності
# ---------------------------------------------------------------------------
Write-Step 'Перевірка залежностей'

# --- WinFsp ---
$winfsp = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
if (-not $winfsp) {
    Write-Warn2 'WinFsp не знайдено. Без нього монтування в літеру диска неможливе.'
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
Write-Ok "WinFsp: служба '$($winfsp.Name)' присутня"

# --- rclone ---
$rclone = $null
$cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
if ($cmd) { $rclone = $cmd.Source }
if (-not $rclone -and (Test-Path "$InstallRoot\rclone.exe")) { $rclone = "$InstallRoot\rclone.exe" }

if (-not $rclone) {
    Write-Warn2 'rclone не знайдено.'
    $done = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (Read-YesNo 'Встановити rclone через winget?' $true) {
            winget install -e --id Rclone.Rclone --accept-package-agreements --accept-source-agreements
            $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('Path','User')
            $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
            if ($cmd) { $rclone = $cmd.Source; $done = $true }
        }
    }
    if (-not $done -and (Read-YesNo "Завантажити портативний rclone у $InstallRoot ?" $true)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        $zip = Join-Path $env:TEMP 'rclone.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $RcloneDlBase -OutFile $zip -UseBasicParsing
        $tmp = Join-Path $env:TEMP 'rclone-unzip'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1
        Copy-Item $src.FullName "$InstallRoot\rclone.exe" -Force
        Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue
        $rclone = "$InstallRoot\rclone.exe"
    }
}
if (-not $rclone) { Write-Err 'rclone відсутній.'; Read-Host 'Enter'; exit 1 }

$rcVer = (& $rclone version | Select-Object -First 1)
Write-Ok "rclone: $rcVer"
Write-Info "Шлях: $rclone"

# ---------------------------------------------------------------------------
# 2. Інтерактивний збір параметрів
# ---------------------------------------------------------------------------
Write-Step 'Параметри підключення'

$proto = Read-Default 'Протокол (webdav / sftp)' 'webdav'
$proto = $proto.ToLower()
if ($proto -notin @('webdav','sftp')) { Write-Err 'Підтримується лише webdav або sftp.'; exit 1 }

$host_ = Read-Default 'Хост (без схеми), напр. fs.example.com' ''
if (-not $host_) { Write-Err 'Хост обовʼязковий.'; exit 1 }

if ($proto -eq 'webdav') {
    $port = Read-Default 'Порт (Synology WebDAV over HTTPS = 5006, reverse proxy = 443)' '5006'
    $useTls = Read-YesNo 'HTTPS?' $true
    $scheme = if ($useTls) { 'https' } else { 'http' }
    $url = if (($useTls -and $port -eq '443') -or (-not $useTls -and $port -eq '80')) {
        "${scheme}://${host_}/"
    } else {
        "${scheme}://${host_}:${port}/"
    }
    Write-Info "URL: $url"
    $vendor = Read-Default 'Vendor (для Synology/DSM = other)' 'other'
} else {
    $port = Read-Default 'Порт SFTP' '22'
}

$user = Read-Default 'Логін' $env:USERNAME

$sec = Read-Host 'Пароль' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

# obscure через stdin — пароль не потрапляє в командний рядок і в історію
$obscured = ($plain | & $rclone obscure -).Trim()
$plain = $null
if (-not $obscured) { Write-Err 'Не вдалося обфускувати пароль.'; exit 1 }
Write-Ok 'Пароль обфусковано'

$skipCert = $false
if ($proto -eq 'webdav' -and $useTls) {
    $skipCert = Read-YesNo 'Сертифікат самопідписаний (вимкнути перевірку TLS)?' $false
    if ($skipCert) { Write-Warn2 'Перевірку сертифіката вимкнено — канал вразливий до MITM.' }
}

# ---------------------------------------------------------------------------
# 3. Параметри монтування
# ---------------------------------------------------------------------------
Write-Step 'Параметри монтування'

$busy = @()
$busy += (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
$busy += (Get-CimInstance Win32_NetworkConnection -ErrorAction SilentlyContinue |
          ForEach-Object { $_.LocalName -replace ':','' })
$busy = $busy | Where-Object { $_ } | Sort-Object -Unique
Write-Info "Зайняті літери: $($busy -join ', ')"

do {
    $drive = (Read-Default 'Літера диска' 'Y').TrimEnd(':').ToUpper()
    $bad = ($drive.Length -ne 1) -or ($drive -notmatch '^[D-Z]$')
    if ($bad)              { Write-Warn2 'Одна літера в діапазоні D..Z.' }
    elseif ($busy -contains $drive) { Write-Warn2 "Літера $drive: зайнята."; $bad = $true }
} while ($bad)

$subPath = Read-Default 'Підтека на сервері (порожньо = корінь)' ''
$remoteSpec = if ($subPath) { "${ProfileName}:$($subPath.Trim('/'))" } else { "${ProfileName}:" }

$volName  = Read-Default 'Мітка тому в Провіднику' $ProfileName
$cacheDir = Read-Default 'Тека VFS-кешу (бажано окремий SSD)' 'D:\rclone-cache'
$cacheMax = Read-Default 'Ліміт кешу' '20G'
$cacheAge = Read-Default 'Час життя кешу' '72h'
$dirCache = Read-Default 'TTL кешу директорій (менше = швидше видно чужі зміни)' '20s'
$readOnly = Read-YesNo 'Режим "лише читання"?' $false
$noModTime= Read-YesNo 'Ігнорувати modtime (Synology WebDAV не приймає PROPPATCH)?' ($proto -eq 'webdav')

$bwLimit = Read-Default 'Обмеження швидкості (напр. 10M або 10M:5M, порожньо = без ліміту)' ''
$startDelay = Read-Default 'Затримка старту після входу, секунд' '15'
$wantWatchdog = Read-YesNo 'Створити watchdog (перевірка живості кожні 5 хв)?' $true

$logDir  = Join-Path $InstallRoot 'logs'
$logFile = Join-Path $logDir "$ProfileName.mount.log"

# ---------------------------------------------------------------------------
# 4. Запис rclone.conf
# ---------------------------------------------------------------------------
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
    $section['type']             = 'sftp'
    $section['host']             = $host_
    $section['port']             = $port
    $section['user']             = $user
    $section['pass']             = $obscured
    $section['shell_type']       = 'unix'
    $section['md5sum_command']   = 'md5sum'
    $section['sha1sum_command']  = 'sha1sum'
}

Set-RcloneSection -Path $confPath -Name $ProfileName -Values $section
Write-Ok "Секцію [$ProfileName] записано"

# ---------------------------------------------------------------------------
# 5. Перевірка зʼєднання
# ---------------------------------------------------------------------------
Write-Step 'Перевірка зʼєднання'

$testArgs = @('lsd', $remoteSpec, '--config', $confPath, '--timeout','30s','--contimeout','15s')
if ($skipCert) { $testArgs += '--no-check-certificate' }

$test = & $rclone @testArgs 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok 'Зʼєднання встановлено. Каталоги верхнього рівня:'
    $test | Select-Object -First 15 | ForEach-Object { Write-Info $_ }
} else {
    Write-Err 'Зʼєднання не вдалося:'
    $test | ForEach-Object { Write-Info $_ }
    if (-not (Read-YesNo 'Продовжити встановлення попри помилку?' $false)) {
        Read-Host 'Enter для виходу'; exit 1
    }
}

# ---------------------------------------------------------------------------
# 6. Створення тек
# ---------------------------------------------------------------------------
Write-Step 'Створення робочих тек'
foreach ($d in @($InstallRoot, $logDir, $cacheDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Write-Ok $d
}
# Кеш і логи мають бути доступні цільовому користувачеві на запис
foreach ($d in @($logDir, $cacheDir)) {
    $acl = Get-Acl $d
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $TargetUser,'Modify','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule); Set-Acl $d $acl
}
Write-Ok "Права на запис надано: $TargetUser"

# ---------------------------------------------------------------------------
# 7. Формування аргументів mount
# ---------------------------------------------------------------------------
$mountArgs = @(
    'mount', "`"$remoteSpec`"", "${drive}:"
    '--config',                 "`"$confPath`""
    '--network-mode'
    '--volname',                "`"$volName`""
    '--vfs-cache-mode',         'full'
    '--cache-dir',              "`"$cacheDir`""
    '--vfs-cache-max-size',     $cacheMax
    '--vfs-cache-max-age',      $cacheAge
    '--vfs-cache-poll-interval','1m'
    '--vfs-read-ahead',         '128M'
    '--vfs-write-back',         '5s'
    '--buffer-size',            '32M'
    '--dir-cache-time',         $dirCache
    '--attr-timeout',           '5s'
    '--transfers',              '8'
    '--checkers',               '8'
    '--timeout',                '120s'
    '--contimeout',             '30s'
    '--retries',                '5'
    '--low-level-retries',      '20'
    '--no-console'
    '--log-file',               "`"$logFile`""
    '--log-level',              'INFO'
)
if ($noModTime) { $mountArgs += '--no-modtime' }
if ($readOnly)  { $mountArgs += '--read-only' }
if ($skipCert)  { $mountArgs += '--no-check-certificate' }
if ($bwLimit)   { $mountArgs += @('--bwlimit', $bwLimit) }

$argString = $mountArgs -join ' '

# ---------------------------------------------------------------------------
# 8. Watchdog
# ---------------------------------------------------------------------------
$wdPath = Join-Path $InstallRoot "$ProfileName.watchdog.ps1"
$wdLog  = Join-Path $logDir "$ProfileName.watchdog.log"
if ($wantWatchdog) {
    $wd = @"
# Watchdog для rclone-mount '$ProfileName' (${drive}:)
# Test-Path на мертвому WinFsp-томі блокується намертво -> ізолюємо в Job.
`$ErrorActionPreference = 'SilentlyContinue'
`$log = '$wdLog'

`$alive = `$false
`$job = Start-Job { Test-Path '${drive}:\' }
if (Wait-Job `$job -Timeout 15) { `$alive = [bool](Receive-Job `$job) }
Remove-Job `$job -Force

if (-not `$alive) {
    "`$(Get-Date -f s)  mount dead -> restart" | Add-Content `$log
    Get-Process rclone | Where-Object { `$_.Path -eq '$rclone' } | Stop-Process -Force
    Start-Sleep 3
    Start-ScheduledTask -TaskName 'rclone-$ProfileName-mount'
}
"@
    [IO.File]::WriteAllText($wdPath, $wd, (New-Object Text.UTF8Encoding($true)))
    Write-Ok "Watchdog: $wdPath"
}

# ---------------------------------------------------------------------------
# 9. Реєстрація завдань Планувальника
#    Служба тут не підходить: WinFsp-монтування в сесії 0 не буде видно
#    у Провіднику користувача.
# ---------------------------------------------------------------------------
Write-Step 'Реєстрація завдань Планувальника'

$taskMount = "rclone-$ProfileName-mount"
$taskWd    = "rclone-$ProfileName-watchdog"

foreach ($tn in @($taskMount, $taskWd)) {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
    }
}

$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -MultipleInstances IgnoreNew

$action  = New-ScheduledTaskAction -Execute $rclone -Argument $argString
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser

Register-ScheduledTask -TaskName $taskMount -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

# Затримка старту (мережа має встигнути піднятись)
$t = Get-ScheduledTask -TaskName $taskMount
$t.Triggers[0].Delay = "PT${startDelay}S"
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

# ---------------------------------------------------------------------------
# 10. Стан для деінсталяції
# ---------------------------------------------------------------------------
[pscustomobject]@{
    ProfileName = $ProfileName
    Protocol    = $proto
    Drive       = "${drive}:"
    RemoteSpec  = $remoteSpec
    ConfPath    = $confPath
    CacheDir    = $cacheDir
    LogFile     = $logFile
    RclonePath  = $rclone
    TargetUser  = $TargetUser
    TaskMount   = $taskMount
    TaskWatchdog= $(if ($wantWatchdog) { $taskWd } else { $null })
    Installed   = (Get-Date -Format s)
} | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

# ---------------------------------------------------------------------------
# 11. Запуск і верифікація
# ---------------------------------------------------------------------------
Write-Step 'Запуск монтування'
Start-ScheduledTask -TaskName $taskMount

$mounted = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep 1
    if (Test-Path "${drive}:\") { $mounted = $true; break }
    Write-Host '.' -NoNewline
}
Write-Host ''

if ($mounted) {
    Write-Ok "Диск ${drive}: змонтовано"
    Get-ChildItem "${drive}:\" -ErrorAction SilentlyContinue |
        Select-Object -First 10 | ForEach-Object { Write-Info $_.Name }
} else {
    Write-Err "Диск ${drive}: не зʼявився за 20 с. Останні рядки логу:"
    if (Test-Path $logFile) { Get-Content $logFile -Tail 20 | ForEach-Object { Write-Info $_ } }
    Write-Info ''
    Write-Info 'Інтерактивний дебаг:'
    Write-Info "  Stop-ScheduledTask $taskMount"
    Write-Info "  & `"$rclone`" $($argString -replace '--no-console','' -replace 'INFO','DEBUG')"
}

# ---------------------------------------------------------------------------
# Підсумок
# ---------------------------------------------------------------------------
$taskList = $taskMount
if ($wantWatchdog) { $taskList = "$taskMount, $taskWd" }
$sep = '-' * 68

Write-Host ''
Write-Host $sep -ForegroundColor DarkGray
Write-Host " Профіль:     $ProfileName ($proto)"
Write-Host " Диск:        ${drive}:  ->  $remoteSpec"
Write-Host " Конфіг:      $confPath"
Write-Host " Кеш:         $cacheDir  (max $cacheMax / $cacheAge)"
Write-Host " Лог:         $logFile"
Write-Host " Завдання:    $taskList"
Write-Host $sep -ForegroundColor DarkGray
Write-Host @"

 Керування:
   Start-ScheduledTask $taskMount        # змонтувати
   Stop-ScheduledTask  $taskMount        # зупинити завдання
   Get-Process rclone | Stop-Process -Force   # примусово розмонтувати
   Get-Content "$logFile" -Tail 50 -Wait      # живий лог

 Видалення:
   powershell -ExecutionPolicy Bypass -File "$PSCommandPath" -Uninstall -ProfileName $ProfileName

"@ -ForegroundColor Gray

Read-Host 'Enter для виходу'
