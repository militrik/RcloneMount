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

Цей скрипт дає те саме, що RaiDrive, але на чистому rclone: диск монтується при вході в систему, живе фоново, автоматично перепідключається після обриву каналу.

---

## Можливості

- Перевірка та автоматичне встановлення **WinFsp** і **rclone** (winget з фолбеком на портативне розпакування)
- Інтерактивне опитування всіх параметрів з валідацією
- Пароль читається як `SecureString` і обфускується через **stdin** — не потрапляє в командний рядок і в історію PowerShell
- Конфіг пишеться в профіль **цільового** користувача, а не адміна, що виконав UAC-елевацію
- Злиття секції в `rclone.conf` без руйнування інших remote + автоматичний бекап
- Перевірка з'єднання (`rclone lsd`) до реєстрації завдань
- Завдання Планувальника: монтування при вході + **watchdog** з перевіркою живості
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

Скрипт сам підніметься через UAC і проведе через усі кроки.

---

## Параметри, які запитує інсталятор

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
| Літера диска | `Y` | перевіряється на зайнятість, включно з `net use`-мапінгами |
| Підтека | *(корінь)* | монтувати не весь remote, а гілку |
| Мітка тому | *= ім'я профілю* | те, що видно в Провіднику |
| Тека кешу | `D:\rclone-cache` | бажано окремий SSD |
| Ліміт кешу | `20G` | `--vfs-cache-max-size` |
| Час життя кешу | `72h` | `--vfs-cache-max-age` |
| TTL кешу директорій | `20s` | менше = швидше видно чужі зміни |
| Лише читання | `N` | `--read-only` |
| Ігнорувати modtime | `Y` для WebDAV | `--no-modtime` |
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
| Лог монтування | `C:\rclone\logs\<profile>.mount.log` |
| Лог watchdog | `C:\rclone\logs\<profile>.watchdog.log` |
| Скрипт watchdog | `C:\rclone\<profile>.watchdog.ps1` |
| Стан для деінсталяції | `C:\rclone\<profile>.state.json` |
| Завдання монтування | `rclone-<profile>-mount` |
| Завдання watchdog | `rclone-<profile>-watchdog` |

---

## Обґрунтування ключових прапорців

**`--vfs-cache-mode full`** — не опція, а вимога. WebDAV не підтримує range-write; без повного кешу будь-який `seek()` на запис (а САПР та офісні пакети роблять це постійно) або провалиться, або перезаллє файл цілком. У режимі `full` rclone тримає локальну копію, працює з нею як зі звичайним файлом і відвантажує асинхронно.

**`--cache-dir` на окремий диск** — за замовчуванням кеш лягає в `%LOCALAPPDATA%\rclone`, тобто на системний SSD. Для 20 ГБ робочих файлів це погана ідея.

**`--dir-cache-time 20s`** — WebDAV не має ChangeNotify, тому `--poll-interval` тут не працює взагалі. Єдиний спосіб побачити чужі зміни — короткий TTL кешу директорій. 20 с — компроміс між штурмом `PROPFIND`-ами і застарілим лістингом.

**`--no-modtime`** — Synology WebDAV не приймає `PROPPATCH` на `getlastmodified`. Без цього прапорця rclone робить зайвий запит на кожен `stat`, який усе одно провалюється. Ціна: дата зміни на диску = час запису на сервері. Якщо modtime критичний — використовуйте SFTP.

**`--attr-timeout 5s`** — WinFsp кешує атрибути; підвищення з дефолтної 1 с помітно прискорює обхід дерева тек Провідником.

**`--vfs-write-back 5s`** — затримка перед відвантаженням. Багато застосунків пишуть великий файл кількома проходами; затримка не дає заливати проміжні стани.

**`--network-mode`** — диск виглядає як мережевий, а не локальний. Уникає спроб Windows індексувати том як локальний.

**`--no-console`** — прибирає вікно консолі, критично для автозапуску.

---

## Архітектурні рішення

### Планувальник, а не служба Windows

WinFsp-монтування, запущене зі служби, потрапляє в сесію 0 і **не буде видимим у Провіднику користувача**. Тому завдання реєструється з принципалом `LogonType = Interactive`, `RunLevel = Limited` і тригером At logon.

Наслідок: диск існує лише всередині сесії користувача — зникає при logout. Це навмисно.

### Watchdog ізолює перевірку в Job

`Test-Path 'Y:\'` на мертвому WinFsp-томі блокується намертво і повісив би сам watchdog. Перевірка виноситься в `Start-Job` з `Wait-Job -Timeout 15` і `Remove-Job -Force`, що дає гарантований вихід.

