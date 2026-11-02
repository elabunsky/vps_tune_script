# vps_tune_script

Набор скриптов и настроек для небольшого Linux VPS (VPN-сервер / тг-боты на ~1 ГБ RAM), который устраняет типовые симптомы деградации:

1. **Фризы, «зависание» SSH** — при переполнении conntrack-таблицы ядро начинает дропать пакеты новых соединений.
2. **Ложное ощущение дискового свопа** — когда холодные страницы вытесняются на диск, а не в быстрый zram.
3. **Тормоза и разрывы под нагрузкой** — маленькие сетевые буферы и очереди, копящиеся TIME_WAIT-сокеты.
4. **Неправильный сниффинг xray** — `fakedns` и `quic` в `destOverride` ломают/замедляют проксирование реального трафика.
5. **Ограничения Nginx** — низкие лимиты файловых дескрипторов systemd/master и worker-процессов, маленький `worker_connections`.

Настройки сохраняются в sysctl/modprobe, systemd и конфигурациях соответствующих сервисов. Nginx получает изменения workers через reload, а лимит master от systemd — при следующем запуске либо с `--restart-nginx`. Секция Nginx идемпотентна: повторный запуск с теми же значениями не переписывает файлы, не создаёт новые backup и не перезагружает сервис. Полный запуск также меняет DNS, swap, сеть и xray; для отдельной настройки Nginx используйте `--nginx-only`.

Поддерживается Linux с systemd, прежде всего Debian/Ubuntu. Нужны root и `python3` для секции Nginx. Если Nginx не установлен, секция пропускается; скрипт его не устанавливает.

## Что настраивает

### 1. Своп / zram
Скрипт проверяет наличие `/dev/zram0`: если его нет — устанавливает пакет модулей ядра (`linux-modules-extra`, при необходимости), создаёт zram-устройство **900 МБ, lz4, приоритет 100** (как на эталонном сервере) и сохраняет автозапуск через systemd-юнит `zram-setup.service`. Если zram уже есть — только тюнит поведение.

| Параметр | Значение | Зачем |
|---|---|---|
| `vm.swappiness` | `60` | Разрешать выгрузку холодных страниц при дефиците RAM, включая серверы с дисковым swap |
| `vm.page-cluster` | `0` | Вытеснять страницы по одной — правильное поведение для zram |

### 2. Conntrack
| Параметр | Значение | Зачем |
|---|---|---|
| `nf_conntrack_max` | `65536` | Вместо дефолтных 8192 — иначе таблица переполняется и ядро дропает пакеты новых соединений |
| hashsize | `16384` | Размер хэш-таблицы (`max / 4`), переживает ребут через `modprobe.d`; большее текущее значение сохраняется |
| `nf_conntrack_tcp_timeout_established` | `86400` | Записи «мертвых» TCP-сессий живут сутки, а не 5 дней — меньше мусора в таблице |

Более высокий текущий `nf_conntrack_max` и более короткий established timeout сохраняются и в runtime, и в файле для следующей загрузки.

### 3. TCP-стек (буферы и очереди)
| Параметр | Значение | Зачем |
|---|---|---|
| `net.ipv4.tcp_rmem` / `tcp_wmem` | `4096 87380 16777216` / `4096 87380 16777216` | Буферы приёма/передачи: min/default/max. Потолок 16 МБ — чтобы длинные VPN-туннели не упирались в буфер |
| `net.core.rmem_max` / `wmem_max` | `16777216` | Абсолютный потолок буферов сокета |
| `net.core.default_qdisc` / `tcp_congestion_control` | `fq` / `bbr` | BBR поверх fq — проверенная связка для прокси-сервера |
| `net.ipv4.ip_forward` | `1` | Форвардинг пакетов — обязателен для VPN-сервера |
| `net.ipv4.tcp_fin_timeout` | `20` | Таймаут осиротевших соединений FIN_WAIT_2 (не TIME_WAIT) |
| `net.ipv4.tcp_tw_reuse` | `1` | Переиспользовать сокеты в TIME_WAIT для новых соединений |
| `net.ipv4.tcp_max_syn_backlog` | `8192` | Очередь полуоткрытых SYN — запас на всплески подключений VPN-клиентов |
| `net.core.somaxconn` | `4096` | Глубина accept-очереди (nginx/xray) |
| `net.core.netdev_max_backlog` | `8192` | Очередь входящих пакетов в ядре |
| `net.ipv4.tcp_syncookies` | `1` | Выживание при SYN-flood |
| `net.ipv4.tcp_fastopen` | `3` | TCP Fast Open на клиент и сервер — минус один RTT на установку |
| `net.ipv4.tcp_keepalive_time` | `300` | Через сколько простоя слать keepalive-пробы — мёртвые соединения выявляются быстрее |
| `net.ipv4.tcp_notsent_lowat` | `131072` | Не копить большие неотправленные очереди в сокете — ниже задержка |

