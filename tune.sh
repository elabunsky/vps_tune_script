#!/usr/bin/env bash
# =============================================================================
# vps_tune.sh — VPS tuning script
# -----------------------------------------------------------------------------
# Applies the full set of settings that keep a low-RAM VPN / Telegram-bot box
# healthy. Learned the hard way on a real server (1 GB RAM, xray/x-ui, bots):
#
#   1. Swap / zram behaviour     — swappiness=60, page-cluster=0
#   2. conntrack capacity        — bigger table, sane timeout, bigger hash
#                                  (prevents "nf_conntrack: table full,
#                                  dropping packet" -> SSH/VPN connection freezes)
#   3. TCP stack                 — buffers, keepalive, backlogs, TIME_WAIT
#   4. xray sniffing             — remove fakeDns / QUIC from destOverride
#   5. DNS cache                 — dnsmasq as the system resolver with a big
#                                  min-TTL cache, replacing systemd-resolved
#                                  stub (cuts resolved CPU + upstream DNS storm)
#   6. Nginx FD limits           — systemd + workers, validated with rollback
#
# Idempotent — safe to re-run. Must be run as root.
#
# Usage:
#   sudo ./tune.sh                 # apply everything
#   sudo ./tune.sh --dry-run       # show what would change, change nothing
#   sudo ./tune.sh --restart-xray  # after patching sniffing, restart x-ui/xray
#   sudo ./tune.sh --nginx-only    # only nginx, no DNS/VPN/system tuning
#   sudo ./tune.sh --nginx-only --restart-nginx  # also apply master limits now
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config (numbers proven for a ~1 GB RAM production box)
# -----------------------------------------------------------------------------
SWAPPINESS=60                     # allow cold-page swap on low-RAM hosts
PAGE_CLUSTER=0                    # swap one page at a time (best for zram)
ZRAM_SIZE_MB=900                  # zram disksize in MiB (same as the fn box)
                                  # only created when no zram/swap exists

CONNTRACK_MAX=65536               # conntrack table slots
CONNTRACK_HASHSIZE=16384          # = MAX / 4 (avg hash chain length)
CONNTRACK_EST_TIMEOUT=86400       # established-entry timeout, seconds (1 day)

# --- TCP stack ---------------------------------------------------------------
# Values proven on the production box (fn): 16 MB buffers + BBR/fq (hwdsl2 VPN
# script heritage) — long VPN tunnels stall on smaller caps.
TCP_FIN_TIMEOUT=20                # timeout for orphaned FIN_WAIT_2 sockets
TCP_TW_REUSE=1                    # reuse sockets in TIME_WAIT for new conns
TCP_MAX_SYN_BACKLOG=8192          # room for pending SYN requests (conn bursts)
CORE_SOMAXCONN=4096               # accept-queue depth (nginx/xray)
CORE_NETDEV_MAX_BACKLOG=8192      # kernel netdev input queue
TCP_SYN_COOKIES=1                 # survive SYN floods
TCP_FASTOPEN=3                    # TCP Fast Open: client + server
TCP_KEEPALIVE_TIME=300            # idle-conn hold time before probes (seconds)
TCP_NOT_SENT_LOWAT=131072         # flush small packets sooner (low latency)
TCP_RMEM="4096 87380 16777216"    # tcp receive buffer: min / default / max
TCP_WMEM="4096 87380 16777216"    # tcp send buffer:    min / default / max
CORE_RMEM_MAX=16777216            # absolute cap, socket receive buffer (16 MB)
CORE_WMEM_MAX=16777216            # absolute cap, socket send buffer    (16 MB)
CORE_RMEM_DEFAULT=1048576         # new UDP/socket receive buffers (1 MiB)
CORE_WMEM_DEFAULT=1048576         # new UDP/socket send buffers (1 MiB)
DEFAULT_QDISC="fq"                # queueing discipline paired with BBR
TCP_CONGESTION="bbr"              # congestion control (needs fq)
IP_FORWARD=1                      # required for VPN server forwarding

# --- xray sniffing -------------------------------------------------------------
# Destinations that should NOT be sniffed (they break / slow down real proxying)
XRAY_CONFIGS=(
    /usr/local/x-ui/bin/config.json
    /usr/local/etc/xray/config.json
    /etc/xray/config.json
)
# x-ui panel regenerates bin/config.json from its sqlite DB on every xray start,
# so the DB is the real source of truth and must be patched too.
XUI_DB="/etc/x-ui/x-ui.db"
SNIFF_REMOVE=(fakedns quic)

# --- DNS cache (dnsmasq) ------------------------------------------------------
# Replaces systemd-resolved stub with a lightweight caching resolver.
# min-cache-ttl inflates short upstream TTLs (e.g. google's 300s -> 1h),
# killing the miss-storm that drove resolved to ~4% CPU on a busy VPN box.
DNSMASQ_CONF="/etc/dnsmasq.d/vps-tune.conf"
DNSMASQ_UPSTREAM=(1.1.1.1 8.8.8.8 2606:4700:4700::1111)
DNSMASQ_CACHE_SIZE=10000
DNSMASQ_MIN_TTL=3600
# tailscale MagicDNS forwarder (empty -> autodetect from resolvectl)
TS_MAGIC_DNS="100.100.100.100"

