#!/usr/bin/env bash
# ==============================================================================
# 🔍 Net-Optimize 状态检测脚本 v1.2（配合 v3.4.0）
# 修复：iptables 多后端检测（nft / legacy 自动遍历）
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

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

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

# --- 检测实际可用的 iptables 后端 ---
# 返回能看到 TCPMSS 规则的后端，如果都没有则返回有 legacy 警告时优先 legacy
detect_ipt_backend() {
  local cmd
  # 优先返回有 TCPMSS 规则的后端
  for cmd in iptables iptables-legacy iptables-nft; do
    has "$cmd" || continue
    local cnt
    cnt="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
    cnt="${cnt%%$'\n'*}"; cnt="${cnt:-0}"
    if [ "$cnt" -gt 0 ]; then
      echo "$cmd"
      return 0
    fi
  done
  # 没有规则时，检测默认 iptables 是否有 legacy 警告
  if has iptables; then
    local warn
    warn="$(iptables -t mangle -S POSTROUTING 2>&1 || true)"
    if echo "$warn" | grep -qi 'iptables-legacy' && has iptables-legacy; then
      echo "iptables-legacy"
      return 0
    fi
    echo "iptables"
    return 0
  fi
  if has iptables-legacy; then echo "iptables-legacy"; return 0; fi
  if has iptables-nft; then echo "iptables-nft"; return 0; fi
  echo ""
}

# 检测后端（全局使用）
IPT_CMD="$(detect_ipt_backend)"

echo "🔍 开始系统状态检测（Net-Optimize v3.4.0 + Nginx）..."
title

# =================================================================
echo "🌐 [1] 网络优化关键状态"
sep

cc="$(get net.ipv4.tcp_congestion_control)"
qdisc="$(get net.core.default_qdisc)"

if [[ "$cc" == bbr* || "$cc" == "bbrplus" ]]; then
  green "✅ 拥塞算法：$cc"
else
  yellow "⚠️ 拥塞算法：$cc（非 BBR 系列）"
fi

green "✅ 默认队列：$qdisc"
has_key net.ipv4.tcp_mtu_probing && green "✅ TCP MTU 探测：$(get net.ipv4.tcp_mtu_probing)"

echo "✅ UDP 缓冲："
echo "  🔹 udp_rmem_min = $(get net.ipv4.udp_rmem_min)"
echo "  🔹 udp_wmem_min = $(get net.ipv4.udp_wmem_min)"
echo "  🔹 udp_mem      = $(get net.ipv4.udp_mem)"
echo "✅ TCP 缓冲："
echo "  🔹 tcp_rmem     = $(get net.ipv4.tcp_rmem)"
echo "  🔹 tcp_wmem     = $(get net.ipv4.tcp_wmem)"
echo "✅ Core 缓冲："
echo "  🔹 rmem_default = $(get net.core.rmem_default)"
echo "  🔹 wmem_default = $(get net.core.wmem_default)"
echo "  🔹 rmem_max     = $(get net.core.rmem_max)"
echo "  🔹 wmem_max     = $(get net.core.wmem_max)"

# rp_filter
rp="$(get net.ipv4.conf.all.rp_filter)"
case "$rp" in
  0) yellow "⚠️ rp_filter = 0（关闭，无 IP spoofing 防护）" ;;
  1) green "✅ rp_filter = 1（严格模式）" ;;
  2) green "✅ rp_filter = 2（松散模式，推荐）" ;;
  *) echo "ℹ️ rp_filter = $rp" ;;
esac

# =================================================================
sep
echo "🔗 [2] conntrack / netfilter 状态"
sep

if has_key net.netfilter.nf_conntrack_max || [[ -d /proc/sys/net/netfilter ]] || [[ -f /proc/net/nf_conntrack ]]; then
  green "✅ nf_conntrack 可用（模块或内建）"
  echo "  🔸 nf_conntrack_max                    = $(get net.netfilter.nf_conntrack_max)"
  echo "  🔸 nf_conntrack_udp_timeout            = $(get net.netfilter.nf_conntrack_udp_timeout)"
  echo "  🔸 nf_conntrack_udp_timeout_stream     = $(get net.netfilter.nf_conntrack_udp_timeout_stream)"
  echo "  🔸 nf_conntrack_tcp_timeout_established = $(get net.netfilter.nf_conntrack_tcp_timeout_established)"
  echo "  🔸 nf_conntrack_tcp_timeout_time_wait   = $(get net.netfilter.nf_conntrack_tcp_timeout_time_wait)"
  echo "  🔸 nf_conntrack_tcp_timeout_close_wait  = $(get net.netfilter.nf_conntrack_tcp_timeout_close_wait)"
  echo "  🔸 nf_conntrack_tcp_timeout_fin_wait    = $(get net.netfilter.nf_conntrack_tcp_timeout_fin_wait)"
