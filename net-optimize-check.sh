#!/usr/bin/env bash
# ==============================================================================
# 🔍 Net-Optimize 状态检测脚本 v1.3（配合 v3.5.0）
# 新增：NIC offload / RPS/RFS / IPv6 MSS / DSCP / initcwnd / 激进模式检测
# ==============================================================================
set -euo pipefail

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }
title(){ echo "============================================================"; }
sep(){ echo "------------------------------------------------------------"; }

has(){ command -v "$1" >/dev/null 2>&1; }
get(){ sysctl -n "$1" 2>/dev/null || echo "N/A"; }
has_key(){ [[ -e "/proc/sys/${1//./\/}" ]]; }

safe_grep_count() {
  local pattern="$1" file="$2"
  local out
  out="$(grep -cE "$pattern" "$file" 2>/dev/null || true)"
  out="${out%%$'\n'*}"
  echo "${out:-0}"
}

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

svc_state() {
  local s="$1"
  if unit_exists "$s"; then
    local en act
    en="$(systemctl is-enabled "$s" 2>/dev/null || true)"
    act="$(systemctl is-active "$s" 2>/dev/null || true)"
    if [[ "$act" == "active" ]]; then
      green "  - $s: enabled=$en, active=$act"
    else
      yellow "  - $s: enabled=$en, active=$act"
    fi
  else
    echo "  - $s: (not installed)"
  fi
}

detect_ipt_backend() {
  local cmd
  for cmd in iptables iptables-legacy iptables-nft; do
    has "$cmd" || continue
    local cnt
    cnt="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
    cnt="${cnt%%$'\n'*}"; cnt="${cnt:-0}"
    [ "$cnt" -gt 0 ] && { echo "$cmd"; return 0; }
  done
  if has iptables; then
    local warn
    warn="$(iptables -t mangle -S POSTROUTING 2>&1 || true)"
    echo "$warn" | grep -qi 'iptables-legacy' && has iptables-legacy && { echo "iptables-legacy"; return 0; }
    echo "iptables"; return 0
  fi
  has iptables-legacy && { echo "iptables-legacy"; return 0; }
  has iptables-nft && { echo "iptables-nft"; return 0; }
  echo ""
}

detect_iface() {
  local iface=""
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -n1 || true)
  [ -z "$iface" ] && iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1 || true)
  echo "$iface"
}

IPT_CMD="$(detect_ipt_backend)"
OUT_IFACE="$(detect_iface)"

echo "🔍 开始系统状态检测（Net-Optimize v3.5.0）..."
title

# === [1] 网络优化关键状态 ===
echo "🌐 [1] 网络优化关键状态"
sep

cc="$(get net.ipv4.tcp_congestion_control)"
qdisc="$(get net.core.default_qdisc)"

_aggressive=0
if [[ -f /etc/net-optimize/config ]] && grep -q 'AGGRESSIVE_MODE=1' /etc/net-optimize/config 2>/dev/null; then _aggressive=1; fi
[[ "$qdisc" == "pfifo_fast" ]] && [[ "$(get net.core.netdev_max_backlog)" == "1000000" ]] && _aggressive=1
[[ "$_aggressive" -eq 1 ]] && green "⚡ 激进模式：已开启"

[[ "$cc" == bbr* || "$cc" == "bbrplus" ]] && green "✅ 拥塞算法：$cc" || yellow "⚠️ 拥塞算法：$cc（非 BBR 系列）"
green "✅ 默认队列：$qdisc"
has_key net.ipv4.tcp_mtu_probing && green "✅ TCP MTU 探测：$(get net.ipv4.tcp_mtu_probing)"