# -----------------------------------------------------------------------------
SYSCTL_D="/etc/sysctl.d"
SWAP_CONF="$SYSCTL_D/99-swap.conf"
NET_CONF="$SYSCTL_D/99-tune-net.conf"
CONNTRACK_CONF="$SYSCTL_D/99-conntrack.conf"
MODPROBE_D="/etc/modprobe.d"
MODPROBE_CONF="$MODPROBE_D/nf_conntrack-hashsize.conf"

# Nginx defaults: per-worker connections, with room for non-socket descriptors.
# Existing larger numeric limits are preserved; fs.nr_open is never changed.
NGINX_NOFILE=262144
NGINX_WORKER_CONNECTIONS=32768

DRY_RUN=0
RESTART_XRAY=0
NGINX_ONLY=0
RESTART_NGINX=0
for a in "$@"; do
    case "$a" in
        --dry-run)       DRY_RUN=1 ;;
        --restart-xray)  RESTART_XRAY=1 ;;
        --nginx-only)    NGINX_ONLY=1 ;;
        --restart-nginx) RESTART_NGINX=1 ;;
        *) echo "Unknown flag: $a"; exit 2 ;;
    esac
done

c() { # run a command unless in dry-run mode
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    DRY-RUN  : $*"
    else
        echo "    APPLYING : $*"
        "$@"
    fi
}

info() { echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()   { echo -e "  \033[1;32mOK\033[0m $*"; }
skip() { echo -e "  \033[1;33mSKIP\033[0m $*"; }

# -----------------------------------------------------------------------------
# Nginx transaction is embedded to keep tune.sh usable as a standalone script.
# Only the conventional nginx.service + compiled default config are supported.
# -----------------------------------------------------------------------------
tune_nginx() {
    info "Nginx: file descriptors + worker connections"
    if ! command -v nginx >/dev/null 2>&1; then
        skip "nginx not installed — nothing to tune"
        return
    fi
    if ! command -v python3 >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        echo "ERROR: nginx tuning requires python3 and systemd" >&2
        return 1
    fi
    python3 - "$DRY_RUN" "$RESTART_NGINX" "$NGINX_NOFILE" "$NGINX_WORKER_CONNECTIONS" <<'NGINX_PY'
import fcntl
import glob
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

SERVICE = "nginx.service"
DROPIN = Path("/etc/systemd/system/nginx.service.d/zz-vps-tune-nofile.conf")
BACKUPS = Path("/var/backups/vps-tune/nginx")
LOCK = Path("/run/lock/vps-tune-nginx.lock")
NR_OPEN = Path("/proc/sys/fs/nr_open")


def run(*args):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout.strip()


def prop(name):
    return run("systemctl", "show", SERVICE, "--value", "-p", name)


def tokens(text):
    # Keep offsets: edit directive values only, preserving comments and layout.
    pattern = r'''\s+|\#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[{};]|(?:\\.|\$\{[^}]*\}|\$(?!\{)|[^\s{};"'\\$])+'''
    result, pos = [], 0
    for match in re.finditer(pattern, text):
        if match.start() != pos:
            raise ValueError("unsupported nginx syntax")
        pos = match.end()
        word = match.group()
        if not word.isspace() and not word.startswith("#"):
            result.append((word, match.start(), match.end()))
    if pos != len(text):
        raise ValueError("unsupported nginx syntax")
    return result


def plan_config(config, nofile, connections):
    texts, found, events, visiting = {}, {}, [], set()
    prefix = config.parent

    def parse(path, context=()):
        path = path.resolve(strict=True)
        if path in visiting:
            raise ValueError("recursive nginx include")
        visiting.add(path)
        text = texts.setdefault(path, path.read_text())
        ts = tokens(text)
        scope, statement = list(context), []
        for token in ts:
            word = token[0]
            if word == "{":
                if not statement:
                    raise ValueError("unexpected nginx block")
                name = statement[0][0]
                if not scope and name == "events":
                    events.append((path, token[2]))
                scope.append(name)
                statement = []
            elif word == "}":
                if statement or len(scope) <= len(context):
                    raise ValueError("unbalanced nginx block")
                scope.pop()
            elif word == ";":
                if not statement:
                    raise ValueError("empty nginx directive")
                name = statement[0][0]
                relevant = (not scope and name == "worker_rlimit_nofile") or (
                    scope == ["events"] and name == "worker_connections")
                if relevant:
                    if name in found or len(statement) != 2:
                        raise ValueError("duplicate or unsupported " + name)
                    value = statement[1]
                    if not re.fullmatch(r"[1-9][0-9]*", value[0]):
                        raise ValueError("non-numeric " + name)
                    found[name] = (path, value)
                if name == "include" and scope in ([], ["events"]):
                    if len(statement) != 2:
                        raise ValueError("unsupported include")
                    include = shlex.split(statement[1][0])[0]
                    include = str(prefix / include) if not os.path.isabs(include) else include
                    matches = sorted(glob.glob(include))
                    if not matches and not glob.has_magic(include):
                        raise ValueError("missing include: " + include)
                    for child in matches:
                        parse(Path(child), tuple(scope))
                statement = []
            else:
                statement.append(token)
        if statement or scope != list(context):
            raise ValueError("unbalanced nginx configuration")
        visiting.remove(path)

    parse(config)
    if len(events) != 1:
        raise ValueError("exactly one main events block is required")
    connections = max(connections, int(found.get("worker_connections", (None, ("0",)))[1][0]))
    # Headroom for logs, listeners, cached files and other non-connection FDs.
    nofile = max(nofile, connections + 1024,
                 int(found.get("worker_rlimit_nofile", (None, ("0",)))[1][0]))
    edits = {}
    for name, value in (("worker_rlimit_nofile", nofile), ("worker_connections", connections)):
        if name in found:
            path, token = found[name]
            edits.setdefault(path, []).append((token[1], token[2], str(value)))
        elif name == "worker_rlimit_nofile":
            # Before any include, in main context (conf.d is usually http context).
            edits.setdefault(config.resolve(), []).append((0, 0, f"{name} {value};\n"))
        else:
            path, offset = events[0]
            edits.setdefault(path, []).append((offset, offset, f"\n    {name} {value};\n"))
    changes = {}
    for path, replacements in edits.items():
        updated = texts[path]
        for start, end, value in sorted(replacements, reverse=True):
            updated = updated[:start] + value + updated[end:]
        if updated != texts[path]:
            changes[path] = updated
    return changes, nofile, connections


def replace(path, content):
    # Atomic replacement on the same filesystem; preserve owner/mode/metadata.
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".vps-tune-", dir=path.parent)
    os.close(fd)
    try:
        if path.exists():
            shutil.copy2(path, tmp)
            st = path.stat()
            os.chown(tmp, st.st_uid, st.st_gid)
        else:
            os.chmod(tmp, 0o644)
        Path(tmp).write_bytes(content if isinstance(content, bytes) else content.encode())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def process_limits(pid):
    for line in Path(f"/proc/{pid}/limits").read_text().splitlines():
        if line.startswith("Max open files"):
            return [int(v) if v.isdigit() else float("inf") for v in line.split()[3:5]]
    raise ValueError("cannot read process RLIMIT_NOFILE")


def worker_pids(pid):
    children = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
    workers = []
    for child in children:
        title = Path(f"/proc/{child}/cmdline").read_text()
        if "nginx: worker process" in title and "shutting down" not in title:
            workers.append(child)
    return workers


def verify_workers(nofile, previous=()):
    # Reload is asynchronous. Ignore old workers draining existing connections.
    for _ in range(30):
        pid = int(prop("MainPID"))
        try:
            workers = worker_pids(pid)
            if (workers and (not previous or set(workers) - set(previous)) and
                    all(min(process_limits(p)) >= nofile for p in workers)):
                return
        except FileNotFoundError:
            pass  # worker exited while reading /proc
        time.sleep(0.2)
    raise RuntimeError("new nginx workers did not acquire the requested FD limit")


def apply(changes, config, nofile, service_limit, dry_run, restart):
    active = prop("ActiveState") == "active"
    needs_restart = active and min(process_limits(int(prop("MainPID")))) < service_limit
    needs_reload = False
    if active:
        try:
            workers = worker_pids(int(prop("MainPID")))
            needs_reload = not workers or any(min(process_limits(p)) < nofile for p in workers)
        except FileNotFoundError:
            needs_reload = True
    print(f"Nginx: worker_rlimit_nofile={nofile}, LimitNOFILE={service_limit}")
    if dry_run:
        for path in changes:
            print(f"DRY-RUN: would back up and update {path}")
        print("DRY-RUN: nginx -t, daemon-reload, " +
              ("restart" if restart and needs_restart else "reload if config changed"))
        return
    if not changes and not needs_reload and not (restart and needs_restart):
        print("Nginx: files already match; no reload/restart needed")
    else:
        backup = None
        originals = {}
        action_attempted = False
        try:
            if changes:
                BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
                backup = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=BACKUPS))
                for i, path in enumerate(changes):
                    saved = backup / str(i) if path.exists() else None
                    if saved is not None:
                        shutil.copy2(path, saved)
                        st = path.stat()
                        os.chown(saved, st.st_uid, st.st_gid)
                    originals[path] = saved
                (backup / "manifest.json").write_text(json.dumps(
                    {str(p): str(s) if s else None for p, s in originals.items()}, indent=2))
                print(f"Nginx backup: {backup}")
                for path, content in changes.items():
                    replace(path, content)
            run("nginx", "-t", "-c", str(config))
            run("systemctl", "daemon-reload")
            if min(int(prop("LimitNOFILESoft")), int(prop("LimitNOFILE"))) < service_limit:
                raise RuntimeError("another systemd drop-in overrides LimitNOFILE")
            if active:
                previous = worker_pids(int(prop("MainPID")))
                if restart and needs_restart:
                    action_attempted = True
                    run("systemctl", "restart", SERVICE)
                elif needs_reload or any(path != DROPIN for path in changes):
                    action_attempted = True
                    run("systemctl", "reload", SERVICE)
                verify_workers(nofile, previous if action_attempted else ())
                if prop("ActiveState") != "active":
                    raise RuntimeError("nginx is no longer active")
                if restart and min(process_limits(int(prop("MainPID")))) < service_limit:
                    raise RuntimeError("nginx master did not acquire LimitNOFILE")
        except BaseException:
            errors = []
            for path, saved in originals.items():
                try:
                    if saved is None:
                        path.unlink(missing_ok=True)
                    else:
                        replace(path, saved.read_bytes())
                        shutil.copystat(saved, path)
                except Exception as exc:
                    errors.append(str(exc))
            try:
                run("systemctl", "daemon-reload")
                run("nginx", "-t", "-c", str(config))
                if active and action_attempted:
                    # A failed restart may have stopped the old master.
                    action = "reload" if prop("ActiveState") == "active" else "start"
                    run("systemctl", action, SERVICE)
                    if prop("ActiveState") != "active":
                        raise RuntimeError("nginx recovery did not become active")
            except Exception as exc:
                errors.append(str(exc))
            print("ERROR: nginx transaction rolled back" + (f"; backup: {backup}" if backup else ""), file=sys.stderr)
            if errors:
                print("ERROR: rollback needs manual recovery: " + "; ".join(errors), file=sys.stderr)
            raise
    if not active:
        print("Nginx is stopped; files are ready for the next start (left stopped).")
    elif min(process_limits(int(prop("MainPID")))) < service_limit:
        print("Nginx master keeps its old limits until restart. Workers use worker_rlimit_nofile.")
        print("Run: sudo ./tune.sh --nginx-only --restart-nginx (briefly interrupts connections).")


