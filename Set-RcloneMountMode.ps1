#Requires -Version 5.1
<#
.SYNOPSIS
    Перемикає профіль кешування існуючого rclone-монтування без перевстановлення.

.DESCRIPTION
    Патчить лише прапорці кешу в уже згенерованому VBS-лаунчері: cache-mode,
    attr-timeout, dir-cache-time, write-back, cache-max-age, poll-interval,
    read-ahead, no-modtime. Решта (конфіг, літера, volname, links, сертифікат,
    bwlimit, rc) лишається незмінною, тож пароль перевводити не треба.

.PARAMETER Mode
    FAST   - cache-mode full, довгий кеш, modtime увімкнено. Рекомендований.
    STRICT - те саме, але короткі TTL: чужі зміни видно за ~5 с ціною гальм.
    RAIDRIVE - без кешу читання, як у RaiDrive. Найповільніший.

.PARAMETER ProfileName
    Ім'я профілю (= ім'я remote). За замовчуванням 'synology'.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Set-RcloneMountMode.ps1 -Mode FAST

.NOTES
    Файл має бути збережений у UTF-8 з BOM.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('FAST','STRICT','RAIDRIVE')]
    [string] $Mode,

    [string] $ProfileName = 'synology'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Ok    { param($m) Write-Host "[ok] $m" -ForegroundColor Green }
function Write-Err   { param($m) Write-Host "[XX] $m" -ForegroundColor Red }
function Write-Info  { param($m) Write-Host "     $m" -ForegroundColor Gray }
function Write-Warn2 { param($m) Write-Host "[!!] $m" -ForegroundColor Yellow }

