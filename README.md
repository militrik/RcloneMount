# Install-RcloneMount

Інтерактивний PowerShell-інсталятор постійного монтування віддаленого сховища (WebDAV / SFTP) у літеру диска Windows через [rclone](https://rclone.org) + [WinFsp](https://winfsp.dev).

Заміна RaiDrive, CloudMounter, Mountain Duck та RcloneView без ліцензійних обмежень і без ручного возіння з `rclone.conf`, десятком VFS-прапорців і Планувальником завдань.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)
![License MIT](https://img.shields.io/badge/License-MIT-green)

---

## Навіщо

Вбудований WebDAV-клієнт Windows (`net use Y: https://...`) непридатний для роботи: жорсткий ліміт 50 МБ на файл (максимум 4 ГБ навіть після правки реєстру), відсутність кешу, відсутність докачки, синхронні `PROPFIND` на кожне оновлення вікна Провідника.

GUI-обгортки над rclone або платні (RcloneView ховає автомонтування за Plus-ліцензією), або тримають монтування живим лише поки відкрите вікно програми.

Цей скрипт дає те саме, що RaiDrive, але на чистому rclone: диск монтується при вході в систему, живе фоново **без консольного вікна**, автоматично перепідключається після обриву каналу.

---

## Можливості

- Перевірка та автоматичне встановлення **WinFsp** і **rclone** (winget з фолбеком на портативне розпакування)
- Детект стороннього rclone з Rclone UI / RcloneView з пропозицією поставити незалежний
- Інтерактивне опитування всіх параметрів з валідацією
- Пароль читається як `SecureString` і обфускується через **stdin** — не потрапляє в командний рядок і в історію PowerShell
- Конфіг пишеться в профіль **цільового** користувача, а не адміна, що виконав UAC-елевацію
- Злиття секції в `rclone.conf` без руйнування інших remote + автоматичний бекап
- Перевірка з'єднання (`rclone lsd`) до реєстрації завдань
- **Прихований VBS-лаунчер** — консольного вікна немає взагалі
- Три профілі кешування під різні сценарії спільної роботи
- Завдання Планувальника: монтування при вході + **watchdog** з перевіркою живості
- Скрипти зупинки та скиду кешу на вимогу
- Перемикання профілю кешування **без перевстановлення і без повторного вводу пароля**
- Підтримка довільної кількості незалежних профілів
- Повне видалення однією командою

---

## Вимоги

| Компонент | Версія | Примітка |
|---|---|---|
| Windows | 10 / 11 | x64 |
| PowerShell | 5.1+ | вбудований |
| WinFsp | 2.x | ставиться скриптом |
| rclone | 1.65+ | ставиться скриптом |
| Права | Адміністратор | UAC-елевація автоматична |

---

## Швидкий старт

```powershell
git clone https://github.com/<user>/Install-RcloneMount.git
cd Install-RcloneMount
powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1
```

> **Обов'язково `-File` або оператор виклику `&`.** Шлях у лапках без них PowerShell сприймає як строковий літерал і просто виводить його в консоль.
>
> Не запускайте з теки OneDrive: при Files On-Demand файл може бути хмарним плейсхолдером, і елевований процес не зможе його прочитати.

---

## Профілі кешування

Головне питання інсталятора. Визначає компроміс між швидкістю вашої роботи і тим, наскільки швидко ви бачите чужі зміни.

| | SOLO | SHARED *(рекомендований)* | RAIDRIVE |
|---|---|---|---|
| `--vfs-cache-mode` | full | full | writes |
| `--vfs-cache-max-age` | 72h | 24h | 1h |
| `--dir-cache-time` | 20s | 30s | 10s |
| `--attr-timeout` | 5s | 3s | 0s |
| `--vfs-write-back` | 5s | 2s | 0s |
| `--vfs-read-ahead` | 128M | 128M | 0 |
| `--no-modtime` | питається | **вимкнено** | увімкнено |
| Швидкість | найвища | висока | **низька** |

### Чому SHARED швидкий і при цьому коректний

Ключ — не короткі TTL, а **modtime**. З `--vfs-cache-mode full` і ввімкненим відстеженням дати rclone звіряє modtime при **кожному відкритті файлу**: якщо серверна копія новіша, локальна викидається і тягнеться заново.

Тому `--vfs-cache-max-age 24h` безпечний. Кеш живе довго, повторні відкриття миттєві, але застарілу копію ви не отримаєте — вона перевіряється на вході.

### Чому `--no-modtime` небезпечний у спільній теці

Прапорець вимикає не лише **запис** modtime (що Synology WebDAV усе одно відхиляє — `getlastmodified` є protected property за RFC 4918), а й **читання**. А саме за ним VFS вирішує, чи актуальна локальна копія.

Наслідок: колега змінив файл, розмір збігся — ваш rclone віддасть стару копію з кешу, і так до кінця `--vfs-cache-max-age`.

### Чому RAIDRIVE повільний

Профіль відтворює **налаштування** RaiDrive, але не його **реалізацію**. RaiDrive — нативний Windows-редиректор із власним кешуванням під патерни доступу Провідника; rclone працює через WinFsp з узагальненим VFS. Однакові назви опцій дають різну механіку.

Конкретно:

- `--attr-timeout 0s` — WinFsp не кешує атрибути взагалі. Провідник питає розмір, дату і прапорці десятки разів на кожен файл; тека на 200 файлів перетворюється на тисячі синхронних HTTP-запитів.
- `--vfs-cache-mode writes` — немає локальної копії, кожне читання йде по мережі. SOLIDWORKS читає збірки непослідовно, і кожен стрибок назад означає нове HTTP-з'єднання з іншим Range.

Профіль корисний лише для діагностики: він гарантує, що ви бачите точний стан сервера. Появу ваших файлів у колег він **не прискорює** — це визначає їхній клієнт.

---

## Решта параметрів інсталятора

### Підключення

| Параметр | Приклад | Опис |
|---|---|---|
| Протокол | `webdav` | `webdav` або `sftp` |
| Хост | `fs.example.com` | без схеми |
| Порт | `5006` | Synology WebDAV over HTTPS; `443` за reverse proxy |
| HTTPS | `Y` | схема URL |
| Vendor | `other` | для Synology DSM саме `other`, не `nextcloud`/`owncloud` |
| Логін / Пароль | — | пароль вводиться приховано |
| Самопідписаний сертифікат | `N` | вмикає `--no-check-certificate` |

### Монтування

| Параметр | Дефолт | Опис |
|---|---|---|
| **Літера диска** | **немає** | обов'язковий явний ввід; показує списки зайнятих і вільних, приймає лише D..Z |
| Підтека | *(корінь)* | монтувати не весь remote, а гілку |
| Мітка тому | *= ім'я профілю* | те, що видно в Провіднику |
| Тека кешу | `D:\rclone-cache` | бажано окремий SSD |
| Ліміт кешу | `20G` | `--vfs-cache-max-size` |
| Лише читання | `N` | `--read-only` |
| Remote control | *= режим ≠ SOLO* | `--rc` для скиду кешу на вимогу |
| Symlink як `.rclonelink` | `Y` для WebDAV | прибирає `ERROR: symlinks not supported: /` |
| Ліміт швидкості | *(немає)* | `10M` або `10M:5M` (down:up) |
| Затримка старту | `15` с | час на підняття мережі |
| Watchdog | `Y` | перевірка кожні 5 хв |

---

## Що створюється

| Артефакт | Шлях |
|---|---|
| Секція remote | `%APPDATA%\rclone\rclone.conf` |
| Бекап конфігу | `rclone.conf.bak-<timestamp>` |
| Робоча тека | `C:\rclone\` |
| **VBS-лаунчер** | `C:\rclone\<profile>.launch.vbs` |
| Скрипт зупинки | `C:\rclone\<profile>.stop.ps1` |
| Скрипт скиду кешу | `C:\rclone\<profile>.refresh.ps1` *(якщо rc увімкнено)* |
| Скрипт watchdog | `C:\rclone\<profile>.watchdog.ps1` |
| Стан для деінсталяції | `C:\rclone\<profile>.state.json` |
| Лог монтування | `C:\rclone\logs\<profile>.mount.log` |
| Лог watchdog | `C:\rclone\logs\<profile>.watchdog.log` |
| Завдання монтування | `rclone-<profile>-mount` |
| Завдання watchdog | `rclone-<profile>-watchdog` |

---

## Керування

```powershell
# Змонтувати
Start-ScheduledTask rclone-synology-mount

# Розмонтувати — Stop-ScheduledTask НЕ працює, див. нижче
powershell -ExecutionPolicy Bypass -File "C:\rclone\synology.stop.ps1"

# Побачити чужі зміни негайно, не чекаючи dir-cache-time
powershell -File "C:\rclone\synology.refresh.ps1"
powershell -File "C:\rclone\synology.refresh.ps1" -Dir "Projects/2026"

# Чи ваші зміни вже на сервері
powershell -File "C:\rclone\synology.refresh.ps1" -Stats

# Живий лог
Get-Content C:\rclone\logs\synology.mount.log -Tail 50 -Wait
```

### Перемикання профілю кешування

Без перевстановлення і без повторного вводу пароля:

```powershell
powershell -ExecutionPolicy Bypass -File .\Set-RcloneMountMode.ps1 -Mode FAST
powershell -ExecutionPolicy Bypass -File .\Set-RcloneMountMode.ps1 -Mode STRICT
powershell -ExecutionPolicy Bypass -File .\Set-RcloneMountMode.ps1 -Mode RAIDRIVE
```

| Режим | Призначення |
|---|---|
| `FAST` | = профіль SHARED інсталятора. Рекомендований для щоденної роботи |
| `STRICT` | `dir-cache 5s`, `attr-timeout 1s`, `write-back 1s`. Чужі зміни за секунди ціною гальм |
| `RAIDRIVE` | без кешу читання. Для діагностики |

Скрипт патчить **лише** прапорці кешу у вже згенерованому VBS-лаунчері. Конфіг, літера, `volname`, `--links`, сертифікат, `bwlimit` і rc лишаються недоторканими.

---

## Архітектурні рішення

### Прихований VBS-лаунчер замість прямого запуску

rclone реалізує `--no-console` через `FreeConsole()`, тобто відв'язується вже **після** того, як Windows створила вікно для console-застосунку. Порожнє вікно лишається висіти, а його закриття шле `CTRL_CLOSE_EVENT` — том розмонтовується.

Завдання Планувальника виконує `wscript.exe <profile>.launch.vbs`, а VBS запускає rclone з `intWindowStyle = 0`. Консоль не створюється взагалі.

**Наслідок:** `wscript` завершується миттєво, тому `Stop-ScheduledTask` **не** зупиняє rclone. Для розмонтування є окремий `<profile>.stop.ps1`.

### Планувальник, а не служба Windows

WinFsp-монтування, запущене зі служби, потрапляє в сесію 0 і **не буде видимим у Провіднику користувача**. Завдання реєструється з принципалом `LogonType = Interactive`, `RunLevel = Limited` і тригером At logon.

Наслідок: диск існує лише всередині сесії користувача — зникає при logout. Це навмисно.

### Елевована сесія не бачить змонтований том

`Test-Path Y:\` з-під адміністратора повертає `$false`, навіть коли диск працює. Мережеві підключення прив'язані до logon session, а UAC видає процесу токен з іншим LUID — той самий механізм, через який `net use`-диски не видно в елевованому cmd.

Тому верифікація в інсталяторі спирається на живий процес rclone плюс маркер `service rclone has been started` у лозі, а `Test-Path` — лише додатковий сигнал.

Щоб елевовані процеси теж бачили том:

```powershell
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name EnableLinkedConnections -PropertyType DWord -Value 1 -Force
```
Потребує перезавантаження. Впливає на всі мережеві мапінги.

### Watchdog ізолює перевірку в Job

`Test-Path 'Y:\'` на мертвому WinFsp-томі блокується намертво і повісив би сам watchdog. Перевірка виноситься в `Start-Job` з `Wait-Job -Timeout 15` і `Remove-Job -Force`.

### Кодування файлів

Скрипти збережено в **UTF-8 з BOM** — PowerShell 5.1 читає `.ps1` без BOM як ANSI, і кирилиця в промптах перетворюється на сміття.

`rclone.conf` навпаки пишеться в **UTF-8 без BOM** — саме цього очікує rclone.

VBS-лаунчер пишеться в **ANSI**: `wscript.exe` на UTF-8 з BOM видає `Invalid character` на першому рядку.

---

## Кілька профілів

Параметр `-ProfileName` ізолює ім'я remote, імена завдань, лог і state:

```powershell
.\Install-RcloneMount.ps1 -ProfileName nas-work
.\Install-RcloneMount.ps1 -ProfileName nas-archive
.\Set-RcloneMountMode.ps1 -Mode FAST -ProfileName nas-work
```

---

## Видалення

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1 -Uninstall -ProfileName synology
```

Знімає обидва завдання, зупиняє процеси rclone (фільтр за шляхом бінарника), видаляє VBS-лаунчер і допоміжні скрипти, окремо запитує про кеш і секцію конфігу.

---

## Діагностика

### Диск не з'явився

```powershell
# Спершу — у ЗВИЧАЙНОМУ, не елевованому PowerShell
Test-Path Y:\
Get-Process rclone | Select-Object Id, Path, MainWindowHandle
```

`MainWindowHandle = 0` підтверджує, що консольного вікна немає.

```powershell
Get-Content C:\rclone\logs\synology.mount.log -Tail 30
```

Інтерактивний запуск тієї ж команди з `--log-level DEBUG` покаже причину напряму.

### Типові помилки

| Симптом | Причина | Рішення |
|---|---|---|
| Скрипт вивів свій шлях і завершився | запущено без `&` або `-File` | `powershell -File .\Install-RcloneMount.ps1` |
| `x509: certificate signed by unknown authority` | самопідписаний сертифікат | імпортувати CA в `Cert:\LocalMachine\Root` або `--no-check-certificate` |
| `cannot find winfsp` | WinFsp не встановлено | встановити з [winfsp.dev/rel](https://winfsp.dev/rel/) і перезавантажитись |
| `symlinks not supported: /` | Synology віддає службовий елемент у корені | `--links` (питається інсталятором) |
| Висить порожня консоль rclone | стара версія без VBS-лаунчера | перевстановити |
| `Stop-ScheduledTask` не розмонтовує | завдання запускає wscript | `<profile>.stop.ps1` |
| Диск є, але з адмін-консолі не видно | `EnableLinkedConnections` | див. вище |
| Різке гальмування Провідника | `--attr-timeout 0s` | `Set-RcloneMountMode.ps1 -Mode FAST` |
| Бачу стару версію чужого файлу | `--no-modtime` при `cache-mode full` | `Set-RcloneMountMode.ps1 -Mode FAST` |
| Помилка 401 після зміни пароля | застарілий obscured-пароль | перезапустити інсталятор |

---

## Спільна робота

### Що працює

Ваш бік налаштовується повністю: `--vfs-write-back` визначає, як швидко закритий файл потрапляє на сервер; `--dir-cache-time` і refresh-скрипт — як швидко ви бачите чужі зміни.

### Чого ви не контролюєте

WebDAV не має механізму сповіщень. Сервер нікого не повідомляє про зміни — кожен клієнт опитує його за власним розкладом. Якщо колега працює через RaiDrive з «Асинхронне оновлення змін сховища = auto», момент, коли він побачить ваш файл, визначає **його** клієнт. Жоден прапорець з вашого боку на це не впливає.

Типова затримка — десятки секунд.

### Як визначити, чий це бік

Відкрийте **DSM File Station у браузері** одразу після збереження. Браузер не користується ні вашим rclone, ні його клієнтом — ви бачите справжній стан сервера.

- Файл у File Station є, у колеги немає → його клієнт. З вашого боку не лікується.
- Файл у File Station з'являється із затримкою → ваш бік, перевіряйте `refresh.ps1 -Stats`.

### Блокувань немає

**rclone не реалізує WebDAV `LOCK`/`UNLOCK`.** Ні ви, ні колега не побачите, що файл відкритий іншим. Одночасне редагування = хто зберіг останнім, той і переміг, мовчки.

RaiDrive має опцію «Блокування файлів» (платна). Якщо вся команда на RaiDrive і опція ввімкнена — захист працює. Перехід частини команди на rclone робить його однобічним, тобто неіснуючим.

Додатково: rclone для WebDAV пише `PUT` одразу на кінцевий шлях, без тимчасового імені. Під час завантаження великого файлу він існує на сервері обрізаним, і хто відкриє його в цей момент — отримає пошкоджені дані.

Для багатокористувацької роботи над спільними файлами потрібен PDM/VCS або SMB з реальним oplock через VPN. Монтування будь-якого типу цього не замінює.

---

## Альтернативи

| Інструмент | Ліцензія | Автомонтування | Примітка |
|---|---|---|---|
| Цей скрипт | MIT | ✅ | rclone напряму, без прошарків |
| [Rclone UI](https://rcloneui.com) | Open source | ✅ | Rust + Tauri, GUI, cron-задачі |
| [RClone Manager](https://github.com/Zarestia-Dev/rclone-manager) | GPLv3 | ✅ | Angular + Tauri |
| [RcloneView](https://rcloneview.com) | Freemium | ⚠️ Plus | найближчий до RaiDrive за UX |
| RaiDrive | Freemium | ✅ | не на rclone; має WebDAV-блокування |
| Вбудований WebDAV Windows | — | ✅ | ліміт 4 ГБ, без кешу |

---

## Ліцензія

MIT