echo "✅ TCP 参数："
echo "  🔹 tcp_window_scaling  = $(get net.ipv4.tcp_window_scaling)"
echo "  🔹 tcp_sack            = $(get net.ipv4.tcp_sack)"
echo "  🔹 tcp_notsent_lowat   = $(get net.ipv4.tcp_notsent_lowat)"
echo "  🔹 tcp_no_metrics_save = $(get net.ipv4.tcp_no_metrics_save)"
echo "  🔹 tcp_autocorking     = $(get net.ipv4.tcp_autocorking)"
echo "✅ UDP 缓冲："
echo "  🔹 udp_rmem_min = $(get net.ipv4.udp_rmem_min)"
echo "  🔹 udp_wmem_min = $(get net.ipv4.udp_wmem_min)"
echo "  🔹 udp_mem      = $(get net.ipv4.udp_mem)"
echo "✅ TCP 缓冲："
echo "  🔹 tcp_rmem = $(get net.ipv4.tcp_rmem)"
echo "  🔹 tcp_wmem = $(get net.ipv4.tcp_wmem)"
echo "✅ Core 缓冲："
echo "  🔹 rmem_default = $(get net.core.rmem_default)"
echo "  🔹 wmem_default = $(get net.core.wmem_default)"
echo "  🔹 rmem_max     = $(get net.core.rmem_max)"
echo "  🔹 wmem_max     = $(get net.core.wmem_max)"
echo "  🔹 netdev_max_backlog = $(get net.core.netdev_max_backlog)"

rp="$(get net.ipv4.conf.all.rp_filter)"
case "$rp" in
  0) yellow "⚠️ rp_filter = 0（关闭）" ;; 1) green "✅ rp_filter = 1（严格）" ;;
  2) green "✅ rp_filter = 2（松散，推荐）" ;; *) echo "ℹ️ rp_filter = $rp" ;;
esac

# === [2] 网卡 Offload / RPS / RFS ===
sep
echo "🔧 [2] 网卡 Offload / RPS / RFS"
sep

if [[ -n "$OUT_IFACE" ]]; then
  echo "  出口网卡: $OUT_IFACE"
  if has ethtool; then
    _offloads=""
    for _feat in generic-receive-offload generic-segmentation-offload tcp-segmentation-offload scatter-gather; do
      _val="$(ethtool -k "$OUT_IFACE" 2>/dev/null | grep "^${_feat}:" | awk '{print $2}' || true)"
      case "$_feat" in
        generic-receive-offload) _s="GRO" ;; generic-segmentation-offload) _s="GSO" ;;
        tcp-segmentation-offload) _s="TSO" ;; scatter-gather) _s="SG" ;;
      esac
      [[ "$_val" == "on" ]] && _offloads+=" ✅$_s" || _offloads+=" ❌$_s"
    done
    echo "  Offload:$_offloads"
  fi

  _txql="$(ip link show "$OUT_IFACE" 2>/dev/null | grep -oP 'qlen \K\d+' || true)"
  [[ -n "$_txql" ]] && { [[ "$_txql" -ge 10000 ]] && green "  ✅ txqueuelen: $_txql（激进）" || echo "  🔹 txqueuelen: $_txql"; }

  _rps_mask=""
  for _q in /sys/class/net/"$OUT_IFACE"/queues/rx-*/rps_cpus; do
    [[ -f "$_q" ]] && _rps_mask="$(cat "$_q" 2>/dev/null || true)" && break
  done
  [[ -n "$_rps_mask" && "$_rps_mask" != "0" && "$_rps_mask" != "00000000" ]] \
    && green "  ✅ RPS 掩码: $_rps_mask" || echo "  🔹 RPS: 未启用或单核"

  _rfs="$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true)"
  [[ -n "$_rfs" && "$_rfs" -gt 0 ]] && green "  ✅ RFS: entries=$_rfs" || echo "  🔹 RFS: 未启用"

  has tc && { _tc="$(tc qdisc show dev "$OUT_IFACE" root 2>/dev/null | awk '{print $2}' | head -n1 || true)"; [[ -n "$_tc" ]] && echo "  🔹 tc qdisc: $_tc"; }

  [[ -f /etc/udev/rules.d/99-net-optimize-offload.rules ]] && green "  ✅ offload 持久化已配置"
  [[ -f /etc/tmpfiles.d/net-optimize-rps.conf ]] && green "  ✅ RPS/RFS 持久化已配置"
