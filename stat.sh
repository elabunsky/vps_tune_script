#!/usr/bin/env bash
# stat.sh — сводка: система / CPU / память / свап+zram / топ процессов
# положен в /usr/local/bin, запуск: stat.sh  (или ssh fn stat.sh)

if [ -t 1 ]; then
    B=$'\e[1m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' D=$'\e[2m' N=$'\e[0m'
else
    B='' R='' G='' Y='' C='' D='' N=''
fi

hdr() { printf '\n%s%s── %s ──%s\n' "$C" "$B" "$1" "$N"; }

### SYSTEM ##########################################################
hdr "SYSTEM"
printf "host    : %s %s(%s)%s\n" "$(hostname)" "$D" "$(uname -r)" "$N"
printf "date    : %(%F %T)T\n" -1
printf "uptime  : %s\n" "$(uptime -p)"
ncpu=$(nproc)
load1=$(cut -d' ' -f1 /proc/loadavg)
per=$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%.2f", l/n}')
lcol=$G; [ "$(awk -v v="$per" 'BEGIN{print (v>=1)?1:0}')" = 1 ] && lcol=$Y
[ "$(awk -v v="$per" 'BEGIN{print (v>=2)?1:0}')" = 1 ] && lcol=$R
printf "load    : %s%s%s %s[%.2f per core, %s core(s)]%s\n" "$lcol" "$load1" "$N" "$D" "$per" "$ncpu" "$N"

### CPU (срез за 1 секунду) ##########################################
hdr "CPU"
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 rest < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 rest < /proc/stat
du=$((u2 + n2 - u1 - n1)); ds=$((s2 - s1)); di=$((i2 - i1))
dw=$((w2 - w1)); dsq=$((sirq2 - sirq1))
tot=$((du + ds + di + dw + dsq)); [ "$tot" -gt 0 ] || tot=1
awk -v u=$du -v s=$ds -v i=$di -v w=$dw -v q=$dsq -v t=$tot \
    -v G="$G" -v Y="$Y" -v R="$R" -v N="$N" 'BEGIN{
    id = i*100/t; col = id < 10 ? R : (id < 40 ? Y : G);
    printf "cpu     : user %.1f%% | sys %.1f%% | softirq %.1f%% | iowait %.1f%% | idle %s%.1f%%%s\n",
           u*100/t, s*100/t, q*100/t, w*100/t, col, id, N;
}'
ks=$(ps -C kswapd0 -o time= 2>/dev/null | tr -d ' '); ks=${ks:-00:00:00}
upsec=$(cut -d. -f1 /proc/uptime)
awk -v t="$ks" -v up="$upsec" -v D="$D" -v N="$N" 'BEGIN{
    n = split(t, a, ":");
    if (n == 3)      sec = a[1]*3600 + a[2]*60 + a[3];
    else if (n == 2) sec = a[1]*60 + a[2];
    else             sec = a[1];
    printf "kswapd  : %s CPU since boot %s(%.3f%% avg)%s\n", t, D, (up > 0 ? sec*100/up : 0), N;
}'
if [ -r /proc/pressure/cpu ]; then
    while read -r kind fields; do
        set -- $fields
        [ "$kind" = "full" ] && continue
        for kv in $fields; do
            case $kv in
                avg10=*) a10=${kv#avg10=} ;;
                avg60=*) a60=${kv#avg60=} ;;
                avg300=*) a300=${kv#avg300=} ;;
            esac
        done
        awk -v k="$kind" -v a="$a10" -v b="$a60" -v c="$a300" \
            -v G="$G" -v Y="$Y" -v R="$R" -v D="$D" -v N="$N" 'BEGIN{
            col = c >= 10 ? R : (c >= 2 ? Y : G);
            printf "PSI %s: some %s%.1f%%(10s) %.1f%%(60s) %.1f%%(300s)%s %s| доля времени, когда задачи ждали CPU%s\n",
                   k, col, a, b, c, N, D, N;
        }'
    done < /proc/pressure/cpu
fi

### MEMORY ###########################################################
hdr "MEMORY"
awk -v G="$G" -v Y="$Y" -v R="$R" -v N="$N" '{
    if ($1 == "MemTotal:")     t = $2;
    if ($1 == "MemFree:")      f = $2;
    if ($1 == "MemAvailable:") a = $2;
    if ($1 == "Cached:")       c = $2;
    if ($1 == "Buffers:")      b = $2;
} END {
    t /= 1024; f /= 1024; a /= 1024;
    used = t - f; bc = (b + c) / 1024;
    col = a < 128 ? R : (a < 256 ? Y : G);
    printf "RAM     : %.0f MiB total | used %.0f | free %.0f | buff/cache %.0f | avail %s%.0f MiB%s\n",
           t, used, f, bc, col, a, N;
}' /proc/meminfo