def main():
    dry_run, restart = map(int, sys.argv[1:3])
    nofile, connections = map(int, sys.argv[3:5])
    if nofile <= 0 or connections <= 0:
        raise ValueError("nginx targets must be positive integers")
    # Do not silently tune a different config than the service actually runs.
    command = prop("ExecStart")
    binary = re.search(r"path=([^ ;]+)", command)
    if not binary or Path(binary.group(1)).resolve() != Path(shutil.which("nginx")).resolve():
        raise ValueError("nginx.service uses a different binary or a wrapper")
    if not prop("FragmentPath") or prop("User") not in ("", "root"):
        raise ValueError("a system nginx.service running a root master is required")
    if re.search(r"(?:\s)-(?:c|p)\S*", command) or any(
            value in command for value in ("worker_rlimit_nofile", "master_process off", "daemon off")):
        raise ValueError("custom nginx -c/-p/-g limits need manual configuration")
    version = subprocess.run(
        ["nginx", "-V"], check=True, text=True, capture_output=True).stderr
    match = re.search(r"--conf-path=(\S+)", version)
    config = Path(match.group(1) if match else "/etc/nginx/nginx.conf")
    if not config.is_absolute() or not config.is_file():
        raise ValueError("nginx needs an existing absolute default config path")
    run("nginx", "-t", "-c", str(config))  # require a valid baseline
    changes, nofile, connections = plan_config(config, nofile, connections)
    nr_open = int(NR_OPEN.read_text())
    if nofile > nr_open:
        raise ValueError(f"required nofile={nofile} exceeds fs.nr_open={nr_open}; kernel left unchanged")
    soft, hard = prop("LimitNOFILESoft"), prop("LimitNOFILE")
    if not soft.isdigit() or not hard.isdigit():
        raise ValueError("non-numeric/infinite systemd limits require manual review")
    # Preserve an existing larger hard or soft service limit.
    service_limit = max(nofile, int(soft), int(hard))
    if service_limit > nr_open:
        raise ValueError("existing systemd limit exceeds fs.nr_open; kernel left unchanged")
    if DROPIN.is_symlink():
        raise ValueError("managed systemd drop-in must not be a symlink")
    desired = f"# Managed by vps_tune_script/tune.sh\n[Service]\nLimitNOFILE={service_limit}\n"
    if not DROPIN.exists() or DROPIN.read_text() != desired:
        changes[DROPIN] = desired
    print(f"Nginx: worker_connections={connections}; fs.nr_open={nr_open}")
    apply(changes, config, nofile, service_limit, dry_run, restart)


if __name__ == "__main__":
    try:
        # Dry-run creates no lock, backup, temporary or configuration files.
        if int(sys.argv[1]):
            main()
        else:
            fd = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "a") as lock:
                lock_stat = os.fstat(lock.fileno())
                if lock_stat.st_uid != os.geteuid() or not stat.S_ISREG(lock_stat.st_mode):
                    raise ValueError("unsafe nginx tuning lock file")
                os.fchmod(lock.fileno(), 0o600)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                def interrupted(signum, frame):
                    raise RuntimeError(f"interrupted by signal {signum}")
                signal.signal(signal.SIGTERM, interrupted)
                signal.signal(signal.SIGHUP, interrupted)
                main()
    except (Exception, KeyboardInterrupt) as exc:
        print(f"ERROR: nginx tuning failed: {exc}", file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError):
            print(exc.stderr, file=sys.stderr)
        sys.exit(1)
NGINX_PY
}

# -----------------------------------------------------------------------------
info "Prerequisites"
# -----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo ./tune.sh)"; exit 1; }
if [[ "$NGINX_ONLY" -eq 1 ]]; then
    tune_nginx
    exit 0
fi
[[ -d $SYSCTL_D ]] || { echo "ERROR: $SYSCTL_D missing"; exit 1; }
c mkdir -p "$SYSCTL_D" "$MODPROBE_D"

# -----------------------------------------------------------------------------
info "1. Swap / zram: bootstrap zram if missing, then tune behaviour"
# -----------------------------------------------------------------------------
ZRAM_SCRIPT="/usr/local/sbin/zram-setup.sh"
ZRAM_UNIT="/etc/systemd/system/zram-setup.service"

if [[ -e /sys/block/zram0 ]]; then
    ok "zram0 already present ($(zramctl --output DISKSIZE --noheadings /dev/zram0 2>/dev/null | tr -d ' ') bytes) — bootstrap skipped"
else
    ZRAM_MB=$ZRAM_SIZE_MB
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    DRY-RUN  : would create zram0 (${ZRAM_MB} MB, lz4, prio 100) + persist via systemd"
    else
        cat > "$ZRAM_SCRIPT" <<'ZEOF'