else
  yellow "  ⚠️ 无法检测出口网卡"
fi

# === [3] conntrack ===
sep
echo "🔗 [3] conntrack / netfilter 状态"
sep

if has_key net.netfilter.nf_conntrack_max || [[ -d /proc/sys/net/netfilter ]] || [[ -f /proc/net/nf_conntrack ]]; then
  green "✅ nf_conntrack 可用"
  echo "  🔸 nf_conntrack_max       = $(get net.netfilter.nf_conntrack_max)"
  echo "  🔸 udp_timeout            = $(get net.netfilter.nf_conntrack_udp_timeout)"
  echo "  🔸 udp_timeout_stream     = $(get net.netfilter.nf_conntrack_udp_timeout_stream)"
  echo "  🔸 tcp_timeout_established = $(get net.netfilter.nf_conntrack_tcp_timeout_established)"
else
  yellow "ℹ️ nf_conntrack 未启用"
fi

if [[ -f /proc/net/nf_conntrack ]]; then
  tcp_c="$(safe_grep_count '^tcp' /proc/net/nf_conntrack)"
  udp_c="$(safe_grep_count '^udp' /proc/net/nf_conntrack)"
  total_c="$(wc -l < /proc/net/nf_conntrack 2>/dev/null | tr -d ' ' || echo 0)"
  other_c=$(( total_c - tcp_c - udp_c )); [[ "$other_c" -lt 0 ]] && other_c=0
  echo "  🔸 TCP=$tcp_c UDP=$udp_c Other=$other_c Total=$total_c"
fi

has conntrack && echo "  🔸 conntrack -C = $(conntrack -C 2>/dev/null | tr -d ' ' || echo N/A)"

_ct_found=0
for _ct_cmd in iptables iptables-legacy iptables-nft; do
  has "$_ct_cmd" || continue
  inv_i="$("$_ct_cmd" -t filter -S INPUT 2>/dev/null | grep -c 'conntrack.*INVALID.*DROP' || true)"
  inv_o="$("$_ct_cmd" -t filter -S OUTPUT 2>/dev/null | grep -c 'conntrack.*INVALID.*DROP' || true)"
  inv_i="${inv_i%%$'\n'*}"; inv_o="${inv_o%%$'\n'*}"
  [[ "${inv_i:-0}" -ge 1 && "${inv_o:-0}" -ge 1 ]] && { green "✅ INVALID DROP（INPUT+OUTPUT）[$_ct_cmd]"; _ct_found=1; break; }
done
[[ "$_ct_found" -eq 0 ]] && yellow "⚠️ INVALID DROP 规则不完整"

# === [4] ulimit ===
sep
echo "📂 [4] ulimit / fd"
sep
green "✅ ulimit -n：$(ulimit -n)"
[[ -f /etc/security/limits.d/99-net-optimize.conf ]] && green "✅ limits.d 已配置"
nofile="$(grep -E '^DefaultLimitNOFILE' /etc/systemd/system.conf 2>/dev/null || true)"
[[ -n "$nofile" ]] && green "✅ systemd: $nofile"

# === [5] MSS / DSCP ===
sep
echo "📡 [5] MSS Clamping（IPv4 + IPv6）/ DSCP"
sep

for _label_cmd in "IPv4:iptables:iptables-legacy:iptables-nft" "IPv6:ip6tables:ip6tables-legacy:ip6tables-nft"; do
  IFS=':' read -r _label _c1 _c2 _c3 <<<"$_label_cmd"
  _found=0
  for _cmd in $_c1 $_c2 $_c3; do
    has "$_cmd" || continue
    _cnt="$("$_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
    _cnt="${_cnt%%$'\n'*}"; _cnt="${_cnt:-0}"
    [ "$_cnt" -eq 0 ] && continue
    _found=1
    [[ "$_cnt" -eq 1 ]] && green "✅ $_label TCPMSS：1 条 [$_cmd]" || yellow "⚠️ $_label TCPMSS：$_cnt 条 [$_cmd]"
    "$_cmd" -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -E 'TCPMSS' || true
    break
  done
  [[ "$_found" -eq 0 ]] && echo "  ℹ️ $_label TCPMSS：未发现"