### Кодування файлів

Сам скрипт збережено в **UTF-8 з BOM** — PowerShell 5.1 читає `.ps1` без BOM як ANSI, і кирилиця в промптах перетворюється на сміття.

`rclone.conf` навпаки пишеться в **UTF-8 без BOM** — саме цього очікує rclone.

---

## Кілька профілів

Один скрипт обслуговує довільну кількість підключень. Параметр `-ProfileName` ізолює ім'я remote, імена завдань, лог і state:

```powershell
.\Install-RcloneMount.ps1 -ProfileName nas-work
.\Install-RcloneMount.ps1 -ProfileName nas-archive
.\Install-RcloneMount.ps1 -ProfileName backup-sftp
```

---

## Керування

```powershell
# Змонтувати вручну
Start-ScheduledTask rclone-synology-mount

# Зупинити завдання
Stop-ScheduledTask rclone-synology-mount

# Примусово розмонтувати
Get-Process rclone | Stop-Process -Force

# Живий лог
Get-Content C:\rclone\logs\synology.mount.log -Tail 50 -Wait

# Статус завдань
Get-ScheduledTask rclone-* | Format-Table TaskName, State
```

---

## Видалення

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RcloneMount.ps1 -Uninstall -ProfileName synology
```

Знімає обидва завдання, зупиняє процеси rclone (фільтр за шляхом бінарника), окремо запитує про видалення кешу і секції конфігу.

---

## Діагностика

### Диск не з'явився

```powershell
Stop-ScheduledTask rclone-synology-mount
Get-Content C:\rclone\logs\synology.mount.log -Tail 30
```

Інтерактивний запуск тієї ж команди без `--no-console` і з `--log-level DEBUG` покаже причину напряму.

### Типові помилки

| Симптом | Причина | Рішення |
|---|---|---|
| `x509: certificate signed by unknown authority` | самопідписаний сертифікат | імпортувати CA в `Cert:\LocalMachine\Root` або `--no-check-certificate` |
| `cannot find winfsp` | WinFsp не встановлено | встановити з [winfsp.dev/rel](https://winfsp.dev/rel/) і перезавантажитись |
| `mount failed: drive letter in use` | літера зайнята | звільнити або обрати іншу |
| Диск є, але порожній | remote вказує на неіснуючу підтеку | перевірити `rclone lsd synology:` |
| Повільний обхід тек | занадто малий `--dir-cache-time` | підняти до `60s`, якщо працюєте одноосібно |
| Помилка 401 після зміни пароля | застарілий obscured-пароль | перезапустити інсталятор — секція перезапишеться |

### Перевірка remote без монтування

```powershell
rclone lsd synology: -vv
rclone about synology:          # квота (Synology зазвичай не віддає)
rclone ls synology: --max-depth 1
```

---

## Обмеження

**Немає справжніх блокувань файлів.** WinFsp + VFS не транслюють byte-range locks на WebDAV-сервер. Одночасне відкриття одного файлу з двох машин через rclone-монтування не дасть попередження «файл зайнятий» — ви отримаєте розбіжні версії. Це стосується будь-якого монтування (RaiDrive, CloudMounter, вбудований WebDAV) однаковою мірою.

Для багатокористувацької роботи над спільними файлами потрібен PDM/VCS або SMB з реальним oplock через VPN, а не монтування.

**Диск живе в сесії користувача.** Недоступний до входу в систему і після logout. Якщо потрібен доступ із служби, що працює під іншим акаунтом — монтуйте як UNC-шару (`rclone mount remote: \\name\share --network-mode`) через NSSM.

**WebDAV повільний на дрібних файлах.** Кожна операція — окремий HTTP-запит. Для тек із тисячами дрібних файлів SFTP суттєво швидший і додатково зберігає коректний modtime та хеші.

---

## Альтернативи

| Інструмент | Ліцензія | Автомонтування | Примітка |
|---|---|---|---|
| Цей скрипт | MIT | ✅ | rclone напряму, без прошарків |
| [Rclone UI](https://rcloneui.com) | Open source | ✅ | Rust + Tauri, GUI, cron-задачі |
| [RClone Manager](https://github.com/Zarestia-Dev/rclone-manager) | GPLv3 | ✅ | Angular + Tauri |
| [RcloneView](https://rcloneview.com) | Freemium | ⚠️ Plus | найближчий до RaiDrive за UX |
| RaiDrive | Freemium | ✅ | не на rclone |
| Вбудований WebDAV Windows | — | ✅ | ліміт 4 ГБ, без кешу |

---

## Ліцензія

MIT