else
  yellow "ℹ️ nf_conntrack 未启用或不可用"
fi

if [[ -f /proc/net/nf_conntrack ]]; then
  tcp_c="$(safe_grep_count '^tcp' /proc/net/nf_conntrack)"
  udp_c="$(safe_grep_count '^udp' /proc/net/nf_conntrack)"
  total_c="$(wc -l < /proc/net/nf_conntrack 2>/dev/null | tr -d ' ' || echo 0)"
  other_c=$(( total_c - tcp_c - udp_c ))
  [[ "$other_c" -lt 0 ]] && other_c=0

  green "✅ /proc/net/nf_conntrack 可读"
  echo "  🔸 TCP entries   = $tcp_c"
  echo "  🔸 UDP entries   = $udp_c"
  echo "  🔸 Other entries = $other_c"
  echo "  🔸 Total entries = $total_c"

  if [[ "$tcp_c" -eq 0 && "$udp_c" -eq 0 && "$total_c" -gt 0 ]]; then
    yellow "  ℹ️ 表中主要是 other 协议记录（ICMP/GRE 等），TCP/UDP 为 0 属正常"
  fi
else
  yellow "ℹ️ /proc/net/nf_conntrack 不存在（可能是 nft / 内核暴露差异）"
fi

if has conntrack; then
  ccount="$(conntrack -C 2>/dev/null | tr -d ' ' || true)"
  echo "  🔸 conntrack -C（内核计数器） = ${ccount:-N/A}"
fi

if has lsmod; then
  if lsmod | grep -q '^nf_conntrack'; then
    green "✅ lsmod 可见 nf_conntrack（非内建）"
  else
    echo "  ℹ️ lsmod 未显示 nf_conntrack（可能是内建，属正常）"
  fi
fi

# conntrack 触发规则检测（遍历所有后端）
_ct_found=0
for _ct_cmd in iptables iptables-legacy iptables-nft; do
  has "$_ct_cmd" || continue
  inv_input="$("$_ct_cmd" -t filter -S INPUT 2>/dev/null | grep -c 'conntrack.*INVALID.*DROP' || true)"
  inv_output="$("$_ct_cmd" -t filter -S OUTPUT 2>/dev/null | grep -c 'conntrack.*INVALID.*DROP' || true)"
  inv_input="${inv_input%%$'\n'*}"; inv_input="${inv_input:-0}"
  inv_output="${inv_output%%$'\n'*}"; inv_output="${inv_output:-0}"

  if [[ "$inv_input" -ge 1 && "$inv_output" -ge 1 ]]; then
    green "✅ conntrack 触发规则：INVALID DROP（INPUT + OUTPUT）[$_ct_cmd]"
    _ct_found=1
    break
  fi
done
if [[ "$_ct_found" -eq 0 ]]; then
  yellow "⚠️ conntrack 触发规则不完整（所有后端均未检测到 INVALID DROP）"
fi

# =================================================================
sep
echo "📂 [3] ulimit / fd"
sep

green "✅ 当前 ulimit -n：$(ulimit -n)"
if [[ -f /etc/security/limits.d/99-net-optimize.conf ]]; then
  green "✅ limits.d 已写入：/etc/security/limits.d/99-net-optimize.conf"
else
  yellow "⚠️ 未发现 limits.d 配置"
fi

nofile="$(grep -E '^DefaultLimitNOFILE' /etc/systemd/system.conf 2>/dev/null || true)"
if [[ -n "$nofile" ]]; then
  green "✅ systemd: $nofile"
else
  echo "  ℹ️ systemd system.conf 未设置 DefaultLimitNOFILE"
fi

# =================================================================
sep
echo "📡 [4] MSS Clamping 规则"
sep

_mss_found=0
for _cmd in iptables iptables-legacy iptables-nft; do
  has "$_cmd" || continue
  _cnt="$("$_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
  _cnt="${_cnt%%$'\n'*}"; _cnt="${_cnt:-0}"
  [ "$_cnt" -eq 0 ] && continue

  _mss_found=1
  echo "✅ $_cmd mangle/POSTROUTING："
  "$_cmd" -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -E 'TCPMSS|Chain|pkts|bytes' || true

  if [ "$_cnt" -gt 1 ]; then
    yellow "⚠️ 发现多条 TCPMSS 规则：$_cnt 条（可能重复叠加）"
  else
    green "✅ TCPMSS 规则数量：1（正常）"
  fi
  break
done