### 4. Сниффинг xray
Скрипт находит конфиги xray (x-ui и standalone) и убирает `fakedns` и `quic` из `sniffing.destOverride` у всех inbound. Эти протоколы в сниффинге ломают/замедляют проксирование реального трафика. Изменение требует рестарта xray: `sudo ./tune.sh --restart-xray` (или через панель x-ui).

### 5. DNS-кэш
Ставит **dnsmasq** как системный резолвер вместо stub'а systemd-resolved. Кэш 10000 записей и `min-cache-ttl=3600` — записи держатся минимум час, даже если upstream-TTL короткий (у google ~300с). На боевом боксе это опустило `systemd-resolved` с 4.1% → 0.3% CPU и убрало шторм upstream-DNS (~98 запр/сек). Cutover безопасный: dnsmasq сначала поднимается и проверяется, и только потом переключается `/etc/resolv.conf` (который дополнительно защищается `chattr +i` от перезаписи cloud-init'ом при будущих загрузках). Tailscale MagicDNS сохраняется через форвард `*.ts.net` → `100.100.100.100` (автодетект tailscale0).

### 6. Nginx: файловые дескрипторы и соединения

| Параметр | Минимальная цель | Контекст |
|---|---|---|
| `LimitNOFILE` | `262144` для soft и hard | Управляемый drop-in `nginx.service`; сохраняется больший существующий soft/hard |
| `worker_rlimit_nofile` | `262144` | `main`, лимит каждого worker |
| `worker_connections` | `32768` | `events`, соединения на worker |

Более высокие текущие значения сохраняются. Лимит worker дополнительно увеличивается, если нужен запас `worker_connections + 1024` для логов и других файлов. `fs.nr_open` проверяется, но не меняется; если нужное значение превышает потолок ядра, секция завершается ошибкой до изменения файлов. `fs.file-max`, глобальные лимиты systemd и `/etc/security/limits.conf` эта секция не меняет.

`worker_connections` учитывает клиентские **и upstream-соединения**: reverse proxy обычно расходует как минимум два соединения на клиента. Это ёмкость, а не обещание выдержать столько клиентов: RAM, TLS и приложение могут ограничить нагрузку раньше. `worker_processes` и выбор event method остаются прежними.

Секция поддерживает обычный `nginx.service` с root master, тем же бинарником из PATH и его стандартным конфигом (`--conf-path` из `nginx -V`). Читает `include` в `main` и `events`, обновляет существующие директивы в их файлах, сохраняет комментарии; симлинки конфигов сохраняются, меняются их целевые файлы. Custom `-c`/`-p`, обёртки запуска, бесконечные лимиты и неоднозначная/неподдерживаемая структура конфигурации требуют ручной настройки. В этом случае файлы не меняются.

Порядок применения:

1. Проверить исходный конфиг через `nginx -t`, рассчитать значения и заблокировать параллельный запуск секции.
2. Сохранить изменяемые файлы и `manifest.json` в отдельный каталог `/var/backups/vps-tune/nginx/<timestamp>-<random>/`. В manifest `null` означает, что файл до запуска отсутствовал.
3. Атомарно заменить конфиги, выполнить `nginx -t` и `systemctl daemon-reload`, проверить эффективные soft/hard лимиты systemd.
4. Для работающего Nginx выполнить reload при изменении конфигурации или устаревших лимитах workers, дождаться новых workers и проверить их реальные soft/hard лимиты через `/proc`. Остановленный сервис оставить остановленным.
5. При ошибке записи, проверки, reload/restart или проверки workers восстановить прежние файлы, удалить новые, перечитать systemd и при необходимости восстановить работу сервиса. Backup сохраняется; ошибка восстановления выводится отдельно. Откат относится только к секции Nginx, а не к уже применённым DNS/sysctl/xray изменениям. SIGKILL, отключение питания и параллельное редактирование сторонними программами не покрываются транзакцией.