### SWAP ##############################################################
hdr "SWAP"
zline=$(awk '$1 ~ /zram/ && $3 ~ /^[0-9]+$/ {print; exit}' /proc/swaps)
if [ -n "$zline" ]; then
    zdev=$(echo "$zline" | awk '{print $1}')
    zs=$(echo "$zline" | awk '{print $3}'); zu=$(echo "$zline" | awk '{print $4}')
    read -r data compr total memlimit maxmem rest < "/sys/block/$(basename "$zdev")/mm_stat" 2>/dev/null || data=0
    awk -v zs=$zs -v zu=$zu -v data=$data -v compr=$compr -v total=$total -v maxmem=$maxmem \
        -v G="$G" -v Y="$Y" -v R="$R" -v N="$N" -v C="$C" -v D="$D" 'BEGIN{
        zs /= 1024; zu /= 1024; zf = zs - zu;
        pct = zu * 100 / zs;
        col = pct > 90 ? R : (pct > 75 ? Y : G);
        printf "%-8s: %s%6.1f MiB%s | used %s%6.1f MiB (%.0f%%)%s | free %6.1f MiB\n",
               "zram", C, zs, N, col, zu, pct, col, zf;
        ratio = (compr > 0) ? data / compr : 0;
        printf "         lz4  : %6.1f MiB сжато в %.1f MiB %s(x%.2f)%s | RAM cost %.1f MiB | peak %.1f MiB\n",
               data/1048576, compr/1048576, D, ratio, N, total/1048576, maxmem/1048576;
    }'
else
    echo "zram    : отсутствует"
fi
fline=$(awk '$1 == "/swapfile" {print; exit}' /proc/swaps)
if [ -n "$fline" ]; then
    fs=$(echo "$fline" | awk '{print $3}'); fu=$(echo "$fline" | awk '{print $4}')
    awk -v s=$fs -v u=$fu -v G="$G" -v Y="$Y" -v N="$N" 'BEGIN{
        s /= 1024; u /= 1024; col = u > 0 ? Y : G;
        printf "%-8s: %6.1f MiB | used %s%6.1f MiB%s | free %6.1f MiB\n", "swapfile", s, col, u, col, s - u;
    }'
fi
awk '$3 ~ /^[0-9]+$/ {tot += $3; usd += $4} END {printf "%-8s: %6.1f MiB | used %6.1f MiB | free %6.1f MiB\n", "TOTAL", tot/1024, usd/1024, (tot-usd)/1024}' /proc/swaps

### ZRAM TRAFFIC (с бот-апа) ##########################################
hdr "ZRAM TRAFFIC (since boot)"
if [ -r /sys/block/zram0/stat ]; then
    read -r rc rm rs rt wc wm ws wt rest < /sys/block/zram0/stat
    read -r fr fw badio nf < /sys/block/zram0/io_stat
    pswpin=$(awk '/^pswpin/ {print $2}' /proc/vmstat)
    pswpout=$(awk '/^pswpout/ {print $2}' /proc/vmstat)
    awk -v rs=$rs -v ws=$ws -v rc=$rc -v wc=$wc -v pin=$pswpin -v pout=$pswpout \
        -v fr=$fr -v fw=$fw -v wt=$wt -v G="$G" -v Y="$Y" -v R="$R" -v N="$N" 'BEGIN{
        printf "written : %8.1f MiB (%d pages) | read %8.1f MiB (%d pages)\n",
               ws*512/1048576, wc, rs*512/1048576, rc;
        so = (pout > 0) ? wc * 100 / pout : 0;
        si = (pin > 0) ? rc * 100 / pin : 0;
        col = so > 90 ? G : (so > 50 ? Y : R);
        printf "share   : %s%.0f%%%s swap-out и %.0f%% swap-in прошло через zram (диск не тронут)\n", col, so, col, si;
        es = fr + fw;
        ecol = es > 0 ? R : G;
        printf "errors  : %s%d%s | время записи %d ms\n", ecol, es, ecol, wt;
    }'
else
    echo "zram0 статистика недоступна"
fi

### CONNTRACK #########################################################
hdr "CONNTRACK"
if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
    ctmax=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    ctcnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    awk -v c=$ctcnt -v m=$ctmax -v G="$G" -v Y="$Y" -v R="$R" -v N="$N" 'BEGIN{
        pct = c * 100 / m;
        col = pct > 90 ? R : (pct > 75 ? Y : G);
        printf "fill    : %s%d / %d (%.0f%%)%s\n", col, c, m, pct, N;
    }'
    drops=$(dmesg 2>/dev/null | grep -c "table full")
    [ "$drops" -gt 0 ] && { printf "drops   : %s%d «table full» since boot%s — были дропы новых соединений (причина фризов), см. dmesg -T | grep 'table full'\n" "$R" "$drops" "$N"; } \
                        || printf "drops   : %s0 «table full» since boot%s\n" "$G" "$N"
else
    echo "conntrack недоступен"
fi

### TOP PROCESSES #####################################################
hdr "TOP PROCESSES (CPU)"
ps -eo pcpu,pmem,rss,time,comm --sort=-pcpu 2>/dev/null | head -8 | \
    awk 'NR == 1 {
        printf "%6s %6s %8s  %-9s  %s\n", "%CPU", "%MEM", "RSS MiB", "TIME", "COMMAND"; next
    } $5 != "ps" && $5 != "top" && shown++ < 5 { printf "%6.1f %6.1f %8.1f  %-9s  %s\n", $1, $2, $3/1024, $4, $5 }'
printf '\n'