if [ "$_mss_found" -eq 0 ]; then
  yellow "⚠️ 所有 iptables 后端均未发现 TCPMSS 规则"
fi

if has nft; then
  nft_mss="$(nft list chain inet mangle postrouting 2>/dev/null | grep -cE 'maxseg|TCPMSS' || true)"
  nft_mss="${nft_mss%%$'\n'*}"; nft_mss="${nft_mss:-0}"
  if [[ "$nft_mss" -gt 0 ]]; then
    echo "  ℹ️ nft inet mangle 中也有 $nft_mss 条 MSS 规则"
  fi
fi

# MSS config 文件
if [[ -f /etc/net-optimize/config ]]; then
  green "✅ MSS 配置文件：/etc/net-optimize/config"
  sed 's/^/    /' /etc/net-optimize/config
else
  yellow "⚠️ 未发现 /etc/net-optimize/config"
fi

# =================================================================
sep
echo "🧷 [5] UDP 监听 / 活跃连接"
sep

echo "✅ UDP 监听（ss）："
if has ss; then
  ss -u -l -n -p 2>/dev/null | head -n 30 || echo "  (none)"
else
  echo "  (ss not installed)"
fi

if has conntrack; then
  udp_lines="$(conntrack -L -p udp 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
  tcp_lines="$(conntrack -L -p tcp 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
  echo "✅ conntrack 活跃连接（趋势参考）："
  echo "  🔸 UDP 活跃：$udp_lines"
  echo "  🔸 TCP 活跃：$tcp_lines"
fi

# =================================================================
sep
echo "🗂 [6] sysctl 持久化与运行态一致性"
sep

SYSCTL_FILE="/etc/sysctl.d/99-net-optimize.conf"
OVERRIDE_FILE="/etc/sysctl.d/zzz-net-optimize-override.conf"

if [[ -f "$SYSCTL_FILE" ]]; then
  green "✅ 主配置文件：$SYSCTL_FILE"
else
  yellow "⚠️ 未发现：$SYSCTL_FILE"
fi

if [[ -f "$OVERRIDE_FILE" ]]; then
  green "✅ Override 文件：$OVERRIDE_FILE（last-wins 保证）"
else
  yellow "⚠️ 未发现：$OVERRIDE_FILE（sysctl 收敛可能未执行）"
fi

# 关键项 runtime vs file 对比
if [[ -f "$SYSCTL_FILE" ]]; then
  echo ""
  echo "  关键项对比（runtime vs file）："

  check_keys=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_mtu_probing
    net.core.rmem_default
    net.core.wmem_default
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.conf.all.rp_filter
    net.netfilter.nf_conntrack_max
    net.netfilter.nf_conntrack_udp_timeout
    net.netfilter.nf_conntrack_udp_timeout_stream
  )

  for k in "${check_keys[@]}"; do
    rt="$(get "$k")"

    fv="$(awk -v kk="$k" '
      $0 ~ "^[[:space:]]*#" {next}
      $1 == kk && $2 == "=" {
        sub("^[^=]*=[[:space:]]*", "", $0);
        gsub(/[[:space:]]+$/, "", $0);
        print $0;
      }
    ' "$SYSCTL_FILE" 2>/dev/null | tail -n1)"
    fv="${fv:-N/A}"

    rt_norm="$(echo "$rt" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
    fv_norm="$(echo "$fv" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"

    if [[ "$fv_norm" == "N/A" ]]; then
      echo "  ℹ️ $k: runtime=$rt (文件中未设置)"
    elif [[ "$rt_norm" == "N/A" ]]; then
      echo "  ℹ️ $k: 内核不支持 (文件值=$fv)"
    elif [[ "$rt_norm" != "$fv_norm" ]]; then
      yellow "  ⚠️ $k: runtime=$rt  file=$fv  (不一致!)"
    else
      green "  ✅ $k: $rt"
    fi
  done
fi

