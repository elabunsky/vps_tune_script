# vps_tune_script

Набор скриптов и настроек для небольшого Linux VPS (VPN-сервер / тг-боты на ~1 ГБ RAM), который устраняет типовые симптомы деградации:

1. **Фризы, «зависание» SSH** — при переполнении conntrack-таблицы ядро начинает дропать пакеты новых соединений.
2. **Ложное ощущение дискового свопа** — когда холодные страницы вытесняются на диск, а не в быстрый zram.
3. **Тормоза и разрывы под нагрузкой** — маленькие сетевые буферы и очереди, копящиеся TIME_WAIT-сокеты.
4. **Неправильный сниффинг xray** — `fakedns` и `quic` в `destOverride` ломают/замедляют проксирование реального трафика.

Всё, что делает скрипт, применяется на лету **и сохраняется в конфиги `/etc/sysctl.d/` и `/etc/modprobe.d/`**, поэтому переживает перезагрузку. Скрипт идемпотентный — его можно перезапускать без опаски.

## Что настраивает

### 1. Своп / zram
Скрипт проверяет наличие `/dev/zram0`: если его нет — устанавливает пакет модулей ядра (`linux-modules-extra`, при необходимости), создаёт zram-устройство **900 МБ, lz4, приоритет 100** (как на эталонном сервере) и сохраняет автозапуск через systemd-юнит `zram-setup.service`. Если zram уже есть — только тюнит поведение.

| Параметр | Значение | Зачем |
|---|---|---|
| `vm.swappiness` | `100` | Раньше выгружать холодные страницы в сжатый zram (он быстрый), а не держать в дефицитной RAM |
| `vm.page-cluster` | `0` | Вытеснять страницы по одной — правильное поведение для zram |

### 2. Conntrack
| Параметр | Значение | Зачем |
|---|---|---|
| `nf_conntrack_max` | `65536` | Вместо дефолтных 8192 — иначе таблица переполняется и ядро дропает пакеты новых соединений |
| hashsize | `16384` | Размер хэш-таблицы (`max / 4`), переживает ребут через `modprobe.d` |
| `nf_conntrack_tcp_timeout_established` | `86400` | Записи «мертвых» TCP-сессий живут сутки, а не 5 дней — меньше мусора в таблице |

### 3. TCP-стек (буферы и очереди)
| Параметр | Значение | Зачем |
|---|---|---|
| `net.ipv4.tcp_rmem` / `tcp_wmem` | `4096 87380 16777216` / `4096 87380 16777216` | Буферы приёма/передачи: min/default/max. Потолок 16 МБ — чтобы длинные VPN-туннели не упирались в буфер |
| `net.core.rmem_max` / `wmem_max` | `16777216` | Абсолютный потолок буферов сокета |
| `net.core.default_qdisc` / `tcp_congestion_control` | `fq` / `bbr` | BBR поверх fq — проверенная связка для прокси-сервера |
| `net.ipv4.ip_forward` | `1` | Форвардинг пакетов — обязателен для VPN-сервера |
| `net.ipv4.tcp_fin_timeout` | `20` | TIME_WAIT освобождает порт быстрее |
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

## Использование

```bash
cd ~/vps_tune_script
sudo ./tune.sh                 # применить всё
sudo ./tune.sh --dry-run       # показать, что изменится, не меняя ничего
sudo ./tune.sh --restart-xray  # после патча сниффинга — рестарт x-ui/xray
```

## Как проверять результат

```bash
sysctl vm.swappiness vm.page-cluster net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count   # текущая заполненность
dmesg -T | grep "table full"                     # не должно появляться новых строк
cat /proc/pressure/cpu /proc/pressure/memory     # PSI: full ≈ 0 = нет фризов
ss -s                                            # состояние сокетов
```

## Какие файлы создаёт/правит

