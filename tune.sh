#!/usr/bin/env bash
# =============================================================================
# vps_tune.sh — VPS tuning script
# -----------------------------------------------------------------------------
# Applies the full set of settings that keep a low-RAM VPN / Telegram-bot box
# healthy. Learned the hard way on a real server (1 GB RAM, xray/x-ui, bots):
#
#   1. Swap / zram behaviour     — swappiness=100, page-cluster=0
#   2. conntrack capacity        — bigger table, sane timeout, bigger hash
#                                  (prevents "nf_conntrack: table full,
#                                  dropping packet" -> SSH/VPN connection freezes)
#   3. TCP stack                 — buffers, keepalive, backlogs, TIME_WAIT
#   4. xray sniffing             — remove fakeDns / QUIC from destOverride
#
# Idempotent — safe to re-run. Must be run as root.
#
# Usage:
#   sudo ./tune.sh                # apply everything
#   sudo ./tune.sh --dry-run      # show what would change, change nothing
#   sudo ./tune.sh --restart-xray # after patching sniffing, restart x-ui/xray
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config (numbers proven for a ~1 GB RAM production box)
# -----------------------------------------------------------------------------
SWAPPINESS=100                    # eager offload of cold pages into (z)ram
PAGE_CLUSTER=0                    # swap one page at a time (best for zram)

CONNTRACK_MAX=65536               # conntrack table slots
CONNTRACK_HASHSIZE=16384          # = MAX / 4 (avg hash chain length)
CONNTRACK_EST_TIMEOUT=86400       # established-entry timeout, seconds (1 day)

# --- TCP stack ---------------------------------------------------------------
# Values proven on the production box (fn): 16 MB buffers + BBR/fq (hwdsl2 VPN
# script heritage) — long VPN tunnels stall on smaller caps.
TCP_FIN_TIMEOUT=20                # TIME_WAIT frees port slots faster
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

# -----------------------------------------------------------------------------
SYSCTL_D="/etc/sysctl.d"
SWAP_CONF="$SYSCTL_D/99-swap.conf"
NET_CONF="$SYSCTL_D/99-tune-net.conf"
CONNTRACK_CONF="$SYSCTL_D/99-conntrack.conf"
MODPROBE_D="/etc/modprobe.d"
MODPROBE_CONF="$MODPROBE_D/nf_conntrack-hashsize.conf"

DRY_RUN=0
RESTART_XRAY=0
for a in "$@"; do
    case "$a" in
        --dry-run)      DRY_RUN=1 ;;
        --restart-xray) RESTART_XRAY=1 ;;
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
info "Prerequisites"
# -----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo ./tune.sh)"; exit 1; }
[[ -d $SYSCTL_D ]] || { echo "ERROR: $SYSCTL_D missing"; exit 1; }
mkdir -p "$SYSCTL_D" "$MODPROBE_D"

# -----------------------------------------------------------------------------
info "1. Swap / zram behaviour"
# -----------------------------------------------------------------------------
if swapon --show 2>/dev/null | grep -q .; then
    {
        echo "# swap/zram tuning"
        grep -q "^vm.swappiness=" "$SWAP_CONF" 2>/dev/null || echo "vm.swappiness=$SWAPPINESS"
        grep -q "^vm.page-cluster=" "$SWAP_CONF" 2>/dev/null || echo "vm.page-cluster=$PAGE_CLUSTER"
    } > /tmp/swap.conf.new
    if [[ -f "$SWAP_CONF" ]]; then
        c sed -i "s|^vm.swappiness=.*|vm.swappiness=$SWAPPINESS|; s|^vm.page-cluster=.*|vm.page-cluster=$PAGE_CLUSTER|" "$SWAP_CONF"
        c rm -f /tmp/swap.conf.new
    else
        c mv /tmp/swap.conf.new "$SWAP_CONF"
    fi
    c sysctl -w "vm.swappiness=$SWAPPINESS" "vm.page-cluster=$PAGE_CLUSTER"
else
    skip "no swap device — swap part skipped (conntrack/TCP/sniffing still apply)"
fi

# -----------------------------------------------------------------------------
info "2. conntrack: capacity + timeout"
# -----------------------------------------------------------------------------
# hashsize is a module parameter -> must survive reboot via modprobe.d
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

{
    echo "# conntrack capacity & timeout"
    echo "net.netfilter.nf_conntrack_max = $CONNTRACK_MAX"
    echo "net.netfilter.nf_conntrack_tcp_timeout_established = $CONNTRACK_EST_TIMEOUT"
} > /tmp/conntrack.conf.new

# Never *lower* an already-running bigger table; never *raise* an already
# smaller established timeout (shorter timeout = faster zombie cleanup).
CUR_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
[[ "$CUR_MAX" -gt "$CONNTRACK_MAX" ]] && CONNTRACK_MAX=$CUR_MAX
CUR_TO=$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo 0)
[[ "$CUR_TO" -gt 0 && "$CUR_TO" -lt "$CONNTRACK_EST_TIMEOUT" ]] && CONNTRACK_EST_TIMEOUT=$CUR_TO

c mv /tmp/conntrack.conf.new "$CONNTRACK_CONF"
c sysctl -w "net.netfilter.nf_conntrack_max=$CONNTRACK_MAX" \
           "net.netfilter.nf_conntrack_tcp_timeout_established=$CONNTRACK_EST_TIMEOUT"

# -----------------------------------------------------------------------------
info "3. TCP stack: buffers, keepalive, backlogs, TIME_WAIT"
# -----------------------------------------------------------------------------
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
    echo "net.core.default_qdisc = $DEFAULT_QDISC"
    echo "net.ipv4.tcp_congestion_control = $TCP_CONGESTION"
    echo "net.ipv4.ip_forward = $IP_FORWARD"
} > /tmp/tune-net.conf.new
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
      "net.core.default_qdisc=$DEFAULT_QDISC" \
      "net.ipv4.tcp_congestion_control=$TCP_CONGESTION" \
      "net.ipv4.ip_forward=$IP_FORWARD"

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
info "5. Verification"
# -----------------------------------------------------------------------------
[[ "$DRY_RUN" -eq 1 ]] && { echo; echo "Dry-run finished — nothing was changed."; exit 0; }

sysctl vm.swappiness vm.page-cluster \
       net.netfilter.nf_conntrack_max \
       net.netfilter.nf_conntrack_tcp_timeout_established \
       net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
       net.core.rmem_max net.core.wmem_max

if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
    echo "conntrack fill: $(< /proc/sys/net/netfilter/nf_conntrack_count) / $(< /proc/sys/net/netfilter/nf_conntrack_max)"
fi

echo
ok "Done. Persisted across reboots:
  $SWAP_CONF        (swap/zram)
  $CONNTRACK_CONF   (conntrack)
  $NET_CONF         (tcp)
  $MODPROBE_CONF    (conntrack hashsize at module load)
To simulate boot-time application:  sysctl --system"