done

_dscp_found=0
for _dcmd in iptables iptables-legacy iptables-nft; do
  has "$_dcmd" || continue
  _dc="$("$_dcmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'DSCP' || true)"
  _dc="${_dc%%$'\n'*}"; _dc="${_dc:-0}"
  [[ "$_dc" -gt 0 ]] && { green "✅ IPv4 DSCP 标记：$_dc 条 [$_dcmd]（QUIC 加速）"; _dscp_found=1; break; }
done
for _dcmd6 in ip6tables ip6tables-legacy ip6tables-nft; do
  has "$_dcmd6" || continue
  _dc6="$("$_dcmd6" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'DSCP' || true)"
  _dc6="${_dc6%%$'\n'*}"; _dc6="${_dc6:-0}"
  [[ "$_dc6" -gt 0 ]] && { green "✅ IPv6 DSCP 标记：$_dc6 条 [$_dcmd6]（QUIC 加速）"; _dscp_found=1; break; }
done
[[ "$_dscp_found" -eq 0 ]] && echo "  ℹ️ DSCP 标记：未发现"

[[ -f /etc/net-optimize/config ]] && { green "✅ 配置文件："; sed 's/^/    /' /etc/net-optimize/config; }

# === [6] initcwnd ===
sep
echo "📡 [6] initcwnd / 路由优化"
sep

_dgw="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
_cwnd="$(echo "$_dgw" | grep -oP 'initcwnd \K\d+' || true)"
[[ -n "$_cwnd" ]] && { [[ "$_cwnd" -ge 64 ]] && green "  ✅ IPv4 initcwnd=$_cwnd（激进）" || green "  ✅ IPv4 initcwnd=$_cwnd"; } || echo "  🔹 IPv4 initcwnd 未设置"

_dgw6="$(ip -6 route show default 2>/dev/null | head -n1 || true)"
_cwnd6="$(echo "$_dgw6" | grep -oP 'initcwnd \K\d+' || true)"
[[ -n "$_cwnd6" ]] && green "  ✅ IPv6 initcwnd=$_cwnd6" || echo "  🔹 IPv6 initcwnd 未设置"

# === [7] UDP 监听 ===
sep
echo "🧷 [7] UDP 监听 / 活跃连接"
sep
has ss && { ss -u -l -n -p 2>/dev/null | head -n 20 || true; }
if has conntrack; then
  echo "✅ conntrack 活跃："
  echo "  🔸 UDP：$(conntrack -L -p udp 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
  echo "  🔸 TCP：$(conntrack -L -p tcp 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
fi

# === [8] sysctl 一致性 ===
sep
echo "🗂 [8] sysctl 持久化"
sep

SYSCTL_FILE="/etc/sysctl.d/99-net-optimize.conf"
OVERRIDE_FILE="/etc/sysctl.d/zzz-net-optimize-override.conf"
[[ -f "$SYSCTL_FILE" ]] && green "✅ 主配置：$SYSCTL_FILE" || yellow "⚠️ 未发现 $SYSCTL_FILE"
[[ -f "$OVERRIDE_FILE" ]] && green "✅ Override：$OVERRIDE_FILE" || yellow "⚠️ 未发现 $OVERRIDE_FILE"