#!/usr/bin/env bash
# Bootstrap zram swap (created by vps_tune.sh). Idempotent.
set -eu
swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram0$' && exit 0
ZRAM_MB="$1"

# Some kernel builds ship zram in linux-modules-extra (Ubuntu). Install it
# best-effort when modprobe cannot find the module.
if ! modprobe zram 2>/dev/null; then
    if command -v apt-get >/dev/null 2>&1; then
        KREL="$(uname -r)"
        apt-get install -y "linux-modules-extra-${KREL}" >/dev/null 2>&1 || true
        modprobe zram 2>/dev/null || true
    fi
fi
[ -e /sys/block/zram0 ] || { echo "zram module unavailable"; exit 1; }
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo $((ZRAM_MB * 1024 * 1024)) > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
ZEOF
        chmod +x "$ZRAM_SCRIPT"
        cat > "$ZRAM_UNIT" <<UNIT
[Unit]
Description=Setup zram swap (created by vps_tune.sh)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$ZRAM_SCRIPT $ZRAM_MB
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
        c systemctl daemon-reload
        c systemctl enable --now "$ZRAM_UNIT"
        # systemd may report failure while apt-get is still fetching the package
        # in the background ExecStart — give it a moment, then re-check.
        sleep 3
        if [[ -e /sys/block/zram0 ]] && swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram0$'; then
            ok "zram0 created: ${ZRAM_MB} MB, lz4, prio 100 (persisted via $ZRAM_UNIT)"
        else
            skip "zram0 did not come up — check: journalctl -u zram-setup.service"
        fi
    fi
fi

if swapon --show 2>/dev/null | grep -q .; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    DRY-RUN  : persist swappiness=$SWAPPINESS, page-cluster=$PAGE_CLUSTER in $SWAP_CONF and existing vpn-zram tuned profile"
    else
        python3 - "$SWAP_CONF" /etc/tuned/vpn-zram/tuned.conf "$SWAPPINESS" "$PAGE_CLUSTER" <<'SWAP_PY'
from pathlib import Path
import re, sys
swap, tuned = map(Path, sys.argv[1:3])
values = {"vm.swappiness": sys.argv[3], "vm.page-cluster": sys.argv[4]}
for path in (swap, tuned):
    if path == tuned and not path.exists():
        continue
    old = path.read_text() if path.exists() else "# swap/zram tuning\n"
    text = old
    if path == tuned:
        section = re.search(r"(?ms)^\[sysctl\][ \t]*\n(.*?)(?=^\[|\Z)", text)
        block = section.group(1) if section else ""
    else:
        block = text
    for key, value in values.items():
        pattern = r"(?m)^[ \t]*" + re.escape(key) + r"[ \t]*=.*$"
        if re.search(pattern, block):
            block = re.sub(pattern, key + "=" + value, block)
        else:
            block = block.rstrip("\n") + "\n" + key + "=" + value + "\n"
    if path == tuned:
        text = (text[:section.start(1)] + block + text[section.end(1):]
                if section else text.rstrip("\n") + "\n[sysctl]\n" + block)
    else:
        text = block
    if text != old or not path.exists():
        if path.exists():
            backup = path.with_name(path.name + ".before-vps-tune-swap")
            if not backup.exists():
                backup.write_bytes(path.read_bytes())
        path.write_text(text)
SWAP_PY
    fi
    c sysctl -w "vm.swappiness=$SWAPPINESS" "vm.page-cluster=$PAGE_CLUSTER"
else
    skip "no swap device — swap part skipped (conntrack/TCP/sniffing still apply)"
fi

# -----------------------------------------------------------------------------
info "2. conntrack: capacity + timeout"
# -----------------------------------------------------------------------------
# hashsize is a module parameter -> must survive reboot via modprobe.d.
# Preserve an existing larger table's hash rather than shrinking it on rerun.
CUR_HASHSIZE=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo 0)
[[ "$CUR_HASHSIZE" -gt "$CONNTRACK_HASHSIZE" ]] && CONNTRACK_HASHSIZE=$CUR_HASHSIZE
if ! grep -q "^options nf_conntrack hashsize=$CONNTRACK_HASHSIZE\$" "$MODPROBE_CONF" 2>/dev/null; then
    c bash -c "echo 'options nf_conntrack hashsize=$CONNTRACK_HASHSIZE' > '$MODPROBE_CONF'"
else
    ok "hashsize already in $MODPROBE_CONF"
fi
if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    H="$CONNTRACK_HASHSIZE"
    [[ "$(cat /sys/module/nf_conntrack/parameters/hashsize)" -eq "$H" ]] \
        || c bash -c "echo $H > /sys/module/nf_conntrack/parameters/hashsize"
    ok "hashsize now $(cat /sys/module/nf_conntrack/parameters/hashsize)"
else
    skip "nf_conntrack not loaded yet — will pick hashsize from modprobe.d at boot"
fi

# Never *lower* an already-running bigger table; never *raise* an already
# smaller established timeout (shorter timeout = faster zombie cleanup).
CUR_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
[[ "$CUR_MAX" -gt "$CONNTRACK_MAX" ]] && CONNTRACK_MAX=$CUR_MAX
CUR_TO=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo 0)
[[ "$CUR_TO" -gt 0 && "$CUR_TO" -lt "$CONNTRACK_EST_TIMEOUT" ]] && CONNTRACK_EST_TIMEOUT=$CUR_TO