# --- Елевація ---------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn2 'Потрібні права адміністратора. Перезапуск через UAC...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass'
        '-File', "`"$PSCommandPath`""
        '-Mode', $Mode, '-ProfileName', $ProfileName
    )
    exit
}

$InstallRoot = 'C:\rclone'
$StateFile   = Join-Path $InstallRoot "$ProfileName.state.json"
$LaunchVbs   = Join-Path $InstallRoot "$ProfileName.launch.vbs"
$TaskMount   = "rclone-$ProfileName-mount"

if (-not (Test-Path $LaunchVbs)) {
    Write-Err "Лаунчер не знайдено: $LaunchVbs"
    Write-Info 'Спершу виконайте Install-RcloneMount.ps1.'
    Read-Host 'Enter'; exit 1
}

# --- Набори прапорців -------------------------------------------------------
# FAST спирається не на короткі TTL, а на modtime: з cache-mode full rclone
# звіряє дату при кожному відкритті файлу і перезавантажує, якщо серверна
# новіша. Тому довгий max-age безпечний, а повторні відкриття миттєві.
$profiles = @{
    FAST = @{
        'vfs-cache-mode'          = 'full'
        'vfs-cache-max-age'       = '24h'
        'vfs-cache-poll-interval' = '1m'
        'vfs-read-ahead'          = '128M'
        'vfs-write-back'          = '2s'
        'dir-cache-time'          = '30s'
        'attr-timeout'            = '3s'
        'no-modtime'              = $false
    }
    STRICT = @{
        'vfs-cache-mode'          = 'full'
        'vfs-cache-max-age'       = '6h'
        'vfs-cache-poll-interval' = '30s'
        'vfs-read-ahead'          = '128M'
        'vfs-write-back'          = '1s'
        'dir-cache-time'          = '5s'
        'attr-timeout'            = '1s'
        'no-modtime'              = $false
    }
    RAIDRIVE = @{
        'vfs-cache-mode'          = 'writes'
        'vfs-cache-max-age'       = '1h'
        'vfs-cache-poll-interval' = '30s'
        'vfs-read-ahead'          = '0'
        'vfs-write-back'          = '0s'
        'dir-cache-time'          = '10s'
        'attr-timeout'            = '0s'
        'no-modtime'              = $true
    }
}
$p = $profiles[$Mode]

# --- Витягування командного рядка з VBS -------------------------------------
# Формат рядка: sh.Run "<cmd з подвоєними лапками>", 0, False
$vbs = Get-Content -LiteralPath $LaunchVbs -Raw -Encoding Default
if ($vbs -notmatch '(?m)^sh\.Run\s+"(.*)",\s*0,\s*False\s*$') {
    Write-Err 'Не вдалося розібрати VBS-лаунчер.'
    Read-Host 'Enter'; exit 1
}
$cmd = $Matches[1] -replace '""','"'     # знімаємо подвоєння
Write-Info 'Поточні прапорці:'
foreach ($k in @('vfs-cache-mode','attr-timeout','dir-cache-time','vfs-write-back')) {
    if ($cmd -match "--$k\s+(\S+)") { Write-Info "  --$k $($Matches[1])" }
}

# --- Патчинг ----------------------------------------------------------------
foreach ($key in @('vfs-cache-mode','vfs-cache-max-age','vfs-cache-poll-interval',
                   'vfs-read-ahead','vfs-write-back','dir-cache-time','attr-timeout')) {
    $val = $p[$key]
    if ($cmd -match "--$key\s+\S+") {
        $cmd = $cmd -replace "--$key\s+\S+", "--$key $val"
    } else {
        $cmd = $cmd + " --$key $val"     # прапорця не було - дописуємо
    }
}

# --no-modtime не має значення, тож додаємо/прибираємо цілком
$cmd = $cmd -replace '\s--no-modtime\b', ''
if ($p['no-modtime']) { $cmd = $cmd + ' --no-modtime' }

$cmd = ($cmd -replace '\s{2,}', ' ').Trim()

# --- Перезапис VBS ----------------------------------------------------------
$cmdEsc = $cmd -replace '"','""'
$vbsBody = @"
' Hidden launcher for rclone mount. Profile: $ProfileName
' Patched by Set-RcloneMountMode.ps1 -- mode: $Mode
' intWindowStyle = 0     -> no console window
' bWaitOnReturn  = False -> wscript exits at once, rclone keeps running detached
Set sh = CreateObject("WScript.Shell")
sh.Run "$cmdEsc", 0, False
"@
# wscript читає .vbs як ANSI
Set-Content -LiteralPath $LaunchVbs -Value $vbsBody -Encoding Default
Write-Ok "Лаунчер оновлено: режим $Mode"

Write-Info 'Нові прапорці:'
foreach ($k in @('vfs-cache-mode','attr-timeout','dir-cache-time','vfs-write-back',
                 'vfs-cache-max-age')) {
    if ($cmd -match "--$k\s+(\S+)") { Write-Info "  --$k $($Matches[1])" }
}
if ($cmd -match '--no-modtime') { Write-Info '  --no-modtime' }
else { Write-Info '  modtime: увімкнено (виявлення чужих змін)' }

# --- Оновлення state --------------------------------------------------------
if (Test-Path $StateFile) {
    try {
        $st = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $st | Add-Member -NotePropertyName Mode         -NotePropertyValue $Mode -Force
        $st | Add-Member -NotePropertyName VfsCacheMode -NotePropertyValue $p['vfs-cache-mode'] -Force
        $st | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    } catch { Write-Warn2 "state.json не оновлено: $($_.Exception.Message)" }
}

# --- Перезапуск монтування --------------------------------------------------
# Прапорці читаються лише при старті процесу, тож потрібен саме перезапуск.
$rcloneExe = $null
if ($cmd -match '^"([^"]+)"') { $rcloneExe = $Matches[1] }

$killed = @(Get-Process rclone -ErrorAction SilentlyContinue |
            Where-Object { -not $rcloneExe -or $_.Path -eq $rcloneExe })
if ($killed.Count -gt 0) {
    $killed | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
    Write-Ok "Зупинено процесів: $($killed.Count)"
}

Start-ScheduledTask -TaskName $TaskMount
Start-Sleep 2

$proc = @(Get-Process rclone -ErrorAction SilentlyContinue |
          Where-Object { -not $rcloneExe -or $_.Path -eq $rcloneExe })
if ($proc.Count -gt 0) {
    Write-Ok "rclone перезапущено (PID $($proc[0].Id))"
    Write-Info 'Перевірте диск у ЗВИЧАЙНОМУ PowerShell, не в цьому елевованому вікні.'
} else {
    Write-Err 'rclone не піднявся. Дивіться лог:'
    Write-Info "  Get-Content `"$InstallRoot\logs\$ProfileName.mount.log`" -Tail 30"
}

Read-Host 'Enter для виходу'