Обычный **reload не изменяет лимиты существующего master**. `--restart-nginx` перезапускает активный сервис, только если лимит master ниже требуемого, и проверяет результат. Рестарт кратковременно прерывает соединения; без флага секция сообщает о необходимости рестарта. При повторном запуске без изменений и без флага рестарта reload/restart не выполняется. `--nginx-only --dry-run` показывает план без записи файлов и без reload/restart.

На проверенном сервере исходно были systemd/master `1024:524288`, workers `65535:65535` и `worker_connections=32768`. План сохраняет service hard-limit `524288`, поднимает service soft до `524288` и workers до `262144`. Это пример, фактические значения скрипт определяет на каждом сервере.

Документация: [Nginx core directives](https://nginx.org/en/docs/ngx_core_module.html), [systemd.exec resource limits](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Process%20Properties).

## Использование

```bash
cd ~/vps_tune_script
sudo ./tune.sh                 # применить все секции (включая dnsmasq-кэш)
sudo ./tune.sh --dry-run       # показать, что изменится, не меняя ничего
sudo ./tune.sh --restart-xray  # после патча сниффинга — рестарт x-ui/xray
sudo ./tune.sh --nginx-only --dry-run  # только план Nginx
sudo ./tune.sh --nginx-only            # Nginx: backup + проверка + reload
sudo ./tune.sh --nginx-only --restart-nginx  # применить лимиты master сейчас
./stat.sh                      # сводка здоровья (без root, ничего не меняет)
```

## Как проверять результат

`./stat.sh` показывает всё необходимое одной панелью: RAM, своп/zram со сжатием, zram-трафик, conntrack (заполненность + дропы `table full`), PSI, топ процессов, лимиты ядра/systemd и реальные FD-лимиты master/workers Nginx с числом открытых файлов. Без root некоторые данные `/proc` недоступны — для полного отчёта запустите `sudo ./stat.sh`. Для справки те же проверки вручную:

```bash
sysctl vm.swappiness vm.page-cluster net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count   # текущая заполненность
dmesg -T | grep "table full"                     # не должно появляться новых строк
cat /proc/pressure/cpu /proc/pressure/memory     # PSI: full ≈ 0 = нет фризов
ss -s                                            # состояние сокетов
sudo nginx -t
systemctl show nginx -p LimitNOFILE -p LimitNOFILESoft
sudo cat /proc/$(systemctl show nginx -p MainPID --value)/limits
python3 -m unittest discover -s tests -v           # тесты без root и без изменения сервисов
```

## Какие файлы создаёт/правит

```
/etc/sysctl.d/99-swap.conf          # vm.swappiness, vm.page-cluster
/etc/sysctl.d/99-conntrack.conf     # nf_conntrack_max, timeout
/etc/sysctl.d/99-tune-net.conf      # tcp/core параметры
/etc/modprobe.d/nf_conntrack-hashsize.conf
<path к конфигу xray>               # sniffing.destOverride
/etc/nginx/nginx.conf              # worker_rlimit_nofile / events; также их include-файлы
/etc/systemd/system/nginx.service.d/zz-vps-tune-nofile.conf
/var/backups/vps-tune/nginx/         # исходные файлы + manifest.json
/etc/dnsmasq.d/vps-tune.conf
/etc/systemd/resolved.conf
/etc/resolv.conf                    # DNS; chattr +i при полном запуске
/usr/local/sbin/zram-setup.sh
/etc/systemd/system/zram-setup.service
/etc/x-ui/x-ui.db                   # sniffing в БД панели, если есть
```

---

# vps_tune_script

A set of scripts and settings for a small Linux VPS (VPN server / Telegram bots on ~1 GB RAM) that fixes typical degradation symptoms:

1. **Freezes / SSH «hangs»** — when the kernel conntrack table overflows, the kernel starts dropping packets of new connections.
2. **The false impression of disk swap** — when cold pages are evicted to disk instead of into fast zram.
3. **Sluggishness and disconnects under load** — small network buffers and queues, accumulating TIME_WAIT sockets.
4. **Wrong xray sniffing** — `fakedns` and `quic` in `destOverride` break/slow down proxying of real traffic.
5. **Nginx capacity limits** — low systemd/master and worker file descriptor limits and a small `worker_connections`.

Settings persist through sysctl/modprobe, systemd and service configuration files. Nginx workers receive changes through reload; the master receives systemd limits on its next start or with `--restart-nginx`. The Nginx section is idempotent: an unchanged run does not rewrite files, create backups or reload the service. A full run also changes DNS, swap, networking and xray; use `--nginx-only` to tune Nginx independently.

Requires Linux with systemd, primarily Debian/Ubuntu. The Nginx section needs root and `python3`. If Nginx is absent, this section is skipped; the script does not install it.

## What it configures

### 1. Swap / zram
The script checks whether `/dev/zram0` exists: if not, it installs the kernel modules package (`linux-modules-extra`, when needed), creates a **900 MB, lz4, priority 100** zram device (matching the reference server) and persists auto-start via the `zram-setup.service` systemd unit. If zram already exists, it only tunes the behaviour.

| Parameter | Value | Why |
|---|---|---|
| `vm.swappiness` | `60` | Allow cold pages to move to swap under memory pressure, including disk swap |
| `vm.page-cluster` | `0` | Swap pages one at a time — the correct behaviour for zram |

### 2. Conntrack
| Parameter | Value | Why |
|---|---|---|
| `nf_conntrack_max` | `65536` | Instead of the default 8192 — otherwise the table overflows and the kernel drops packets of new connections |
| hashsize | `16384` | Hash table size (`max / 4`), survives reboot via `modprobe.d`; preserves a higher current value |
| `nf_conntrack_tcp_timeout_established` | `86400` | Dead TCP session records live one day instead of five — less garbage in the table |

A higher current `nf_conntrack_max` and a shorter established timeout are preserved both at runtime and in the persistent file.

### 3. TCP stack (buffers and queues)
| Parameter | Value | Why |
|---|---|---|
| `net.ipv4.tcp_rmem` / `tcp_wmem` | `4096 87380 16777216` / `4096 87380 16777216` | Receive/send buffers: min/default/max. 16 MB ceiling so long VPN tunnels don't stall on buffer limits |
| `net.core.rmem_max` / `wmem_max` | `16777216` | Absolute cap for socket buffers |
| `net.core.default_qdisc` / `tcp_congestion_control` | `fq` / `bbr` | BBR over fq — a proven pair for proxy servers |
| `net.ipv4.ip_forward` | `1` | Packet forwarding — required for a VPN server |
| `net.ipv4.tcp_fin_timeout` | `20` | Timeout for orphaned FIN_WAIT_2 sockets (not TIME_WAIT) |
| `net.ipv4.tcp_tw_reuse` | `1` | Reuse sockets in TIME_WAIT for new connections |
| `net.ipv4.tcp_max_syn_backlog` | `8192` | Half-open SYN queue — headroom for VPN client connect bursts |
| `net.core.somaxconn` | `4096` | Accept-queue depth (nginx/xray) |
| `net.core.netdev_max_backlog` | `8192` | Kernel incoming-packet queue |
| `net.ipv4.tcp_syncookies` | `1` | Survive SYN floods |
| `net.ipv4.tcp_fastopen` | `3` | TCP Fast Open on client and server — one RTT less on connect |
| `net.ipv4.tcp_keepalive_time` | `300` | Idle time before keepalive probes — dead connections are detected sooner |
| `net.ipv4.tcp_notsent_lowat` | `131072` | Don't accumulate large unsent queues in the socket — lower latency |

### 4. xray sniffing
The script finds xray configs (x-ui and standalone) and removes `fakedns` and `quic` from `sniffing.destOverride` on all inbounds. Those protocols in sniffing break/slow down proxying of real traffic. The change needs an xray restart: `sudo ./tune.sh --restart-xray` (or via the x-ui panel).

### 5. DNS cache
Installs **dnsmasq** as the system resolver in place of the systemd-resolved stub. A 10000-entry cache with `min-cache-ttl=3600` keeps records for at least an hour even when the upstream TTL is short (google's is ~300s). On the production box this dropped `systemd-resolved` from 4.1% to 0.3% CPU and eliminated the upstream DNS storm (~98 q/s). The cutover is safe: dnsmasq is started and verified first, and only then is `/etc/resolv.conf` repointed (and additionally locked with `chattr +i` so cloud-init cannot rewrite it at later boots). Tailscale MagicDNS is preserved by forwarding `*.ts.net` to `100.100.100.100` (tailscale0 is auto-detected).

### 6. Nginx: file descriptors and connections

| Parameter | Minimum target | Context |
|---|---|---|
| `LimitNOFILE` | `262144` soft and hard | Managed `nginx.service` drop-in; preserves a higher existing soft/hard limit |
| `worker_rlimit_nofile` | `262144` | `main`, per-worker FD limit |
| `worker_connections` | `32768` | `events`, connections per worker |

Higher existing values are preserved. The worker FD limit is raised further when needed to leave `worker_connections + 1024` headroom for logs and other files. `fs.nr_open` is checked but never changed; exceeding the kernel ceiling fails before writing files. This section does not change `fs.file-max`, global systemd limits or `/etc/security/limits.conf`.

`worker_connections` counts both client **and upstream connections**: a reverse proxy usually needs at least two connections per client. These are capacity settings, not a promise of concurrent client throughput; RAM, TLS and the application can become limiting factors first. `worker_processes` and event method selection are preserved.

Supports a conventional `nginx.service` with a root master, the same binary as PATH and its compiled default configuration (`--conf-path` from `nginx -V`). Follows `main` and `events` includes and updates existing directives in their own files while keeping comments. Config symlinks are preserved by editing their targets. Custom `-c`/`-p`, service wrappers, infinite limits and ambiguous/unsupported configuration syntax require manual configuration; files are left unchanged in these cases.

Application sequence:

1. Validate the baseline with `nginx -t`, calculate targets and lock concurrent runs of this section.
2. Back up changed files and a `manifest.json` in a unique `/var/backups/vps-tune/nginx/<timestamp>-<random>/` directory. A manifest value of `null` means the file did not previously exist.
3. Replace files atomically, run `nginx -t` and `systemctl daemon-reload`, then check effective systemd soft/hard limits.
4. Reload active Nginx when its configuration changes or running worker limits are stale, wait for new workers and verify their actual soft/hard limits via `/proc`. Leave an inactive service stopped.
5. On write, validation, reload/restart or worker verification failure, restore original files, remove newly created files, reload systemd and recover the service when necessary. Backups remain available; recovery failures are reported separately. Rollback covers the Nginx section only, not earlier DNS/sysctl/xray changes. SIGKILL, power loss and concurrent edits by other programs are outside the transaction guarantee.

A normal **reload does not change the running master's limits**. `--restart-nginx` restarts an active service only when its master limit is below target, then verifies the result. Restart briefly interrupts connections; without the flag, the script reports a pending restart. An unchanged rerun without the restart flag performs no reload/restart. `--nginx-only --dry-run` prints the plan without writing files or reloading/restarting services.

The inspected server started with systemd/master `1024:524288`, workers `65535:65535` and `worker_connections=32768`. Its plan preserves the service hard limit of `524288`, raises its soft limit to `524288` and workers to `262144`. This is an example; each host is inspected independently.

References: [Nginx core directives](https://nginx.org/en/docs/ngx_core_module.html), [systemd.exec resource limits](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Process%20Properties).

## Usage

```bash
cd ~/vps_tune_script
sudo ./tune.sh                 # apply everything (incl. dnsmasq cache)
sudo ./tune.sh --dry-run       # show what would change without changing anything
sudo ./tune.sh --restart-xray  # after the sniffing patch — restart x-ui/xray
sudo ./tune.sh --nginx-only --dry-run  # Nginx plan only
sudo ./tune.sh --nginx-only            # Nginx: backup + validation + reload
sudo ./tune.sh --nginx-only --restart-nginx  # apply master limits now
./stat.sh                      # one-screen health report (read-only, no root)
```

## Verifying the result

`./stat.sh` renders everything that matters on one screen: RAM, swap/zram with compression, zram traffic, conntrack (fill level + `table full` drops), PSI, top processes, kernel/systemd FD limits and real Nginx master/worker limits with open FD counts. Some `/proc` data may be unavailable without root; run `sudo ./stat.sh` for the complete report. For reference, the same checks by hand:
```bash
sysctl vm.swappiness vm.page-cluster net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count   # current fill level
dmesg -T | grep "table full"                     # no new lines should appear
cat /proc/pressure/cpu /proc/pressure/memory     # PSI: full ≈ 0 means no freezes
ss -s                                            # socket state
sudo nginx -t
systemctl show nginx -p LimitNOFILE -p LimitNOFILESoft
sudo cat /proc/$(systemctl show nginx -p MainPID --value)/limits
python3 -m unittest discover -s tests -v           # tests without root or service changes
```

## Files it creates/modifies

```
/etc/sysctl.d/99-swap.conf          # vm.swappiness, vm.page-cluster
/etc/sysctl.d/99-conntrack.conf     # nf_conntrack_max, timeout
/etc/sysctl.d/99-tune-net.conf      # tcp/core parameters
/etc/modprobe.d/nf_conntrack-hashsize.conf
<path to xray config>               # sniffing.destOverride
/etc/nginx/nginx.conf              # worker_rlimit_nofile / events; or their include files
/etc/systemd/system/nginx.service.d/zz-vps-tune-nofile.conf
/var/backups/vps-tune/nginx/         # original files + manifest.json
/etc/dnsmasq.d/vps-tune.conf
/etc/systemd/resolved.conf
/etc/resolv.conf                    # DNS; chattr +i on a full run
/usr/local/sbin/zram-setup.sh
/etc/systemd/system/zram-setup.service
/etc/x-ui/x-ui.db                   # panel DB sniffing, if present
```

## File layout

```
vps_tune_script/
├── tune.sh    # main tuning script (run as root)
├── stat.sh    # health report (read-only; sudo for complete /proc data)
├── tests/     # nginx parsing, idempotence and rollback tests
└── README.md  # this documentation
```

## Optional integration test / Интеграционный тест

```bash
sudo python3 tests/integration_nginx.py tune.sh
```

Linux + systemd + Nginx only. Creates a disposable service and configuration,
checks real reload/restart, worker limits, idempotence and invalid-config rollback,
then removes the test service and files. Does not change `nginx.service`.

Только Linux + systemd + Nginx. Создаёт временный сервис и конфиг, проверяет
реальные reload/restart, лимиты workers, повторный запуск и откат невалидного
конфига, затем удаляет тестовые файлы и сервис. `nginx.service` не меняет.

## Recovery settings / Настройки после восстановления

- `vm.swappiness=60` persists in `99-swap.conf` and, if present, the `[sysctl]` section of `/etc/tuned/vpn-zram/tuned.conf`. Missing keys are appended; original files are backed up once. This avoids conflicting values when tuned reapplies its profile.
- New UDP/socket buffers default to 1 MiB (`net.core.rmem_default`, `net.core.wmem_default`); application-requested caps remain 16 MiB. Existing sockets keep their buffers. `udp_mem` remains kernel-calculated for the host RAM.
- If `ethtool` is installed, `vps-tune-rx-rings.service` sets physical NIC RX rings to the driver's reported maximum on each boot. Already-maximized and unsupported interfaces are skipped; TX is unchanged. A change can briefly interrupt traffic.
- UDP drop counters are cumulative since boot: compare two samples under load. Buffer tuning cannot guarantee zero drops or fix a slow application. Check `free -m`, `/proc/pressure/memory`, and `grep Udp: /proc/net/snmp`.

На `moscow` интерфейс `ens3` уже имеет RX `256/256`; значение `4096` нельзя переносить с другого драйвера. Настройка swap устраняет обнаруженный запрет на обычную выгрузку холодных страниц, но сама по себе не доказывает причину всех сетевых сбоев.