```
/etc/sysctl.d/99-swap.conf          # vm.swappiness, vm.page-cluster
/etc/sysctl.d/99-conntrack.conf     # nf_conntrack_max, timeout
/etc/sysctl.d/99-tune-net.conf      # tcp/core параметры
/etc/modprobe.d/nf_conntrack-hashsize.conf
<path к конфигу xray>               # sniffing.destOverride
```

---

# vps_tune_script

A set of scripts and settings for a small Linux VPS (VPN server / Telegram bots on ~1 GB RAM) that fixes typical degradation symptoms:

1. **Freezes / SSH «hangs»** — when the kernel conntrack table overflows, the kernel starts dropping packets of new connections.
2. **The false impression of disk swap** — when cold pages are evicted to disk instead of into fast zram.
3. **Sluggishness and disconnects under load** — small network buffers and queues, accumulating TIME_WAIT sockets.
4. **Wrong xray sniffing** — `fakedns` and `quic` in `destOverride` break/slow down proxying of real traffic.

Everything the script does is applied at runtime **and persisted into `/etc/sysctl.d/` and `/etc/modprobe.d/`**, so it survives reboots. The script is idempotent — safe to re-run.

## What it configures

### 1. Swap / zram
The script checks whether `/dev/zram0` exists: if not, it installs the kernel modules package (`linux-modules-extra`, when needed), creates a **900 MB, lz4, priority 100** zram device (matching the reference server) and persists auto-start via the `zram-setup.service` systemd unit. If zram already exists, it only tunes the behaviour.

| Parameter | Value | Why |
|---|---|---|
| `vm.swappiness` | `100` | Offload cold pages into compressed zram early (it is fast) instead of keeping them in scarce RAM |
| `vm.page-cluster` | `0` | Swap pages one at a time — the correct behaviour for zram |

### 2. Conntrack
| Parameter | Value | Why |
|---|---|---|
| `nf_conntrack_max` | `65536` | Instead of the default 8192 — otherwise the table overflows and the kernel drops packets of new connections |
| hashsize | `16384` | Hash table size (`max / 4`), survives reboot via `modprobe.d` |
| `nf_conntrack_tcp_timeout_established` | `86400` | Dead TCP session records live one day instead of five — less garbage in the table |

### 3. TCP stack (buffers and queues)
| Parameter | Value | Why |
|---|---|---|
| `net.ipv4.tcp_rmem` / `tcp_wmem` | `4096 87380 16777216` / `4096 87380 16777216` | Receive/send buffers: min/default/max. 16 MB ceiling so long VPN tunnels don't stall on buffer limits |
| `net.core.rmem_max` / `wmem_max` | `16777216` | Absolute cap for socket buffers |
| `net.core.default_qdisc` / `tcp_congestion_control` | `fq` / `bbr` | BBR over fq — a proven pair for proxy servers |
| `net.ipv4.ip_forward` | `1` | Packet forwarding — required for a VPN server |
| `net.ipv4.tcp_fin_timeout` | `20` | TIME_WAIT frees port slots faster |
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

## Usage

```bash
cd ~/vps_tune_script
sudo ./tune.sh                 # apply everything
sudo ./tune.sh --dry-run       # show what would change without changing anything
sudo ./tune.sh --restart-xray  # after the sniffing patch — restart x-ui/xray
```

## Verifying the result

```bash
sysctl vm.swappiness vm.page-cluster net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count   # current fill level
dmesg -T | grep "table full"                     # no new lines should appear
cat /proc/pressure/cpu /proc/pressure/memory     # PSI: full ≈ 0 means no freezes
ss -s                                            # socket state
```

## Files it creates/modifies

```
/etc/sysctl.d/99-swap.conf          # vm.swappiness, vm.page-cluster
/etc/sysctl.d/99-conntrack.conf     # nf_conntrack_max, timeout
/etc/sysctl.d/99-tune-net.conf      # tcp/core parameters
/etc/modprobe.d/nf_conntrack-hashsize.conf
<path to xray config>               # sniffing.destOverride
```

## File layout

```
vps_tune_script/
├── tune.sh    # main script (run as root)
└── README.md  # this documentation
```