# 检查是否有被禁用的冲突文件
disabled_count="$(ls /etc/sysctl.d/*.disabled-by-net-optimize-* 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
if [[ "$disabled_count" -gt 0 ]]; then
  echo ""
  yellow "  ℹ️ 发现 $disabled_count 个被 net-optimize 禁用的冲突 sysctl 文件"
  ls /etc/sysctl.d/*.disabled-by-net-optimize-* 2>/dev/null | sed 's/^/    /'
fi

# =================================================================
sep
echo "🛠 [7] 开机自启服务"
sep

svc_state "net-optimize.service"

if [[ -x /usr/local/sbin/net-optimize-apply ]]; then
  green "✅ apply 脚本：/usr/local/sbin/net-optimize-apply"
else
  yellow "⚠️ apply 脚本不存在或不可执行"
fi

if [[ -f /etc/modules-load.d/conntrack.conf ]]; then
  green "✅ conntrack 模块开机加载：/etc/modules-load.d/conntrack.conf"
else
  yellow "⚠️ 未发现 conntrack 模块开机加载配置"
fi

# =================================================================
sep
echo "🔧 [8] Nginx 源与服务"
sep

if ! has apt-cache; then
  echo "ℹ️ 非 apt 系统，跳过 Nginx 检测"
else
  echo "📌 nginx 相关 sources："
  ls -l /etc/apt/sources.list.d/*nginx* 2>/dev/null || echo "  (none)"

  if grep -RIEq 'nginx\.org/(packages|keys)' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    green "✅ 检测到 nginx.org 官方源"
  else
    echo "  ℹ️ 未检测到 nginx.org 源"
  fi

  if grep -RIEq 'ppa\.launchpadcontent\.net/ondrej/nginx|ondrej.*nginx' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    green "✅ 检测到 ondrej/nginx PPA 源"
  fi

  if [[ -f /etc/apt/preferences.d/99-nginx-official ]]; then
    green "✅ nginx.org Pin 优先级已配置"
  else
    echo "  ℹ️ 未发现 nginx.org Pin 配置"
  fi

  if has nginx; then
    ver="$(nginx -v 2>&1 | awk -F/ '{print $2}')"
    green "✅ Nginx 版本：$ver"
    if systemctl is-active nginx >/dev/null 2>&1; then
      green "✅ Nginx：运行中"
    else
      yellow "⚠️ Nginx：未运行"
    fi
  else
    echo "  ℹ️ 未安装 Nginx"
  fi

  echo ""
  echo "  apt-cache policy nginx："
  apt-cache policy nginx 2>/dev/null | sed 's/^/    /' || true
fi

# =================================================================
sep
echo "🔁 [9] Nginx 自动更新（cron）"
sep

cron_file="/etc/cron.d/net-optimize-nginx-update"

if [[ -f "$cron_file" ]]; then
  green "✅ Nginx 自动更新 cron：$cron_file"
  echo "  内容："
  sed 's/^/    /' "$cron_file"

  perms="$(stat -c '%a' "$cron_file" 2>/dev/null || echo "?")"
  owner="$(stat -c '%U:%G' "$cron_file" 2>/dev/null || echo "?")"
  echo "  权限：$perms  属主：$owner"

  [[ "$perms" != "644" ]] && yellow "  ⚠️ cron 权限异常（建议 644）"

  if ! grep -qE '(apt-get|apt)\s+.*(install|upgrade).*(nginx)(\s|$)' "$cron_file" 2>/dev/null; then
    yellow "  ⚠️ cron 存在但未检测到 nginx upgrade 命令"
  fi
else
  yellow "⚠️ 未发现 Nginx 自动更新 cron"
  echo "  预期路径：/etc/cron.d/net-optimize-nginx-update"
fi

if unit_exists "cron.service"; then
  state="$(systemctl is-active cron 2>/dev/null || true)"
  [[ "$state" == "active" ]] && green "✅ cron 服务运行中" || yellow "⚠️ cron 服务状态：$state"
elif unit_exists "crond.service"; then
  state="$(systemctl is-active crond 2>/dev/null || true)"
  [[ "$state" == "active" ]] && green "✅ crond 服务运行中" || yellow "⚠️ crond 服务状态：$state"
else
  yellow "ℹ️ 未检测到 cron/crond 服务"
fi

# =================================================================
sep
echo "💻 [10] 系统信息"
sep

printf "  %-14s : %s\n" "内核版本" "$(uname -r)"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  printf "  %-14s : %s\n" "发行版" "${PRETTY_NAME:-${ID:-unknown}}"
fi
printf "  %-14s : %s\n" "总内存" "$(free -h | awk '/^Mem:/ {print $2}')"
printf "  %-14s : %s\n" "可用内存" "$(free -h | awk '/^Mem:/ {print $NF}')"
printf "  %-14s : %s\n" "运行时间" "$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*//')"

if [[ -f /usr/local/sbin/net-optimize-ultimate.sh ]]; then
  script_ver="$(grep -oP 'v\d+\.\d+\.\d+' /usr/local/sbin/net-optimize-ultimate.sh | head -n1 || echo "unknown")"
  green "✅ 已安装脚本版本：$script_ver"
else
  yellow "⚠️ 未发现已安装的 net-optimize-ultimate.sh"
fi

# iptables 后端信息
if [[ -n "$IPT_CMD" ]]; then
  echo "  ℹ️ iptables 实际后端：$IPT_CMD"
fi

title
green "🎉 检测完成"