if [[ "$DRY_RUN" -eq 0 ]]; then
    {
        echo "# conntrack capacity & timeout"
        echo "net.netfilter.nf_conntrack_max = $CONNTRACK_MAX"
        echo "net.netfilter.nf_conntrack_tcp_timeout_established = $CONNTRACK_EST_TIMEOUT"
    } > /tmp/conntrack.conf.new
fi

c mv /tmp/conntrack.conf.new "$CONNTRACK_CONF"
c sysctl -w "net.netfilter.nf_conntrack_max=$CONNTRACK_MAX" \
           "net.netfilter.nf_conntrack_tcp_timeout_established=$CONNTRACK_EST_TIMEOUT"

# -----------------------------------------------------------------------------
info "3. TCP stack: buffers, keepalive, backlogs, TIME_WAIT"
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
    {
        echo "# tcp tuning (vps_tune.sh)"
        echo "net.ipv4.tcp_syncookies = $TCP_SYN_COOKIES"
        echo "net.ipv4.tcp_fin_timeout = $TCP_FIN_TIMEOUT"
        echo "net.ipv4.tcp_tw_reuse = $TCP_TW_REUSE"
        echo "net.ipv4.tcp_max_syn_backlog = $TCP_MAX_SYN_BACKLOG"
        echo "net.core.somaxconn = $CORE_SOMAXCONN"
        echo "net.core.netdev_max_backlog = $CORE_NETDEV_MAX_BACKLOG"
        echo "net.ipv4.tcp_fastopen = $TCP_FASTOPEN"
        echo "net.ipv4.tcp_keepalive_time = $TCP_KEEPALIVE_TIME"
        echo "net.ipv4.tcp_notsent_lowat = $TCP_NOT_SENT_LOWAT"
        echo "net.ipv4.tcp_rmem = $TCP_RMEM"
        echo "net.ipv4.tcp_wmem = $TCP_WMEM"
        echo "net.core.rmem_max = $CORE_RMEM_MAX"
        echo "net.core.wmem_max = $CORE_WMEM_MAX"
        echo "net.core.rmem_default = $CORE_RMEM_DEFAULT"
        echo "net.core.wmem_default = $CORE_WMEM_DEFAULT"
        echo "net.core.default_qdisc = $DEFAULT_QDISC"
        echo "net.ipv4.tcp_congestion_control = $TCP_CONGESTION"
        echo "net.ipv4.ip_forward = $IP_FORWARD"
    } > /tmp/tune-net.conf.new
fi
c mv /tmp/tune-net.conf.new "$NET_CONF"
c sysctl -w \
      "net.ipv4.tcp_syncookies=$TCP_SYN_COOKIES" \
      "net.ipv4.tcp_fin_timeout=$TCP_FIN_TIMEOUT" \
      "net.ipv4.tcp_tw_reuse=$TCP_TW_REUSE" \
      "net.ipv4.tcp_max_syn_backlog=$TCP_MAX_SYN_BACKLOG" \
      "net.core.somaxconn=$CORE_SOMAXCONN" \
      "net.core.netdev_max_backlog=$CORE_NETDEV_MAX_BACKLOG" \
      "net.ipv4.tcp_fastopen=$TCP_FASTOPEN" \
      "net.ipv4.tcp_keepalive_time=$TCP_KEEPALIVE_TIME" \
      "net.ipv4.tcp_notsent_lowat=$TCP_NOT_SENT_LOWAT" \
      "net.ipv4.tcp_rmem=$TCP_RMEM" \
      "net.ipv4.tcp_wmem=$TCP_WMEM" \
      "net.core.rmem_max=$CORE_RMEM_MAX" \
      "net.core.wmem_max=$CORE_WMEM_MAX" \
      "net.core.rmem_default=$CORE_RMEM_DEFAULT" \
      "net.core.wmem_default=$CORE_WMEM_DEFAULT" \
      "net.core.default_qdisc=$DEFAULT_QDISC" \
      "net.ipv4.tcp_congestion_control=$TCP_CONGESTION" \
      "net.ipv4.ip_forward=$IP_FORWARD"

# RX ring capacity depends on the driver; unsupported NICs are skipped.
info "3b. NIC RX rings: supported maximum, persisted via systemd"
if ! command -v ethtool >/dev/null 2>&1; then
    skip "ethtool missing — RX ring tuning skipped"
elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "    DRY-RUN  : install and run vps-tune-rx-rings.service (driver-reported RX maximum)"
else
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/vps-tune-rx-rings <<'RINGS_SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 0 ]]; then
    for path in /sys/class/net/*; do
        [[ -e "$path/device" ]] || continue
        set -- "$@" "${path##*/}"
    done