if [[ -f "$SYSCTL_FILE" ]]; then
  echo "  关键项对比："
  for k in net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_window_scaling net.ipv4.tcp_sack net.core.rmem_max net.core.wmem_max net.ipv4.conf.all.rp_filter net.netfilter.nf_conntrack_max; do
    rt="$(get "$k")"
    fv="$(awk -v kk="$k" '$0 ~ "^[[:space:]]*#" {next} $1 == kk && $2 == "=" {sub("^[^=]*=[[:space:]]*", "", $0); gsub(/[[:space:]]+$/, "", $0); print $0}' "$SYSCTL_FILE" 2>/dev/null | tail -n1)"
    fv="${fv:-N/A}"
    rt_n="$(echo "$rt" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"; fv_n="$(echo "$fv" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
    if [[ "$fv_n" == "N/A" ]]; then echo "  ℹ️ $k: runtime=$rt"
    elif [[ "$rt_n" != "$fv_n" ]]; then
      # qdisc/cc 可能由外部内核脚本管控，不一致时降级为提示
      if [[ "$k" == "net.core.default_qdisc" || "$k" == "net.ipv4.tcp_congestion_control" ]]; then
        echo "  ℹ️ $k: runtime=$rt_n（外部设置）, file=$fv_n"
      else
        yellow "  ⚠️ $k: runtime=$rt file=$fv"
      fi
    else green "  ✅ $k: $rt"; fi
  done
fi

disabled_count="$(ls /etc/sysctl.d/*.disabled-by-net-optimize-* 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
[[ "$disabled_count" -gt 0 ]] && yellow "  ℹ️ $disabled_count 个被禁用的冲突文件"

# === [9] 开机自启 ===
sep
echo "🛠 [9] 开机自启服务"
sep
svc_state "net-optimize.service"
[[ -x /usr/local/sbin/net-optimize-apply ]] && green "✅ apply 脚本存在" || yellow "⚠️ apply 脚本缺失"
[[ -f /etc/modules-load.d/conntrack.conf ]] && green "✅ conntrack 模块开机加载"

# === [10] Nginx ===
sep
echo "🔧 [10] Nginx"
sep
if has apt-cache; then
  has nginx && { green "✅ Nginx $(nginx -v 2>&1 | awk -F/ '{print $2}')"; systemctl is-active nginx >/dev/null 2>&1 && green "✅ 运行中" || yellow "⚠️ 未运行"; } || echo "  ℹ️ 未安装"
  [[ -f /etc/cron.d/net-optimize-nginx-update ]] && green "✅ 自动更新 cron 已配置"
fi

# === [11] 系统信息 ===
sep
echo "💻 [11] 系统信息"
sep
printf "  %-10s: %s\n" "内核" "$(uname -r)"
printf "  %-10s: %s\n" "CPU" "$(nproc 2>/dev/null || echo '?') 核"
if has free; then
  printf "  %-10s: %s\n" "内存" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
  printf "  %-10s: %s\n" "可用" "$(free -h 2>/dev/null | awk '/^Mem:/{print $7}')"
elif [[ -f /proc/meminfo ]]; then
  _mem_total="$(awk '/^MemTotal:/{printf "%.0f MB", $2/1024}' /proc/meminfo 2>/dev/null || echo '?')"
  _mem_avail="$(awk '/^MemAvailable:/{printf "%.0f MB", $2/1024}' /proc/meminfo 2>/dev/null || echo '?')"
  printf "  %-10s: %s\n" "内存" "$_mem_total"
  printf "  %-10s: %s\n" "可用" "$_mem_avail"
else
  printf "  %-10s: %s\n" "内存" "N/A"
  printf "  %-10s: %s\n" "可用" "N/A"
fi
printf "  %-10s: %s\n" "运行" "$(uptime -p 2>/dev/null || echo '?')"
[[ -f /usr/local/sbin/net-optimize-ultimate.sh ]] && green "✅ 脚本版本：$(grep -oP 'v\d+\.\d+\.\d+' /usr/local/sbin/net-optimize-ultimate.sh | head -n1)"
[[ -n "$IPT_CMD" ]] && echo "  ℹ️ iptables 后端：$IPT_CMD"
[[ -n "$OUT_IFACE" ]] && echo "  ℹ️ 出口网卡：$OUT_IFACE"

title
green "🎉 检测完成"