fi
failed=0
for iface in "$@"; do
    if ! rings=$(LC_ALL=C ethtool -g "$iface" 2>/dev/null); then
        echo "SKIP $iface: ring parameters unsupported"
        continue
    fi
    read -r maximum current < <(awk '
        /Pre-set maximums:/ { section="max"; next }
        /Current hardware settings:/ { section="current"; next }
        $1 == "RX:" && section == "max" { maximum=$2 }
        $1 == "RX:" && section == "current" { current=$2 }
        END { print maximum ? maximum : "n/a", current ? current : "n/a" }
    ' <<< "$rings")
    if [[ ! "$maximum" =~ ^[1-9][0-9]*$ || ! "$current" =~ ^[0-9]+$ ]]; then
        echo "SKIP $iface: no numeric RX limits"
    elif [[ "$maximum" == "$current" ]]; then
        echo "OK $iface: RX already $current/$maximum"
    elif ethtool -G "$iface" rx "$maximum"; then
        echo "OK $iface: RX set to $maximum"
    else
        echo "ERROR $iface: unable to set RX to $maximum" >&2
        failed=1
    fi
done
exit "$failed"
RINGS_SH
    chmod 755 /usr/local/sbin/vps-tune-rx-rings
    cat > /etc/systemd/system/vps-tune-rx-rings.service <<'RINGS_UNIT'
[Unit]
Description=Maximize supported NIC RX rings (vps_tune.sh)
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-tune-rx-rings
[Install]
WantedBy=multi-user.target
RINGS_UNIT
    systemctl daemon-reload
    systemctl enable vps-tune-rx-rings.service
    if ! systemctl start vps-tune-rx-rings.service; then
        skip "some RX rings could not be tuned — check journalctl -u vps-tune-rx-rings"
    fi
fi

# -----------------------------------------------------------------------------
info "4. xray sniffing: remove fakeDns / QUIC from destOverride"
# -----------------------------------------------------------------------------
PATCHED=""
for f in "${XRAY_CONFIGS[@]}"; do
    [[ -f "$f" ]] || continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    DRY-RUN  : would patch sniffing in $f"
        continue
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 missing — cannot patch $f; do it in x-ui panel:"
        skip "  Inbound edit -> sniffing -> uncheck fakeDns and QUIC"
        continue
    fi
    SET="$IFS"; IFS=,; REMOVE="${SNIFF_REMOVE[*]}"; IFS="$SET"
    if RESULT=$(python3 - "$f" "$REMOVE" <<'PYEOF'
import json, sys
path, remove = sys.argv[1], set(sys.argv[2].split(','))
with open(path) as fh: cfg = json.load(fh)
changed = False
for ib in cfg.get("inbounds", []):
    s = ib.get("sniffing")
    if not s: continue
    dst = [d for d in s.get("destOverride", []) if d not in remove]
    if dst != s.get("destOverride"):
        s["destOverride"] = dst
        changed = True
if changed:
    with open(path, "w") as fh: json.dump(cfg, fh, indent=2, ensure_ascii=False)
print("CHANGED" if changed else "ALREADY_OK")
PYEOF
    ); then
        if [[ "$RESULT" == "CHANGED" ]]; then
            ok "sniffing patched in $f (removed: ${SNIFF_REMOVE[*]})"
            PATCHED=1
        else
            ok "sniffing already clean in $f"
        fi
    else
        skip "failed to parse $f — check config (do it via x-ui panel instead)"
    fi
done

# x-ui sqlite DB: patch the sniffing column so the panel does not regenerate
# the old destOverride on next xray start.
if [[ -f "$XUI_DB" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    DRY-RUN  : would patch sniffing in $XUI_DB (sqlite inbounds.sniffing)"
    elif command -v python3 >/dev/null 2>&1; then
        cp -a "$XUI_DB" "${XUI_DB}.bak.$(date +%Y%m%d-%H%M%S)"
        if RESULT=$(python3 - "$XUI_DB" "${SNIFF_REMOVE[*]}" <<'PYEOF'
import sqlite3, sys, json
path, remove = sys.argv[1], set(sys.argv[2].split())
con = sqlite3.connect(path)
cur = con.cursor()
changed = 0
for iid, sniff_json in cur.execute("SELECT id, sniffing FROM inbounds").fetchall():
    if not sniff_json: continue
    try: sniff = json.loads(sniff_json)
    except Exception: continue
    dst = [d for d in sniff.get("destOverride", []) if d not in remove]
    if dst != sniff.get("destOverride"):
        sniff["destOverride"] = dst
        cur.execute("UPDATE inbounds SET sniffing=? WHERE id=?", (json.dumps(sniff), iid))
        changed += 1
con.commit(); con.close()
print(changed)
PYEOF
        ); then
            if [[ "$RESULT" -gt 0 ]]; then
                ok "x-ui DB patched: $RESULT inbound(s) cleaned in $XUI_DB"
                PATCHED_DB=1
            else
                ok "x-ui DB already clean ($XUI_DB)"
            fi
        else
            skip "failed to patch $XUI_DB — do it via x-ui panel: Inbound edit -> sniffing -> uncheck fakeDns and QUIC"
        fi
    else
        skip "python3 missing — cannot patch $XUI_DB; do it via x-ui panel"
    fi
fi

[[ -n "$PATCHED" || -n "${PATCHED_DB:-}" ]] && echo "    info: restart xray to apply:  sudo ./tune.sh --restart-xray   (or via x-ui panel)"

if [[ "$RESTART_XRAY" -eq 1 ]]; then
    UNIT=""
    for u in x-ui xray; do
        systemctl cat "$u" >/dev/null 2>&1 && { UNIT="$u"; break; }
    done
    if [[ -n "$UNIT" ]]; then
        c systemctl restart "$UNIT"
        ok "restarted $UNIT"
        sleep 2
        systemctl is-active "$UNIT"
        systemctl status "$UNIT" --no-pager -n 5 | tail -8 || true
    else
        skip "no x-ui/xray systemd unit found — restart manually"
    fi
fi

# -----------------------------------------------------------------------------
info "5. DNS cache: dnsmasq as system resolver"
# -----------------------------------------------------------------------------
# Replaces systemd-resolved stub with dnsmasq: big cache + min-cache-ttl kills
# the short-TTL miss-storm that drove resolved to ~4% CPU under proxy load.
# Safe cutover: dnsmasq is started and *proven* before resolv.conf is touched.
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "    DRY-RUN  : would install dnsmasq, configure cache (size=$DNSMASQ_CACHE_SIZE, min-ttl=$DNSMASQ_MIN_TTL),"
    echo "    DRY-RUN  : disable resolved stub, repoint /etc/resolv.conf -> 127.0.0.1"
else
    if grep -q '^nameserver 127.0.0.1$' /etc/resolv.conf 2>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
        ok "dnsmasq already the system resolver — nothing to do"
    else
        # 5a. install — the full package brings the systemd unit; dnsmasq-base
        # (binary only) is not enough.
        if ! systemctl cat dnsmasq >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                c bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq >/dev/null 2>&1'
            else
                skip "dnsmasq service not installed and no apt-get — install manually, then re-run"
            fi
        fi
        if systemctl cat dnsmasq >/dev/null 2>&1; then
            systemctl stop dnsmasq 2>/dev/null || true
            # 5b. build tailscale forward lines (MagicDNS) if tailscale0 exists
            TS_LINES=""
            if ip link show tailscale0 >/dev/null 2>&1; then
                TS_LINES="$TS_LINES
server=/ts.net/${TS_MAGIC_DNS}
server=/100.in-addr.arpa/${TS_MAGIC_DNS}
server=/0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa/${TS_MAGIC_DNS}"
            fi
            # 5c. config
            {
                echo "# vps_tune: caching resolver, replaces systemd-resolved stub"
                echo "listen-address=127.0.0.1"
                echo "bind-interfaces"
                echo "no-resolv"
                echo "domain-needed"
                echo "bogus-priv"
                echo "cache-size=${DNSMASQ_CACHE_SIZE}"
                echo "min-cache-ttl=${DNSMASQ_MIN_TTL}"
                echo "local-ttl=${DNSMASQ_MIN_TTL}"
                for s in "${DNSMASQ_UPSTREAM[@]}"; do echo "server=$s"; done
                echo -n "$TS_LINES"
            } > "$DNSMASQ_CONF"
            c systemctl daemon-reload
            c systemctl enable dnsmasq
            c systemctl start dnsmasq
            sleep 1
            # 5d. PROVE dnsmasq works BEFORE touching the system resolver
            if dig +short +time=3 +tries=1 @127.0.0.1 www.google.com | grep -qE '^[0-9]'; then
                ok "dnsmasq resolves correctly on 127.0.0.1 — cutting over"
                # 5e. disable resolved stub listener (frees 127.0.0.53, stops managing resolv.conf)
                if ! grep -q '^DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
                    echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
                else
                    c sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                fi
                c systemctl restart systemd-resolved
                # 5f. static resolv.conf (regular file, not symlink — resolved won't
                # rewrite it) and make it immutable so neither cloud-init nor anything
                # else can overwrite it at later boots.
                SEARCH_LINE=""
                ts_dom=$( { resolvectl domain tailscale0 2>/dev/null || true; } | awk '{print $3}' | head -1)
                [[ -n "$ts_dom" ]] && SEARCH_LINE="search ${ts_dom}"
                cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
                c bash -c "chattr -i /etc/resolv.conf 2>/dev/null || true; rm -f /etc/resolv.conf && printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n${SEARCH_LINE}\n' > /etc/resolv.conf && chattr +i /etc/resolv.conf 2>/dev/null || true"
                ok "/etc/resolv.conf -> 127.0.0.1 (dnsmasq), resolved stub disabled, file locked (chattr +i)"
                # 5g. final verify through the system resolver
                if dig +short +time=3 +tries=1 www.google.com | grep -qE '^[0-9]'; then
                    ok "system resolver verified: www.google.com resolves via dnsmasq"
                else
                    skip "post-cutover verify failed — check: dig @127.0.0.1 www.google.com ; journalctl -u dnsmasq"
                fi
            else
                skip "dnsmasq did not resolve www.google.com — aborting cutover (resolved left intact)"
                systemctl stop dnsmasq 2>/dev/null || true
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
tune_nginx

# -----------------------------------------------------------------------------
info "7. Verification"
# -----------------------------------------------------------------------------
[[ "$DRY_RUN" -eq 1 ]] && { echo; echo "Dry-run finished — nothing was changed."; exit 0; }

sysctl vm.swappiness vm.page-cluster \
       net.netfilter.nf_conntrack_max \
       net.netfilter.nf_conntrack_tcp_timeout_established \
       net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
       net.core.rmem_max net.core.wmem_max \
       net.core.rmem_default net.core.wmem_default

if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
    echo "conntrack fill: $(< /proc/sys/net/netfilter/nf_conntrack_count) / $(< /proc/sys/net/netfilter/nf_conntrack_max)"
fi

echo
ok "Done. Persisted across reboots:
  $SWAP_CONF        (swap/zram)
  $CONNTRACK_CONF   (conntrack)
  $NET_CONF         (tcp)
  $MODPROBE_CONF    (conntrack hashsize at module load)
  $DNSMASQ_CONF     (dnsmasq cache)
To simulate boot-time application:  sysctl --system"
