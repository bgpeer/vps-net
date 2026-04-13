#!/usr/bin/env bash
# ==============================================================================
# 🚀 Net-Optimize-Ultimate v3.7.2
# 功能：深度整合优化 + UDP活跃修复 + 智能检测 + 安全持久化
# v3.7.0 新增：
#   1) BBRv2/BBRv3 自动检测（内核支持时优先启用）
#   2) CPU 调频策略自动切换 performance（降低包处理延迟）
#   3) XPS 发送端包分发（配合 RPS，减少跨核锁竞争）
#   4) 网卡中断合并自适应调优（ethtool adaptive coalescing）
#   5) 基于实际内存动态计算缓冲区大小（告别硬编码 64MB）
#   6) tcp_mem 动态计算（防止低内存 VPS 触发 TCP 内存压力）
#   7) TCP thin stream 优化（游戏/交互式连接减少重传等待）
#   8) MPTCP 自动启用（内核 5.6+）
#   9) WireGuard 检测 + UDP GRO 转发优化
# v3.6.0 新增：
#   1) 游戏低延迟 QoS（cake diffserv4 优先，fallback prio+fq_codel）
#   2) 游戏 DSCP 标记（UDP 小包 ≤200B 非 443 → AF41 低延迟档）
#   3) cake 4 档自动分流：大流→Bulk 小包→Voice，视频游戏兼容
#   4) prio fallback：3 band + tc filter 按 DSCP/包大小分流
# v3.5.0 新增：
#   1) 网卡 offload 优化（GRO/GSO/TSO 自动开启）
#   2) RPS/RFS 多核收包均衡（自动检测 CPU 核数）
#   3) TCP 参数微调（window_scaling / sack / notsent_lowat 代理优化）
#   4) IPv6 MSS clamping（ip6tables 支持）
#   5) QUIC/UDP DSCP 优先级标记（EF 加速）
#   6) 自动检测线路质量，高延迟线路加大 initcwnd
# 历史修复见 changelog
# ==============================================================================

set -euo pipefail

# === 1. 自动更新机制（含 SHA256SUMS 校验）===
SCRIPT_PATH="/usr/local/sbin/net-optimize-ultimate.sh"
REMOTE_URL="https://raw.githubusercontent.com/bgpeer/vps-net/main/net-optimize-ultimate.sh"
REMOTE_SHA256SUMS_URL="https://raw.githubusercontent.com/bgpeer/vps-net/main/SHA256SUMS"

# conntrack 模块开机加载（systemd）
CONNTRACK_MODULES_CONF="/etc/modules-load.d/conntrack.conf"

fetch_raw() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    return 1
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    echo ""
  fi
}

# --- 自动更新（带 SHA256SUMS 签名校验）---
auto_update() {
  local remote_buf remote_hash local_hash

  remote_buf="$(fetch_raw "$REMOTE_URL" || true)"
  [ -z "${remote_buf:-}" ] && return 0

  remote_hash="$(printf "%s" "$remote_buf" | sha256_of)"
  local_hash="$([ -f "$SCRIPT_PATH" ] && sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo "")"

  # 无变化：跳过
  [ -n "$remote_hash" ] && [ "$remote_hash" = "$local_hash" ] && return 0

  # SHA256SUMS 校验
  local sums_buf expected_hash
  sums_buf="$(fetch_raw "$REMOTE_SHA256SUMS_URL" || true)"
  if [ -z "${sums_buf:-}" ]; then
    echo "⚠️ 无法获取 SHA256SUMS，跳过自动更新（安全策略）"
    return 0
  fi

  # SHA256SUMS 格式：<hash>  <filename> 或 <hash> <filename>
  expected_hash="$(printf "%s\n" "$sums_buf" | grep -E '(^|\s)net-optimize-ultimate\.sh$' | awk '{print $1}' | head -n1)"
  if [ -z "${expected_hash:-}" ]; then
    echo "⚠️ SHA256SUMS 中未找到脚本条目，跳过自动更新"
    return 0
  fi

  if [ "$remote_hash" != "$expected_hash" ]; then
    echo "❌ 远程脚本 SHA256 校验失败！可能被篡改，拒绝更新"
    echo "  期望: $expected_hash"
    echo "  实际: $remote_hash"
    return 0
  fi

  echo "🌀 检测到新版本（SHA256 校验通过），正在更新..."
  printf "%s" "$remote_buf" >"$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  exec "$SCRIPT_PATH" "$@"
}

auto_update "$@"

# 当你用 bash <(curl ...) 运行时，$0 可能是 /dev/fd/*，这里允许失败
install -Dm755 "$0" "$SCRIPT_PATH" 2>/dev/null || true

trap 'code=$?; echo "❌ 出错：第 ${BASH_LINENO[0]} 行 -> ${BASH_COMMAND} (退出码 $code)"; exit $code' ERR

echo "🚀 Net-Optimize-Ultimate v3.7.1 开始执行..."
echo "========================================================"

# === 2. 全局配置开关 ===
: "${ENABLE_FQ_PIE:=1}"
: "${ENABLE_MTU_PROBE:=1}"
: "${ENABLE_MSS_CLAMP:=1}"
: "${MSS_VALUE:=1452}"
: "${ENABLE_CONNTRACK_TUNE:=1}"
: "${NFCT_MAX:=262144}"
: "${ENABLE_NGINX_REPO:=1}"
: "${SKIP_APT:=0}"
: "${APPLY_AT_BOOT:=1}"
: "${RP_FILTER:=2}"  # 0=关闭 1=严格 2=松散（默认松散，兼顾代理+安全）
: "${ENABLE_NIC_OFFLOAD:=1}"    # 网卡 offload（GRO/GSO/TSO）
: "${ENABLE_RPS_RFS:=1}"        # RPS/RFS 多核收包均衡
: "${ENABLE_IPV6_MSS:=1}"       # IPv6 MSS clamping
: "${ENABLE_DSCP:=1}"           # QUIC/UDP DSCP 优先级标记
: "${ENABLE_INITCWND:=1}"       # 自动检测线路质量调整 initcwnd
: "${TCP_NOTSENT_LOWAT:=4096}"  # 代理场景低延迟（默认 4096，原 16384）
: "${AGGRESSIVE_MODE:=0}"      # 激进模式：抢带宽（类似 Hy2 暴力发包思路）
: "${ENABLE_GAME_QOS:=1}"      # 游戏低延迟 QoS（cake/prio 双方案自动选择）
: "${ADAPTIVE_QOS:=1}"         # 自适应 QoS：流量高→抢带宽，流量低→游戏低延迟（自动切换）
: "${ADAPTIVE_QOS_THRESHOLD:=1048576}"  # 自适应阈值（字节/秒，默认 1MB/s）
: "${ADAPTIVE_QOS_INTERVAL:=2}"         # 采样间隔（秒）
: "${ADAPTIVE_QOS_COOLDOWN:=10}"        # 抢带宽冷却时间（秒，流量降下后多久切回游戏模式）
: "${ENABLE_CPU_GOVERNOR:=1}"           # CPU 调频切换到 performance 模式
: "${ENABLE_XPS:=1}"                    # XPS 发送端包分发（配合 RPS）
: "${ENABLE_IRQ_COALESCING:=1}"         # 网卡中断合并自适应调优
: "${ENABLE_MPTCP:=1}"                  # MPTCP 多路径传输（内核 5.6+）
: "${ENABLE_WG_OPT:=1}"                 # WireGuard UDP GRO 转发优化
: "${RAM_ADAPTIVE_BUFFERS:=1}"          # 基于实际内存动态计算缓冲区大小

# 路径定义
CONFIG_DIR="/etc/net-optimize"
CONFIG_FILE="$CONFIG_DIR/config"
MODULES_FILE="$CONFIG_DIR/modules.list"
APPLY_SCRIPT="/usr/local/sbin/net-optimize-apply"
CONNTRACK_MODULES_CONF="/etc/modules-load.d/conntrack.conf"

# === 3. 核心工具函数 ===
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || {
    echo "❌ 请使用 root 用户运行"
    exit 1
  }
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

has_sysctl_key() {
  local p="/proc/sys/${1//.//}"
  [[ -e "$p" ]]
}

get_sysctl() { sysctl -n "$1" 2>/dev/null || echo "N/A"; }

detect_distro() {
  local id codename
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    id="${ID:-unknown}"
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
  else
    id="unknown"
    codename="unknown"
  fi
  echo "${id}:${codename}"
}

check_dpkg_clean() {
  have_cmd dpkg || return 0

  # 检查是否有异常状态的包
  local broken_pkgs
  broken_pkgs="$(dpkg --audit 2>/dev/null || true)"
  [ -z "$broken_pkgs" ] && return 0

  echo "⚠️ 检测到 dpkg 状态异常，正在自动修复..."

  # 第一轮：常规修复（尝试正常 configure）
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y 2>&1 || true

  # 检查是否修好了
  broken_pkgs="$(dpkg --audit 2>/dev/null || true)"
  [ -z "$broken_pkgs" ] && { echo "✅ dpkg 自动修复完成"; return 0; }

  # 第二轮：仅移除 dpkg --audit 报告的异常包（精确提取包名）
  echo "⚠️ 常规修复失败，仅移除 dpkg --audit 报告的异常包..."
  local pkg
  # dpkg --audit 输出格式：" 包名  描述..."，提取第一列包名
  dpkg --audit 2>/dev/null | awk '/^ /{print $1}' | sort -u | while read -r pkg; do
    [ -z "$pkg" ] && continue
    # 安全检查：跳过基础系统包，防止误删
    case "$pkg" in
      apt|bash|coreutils|dpkg|libc6|systemd|util-linux|base-files|base-passwd|dash) 
        echo "  ⚠️ 跳过系统关键包: $pkg"
        continue ;;
    esac
    echo "  🔧 强制移除: $pkg"
    dpkg --remove --force-remove-reinstreq "$pkg" 2>/dev/null || true
  done

  # 清理残留依赖
  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1 || true

  # 最终检查
  if dpkg --audit 2>/dev/null | grep -q .; then
    echo "❌ dpkg 自动修复失败，请手动处理后重试"
    exit 1
  fi
  echo "✅ dpkg 异常包已清理，环境恢复正常"
}

# === conntrack 可用性检测（不依赖 lsmod）===
conntrack_available() {
  has_sysctl_key net.netfilter.nf_conntrack_max && return 0

  if [ -d /proc/sys/net/netfilter ] && ls /proc/sys/net/netfilter/nf_conntrack* >/dev/null 2>&1; then
    return 0
  fi

  [ -f /proc/net/nf_conntrack ] && return 0
  return 1
}

# === qdisc 真实可设置探测（不依赖 lsmod）===
try_set_qdisc() {
  local q="$1"
  has_sysctl_key net.core.default_qdisc || return 1
  sysctl -w net.core.default_qdisc="$q" >/dev/null 2>&1
}

# === 3.5 Sysctl 权威收敛（避免多脚本互相覆盖）===
SYSCTL_BACKUP_DIR="/etc/net-optimize/sysctl-backup"
SYSCTL_AUTH_FILE="/etc/sysctl.d/99-net-optimize.conf"

SYSCTL_KEYS=(
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.ipv4.tcp_mtu_probing
  net.core.rmem_default
  net.core.wmem_default
  net.core.rmem_max
  net.core.wmem_max
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.ipv4.udp_rmem_min
  net.ipv4.udp_wmem_min
  net.ipv4.udp_mem
  net.netfilter.nf_conntrack_max
  net.netfilter.nf_conntrack_udp_timeout
  net.netfilter.nf_conntrack_udp_timeout_stream
)

sysctl_file_hits_keys() {
  local f="$1" k
  for k in "${SYSCTL_KEYS[@]}"; do
    if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

backup_and_disable_sysctl_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sysctl_file_hits_keys "$f" || return 0

  mkdir -p "$SYSCTL_BACKUP_DIR"
  local ts
  ts="$(date +%F-%H%M%S)"

  echo "🧯 发现冲突 sysctl 文件：$f"
  cp -a "$f" "$SYSCTL_BACKUP_DIR/$(basename "$f").bak-$ts"
  mv "$f" "$f.disabled-by-net-optimize-$ts"
  echo "  ✅ 已备份并禁用：$f"
}

converge_sysctl_authority() {
  echo "🧠 收敛 sysctl 权威（以 $SYSCTL_AUTH_FILE 为准，保证 last-wins）..."

  local main_conf="$SYSCTL_AUTH_FILE"
  local override_conf="/etc/sysctl.d/zzz-net-optimize-override.conf"

  [[ -f "$main_conf" ]] || { echo "⚠️ 未发现：$main_conf，跳过"; return 0; }

  # 从 main_conf 抽取期望值
  declare -A want
  local k v
  for k in "${SYSCTL_KEYS[@]}"; do
    v="$(awk -v kk="$k" '
      $0 ~ "^[[:space:]]*#" {next}
      $1 == kk && $2 == "=" {
        sub("^[^=]*=[[:space:]]*", "", $0);
        print $0;
      }
    ' "$main_conf" 2>/dev/null | tail -n1)"
    [[ -n "${v:-}" ]] && want["$k"]="$v"
  done

  [[ "${#want[@]}" -gt 0 ]] || { echo "⚠️ $main_conf 未解析到关键项，跳过"; return 0; }

  # 1) 生成 override（最后加载，保证 last-wins）
  {
    echo "# Net-Optimize: override to guarantee last-wins"
    echo "# Generated: $(date -u '+%F %T UTC')"
    for k in "${SYSCTL_KEYS[@]}"; do
      [[ -n "${want[$k]:-}" ]] && echo "$k = ${want[$k]}"
    done
  } > "$override_conf"
  chmod 644 "$override_conf"
  echo "✅ 写入 override：$override_conf"

  # 2) 禁用 /etc/sysctl.d 里冲突文件（保留 main_conf 和 override）
  shopt -s nullglob
  local f
  for f in /etc/sysctl.d/*.conf; do
    [[ "$f" == "$main_conf" ]] && continue
    [[ "$f" == "$override_conf" ]] && continue
    backup_and_disable_sysctl_file "$f"
  done
  shopt -u nullglob

  # 3) /etc/sysctl.conf 冲突项注释掉
  if [[ -f /etc/sysctl.conf ]]; then
    local hit=0
    for k in "${SYSCTL_KEYS[@]}"; do
      if grep -qE "^[[:space:]]*${k}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i -E "s@^[[:space:]]*(${k}[[:space:]]*=.*)@# net-optimize disabled: \1@g" /etc/sysctl.conf 2>/dev/null || true
        hit=1
      fi
    done
    [[ "$hit" -eq 1 ]] && echo "✅ 已削弱冲突：/etc/sysctl.conf"
  fi

  # 4) 立即落地
  sysctl --system >/dev/null 2>&1 || true
  for k in "${SYSCTL_KEYS[@]}"; do
    [[ -n "${want[$k]:-}" ]] || continue
    sysctl -w "$k=${want[$k]}" >/dev/null 2>&1 || true
    # 验证是否生效（跳过可能由外部内核脚本管控的 qdisc/cc）
    [[ "$k" == "net.core.default_qdisc" ]] && continue
    [[ "$k" == "net.ipv4.tcp_congestion_control" ]] && continue
    local actual
    actual="$(sysctl -n "$k" 2>/dev/null || true)"
    actual="$(echo "$actual" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
    local expected
    expected="$(echo "${want[$k]}" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"
    if [[ "$actual" != "$expected" ]]; then
      local proc_path="/proc/sys/${k//./\/}"
      if [[ -w "$proc_path" ]]; then
        echo "${want[$k]}" > "$proc_path" 2>/dev/null || true
        echo "  ⚠️ $k 被外部覆盖，已强制恢复"
      fi
    fi
  done

  echo "✅ sysctl 收敛完成（override 已保证 last-wins）"
}

force_apply_sysctl_runtime() {
  echo "🧷 强制写入 sysctl runtime（防止云镜像/agent 覆盖）"
  sysctl --system >/dev/null 2>&1 || true

  # 云厂商 systemd-networkd / cloud-init 会按接口覆盖 rp_filter，逐接口强制写回
  if has_sysctl_key net.ipv4.conf.all.rp_filter; then
    sysctl -w net.ipv4.conf.all.rp_filter="$RP_FILTER" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.rp_filter="$RP_FILTER" >/dev/null 2>&1 || true
    local iface_path
    for iface_path in /proc/sys/net/ipv4/conf/*/rp_filter; do
      echo "$RP_FILTER" > "$iface_path" 2>/dev/null || true
    done
    echo "  ✅ rp_filter 已逐接口强制覆盖为 $RP_FILTER"
  fi
}

# === 4. 清理旧配置 ===
clean_old_config() {
  echo "🧹 清理旧配置..."

  local need_clean=0

  [[ -f /etc/systemd/system/net-optimize.service ]] && need_clean=1
  [[ -d "$CONFIG_DIR" ]] && need_clean=1

  if have_cmd iptables; then
    if timeout 2s iptables -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -qE 'TCPMSS|DSCP'; then
      need_clean=1
    fi
  fi
  if have_cmd iptables-legacy; then
    if timeout 2s iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -qE 'TCPMSS|DSCP'; then
      need_clean=1
    fi
  fi
  if have_cmd ip6tables-legacy; then
    if timeout 2s ip6tables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -qE 'TCPMSS|DSCP'; then
      need_clean=1
    fi
  fi
  if have_cmd ip6tables; then
    if timeout 2s ip6tables -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -qE 'TCPMSS|DSCP'; then
      need_clean=1
    fi
  fi

  if [[ "$need_clean" -eq 0 ]]; then
    echo "✅ 未发现旧配置，跳过清理"
    mkdir -p "$CONFIG_DIR"
    return 0
  fi

  echo "🔎 发现旧配置，开始清理..."

  timeout 5s systemctl stop net-optimize.service 2>/dev/null || true
  timeout 5s systemctl disable net-optimize.service 2>/dev/null || true
  rm -f /etc/systemd/system/net-optimize.service

  # 清理所有后端的 TCPMSS + DSCP 规则（IPv4 + IPv6）
  for _clean_cmd in iptables iptables-legacy iptables-nft ip6tables ip6tables-legacy ip6tables-nft; do
    have_cmd "$_clean_cmd" || continue
    local _clean_rules
    _clean_rules="$(timeout 3s "$_clean_cmd" -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -E 'TCPMSS|DSCP' || true)"
    [ -z "$_clean_rules" ] && continue
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      local del_rule="${rule/-A POSTROUTING/-D POSTROUTING}"
      local -a del_parts
      read -r -a del_parts <<<"$del_rule"
      "$_clean_cmd" -w 2 -t mangle "${del_parts[@]}" 2>/dev/null || true
    done <<<"$_clean_rules"
  done

  mkdir -p "$CONFIG_DIR"
  rm -f "$CONFIG_FILE" "$MODULES_FILE"

  echo "✅ 旧配置清理完成"
}

# === 5. 工具安装（可选，含 APT 源自愈）===
maybe_install_tools() {
  if [ "${SKIP_APT:-0}" = "1" ]; then
    echo "⏭️ 跳过工具安装（SKIP_APT=1）"
    return 0
  fi

  if ! have_cmd apt-get; then
    echo "ℹ️ 非APT系统，跳过工具安装"
    return 0
  fi

  local os_id os_codename
  os_id="unknown"; os_codename="unknown"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    os_id="${ID:-unknown}"
    os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
  fi

  # APT 源自愈
  local f ts
  ts="$(date +%F-%H%M%S)"

  for f in /etc/apt/sources.list.d/*nginx*.list /etc/apt/sources.list.d/*nginx*.sources; do
    [ -e "$f" ] || continue

    if [ "$os_id" = "ubuntu" ] && grep -qE 'nginx\.org/packages(/mainline)?/debian' "$f" 2>/dev/null; then
      mv "$f" "$f.disabled.$ts"
      echo "🧹 [APT自愈] Ubuntu 检测到 nginx Debian 源，已禁用：$(basename "$f")"
      continue
    fi

    if [ "$os_id" = "debian" ] && grep -qE 'nginx\.org/packages(/mainline)?/ubuntu' "$f" 2>/dev/null; then
      mv "$f" "$f.disabled.$ts"
      echo "🧹 [APT自愈] Debian 检测到 nginx Ubuntu 源，已禁用：$(basename "$f")"
      continue
    fi

    if grep -qE 'nginx\.org/packages(/mainline)?/debian.*\bnoble\b' "$f" 2>/dev/null; then
      mv "$f" "$f.disabled.$ts"
      echo "🧹 [APT自愈] 检测到 debian 路径却使用 noble，已禁用：$(basename "$f")"
      continue
    fi
  done

  echo "🧰 安装必要工具..."
  check_dpkg_clean

  DEBIAN_FRONTEND=noninteractive apt-get update -y \
    || echo "⚠️ apt update 失败（已忽略，不影响主流程）"

  local packages=""
  packages+=" ca-certificates curl wget gnupg2 lsb-release"
  packages+=" ethtool iproute2 irqbalance chrony"
  packages+=" nftables conntrack iptables"
  packages+=" software-properties-common apt-transport-https"

  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages \
    || echo "⚠️ 部分包安装失败（已忽略）"

  systemctl enable --now irqbalance chrony 2>/dev/null || true
}

# === 6. Ulimit 优化 ===
setup_ulimit() {
  echo "📂 优化文件描述符限制..."

  install -d /etc/security/limits.d
  cat > /etc/security/limits.d/99-net-optimize.conf <<'EOF'
# Net-Optimize Ultimate - File Descriptor Limits
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  if ! grep -q '^DefaultLimitNOFILE=' /etc/systemd/system.conf 2>/dev/null; then
    echo 'DefaultLimitNOFILE=1048576' >> /etc/systemd/system.conf
  else
    sed -i 's/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/system.conf
  fi

  for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    if [ -f "$pam_file" ] && ! grep -q "pam_limits.so" "$pam_file"; then
      echo "session required pam_limits.so" >> "$pam_file"
    fi
  done

  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "✅ ulimit 配置完成"
}

# === 7. 拥塞控制与队列算法 ===
setup_tcp_congestion() {
  echo "📶 设置TCP拥塞算法和队列..."

  if [ "$AGGRESSIVE_MODE" = "1" ]; then
    # 激进模式：用 pfifo_fast 不限速，不做公平调度
    if try_set_qdisc pfifo_fast; then
      FINAL_QDISC="pfifo_fast"
    elif try_set_qdisc fq; then
      FINAL_QDISC="fq"
    else
      FINAL_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    fi
    echo "  ⚡ 激进模式：队列算法 pfifo_fast（无限速）"
  else
    if [ "$ENABLE_FQ_PIE" = "1" ] && try_set_qdisc fq_pie; then
      FINAL_QDISC="fq_pie"
    elif try_set_qdisc fq; then
      FINAL_QDISC="fq"
    elif try_set_qdisc pie; then
      FINAL_QDISC="pie"
    else
      FINAL_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    fi
  fi

  local target_cc="cubic"
  local available_cc
  available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo cubic)"

  # 优先级：bbr3 > bbr2 > bbrplus > bbr > cubic
  if echo "$available_cc" | grep -qw bbr3; then
    target_cc="bbr3"
  elif echo "$available_cc" | grep -qw bbr2; then
    target_cc="bbr2"
  elif echo "$available_cc" | grep -qw bbrplus; then
    target_cc="bbrplus"
  elif echo "$available_cc" | grep -qw bbr; then
    target_cc="bbr"
  fi

  if has_sysctl_key net.ipv4.tcp_congestion_control; then
    sysctl -w net.ipv4.tcp_congestion_control="$target_cc" >/dev/null 2>&1 || true
  fi

  FINAL_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

  echo "✅ 最终生效拥塞算法: $FINAL_CC"
  echo "✅ 最终生效队列算法: $FINAL_QDISC"

  if [[ "$target_cc" == bbr* ]] && [[ "$FINAL_CC" != "$target_cc" ]]; then
    echo "⚠️ 提示: 尝试启用 $target_cc 失败，系统自动回退到了 $FINAL_CC"
  fi
}

# === 8. Sysctl 深度整合 ===
write_sysctl_conf() {
  echo "📊 写入内核参数配置文件..."

  local sysctl_file="$SYSCTL_AUTH_FILE"
  install -d /etc/sysctl.d

  # --- 动态计算缓冲区大小（基于实际物理内存）---
  local total_ram_kb rmem_max wmem_max rmem_default wmem_default
  total_ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 1048576)"
  if [ "${RAM_ADAPTIVE_BUFFERS:-1}" = "1" ]; then
    if   [ "$total_ram_kb" -ge 8000000 ]; then
      rmem_max=268435456; wmem_max=268435456    # ≥8GB: 256MB
    elif [ "$total_ram_kb" -ge 4000000 ]; then
      rmem_max=134217728; wmem_max=134217728    # ≥4GB: 128MB
    elif [ "$total_ram_kb" -ge 2000000 ]; then
      rmem_max=67108864;  wmem_max=67108864     # ≥2GB: 64MB
    else
      rmem_max=33554432;  wmem_max=33554432     # <2GB: 32MB
    fi
  else
    rmem_max=67108864; wmem_max=67108864
  fi
  rmem_default=262144; wmem_default=262144

  # tcp_mem: min/pressure/max（单位：页，4KB/页）
  # 分别取 RAM 的 1/32、1/8、1/4，并设上下限
  local pages_per_kb=1  # 4KB page = 1 page per 4KB = 0.25 page per KB
  local tcp_mem_min tcp_mem_pressure tcp_mem_max
  tcp_mem_min=$(( total_ram_kb / 4 / 32 ))
  tcp_mem_pressure=$(( total_ram_kb / 4 / 8 ))
  tcp_mem_max=$(( total_ram_kb / 4 / 4 ))
  # 下限保护
  [ "$tcp_mem_min" -lt 8192  ] && tcp_mem_min=8192
  [ "$tcp_mem_pressure" -lt 32768 ] && tcp_mem_pressure=32768
  [ "$tcp_mem_max" -lt 65536 ] && tcp_mem_max=65536

  local cc qdisc
  cc="${FINAL_CC:-$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)}"
  qdisc="${FINAL_QDISC:-$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq)}"

  {
    echo "# ========================================================="
    echo "# 🚀 Net-Optimize Ultimate v3.7.0 - Kernel Parameters"
    echo "# Generated: $(date -u '+%F %T UTC')"
    echo "# ========================================================="
    echo

    echo "# === 拥塞控制 / 队列 ==="
    echo "net.core.default_qdisc = $qdisc"
    echo "net.ipv4.tcp_congestion_control = $cc"
    echo

    echo "# === 基础网络设置 ==="
    echo "net.core.netdev_max_backlog = 250000"
    echo "net.core.somaxconn = 1000000"
    echo "net.ipv4.tcp_max_syn_backlog = 819200"
    echo "net.ipv4.tcp_syncookies = 1"
    echo

    echo "# === 网卡收包预算 ==="
    echo "net.core.netdev_budget = 50000"
    echo "net.core.netdev_budget_usecs = 5000"
    echo

    echo "# === 连接生命周期 ==="
    echo "net.ipv4.tcp_fin_timeout = 15"
    echo "net.ipv4.tcp_keepalive_time = 600"
    echo "net.ipv4.tcp_keepalive_intvl = 15"
    echo "net.ipv4.tcp_keepalive_probes = 2"
    echo "net.ipv4.tcp_max_tw_buckets = 32768"
    echo "net.ipv4.ip_local_port_range = 1024 65535"
    echo

    echo "# === TCP算法优化 ==="
    echo "net.ipv4.tcp_mtu_probing = $ENABLE_MTU_PROBE"
    echo "net.ipv4.tcp_window_scaling = 1"
    echo "net.ipv4.tcp_sack = 1"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_no_metrics_save = 0"
    echo "net.ipv4.tcp_ecn = 1"
    echo "net.ipv4.tcp_ecn_fallback = 1"
    echo "net.ipv4.tcp_notsent_lowat = $TCP_NOTSENT_LOWAT"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_timestamps = 1"
    echo "net.ipv4.tcp_autocorking = 0"
    echo "net.ipv4.tcp_orphan_retries = 1"
    echo "net.ipv4.tcp_retries2 = 5"
    echo "net.ipv4.tcp_synack_retries = 1"
    echo "net.ipv4.tcp_early_retrans = 3"
    echo "net.ipv4.tcp_thin_linear_timeouts = 1"  # 游戏/交互小包流：线性重传替代指数退避
    echo
    echo "# === 低延迟轮询（代理/游戏服务器降低响应延迟）==="
    echo "net.core.busy_poll = 50"    # socket poll 忙等 50μs，减少中断唤醒延迟
    echo "net.core.busy_read = 50"    # socket read 忙等 50μs
    echo
    # 注：tcp_low_latency 在 4.14+ 已移除；tcp_fack / tcp_frto 在 BBR 下无实际作用
    # 不再写入，避免 sysctl -e 报 unknown key 警告

    echo "# === 内存缓冲区优化（基于物理内存动态计算，default=256KB 让 TCP autotuning 自行扩展）==="
    echo "# 当前系统内存: $((total_ram_kb / 1024)) MB → rmem/wmem_max = $((rmem_max / 1024 / 1024)) MB"
    echo "net.core.rmem_max = $rmem_max"
    echo "net.core.wmem_max = $wmem_max"
    echo "net.core.rmem_default = $rmem_default"
    echo "net.core.wmem_default = $wmem_default"
    echo "net.core.optmem_max = 65536"
    echo "net.ipv4.tcp_rmem = 4096 87380 $rmem_max"
    echo "net.ipv4.tcp_wmem = 4096 65536 $wmem_max"
    echo "net.ipv4.udp_rmem_min = 16384"
    echo "net.ipv4.udp_wmem_min = 16384"
    echo "net.ipv4.udp_mem = $tcp_mem_min $tcp_mem_pressure $tcp_mem_max"
    echo "net.ipv4.tcp_mem = $tcp_mem_min $tcp_mem_pressure $tcp_mem_max"
    echo

    if [ "$AGGRESSIVE_MODE" = "1" ]; then
      echo "# === 激进模式参数（抢带宽）==="
      echo "# 加大发送队列深度，减少队列满丢包"
      echo "net.core.netdev_max_backlog = 1000000"
      echo "# 关闭 TCP 指数退避，丢包后不减速"
      echo "net.ipv4.tcp_retries2 = 15"
      echo "# 关闭慢启动重启"
      echo "net.ipv4.tcp_slow_start_after_idle = 0"
      echo "# 关闭 metrics 缓存，每次连接都从最大窗口开始"
      echo "net.ipv4.tcp_no_metrics_save = 1"
      echo "# 最大化 TCP 初始窗口相关"
      echo "net.ipv4.tcp_notsent_lowat = 131072"
      echo "# 加大 SYN backlog"
      echo "net.ipv4.tcp_max_syn_backlog = 2097152"
      echo "# UDP 缓冲区加大到 128MB"
      echo "net.ipv4.udp_rmem_min = 65536"
      echo "net.ipv4.udp_wmem_min = 65536"
      echo "net.ipv4.udp_mem = 131072 262144 524288"
      echo "# 加大 orphan 重试，不轻易放弃连接"
      echo "net.ipv4.tcp_orphan_retries = 3"
      echo
    fi

    echo "# === 路由/转发 ==="
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv4.conf.all.forwarding = 1"
    echo "net.ipv4.conf.default.forwarding = 1"
    echo "net.ipv4.conf.all.route_localnet = 1"
    echo "net.ipv4.conf.all.rp_filter = $RP_FILTER"
    echo "net.ipv4.conf.default.rp_filter = $RP_FILTER"
    echo

    echo "# === 安全加固 ==="
    echo "net.ipv4.conf.all.accept_redirects = 0"
    echo "net.ipv4.conf.default.accept_redirects = 0"
    echo "net.ipv4.conf.all.secure_redirects = 0"
    echo "net.ipv4.conf.default.secure_redirects = 0"
    echo "net.ipv4.conf.all.send_redirects = 0"
    echo "net.ipv4.conf.default.send_redirects = 0"
    echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"
    echo "net.ipv4.icmp_ignore_bogus_error_responses = 1"
    echo "net.ipv4.icmp_echo_ignore_all = 0"
    echo

    echo "# === IPv6优化 ==="
    echo "net.ipv6.conf.all.disable_ipv6 = 0"
    echo "net.ipv6.conf.default.disable_ipv6 = 0"
    echo "net.ipv6.conf.all.forwarding = 1"
    echo "net.ipv6.conf.default.forwarding = 1"
    echo "net.ipv6.conf.all.accept_ra = 2"
    echo "net.ipv6.conf.default.accept_ra = 2"
    echo "net.ipv6.conf.all.use_tempaddr = 2"
    echo "net.ipv6.conf.default.use_tempaddr = 2"
    echo "net.ipv6.conf.all.accept_redirects = 0"
    echo "net.ipv6.conf.default.accept_redirects = 0"
    echo

    echo "# === 邻居表调优 ==="
    echo "net.ipv4.neigh.default.gc_thresh1 = 2048"
    echo "net.ipv4.neigh.default.gc_thresh2 = 4096"
    echo "net.ipv4.neigh.default.gc_thresh3 = 8192"
    echo "net.ipv6.neigh.default.gc_thresh1 = 2048"
    echo "net.ipv6.neigh.default.gc_thresh2 = 4096"
    echo "net.ipv6.neigh.default.gc_thresh3 = 8192"
    echo "net.ipv4.neigh.default.unres_qlen = 10000"
    echo

    echo "# === 内核/文件系统安全 ==="
    echo "kernel.kptr_restrict = 1"
    echo "kernel.yama.ptrace_scope = 1"
    echo "kernel.sysrq = 176"
    echo "vm.mmap_min_addr = 65536"
    echo "vm.max_map_count = 1048576"
    echo "vm.swappiness = 1"
    echo "vm.overcommit_memory = 2"  # 适度超量（commit_limit=swap+RAM*50%），避免 = 1 彻底关闭 OOM 保护导致内存耗尽
    echo "kernel.pid_max = 4194304"
    echo
    echo "fs.protected_fifos = 1"
    echo "fs.protected_hardlinks = 1"
    echo "fs.protected_regular = 2"
    echo "fs.protected_symlinks = 1"
    echo

    if [ "$ENABLE_CONNTRACK_TUNE" = "1" ]; then
      echo "# === 连接跟踪优化 ==="
      echo "net.netfilter.nf_conntrack_max = $NFCT_MAX"
      echo "net.netfilter.nf_conntrack_udp_timeout = 30"
      echo "net.netfilter.nf_conntrack_udp_timeout_stream = 180"
      echo "net.netfilter.nf_conntrack_tcp_timeout_established = 432000"
      echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120"
      echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60"
      echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120"
      echo
    fi
  } >"$sysctl_file"

  sysctl -e --system >/dev/null 2>&1 || echo "⚠️ 部分参数不支持，但不影响其他项"
  echo "✅ sysctl 参数已写入并应用：$sysctl_file"
}

# === 9. 连接跟踪模块加载 + 触发 ===
setup_conntrack() {
  if [ "${ENABLE_CONNTRACK_TUNE:-1}" != "1" ]; then
    echo "⏭️ 跳过连接跟踪调优"
    return 0
  fi

  echo "🔗 连接跟踪（conntrack）初始化..."

  : "${CONNTRACK_MODULES_CONF:=/etc/modules-load.d/conntrack.conf}"

  local modules=(
    nf_conntrack
    nf_conntrack_netlink
    nf_conntrack_ftp
    nf_nat
    xt_MASQUERADE
  )

  for m in "${modules[@]}"; do
    modprobe "$m" 2>/dev/null || true
  done

  install -d /etc/modules-load.d
  {
    echo "# Net-Optimize: conntrack/nat modules"
    for m in "${modules[@]}"; do
      echo "$m"
    done
  } > "$CONNTRACK_MODULES_CONF"
  chmod 644 "$CONNTRACK_MODULES_CONF"
  echo "  ✅ 已写入开机模块加载: $CONNTRACK_MODULES_CONF"

  install -d "$(dirname "$MODULES_FILE")"
  printf "%s\n" "${modules[@]}" | sort -u > "$MODULES_FILE"

  systemctl restart systemd-modules-load 2>/dev/null || true

  # conntrack 触发规则：INVALID -> DROP（与 apply 脚本保持一致）
  if command -v iptables >/dev/null 2>&1; then
    iptables -t filter -C INPUT  -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
      || iptables -t filter -I INPUT 1 -m conntrack --ctstate INVALID -j DROP

    iptables -t filter -C OUTPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
      || iptables -t filter -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP

    echo "  ✅ 已写入 conntrack 触发规则（INVALID -> DROP）：INPUT/OUTPUT"
  fi

  if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    echo "  🔎 nf_conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"
  fi

  echo "✅ 连接跟踪配置完成"
}

# === 9.5 网卡 Offload 优化（GRO/GSO/TSO）===
setup_nic_offload() {
  if [ "${ENABLE_NIC_OFFLOAD:-1}" != "1" ]; then
    echo "⏭️ 跳过网卡 offload 优化"
    return 0
  fi

  echo "🔧 网卡 offload 优化..."

  have_cmd ethtool || { echo "  ⚠️ ethtool 未安装，跳过"; return 0; }

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"
  [ -z "$iface" ] && { echo "  ⚠️ 无法检测出口网卡，跳过"; return 0; }

  local feature applied=0
  for feature in gro gso tso sg rx-checksumming tx-checksumming; do
    if ethtool -k "$iface" 2>/dev/null | grep -qE "^${feature}:.*off"; then
      ethtool -K "$iface" "$feature" on 2>/dev/null && applied=$((applied + 1)) || true
    fi
  done

  # 开启 tx-nocache-copy 减少代理场景 CPU 拷贝
  ethtool -K "$iface" tx-nocache-copy on 2>/dev/null || true

  # 激进模式：加大网卡环形缓冲区
  if [ "${AGGRESSIVE_MODE:-0}" = "1" ]; then
    # 加大 txqueuelen（发送队列深度）
    ip link set "$iface" txqueuelen 10000 2>/dev/null || true
    local _actual_txql
    _actual_txql="$(ip link show "$iface" 2>/dev/null | grep -oP 'qlen \K\d+' || true)"
    if [ "${_actual_txql:-0}" -ge 10000 ]; then
      echo "  ⚡ 激进模式: txqueuelen=$_actual_txql"
    else
      echo "  ⚠️ 激进模式: txqueuelen 设置未生效（当前 ${_actual_txql:-unknown}，可能网卡不支持）"
    fi

    # 尝试加大网卡 ring buffer
    local rx_max tx_max
    rx_max="$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set.*/{found=1} found && /RX:/{print $2; exit}' || true)"
    tx_max="$(ethtool -g "$iface" 2>/dev/null | awk '/Pre-set.*/{found=1} found && /TX:/{print $2; exit}' || true)"
    [ -n "$rx_max" ] && [ "$rx_max" -gt 0 ] && ethtool -G "$iface" rx "$rx_max" 2>/dev/null || true
    [ -n "$tx_max" ] && [ "$tx_max" -gt 0 ] && ethtool -G "$iface" tx "$tx_max" 2>/dev/null || true
    echo "  ⚡ 激进模式: ring buffer 已最大化"
  fi

  echo "  ✅ 出口网卡: $iface，offload 已检查（新开启 $applied 项）"

  # 持久化：写入 udev 规则，开机自动应用
  local udev_file="/etc/udev/rules.d/99-net-optimize-offload.rules"
  {
    echo "# Net-Optimize: NIC offload 持久化"
    echo "ACTION==\"add\", SUBSYSTEM==\"net\", NAME==\"$iface\", RUN+=\"/usr/sbin/ethtool -K $iface gro on gso on tso on sg on tx-nocache-copy on\""
    if [ "${AGGRESSIVE_MODE:-0}" = "1" ]; then
      echo "ACTION==\"add\", SUBSYSTEM==\"net\", NAME==\"$iface\", RUN+=\"/usr/sbin/ip link set $iface txqueuelen 10000\""
    fi
  } > "$udev_file"
  chmod 644 "$udev_file"
  echo "  ✅ offload 持久化：$udev_file"

  # === 自适应中断合并（降低延迟，平衡吞吐）===
  if [ "${ENABLE_IRQ_COALESCING:-1}" = "1" ]; then
    # 优先开启自适应模式；若网卡不支持，退回手动设置 50μs
    if ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null; then
      echo "  ✅ 中断合并：自适应模式已开启（adaptive-rx/tx on）"
    else
      ethtool -C "$iface" rx-usecs 50 tx-usecs 50 2>/dev/null \
        && echo "  ✅ 中断合并：固定 50μs (rx/tx-usecs)" \
        || echo "  ℹ️ 中断合并：网卡不支持，已跳过"
    fi
  fi

  # === WireGuard UDP GRO 转发（降低 WG 中转 CPU 占用）===
  if [ "${ENABLE_WG_OPT:-1}" = "1" ]; then
    if ip link show type wireguard >/dev/null 2>&1; then
      # 开启出口网卡的 UDP GRO 转发，让内核合并 WG UDP 包再转发
      ethtool -K "$iface" rx-udp-gro-forwarding on 2>/dev/null \
        && echo "  ✅ WireGuard UDP GRO 转发已开启（$iface）" \
        || echo "  ℹ️ WireGuard UDP GRO 转发：网卡不支持或内核版本不足，已跳过"
      # 对每个 WG 接口也开启 rx-udp-gro-forwarding
      local wg_iface
      while IFS= read -r wg_iface; do
        [ -z "$wg_iface" ] && continue
        ethtool -K "$wg_iface" rx-udp-gro-forwarding on 2>/dev/null || true
      done < <(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}')
    else
      echo "  ℹ️ 未检测到 WireGuard 接口，跳过 UDP GRO 转发"
    fi
  fi
}

# === 9.6 RPS/RFS 多核收包均衡 ===
setup_rps_rfs() {
  if [ "${ENABLE_RPS_RFS:-1}" != "1" ]; then
    echo "⏭️ 跳过 RPS/RFS 配置"
    return 0
  fi

  echo "🔧 RPS/RFS 多核收包均衡..."

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"
  [ -z "$iface" ] && { echo "  ⚠️ 无法检测出口网卡，跳过"; return 0; }

  local ncpu
  ncpu="$(nproc 2>/dev/null || echo 1)"
  [ "$ncpu" -le 1 ] && { echo "  ℹ️ 单核 CPU，RPS/RFS 无需配置"; return 0; }

  # 计算 CPU 掩码：所有核参与（例如 4 核 = f，8 核 = ff）
  local cpu_mask
  cpu_mask="$(printf '%x' $(( (1 << ncpu) - 1 )))"

  # RPS：设置每个 rx queue 的 CPU 掩码
  local rps_applied=0
  local queue_dir
  for queue_dir in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [ -f "$queue_dir" ] || continue
    echo "$cpu_mask" > "$queue_dir" 2>/dev/null && rps_applied=$((rps_applied + 1)) || true
  done

  # RFS：设置全局 flow 表大小和每队列 flow 数
  local rfs_entries=$(( 32768 * ncpu ))
  if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
    echo "$rfs_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
  fi

  local rfs_per_queue=$(( rfs_entries / (rps_applied > 0 ? rps_applied : 1) ))
  for queue_dir in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
    [ -f "$queue_dir" ] || continue
    echo "$rfs_per_queue" > "$queue_dir" 2>/dev/null || true
  done

  echo "  ✅ $iface: RPS 掩码=$cpu_mask (${ncpu}核), RFS entries=$rfs_entries, queues=$rps_applied"

  # 持久化：写入 systemd-tmpfiles
  local tmpfiles_conf="/etc/tmpfiles.d/net-optimize-rps.conf"
  {
    echo "# Net-Optimize: RPS/RFS 持久化"
    echo "w /proc/sys/net/core/rps_sock_flow_entries - - - - $rfs_entries"
    for queue_dir in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
      [ -f "$queue_dir" ] && echo "w $queue_dir - - - - $cpu_mask"
    done
    for queue_dir in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
      [ -f "$queue_dir" ] && echo "w $queue_dir - - - - $rfs_per_queue"
    done
  } > "$tmpfiles_conf"
  chmod 644 "$tmpfiles_conf"
  echo "  ✅ RPS/RFS 持久化：$tmpfiles_conf"

  # === XPS（Transmit Packet Steering）===
  # 让发包也绑定到 CPU，与 RPS 配合减少跨核锁竞争
  if [ "${ENABLE_XPS:-1}" = "1" ]; then
    local xps_applied=0
    local tx_queue_dir
    for tx_queue_dir in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
      [ -f "$tx_queue_dir" ] || continue
      echo "$cpu_mask" > "$tx_queue_dir" 2>/dev/null && xps_applied=$((xps_applied + 1)) || true
    done
    if [ "$xps_applied" -gt 0 ]; then
      echo "  ✅ XPS 已配置：$xps_applied 个 TX 队列绑定掩码=$cpu_mask"
      # 追加到 tmpfiles 持久化
      for tx_queue_dir in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
        [ -f "$tx_queue_dir" ] && echo "w $tx_queue_dir - - - - $cpu_mask" >> "$tmpfiles_conf"
      done
    else
      echo "  ℹ️ XPS：未发现可配置的 TX 队列（单队列网卡或不支持）"
    fi
  fi
}

# === 9.7 QUIC/UDP DSCP 优先级标记 ===
setup_dscp_marking() {
  if [ "${ENABLE_DSCP:-1}" != "1" ]; then
    echo "⏭️ 跳过 DSCP 标记"
    return 0
  fi

  echo "🏷️ QUIC/UDP DSCP 优先级标记..."

  # 复用 MSS 阶段已检测并记录的后端，避免重复试写干扰
  local ipt_backend=""
  if [ -f "$CONFIG_FILE" ]; then
    ipt_backend="$(grep '^IPT_BACKEND=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)"
  fi
  if [ -z "$ipt_backend" ] || ! have_cmd "$ipt_backend"; then
    ipt_backend="$(_nopt_detect_ipt_backend)"
  fi
  [ -z "$ipt_backend" ] && { echo "  ⚠️ iptables 不可用，跳过"; return 0; }

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"

  # DSCP EF (46 = 0x2E) 用于 UDP 443 (QUIC) 出口流量加速
  # 清理旧规则（用 here-string 避免 pipe subshell 问题）
  for cmd in iptables iptables-legacy iptables-nft; do
    have_cmd "$cmd" || continue
    local _dscp_rules
    _dscp_rules="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x2e|dscp-class EF|set-dscp 46' || true)"
    [ -z "$_dscp_rules" ] && continue
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      local del="${rule/-A POSTROUTING/-D POSTROUTING}"
      local -a parts
      read -r -a parts <<<"$del"
      "$cmd" -t mangle "${parts[@]}" 2>/dev/null || true
    done <<<"$_dscp_rules"
  done

  # 写入新规则：UDP 443 (QUIC) 标记为 EF
  local -a rule_opts=(-p udp --dport 443 -j DSCP --set-dscp-class EF)
  if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
    "$ipt_backend" -t mangle -A POSTROUTING -o "$iface" "${rule_opts[@]}" 2>/dev/null || true
  else
    "$ipt_backend" -t mangle -A POSTROUTING "${rule_opts[@]}" 2>/dev/null || true
  fi

  # IPv4 DSCP 去重（保留 1 条）
  # IPv4 DSCP 去重（保留 1 条）
  _nopt_dedup_rules "$ipt_backend" mangle POSTROUTING 'DSCP'

  # IPv6 DSCP（如果有 ip6tables 对应后端）
  local ip6_cmd=""
  if [ "$ipt_backend" = "iptables-legacy" ] && have_cmd ip6tables-legacy; then
    ip6_cmd="ip6tables-legacy"
  elif have_cmd ip6tables; then
    ip6_cmd="ip6tables"
  fi

  if [ -n "$ip6_cmd" ]; then
    # 清理旧 IPv6 DSCP
    local _dscp6_rules
    _dscp6_rules="$("$ip6_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x2e|dscp-class EF|set-dscp 46' || true)"
    if [ -n "$_dscp6_rules" ]; then
      while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        local del="${rule/-A POSTROUTING/-D POSTROUTING}"
        local -a parts
        read -r -a parts <<<"$del"
        "$ip6_cmd" -t mangle "${parts[@]}" 2>/dev/null || true
      done <<<"$_dscp6_rules"
    fi

    if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
      "$ip6_cmd" -t mangle -A POSTROUTING -o "$iface" "${rule_opts[@]}" 2>/dev/null || true
    else
      "$ip6_cmd" -t mangle -A POSTROUTING "${rule_opts[@]}" 2>/dev/null || true
    fi

    # IPv6 DSCP 去重
    _nopt_dedup_rules "$ip6_cmd" mangle POSTROUTING 'DSCP'
  fi

  echo "  ✅ UDP 443 (QUIC) DSCP=EF 已标记（$ipt_backend）"
}

# === 9.8b CPU 调频策略优化 ===
setup_cpu_governor() {
  if [ "${ENABLE_CPU_GOVERNOR:-1}" != "1" ]; then
    echo "⏭️ 跳过 CPU 调频优化"
    return 0
  fi

  echo "⚡ CPU 调频策略优化（performance 模式）..."

  local changed=0 total=0
  local gov_file
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov_file" ] || continue
    total=$((total + 1))
    local current
    current="$(cat "$gov_file" 2>/dev/null || true)"
    if [ "$current" != "performance" ]; then
      echo "performance" > "$gov_file" 2>/dev/null && changed=$((changed + 1)) || true
    fi
  done

  if [ "$total" -eq 0 ]; then
    echo "  ℹ️ 未发现 cpufreq 接口（容器/虚拟化环境不支持，已跳过）"
    return 0
  fi

  if [ "$changed" -gt 0 ]; then
    echo "  ✅ $changed/$total 个 CPU 核心已切换到 performance 模式"
  else
    echo "  ✅ CPU 调频已是 performance 模式（$total 核心，无需变更）"
  fi

  # 持久化：写入 cpupower / systemd-tmpfiles（双保险）
  if have_cmd cpupower; then
    cpupower frequency-set -g performance >/dev/null 2>&1 || true
  fi
  # tmpfiles 持久化
  local cpufreq_tmpfiles="/etc/tmpfiles.d/net-optimize-cpufreq.conf"
  {
    echo "# Net-Optimize: CPU performance governor"
    for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [ -f "$gov_file" ] && echo "w $gov_file - - - - performance"
    done
  } > "$cpufreq_tmpfiles"
  chmod 644 "$cpufreq_tmpfiles"
  echo "  ✅ CPU 调频持久化：$cpufreq_tmpfiles"
}

# === 9.8c MPTCP 多路径传输（内核 5.6+）===
setup_mptcp() {
  if [ "${ENABLE_MPTCP:-1}" != "1" ]; then
    echo "⏭️ 跳过 MPTCP 配置"
    return 0
  fi

  echo "🔀 MPTCP 多路径传输检测..."

  # 检测内核是否支持 MPTCP
  if ! sysctl net.mptcp.enabled >/dev/null 2>&1; then
    echo "  ℹ️ 内核不支持 MPTCP（需要 5.6+），已跳过"
    return 0
  fi

  sysctl -w net.mptcp.enabled=1 >/dev/null 2>&1 || true
  local mptcp_state
  mptcp_state="$(sysctl -n net.mptcp.enabled 2>/dev/null || echo 0)"

  if [ "$mptcp_state" = "1" ]; then
    echo "  ✅ MPTCP 已启用"
    # 写入 sysctl 持久化文件
    local mptcp_conf="/etc/sysctl.d/98-net-optimize-mptcp.conf"
    echo "net.mptcp.enabled = 1" > "$mptcp_conf"
    chmod 644 "$mptcp_conf"
  else
    echo "  ⚠️ MPTCP 启用失败（可能被内核编译选项禁用）"
  fi
}

# === 9.8 自动检测线路质量 + initcwnd 调整 ===
setup_initcwnd() {
  if [ "${ENABLE_INITCWND:-1}" != "1" ]; then
    echo "⏭️ 跳过 initcwnd 自动调整"
    return 0
  fi

  echo "📡 检测线路质量，自动调整 initcwnd..."

  # 测量到几个目标的 RTT
  local total_rtt=0 count=0 rtt
  for target in 1.1.1.1 8.8.8.8 9.9.9.9; do
    rtt="$(ping -c 3 -W 2 "$target" 2>/dev/null \
      | awk -F'/' '/^rtt|^round-trip/ {print $5}' | head -n1 || true)"
    if [ -n "$rtt" ] && [ "$rtt" != "0" ]; then
      # 取整数部分
      local rtt_int="${rtt%%.*}"
      [ -n "$rtt_int" ] && [ "$rtt_int" -gt 0 ] 2>/dev/null && {
        total_rtt=$((total_rtt + rtt_int))
        count=$((count + 1))
      }
    fi
  done

  local avg_rtt=0
  if [ "$count" -gt 0 ]; then
    avg_rtt=$((total_rtt / count))
  fi

  # 根据 RTT 选择 initcwnd
  # 普通模式：
  #   RTT < 50ms: initcwnd=20 / 50-150ms: initcwnd=30 / >150ms: initcwnd=50
  # 激进模式：一律 initcwnd=64（最大化初始窗口）
  local initcwnd=20
  if [ "${AGGRESSIVE_MODE:-0}" = "1" ]; then
    initcwnd=64
    echo "  ⚡ 激进模式: initcwnd=64（最大初始窗口）"
  else
    if [ "$avg_rtt" -gt 150 ]; then
      initcwnd=50
    elif [ "$avg_rtt" -gt 50 ]; then
      initcwnd=30
    fi
  fi

  echo "  ℹ️ 平均 RTT: ${avg_rtt}ms → initcwnd=$initcwnd"

  # 获取默认路由并设置 initcwnd + initrwnd
  local default_gw
  default_gw="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
  if [ -n "$default_gw" ]; then
    local clean_gw
    clean_gw="$(_strip_route_params "$default_gw")"
    local -a gw_parts; read -ra gw_parts <<<"$clean_gw"
    ip route change "${gw_parts[@]}" initcwnd "$initcwnd" initrwnd "$initcwnd" 2>/dev/null || true
    echo "  ✅ IPv4 默认路由 initcwnd=$initcwnd initrwnd=$initcwnd"
  fi

  # IPv6 默认路由
  local default_gw6
  default_gw6="$(ip -6 route show default 2>/dev/null | head -n1 || true)"
  if [ -n "$default_gw6" ]; then
    local clean_gw6
    clean_gw6="$(_strip_route_params "$default_gw6")"
    local -a gw6_parts; read -ra gw6_parts <<<"$clean_gw6"
    ip -6 route change "${gw6_parts[@]}" initcwnd "$initcwnd" initrwnd "$initcwnd" 2>/dev/null || true
    echo "  ✅ IPv6 默认路由 initcwnd=$initcwnd initrwnd=$initcwnd"
  fi

  # 持久化到 config（供 apply 脚本用）
  if [ -f "$CONFIG_FILE" ]; then
    # 追加或更新
    grep -q '^INITCWND=' "$CONFIG_FILE" 2>/dev/null \
      && sed -i "s/^INITCWND=.*/INITCWND=$initcwnd/" "$CONFIG_FILE" \
      || echo "INITCWND=$initcwnd" >> "$CONFIG_FILE"
  fi

  echo "  ✅ initcwnd 配置完成"
}

# === 9.9 激进模式：网卡 tc qdisc 覆盖 ===
setup_aggressive_tc() {
  if [ "${ADAPTIVE_QOS:-0}" = "1" ]; then
    return 0
  fi
  if [ "${AGGRESSIVE_MODE:-0}" != "1" ]; then
    return 0
  fi

  echo "⚡ 激进模式：覆盖网卡 tc qdisc..."

  have_cmd tc || { echo "  ⚠️ tc 命令不可用，跳过"; return 0; }

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"
  [ -z "$iface" ] && { echo "  ⚠️ 无法检测出口网卡，跳过"; return 0; }

  # 替换网卡 qdisc 为 pfifo_fast（不做流量整形，不限速）
  tc qdisc replace dev "$iface" root pfifo_fast 2>/dev/null || \
    tc qdisc replace dev "$iface" root pfifo limit 10000 2>/dev/null || true

  local current_qdisc
  current_qdisc="$(tc qdisc show dev "$iface" root 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  echo "  ✅ $iface qdisc 已设置为: ${current_qdisc:-unknown}"
  echo "  ⚡ 无流量整形，发包不受 AQM 限制"
}

# === 9.10 游戏低延迟 QoS（cake + prio 双方案）===
setup_game_qos() {
  if [ "${ADAPTIVE_QOS:-0}" = "1" ]; then
    return 0
  fi
  if [ "${ENABLE_GAME_QOS:-1}" != "1" ]; then
    echo "⏭️ 跳过游戏 QoS 配置"
    return 0
  fi

  # 激进模式与游戏 QoS 互斥（激进模式用 pfifo_fast 不做调度）
  if [ "${AGGRESSIVE_MODE:-0}" = "1" ]; then
    echo "⏭️ 激进模式已开启，跳过游戏 QoS（互斥）"
    return 0
  fi

  echo "🎮 游戏低延迟 QoS 配置..."

  have_cmd tc || { echo "  ⚠️ tc 命令不可用，跳过"; return 0; }

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"
  [ -z "$iface" ] && { echo "  ⚠️ 无法检测出口网卡，跳过"; return 0; }

  # --- 检测 iptables 后端（复用已保存的）---
  local ipt_backend=""
  if [ -f "$CONFIG_FILE" ]; then
    ipt_backend="$(grep '^IPT_BACKEND=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)"
  fi
  if [ -z "$ipt_backend" ] || ! have_cmd "$ipt_backend"; then
    ipt_backend="$(_nopt_detect_ipt_backend)"
  fi

  # --- 检测 IPv6 后端 ---
  local ip6_cmd=""
  if [ "$ipt_backend" = "iptables-legacy" ] && have_cmd ip6tables-legacy; then
    ip6_cmd="ip6tables-legacy"
  elif have_cmd ip6tables; then
    ip6_cmd="ip6tables"
  fi

  # === 方案选择：优先 cake，fallback prio ===
  local qos_scheme="none"

  # 检测 cake 是否可用
  if modprobe sch_cake 2>/dev/null; then
    # 试挂 cake，如果成功就用 cake
    if tc qdisc replace dev "$iface" root cake bandwidth unlimited diffserv4 nat nowash no-split-gso 2>/dev/null; then
      qos_scheme="cake"
      echo "  ✅ 方案 A：cake diffserv4 已启用"
      echo "    → 4 档优先级自动分流（Bulk/Best Effort/Video/Voice）"
      echo "    → 游戏小包自动归入高优先级队列"
      echo "    → 视频大流归入 Bulk 队列，不挤压游戏包"
    else
      echo "  ⚠️ cake 挂载失败，回退方案 B"
    fi
  fi

  # cake 不可用，用 prio + fq_codel 分流
  if [ "$qos_scheme" = "none" ]; then
    # prio 3 档：band 0（高优先）/ band 1（普通）/ band 2（低优先）
    # 每个 band 下挂 fq_codel 做 per-flow 公平调度
    tc qdisc replace dev "$iface" root handle 1: prio bands 3 priomap \
      1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 2>/dev/null || {
      echo "  ⚠️ prio qdisc 设置失败，跳过游戏 QoS"
      return 0
    }

    # 每个 band 挂 fq_codel
    tc qdisc replace dev "$iface" parent 1:1 handle 10: fq_codel 2>/dev/null || true
    tc qdisc replace dev "$iface" parent 1:2 handle 20: fq_codel 2>/dev/null || true
    tc qdisc replace dev "$iface" parent 1:3 handle 30: fq_codel 2>/dev/null || true

    # tc filter：DSCP EF(46) / AF41(34) → band 0（高优先）
    # 先清旧 filter
    tc filter del dev "$iface" parent 1: 2>/dev/null || true
    # DSCP EF (TOS 0xb8) → band 0
    tc filter add dev "$iface" parent 1: protocol ip prio 1 u32 \
      match ip tos 0xb8 0xfc flowid 1:1 2>/dev/null || true
    # DSCP AF41 (TOS 0x88) → band 0
    tc filter add dev "$iface" parent 1: protocol ip prio 2 u32 \
      match ip tos 0x88 0xfc flowid 1:1 2>/dev/null || true
    # 小 UDP 包 (≤128 字节) → band 0（游戏包通常很小）
    tc filter add dev "$iface" parent 1: protocol ip prio 3 u32 \
      match ip protocol 17 0xff match u16 0x0000 0xff80 at 2 flowid 1:1 2>/dev/null || true

    qos_scheme="prio"
    echo "  ✅ 方案 B：prio + fq_codel 已启用"
    echo "    → band 0（高优先）：DSCP EF/AF41 + 小 UDP 包"
    echo "    → band 1（普通）：一般流量"
    echo "    → band 2（低优先）：Bulk 流量"
  fi

  # === DSCP 标记：游戏流量打 AF41 ===
  # 游戏特征：小 UDP 包（≤128 字节，排除 QUIC 443 已经打了 EF）
  # 这里标记 UDP 非 443 端口的小包为 AF41
  if [ -n "$ipt_backend" ] && have_cmd "$ipt_backend"; then
    # 清理旧的 AF41 规则
    local _af41_rules
    for _cmd in "$ipt_backend" ${ip6_cmd:+"$ip6_cmd"}; do
      [ -n "$_cmd" ] && have_cmd "$_cmd" || continue
      _af41_rules="$("$_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x22|dscp-class AF41|set-dscp 34' || true)"
      if [ -n "$_af41_rules" ]; then
        while IFS= read -r rule; do
          [ -z "$rule" ] && continue
          local del="${rule/-A POSTROUTING/-D POSTROUTING}"
          local -a parts
          read -r -a parts <<<"$del"
          "$_cmd" -t mangle "${parts[@]}" 2>/dev/null || true
        done <<<"$_af41_rules"
      fi
    done

    # 写入新规则：UDP 小包（≤128 字节）且非 443 端口 → AF41
    # -m length 匹配 IP 总长度（含头），UDP 游戏包通常 <200 字节
    local -a _game_dscp_opts=(-p udp ! --dport 443 -m length --length 0:200 -j DSCP --set-dscp-class AF41)
    if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
      "$ipt_backend" -t mangle -A POSTROUTING -o "$iface" "${_game_dscp_opts[@]}" 2>/dev/null || true
    else
      "$ipt_backend" -t mangle -A POSTROUTING "${_game_dscp_opts[@]}" 2>/dev/null || true
    fi

    # IPv6 同样处理
    if [ -n "$ip6_cmd" ]; then
      if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
        "$ip6_cmd" -t mangle -A POSTROUTING -o "$iface" "${_game_dscp_opts[@]}" 2>/dev/null || true
      else
        "$ip6_cmd" -t mangle -A POSTROUTING "${_game_dscp_opts[@]}" 2>/dev/null || true
      fi
    fi

    echo "  ✅ 游戏 DSCP 标记：UDP 小包(≤200B, 非443) → AF41"
  fi

  # 持久化到 config
  if [ -f "$CONFIG_FILE" ]; then
    grep -q '^GAME_QOS_SCHEME=' "$CONFIG_FILE" 2>/dev/null \
      && sed -i "s/^GAME_QOS_SCHEME=.*/GAME_QOS_SCHEME=$qos_scheme/" "$CONFIG_FILE" \
      || echo "GAME_QOS_SCHEME=$qos_scheme" >> "$CONFIG_FILE"
  fi

  echo "  ✅ 游戏 QoS 配置完成（方案: $qos_scheme）"
}

# === 9.11 自适应 QoS（流量高→抢带宽，流量低→游戏低延迟）===
ADAPTIVE_QOS_DAEMON="/usr/local/sbin/net-optimize-adaptive-qos"
ADAPTIVE_QOS_SERVICE="net-optimize-adaptive-qos"

setup_adaptive_qos() {
  if [ "${ADAPTIVE_QOS:-0}" != "1" ]; then
    # 清理：如果之前启用过，现在关闭
    if systemctl is-active "${ADAPTIVE_QOS_SERVICE}" >/dev/null 2>&1; then
      systemctl stop "${ADAPTIVE_QOS_SERVICE}" 2>/dev/null || true
      systemctl disable "${ADAPTIVE_QOS_SERVICE}" 2>/dev/null || true
      echo "🔄 自适应 QoS 已停止并关闭"
    fi
    return 0
  fi

  echo "🔄 自适应 QoS 配置（流量自动切换）..."

  have_cmd tc || { echo "  ⚠️ tc 命令不可用，跳过"; return 0; }

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"
  [ -z "$iface" ] && { echo "  ⚠️ 无法检测出口网卡，跳过"; return 0; }

  # 检测 cake 可用性
  local has_cake=0
  if modprobe sch_cake 2>/dev/null; then
    has_cake=1
  fi

  # 检测 iptables 后端
  local ipt_backend=""
  if [ -f "$CONFIG_FILE" ]; then
    ipt_backend="$(grep '^IPT_BACKEND=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)"
  fi
  if [ -z "$ipt_backend" ] || ! have_cmd "$ipt_backend"; then
    ipt_backend="$(_nopt_detect_ipt_backend)"
  fi

  local ip6_cmd=""
  if [ "$ipt_backend" = "iptables-legacy" ] && have_cmd ip6tables-legacy; then
    ip6_cmd="ip6tables-legacy"
  elif have_cmd ip6tables; then
    ip6_cmd="ip6tables"
  fi

  # === 检查 Python3 ===
  if ! have_cmd python3; then
    echo "  ⚠️ python3 不可用，跳过自适应 QoS"
    return 0
  fi

  # === 检测 -m length 模块可用性（IPv4 和 IPv6 分别测试）===
  local has_length=0
  if [ -n "$ipt_backend" ] && have_cmd "$ipt_backend"; then
    if "$ipt_backend" -t mangle -A POSTROUTING -p udp -m length --length 0:200 -j RETURN 2>/dev/null; then
      "$ipt_backend" -t mangle -D POSTROUTING -p udp -m length --length 0:200 -j RETURN 2>/dev/null || true
      has_length=1
    fi
  fi
  [ "$has_length" = "0" ] && echo "  ⚠️ iptables -m length 不可用，IPv4 AF41 标记将跳过"

  local has_length_ip6=0
  if [ -n "$ip6_cmd" ] && have_cmd "$ip6_cmd"; then
    if "$ip6_cmd" -t mangle -A POSTROUTING -p udp -m length --length 0:200 -j RETURN 2>/dev/null; then
      "$ip6_cmd" -t mangle -D POSTROUTING -p udp -m length --length 0:200 -j RETURN 2>/dev/null || true
      has_length_ip6=1
    fi
  fi
  [ "$has_length_ip6" = "0" ] && [ -n "$ip6_cmd" ] && echo "  ⚠️ ip6tables -m length 不可用，IPv6 AF41 标记将跳过"

  # === 写入 JSON 配置 ===
  cat >"$CONFIG_DIR/adaptive-qos.conf" <<CONFEOF
{
  "iface": "$iface",
  "threshold": $ADAPTIVE_QOS_THRESHOLD,
  "interval": $ADAPTIVE_QOS_INTERVAL,
  "cooldown": ${ADAPTIVE_QOS_COOLDOWN:-10},
  "has_cake": $([ "$has_cake" = "1" ] && echo "true" || echo "false"),
  "has_length": $([ "$has_length" = "1" ] && echo "true" || echo "false"),
  "has_length_ip6": $([ "$has_length_ip6" = "1" ] && echo "true" || echo "false"),
  "ipt_backend": "$ipt_backend",
  "ip6_cmd": "$ip6_cmd"
}
CONFEOF

  # === 写入 Python3 守护脚本 ===
  cat >"$ADAPTIVE_QOS_DAEMON" <<'PYEOF'
#!/usr/bin/env python3
"""net-optimize adaptive QoS daemon
自动根据出口流量切换 抢带宽(pfifo_fast) ↔ 游戏低延迟(cake/prio)
"""

import json
import logging
import logging.handlers
import os
import shutil
import subprocess
import sys
import time

CONF_PATH = "/etc/net-optimize/adaptive-qos.conf"

# ---------------------------------------------------------------------------
# Logging → syslog (tag: adaptive-qos)
# ---------------------------------------------------------------------------
log = logging.getLogger("adaptive-qos")
log.setLevel(logging.INFO)
try:
    _h = logging.handlers.SysLogHandler(address="/dev/log")
    _h.ident = "adaptive-qos: "
    log.addHandler(_h)
except Exception:
    logging.basicConfig(level=logging.INFO)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def run(cmd: str, check: bool = False) -> subprocess.CompletedProcess:
    """Run a shell command; never raise unless check=True."""
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, check=check)

def has_cmd(name: str) -> bool:
    return shutil.which(name) is not None

def read_tx_bytes(iface: str) -> int:
    try:
        with open(f"/sys/class/net/{iface}/statistics/tx_bytes") as f:
            return int(f.read().strip())
    except Exception:
        return 0

def read_rx_bytes(iface: str) -> int:
    try:
        with open(f"/sys/class/net/{iface}/statistics/rx_bytes") as f:
            return int(f.read().strip())
    except Exception:
        return 0

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
def load_conf() -> dict:
    with open(CONF_PATH) as f:
        return json.load(f)

# ---------------------------------------------------------------------------
# QoS switching
# ---------------------------------------------------------------------------
class AdaptiveQoS:
    def __init__(self, conf: dict):
        self.iface         = conf["iface"]
        self.threshold     = conf["threshold"]
        self.interval      = conf["interval"]
        self.cooldown_secs = conf.get("cooldown", 10)
        self.has_cake      = conf.get("has_cake", False)
        self.has_length     = conf.get("has_length", False)
        self.has_length_ip6 = conf.get("has_length_ip6", conf.get("has_length", False))
        self.ipt            = conf.get("ipt_backend", "")
        self.ip6            = conf.get("ip6_cmd", "")
        self.mode          = "unknown"  # game / aggressive / unknown

    # ---- tc: 游戏低延迟 ----
    def _apply_cake(self) -> bool:
        r = run(f"tc qdisc replace dev {self.iface} root cake bandwidth unlimited "
                f"diffserv4 nat nowash no-split-gso")
        return r.returncode == 0

    def _apply_prio(self):
        run(f"tc qdisc replace dev {self.iface} root handle 1: prio bands 3 "
            f"priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1")
        run(f"tc qdisc replace dev {self.iface} parent 1:1 handle 10: fq_codel")
        run(f"tc qdisc replace dev {self.iface} parent 1:2 handle 20: fq_codel")
        run(f"tc qdisc replace dev {self.iface} parent 1:3 handle 30: fq_codel")
        run(f"tc filter del dev {self.iface} parent 1:")
        # DSCP EF → band 0
        run(f"tc filter add dev {self.iface} parent 1: protocol ip prio 1 u32 "
            f"match ip tos 0xb8 0xfc flowid 1:1")
        # DSCP AF41 → band 0
        run(f"tc filter add dev {self.iface} parent 1: protocol ip prio 2 u32 "
            f"match ip tos 0x88 0xfc flowid 1:1")
        # 小 UDP 包 → band 0
        run(f"tc filter add dev {self.iface} parent 1: protocol ip prio 3 u32 "
            f"match ip protocol 17 0xff match u16 0x0000 0xff80 at 2 flowid 1:1")

    # ---- tc: 抢带宽 ----
    def _apply_pfifo(self):
        r = run(f"tc qdisc replace dev {self.iface} root pfifo_fast")
        if r.returncode != 0:
            run(f"tc qdisc replace dev {self.iface} root pfifo limit 10000")

    # ---- DSCP AF41: 游戏小包标记 ----
    def _clear_af41(self):
        """清除所有 AF41 DSCP 规则（兼容 0x22 / dscp-class AF41 / set-dscp 34）"""
        for cmd in [self.ipt, self.ip6]:
            if not cmd or not has_cmd(cmd):
                continue
            r = run(f"{cmd} -t mangle -S POSTROUTING")
            if r.returncode != 0:
                continue
            for line in r.stdout.splitlines():
                if "0x22" not in line and "dscp-class AF41" not in line and "set-dscp 34" not in line:
                    continue
                del_rule = line.replace("-A POSTROUTING", "-D POSTROUTING", 1)
                run(f"{cmd} -t mangle {del_rule}")

    def _apply_af41(self):
        """写入 AF41 DSCP: UDP ≤200B 非443 端口"""
        self._clear_af41()
        opts_len = ("-p udp ! --dport 443 -m length --length 0:200 "
                    "-j DSCP --set-dscp-class AF41")
        opts_nolen = "-p udp ! --dport 443 -j DSCP --set-dscp-class AF41"
        if self.ipt and has_cmd(self.ipt) and self.has_length:
            run(f"{self.ipt} -t mangle -A POSTROUTING -o {self.iface} {opts_len}")
        if self.ip6 and has_cmd(self.ip6):
            if self.has_length_ip6:
                r = run(f"{self.ip6} -t mangle -A POSTROUTING -o {self.iface} {opts_len}")
                if r.returncode != 0:
                    # ip6tables -m length 不支持时降级为不带长度过滤的规则
                    run(f"{self.ip6} -t mangle -A POSTROUTING -o {self.iface} {opts_nolen}")
            else:
                run(f"{self.ip6} -t mangle -A POSTROUTING -o {self.iface} {opts_nolen}")

    # ---- 模式切换 ----
    def switch_to_game(self):
        if self.mode == "game":
            return
        if self.has_cake:
            if not self._apply_cake():
                self._apply_prio()
        else:
            self._apply_prio()
        self._apply_af41()
        self.mode = "game"
        log.info("切换 → 游戏低延迟 (rate < %d B/s)", self.threshold)

    def switch_to_aggressive(self):
        if self.mode == "aggressive":
            return
        self._apply_pfifo()
        self._apply_af41()
        self.mode = "aggressive"
        log.info("切换 → 抢带宽 (rate >= %d B/s)", self.threshold)

    # ---- 主循环 ----
    def run_forever(self):
        cooldown_max = max(1, self.cooldown_secs // self.interval)
        log.info("启动: iface=%s threshold=%d interval=%d cooldown=%ds(%d ticks)",
                 self.iface, self.threshold, self.interval,
                 self.cooldown_secs, cooldown_max)

        # 启动时先进入游戏模式
        self.switch_to_game()

        prev_rx = read_rx_bytes(self.iface)
        prev_tx = read_tx_bytes(self.iface)
        time.sleep(self.interval)

        cooldown_ticks = 0  # 抢带宽冷却计数器（>0 时保持抢带宽）

        while True:
            rx = read_rx_bytes(self.iface)
            tx = read_tx_bytes(self.iface)

            # 入站/出站取最大值，任意方向达到阈值即触发抢带宽
            rx_rate = (rx - prev_rx) // self.interval
            tx_rate = (tx - prev_tx) // self.interval
            rate = max(rx_rate, tx_rate)

            prev_rx = rx
            prev_tx = tx

            if rate >= self.threshold:
                # 流量达到阈值：立即抢带宽，重置冷却计时
                cooldown_ticks = cooldown_max
                self.switch_to_aggressive()
            else:
                if cooldown_ticks > 0:
                    # 冷却中：保持抢带宽，等流量稳定后再切回
                    cooldown_ticks -= 1
                else:
                    self.switch_to_game()

            time.sleep(self.interval)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    try:
        conf = load_conf()
    except Exception as e:
        print(f"❌ 读取配置失败: {e}", file=sys.stderr)
        sys.exit(1)

    qos = AdaptiveQoS(conf)
    try:
        qos.run_forever()
    except KeyboardInterrupt:
        log.info("收到停止信号，退出")
    except Exception as e:
        log.error("守护进程异常: %s", e)
        sys.exit(1)
PYEOF

  chmod +x "$ADAPTIVE_QOS_DAEMON"

  # === 安装 systemd 服务 ===
  cat >"/etc/systemd/system/${ADAPTIVE_QOS_SERVICE}.service" <<SVCEOF
[Unit]
Description=Net-Optimize Adaptive QoS Daemon (Python3)
After=network-online.target net-optimize.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${ADAPTIVE_QOS_DAEMON}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "${ADAPTIVE_QOS_SERVICE}.service" 2>/dev/null || true
  systemctl restart "${ADAPTIVE_QOS_SERVICE}.service" 2>/dev/null || true

  # 持久化到 config
  if [ -f "$CONFIG_FILE" ]; then
    grep -q '^ADAPTIVE_QOS=' "$CONFIG_FILE" 2>/dev/null \
      && sed -i "s/^ADAPTIVE_QOS=.*/ADAPTIVE_QOS=1/" "$CONFIG_FILE" \
      || echo "ADAPTIVE_QOS=1" >> "$CONFIG_FILE"
    grep -q '^ADAPTIVE_QOS_IFACE=' "$CONFIG_FILE" 2>/dev/null \
      && sed -i "s/^ADAPTIVE_QOS_IFACE=.*/ADAPTIVE_QOS_IFACE=$iface/" "$CONFIG_FILE" \
      || echo "ADAPTIVE_QOS_IFACE=$iface" >> "$CONFIG_FILE"
  fi

  echo "  ✅ 自适应 QoS 守护进程已启动"
  echo "    → 网卡: $iface"
  echo "    → 阈值: $(( ADAPTIVE_QOS_THRESHOLD / 1024 )) KB/s"
  echo "    → 采样: 每 ${ADAPTIVE_QOS_INTERVAL}s"
  echo "    → 流量 ≥ 阈值 → pfifo_fast（抢带宽）"
  echo "    → 流量 < 阈值 → ${has_cake:+cake}${has_cake:+/}prio（游戏低延迟）"
  echo "    → 服务: systemctl status ${ADAPTIVE_QOS_SERVICE}"
}

# === 10. MSS Clamping ===
detect_outbound_iface() {
  local iface=""
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -n1 || true)
  if [ -z "$iface" ]; then
    iface=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -n1 || true)
  fi
  if [ -z "$iface" ]; then
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1 || true)
  fi
  echo "$iface"
}

# --- MSS 清理辅助（统一给主脚本 + apply 脚本用）---
_nopt_clear_all_tcpmss() {
  local cmd="$1"
  local round=0

  while :; do
    local rules
    rules="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E 'TCPMSS' || true)"
    [ -z "$rules" ] && break

    round=$((round + 1))
    [ "$round" -gt 80 ] && break

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      local del="${rule/-A POSTROUTING/-D POSTROUTING}"
      local -a parts
      read -r -a parts <<<"$del"
      "$cmd" -t mangle "${parts[@]}" 2>/dev/null || true
    done <<<"$rules"
  done
}

_nopt_apply_one_tcpmss() {
  local cmd="$1" iface="$2" mss="$3"

  if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
    "$cmd" -t mangle -A POSTROUTING -o "$iface" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --set-mss "$mss" 2>/dev/null && return 0
  else
    "$cmd" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --set-mss "$mss" 2>/dev/null && return 0
  fi

  return 1
}

# --- iptables 规则去重：保留 keep 条，其余删除 ---
# 用法: _nopt_dedup_rules <cmd> <table> <chain> <grep-pattern> [keep=1]
_nopt_dedup_rules() {
  local cmd="$1" table="$2" chain="$3" pattern="$4" keep="${5:-1}"
  local round=0 cnt first del
  local -a parts
  while :; do
    cnt="$("$cmd" -t "$table" -S "$chain" 2>/dev/null | grep -cE "$pattern" || true)"
    cnt="${cnt%%$'\n'*}"; cnt="${cnt:-0}"
    [ "$cnt" -le "$keep" ] && break
    round=$((round + 1)); [ "$round" -gt 20 ] && break
    first="$("$cmd" -t "$table" -S "$chain" 2>/dev/null | grep -E "$pattern" | head -n1 || true)"
    [ -z "$first" ] && break
    del="${first//-A ${chain}/-D ${chain}}"
    read -ra parts <<<"$del"
    "$cmd" -t "$table" "${parts[@]}" 2>/dev/null || break
  done
}

# --- 从路由字符串中剥离 ip route change 不接受的参数 ---
_strip_route_params() {
  echo "$1" | sed -E \
    's/ initcwnd [0-9]+//g;
     s/ initrwnd [0-9]+//g;
     s/ expires [0-9]+sec//g;
     s/ hoplimit [0-9]+//g;
     s/ pref [a-z]+//g'
}

# --- 检测 iptables 实际可用后端 ---
# 有些系统同时装了 iptables-nft 和 iptables-legacy，默认 iptables 指向 nft，
# 但 legacy tables 存在时 nft 后端写入会静默失败或被忽略。
# 检测方法：
#   1) 先看 iptables 有没有 legacy 警告（快速路径）
#   2) 如果没有警告，用默认 iptables 试写一条，检查是否真的写进去了
#   3) 如果试写失败（静默失败），换 iptables-legacy 试
_nopt_detect_ipt_backend() {
  local warn

  # 快速路径：有 legacy 警告就直接返回 legacy
  if have_cmd iptables; then
    warn="$(iptables -t mangle -S POSTROUTING 2>&1 || true)"
    if echo "$warn" | grep -qi 'iptables-legacy'; then
      if have_cmd iptables-legacy; then
        echo "iptables-legacy"
        return 0
      fi
    fi
  fi

  # 试写验证：用默认 iptables 写一条测试规则，检查是否真的存在
  if have_cmd iptables; then
    # 写入测试规则（用一个不太可能冲突的 MSS 值做标记）
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --set-mss 9999 2>/dev/null || true

    local test_cnt
    test_cnt="$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c 'set-mss 9999' || true)"
    test_cnt="${test_cnt%%$'\n'*}"; test_cnt="${test_cnt:-0}"

    # 清理测试规则（不管在哪个后端都清）
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --set-mss 9999 2>/dev/null || true
    if have_cmd iptables-legacy; then
      iptables-legacy -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss 9999 2>/dev/null || true
    fi

    if [ "$test_cnt" -ge 1 ]; then
      # 默认 iptables 能写能读，正常使用
      echo "iptables"
      return 0
    fi

    # 默认 iptables 试写失败（静默失败），尝试 iptables-legacy
    if have_cmd iptables-legacy; then
      iptables-legacy -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss 9999 2>/dev/null || true

      test_cnt="$(iptables-legacy -t mangle -S POSTROUTING 2>/dev/null | grep -c 'set-mss 9999' || true)"
      test_cnt="${test_cnt%%$'\n'*}"; test_cnt="${test_cnt:-0}"

      # 清理
      iptables-legacy -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss 9999 2>/dev/null || true

      if [ "$test_cnt" -ge 1 ]; then
        echo "iptables-legacy"
        return 0
      fi
    fi

    # 都写不进去，还是返回默认
    echo "iptables"
    return 0
  fi

  # fallback
  if have_cmd iptables-legacy; then
    echo "iptables-legacy"
    return 0
  fi
  if have_cmd iptables-nft; then
    echo "iptables-nft"
    return 0
  fi
  echo ""
}

setup_mss_clamping() {
  if [ "${ENABLE_MSS_CLAMP:-0}" != "1" ]; then
    echo "⏭️ 跳过MSS Clamping"
    return 0
  fi

  # 清理 netfilter-persistent 保存文件中的 mangle 规则（防止开机恢复旧 MSS/DSCP 规则导致重复）
  # 注意：保留 netfilter-persistent 启用状态，它负责恢复 nat 表的端口跳跃规则
  for _pf in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ -f "$_pf" ] && grep -q '^\*mangle' "$_pf" 2>/dev/null; then
      sed -i '/^\*mangle$/,/^COMMIT$/d' "$_pf" 2>/dev/null || true
      echo "  ℹ️ 已从 $_pf 中移除 mangle 段"
    fi
  done
  # 确保 netfilter-persistent 处于启用状态（可能被旧版脚本禁用过）
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
    systemctl enable netfilter-persistent 2>/dev/null || true
  fi

  echo "📡 设置MSS Clamping (MSS=$MSS_VALUE)..."

  local iface
  iface="$(detect_outbound_iface 2>/dev/null || true)"

  if [ -z "${iface:-}" ]; then
    echo "⚠️ 无法确定出口接口，将使用全局规则"
    iface=""
  else
    echo "✅ 检测到出口接口: $iface"
  fi

  # 确保 iptables 模块已加载（有些系统首次调用前需要，必须在后端检测前执行）
  modprobe ip_tables 2>/dev/null || true
  modprobe iptable_mangle 2>/dev/null || true
  modprobe ip6_tables 2>/dev/null || true
  modprobe ip6table_mangle 2>/dev/null || true

  # 检测实际后端
  local ipt_backend
  ipt_backend="$(_nopt_detect_ipt_backend)"
  [ -z "$ipt_backend" ] && { echo "⚠️ iptables 不可用，跳过"; return 0; }
  echo "  ℹ️ iptables 后端: $ipt_backend"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
ENABLE_MSS_CLAMP=1
CLAMP_IFACE=$iface
MSS_VALUE=$MSS_VALUE
RP_FILTER=$RP_FILTER
IPT_BACKEND=$ipt_backend
EOF

  # 1) 所有后端先强制清理
  for cmd in iptables iptables-nft iptables-legacy; do
    have_cmd "$cmd" && _nopt_clear_all_tcpmss "$cmd"
  done

  # 2) 用检测到的后端写入 1 条
  if _nopt_apply_one_tcpmss "$ipt_backend" "$iface" "$MSS_VALUE"; then
    echo "✅ MSS 规则已写入（$ipt_backend）"
  else
    echo "❌ MSS 写入失败（$ipt_backend）"
    return 1
  fi

  # 3) 验证 + 自动去重（用同一个后端检查）
  _nopt_dedup_rules "$ipt_backend" mangle POSTROUTING 'TCPMSS'

  local cnt
  cnt="$("$ipt_backend" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
  cnt="${cnt%%$'\n'*}"; cnt="${cnt:-0}"
  if [ "$cnt" -eq 1 ]; then
    echo "✅ TCPMSS 规则数量：1（正常）"
  elif [ "$cnt" -eq 0 ]; then
    echo "⚠️ TCPMSS 规则数量：0（写入可能失败）"
  else
    echo "⚠️ TCPMSS 规则数量：$cnt（仍有重复，可能有其他服务在加）"
  fi

  echo "✅ MSS Clamping 设置完成"

  # === IPv6 MSS Clamping ===
  if [ "${ENABLE_IPV6_MSS:-1}" = "1" ]; then
    echo "📡 设置 IPv6 MSS Clamping..."

    # 检测 IPv6 对应后端
    local ip6_cmd=""
    if [ "$ipt_backend" = "iptables-legacy" ] && have_cmd ip6tables-legacy; then
      ip6_cmd="ip6tables-legacy"
    elif have_cmd ip6tables; then
      ip6_cmd="ip6tables"
    fi

    if [ -n "$ip6_cmd" ]; then
      # 清理旧 IPv6 TCPMSS
      local ip6_round=0
      while :; do
        local ip6_rules
        ip6_rules="$("$ip6_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E 'TCPMSS' || true)"
        [ -z "$ip6_rules" ] && break
        ip6_round=$((ip6_round + 1))
        [ "$ip6_round" -gt 40 ] && break
        while IFS= read -r rule; do
          [ -z "$rule" ] && continue
          local del6="${rule/-A POSTROUTING/-D POSTROUTING}"
          local -a parts6
          read -r -a parts6 <<<"$del6"
          "$ip6_cmd" -t mangle "${parts6[@]}" 2>/dev/null || true
        done <<<"$ip6_rules"
      done

      # 写入 IPv6 MSS 规则（MSS 值与 IPv4 一致）
      local ipv6_mss=$((MSS_VALUE - 20))  # IPv6 头比 IPv4 大 20 字节
      if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
        "$ip6_cmd" -t mangle -A POSTROUTING -o "$iface" -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$ipv6_mss" 2>/dev/null || true
      else
        "$ip6_cmd" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$ipv6_mss" 2>/dev/null || true
      fi

      # IPv6 去重（保留 1 条）
      _nopt_dedup_rules "$ip6_cmd" mangle POSTROUTING 'TCPMSS'

      local ip6_cnt
      ip6_cnt="$("$ip6_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
      ip6_cnt="${ip6_cnt%%$'\n'*}"; ip6_cnt="${ip6_cnt:-0}"
      echo "  ✅ IPv6 MSS=$ipv6_mss ($ip6_cmd), 规则数：$ip6_cnt"
    else
      echo "  ℹ️ ip6tables 不可用，跳过 IPv6 MSS"
    fi
  fi

  # === 最终完整性校验：确认 IPv4 TCPMSS 仍然存在 ===
  local final_v4
  final_v4="$("$ipt_backend" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
  final_v4="${final_v4%%$'\n'*}"; final_v4="${final_v4:-0}"
  if [ "$final_v4" -eq 0 ]; then
    echo "  ⚠️ IPv4 TCPMSS 在 IPv6 处理后消失，重新写入..."
    _nopt_apply_one_tcpmss "$ipt_backend" "$iface" "$MSS_VALUE" || true
    final_v4="$("$ipt_backend" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
    final_v4="${final_v4%%$'\n'*}"; final_v4="${final_v4:-0}"
    [ "$final_v4" -ge 1 ] && echo "  ✅ IPv4 TCPMSS 已恢复" || echo "  ❌ IPv4 TCPMSS 恢复失败"
  fi
}

# === 11. Nginx 安装 + 自动更新 ===
fix_nginx_repo() {
  if [ "${ENABLE_NGINX_REPO:-0}" != "1" ]; then
    echo "⏭️ 跳过 Nginx 管理"
    return 0
  fi

  if [ "${SKIP_APT:-0}" = "1" ]; then
    if have_cmd nginx; then
      local ver cron_file="/etc/cron.d/net-optimize-nginx-update"
      ver="$(nginx -v 2>&1 | awk -F/ '{print $2}')"
      echo "ℹ️ 已检测到 Nginx：$ver（SKIP_APT=1：不改源）"

      if [ ! -f "$cron_file" ]; then
        cat > "$cron_file" <<'CRON'
# Net-Optimize: monthly nginx auto upgrade
0 3 1 * * root DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install --only-upgrade -y nginx > /var/log/nginx-auto-upgrade.log 2>&1
CRON
        chmod 644 "$cron_file"
        echo "✅ 已创建 Nginx 自动更新 cron（每月一次）"
      else
        echo "ℹ️ Nginx 自动更新 cron 已存在"
      fi
    else
      echo "⚠️ 未安装 Nginx 且 SKIP_APT=1：跳过安装/源配置/cron（不影响主流程）"
    fi
    return 0
  fi

  if ! have_cmd apt-get; then
    echo "⚠️ 非 APT 系统：跳过 Nginx 管理"
    return 0
  fi

  . /etc/os-release || true
  local distro="${ID:-}"
  local codename="${VERSION_CODENAME:-stable}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common >/dev/null 2>&1 || true

  local nginx_keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
  local nginx_official_list="/etc/apt/sources.list.d/nginx-official.list"
  local nginx_pin="/etc/apt/preferences.d/99-nginx-official"

  if [ ! -s "$nginx_keyring" ]; then
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
      | gpg --dearmor -o "$nginx_keyring"
    chmod 644 "$nginx_keyring" || true
    echo "✅ 已写入 nginx.org keyring"
  fi

  local base="http://nginx.org/packages"
  if [ "$distro" = "ubuntu" ]; then
    base="$base/ubuntu"
  else
    base="$base/debian"
  fi

  if [ ! -f "$nginx_official_list" ] || ! grep -q "nginx.org/packages" "$nginx_official_list" 2>/dev/null; then
    cat > "$nginx_official_list" <<EOF
deb [signed-by=$nginx_keyring] $base $codename nginx
EOF
    echo "✅ 已配置 nginx.org 官方源：$base $codename"
  else
    echo "ℹ️ nginx.org 官方源已存在"
  fi

  if [ ! -f "$nginx_pin" ] || ! grep -q "origin nginx.org" "$nginx_pin" 2>/dev/null; then
    cat > "$nginx_pin" <<'EOF'
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 1001
EOF
    echo "✅ 已设置 nginx.org Pin=1001（默认优先）"
  else
    echo "ℹ️ nginx.org Pin 已存在"
  fi

  if [ "$distro" = "ubuntu" ]; then
    local has_ondrej=0
    if ls /etc/apt/sources.list.d/*ondrej*nginx* >/dev/null 2>&1; then
      has_ondrej=1
    else
      if grep -R "ppa.launchpadcontent.net/ondrej/nginx" /etc/apt/sources.list.d >/dev/null 2>&1; then
        has_ondrej=1
      fi
    fi

    if [ "$has_ondrej" = "1" ]; then
      echo "ℹ️ 已检测到 ondrej/nginx PPA 源（共存保留）"
    else
      add-apt-repository -y ppa:ondrej/nginx >/dev/null 2>&1 || true
      if grep -R "ppa.launchpadcontent.net/ondrej/nginx" /etc/apt/sources.list.d >/dev/null 2>&1; then
        echo "✅ 已添加 ondrej/nginx PPA 源（共存备胎）"
      else
        echo "⚠️ ondrej/nginx PPA 添加失败：继续（不影响主流程）"
      fi
    fi
  else
    echo "ℹ️ 非 Ubuntu：跳过 ondrej/nginx PPA（仍保留 nginx.org 官方源）"
  fi

  if have_cmd nginx; then
    local ver
    ver="$(nginx -v 2>&1 | awk -F/ '{print $2}')"
    echo "ℹ️ 已检测到 Nginx：$ver（双源共存，默认优先 nginx.org）"
  else
    echo "📦 未检测到 Nginx，开始安装（默认按 Pin 优先 nginx.org）..."
    apt-get update -y
    apt-get install -y nginx || { echo "⚠️ Nginx 安装失败：跳过（不影响主流程）"; return 0; }
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx  >/dev/null 2>&1 || true
    echo "✅ Nginx 安装完成"
  fi

  local cron_file="/etc/cron.d/net-optimize-nginx-update"
  if [ ! -f "$cron_file" ]; then
    cat > "$cron_file" <<'CRON'
# Net-Optimize: monthly nginx auto upgrade
0 3 1 * * root DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install --only-upgrade -y nginx > /var/log/nginx-auto-upgrade.log 2>&1
CRON
    chmod 644 "$cron_file"
    echo "✅ 已创建 Nginx 自动更新 cron（每月一次）"
  else
    echo "ℹ️ Nginx 自动更新 cron 已存在"
  fi

  return 0
}

# === 12. 开机自启服务（MSS + rp_filter 逻辑与主脚本统一）===
install_boot_service() {
  if [ "$APPLY_AT_BOOT" != "1" ]; then
    echo "⏭️ 跳过开机自启配置"
    return 0
  fi

  echo "🛠️ 配置开机自启动服务..."

  cat >"$APPLY_SCRIPT" <<'APPLYEOF'
#!/usr/bin/env bash
# 开机恢复脚本：不使用 set -e，确保所有步骤都能执行到

# 文件锁：防止多实例并发执行
LOCKFILE="/var/run/net-optimize-apply.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "[$(date)] net-optimize-apply: 另一实例正在运行，跳过"
  exit 0
fi

MODULES_FILE="/etc/net-optimize/modules.list"
CONFIG_FILE="/etc/net-optimize/config"

# 配置文件只 source 一次，后续所有块共用已设置的变量
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

if [ -f "$MODULES_FILE" ]; then
  while IFS= read -r module; do
    [ -n "$module" ] && modprobe "$module" 2>/dev/null || true
  done <"$MODULES_FILE"
fi

sysctl -e --system >/dev/null 2>&1 || true

# === 强制覆盖 rp_filter（防止 cloud-init/systemd-networkd 按接口覆盖）===
_RP="${RP_FILTER:-2}"
for _rp_path in /proc/sys/net/ipv4/conf/*/rp_filter; do
  echo "$_RP" > "$_rp_path" 2>/dev/null || true
done

# === conntrack 触发（与主脚本一致：INVALID -> DROP）===
if command -v iptables >/dev/null 2>&1; then
  iptables -t filter -C INPUT  -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
    || iptables -t filter -I INPUT 1 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true

  iptables -t filter -C OUTPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
    || iptables -t filter -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
fi

# 触发 conntrack 计数（让内核开始跟踪）
if command -v curl >/dev/null 2>&1; then
  curl -4I https://1.1.1.1 --max-time 3 >/dev/null 2>&1 || true
  curl -4I https://www.google.com --max-time 3 >/dev/null 2>&1 || true
fi

# === 清理 netfilter-persistent 保存的 mangle 规则（防止与本脚本重复）===
# 不 stop netfilter-persistent，保留 nat 表（端口跳跃等）
if command -v systemctl >/dev/null 2>&1; then
  for _pf in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [ -f "$_pf" ] && grep -q '^\*mangle' "$_pf" 2>/dev/null; then
      sed -i '/^\*mangle$/,/^COMMIT$/d' "$_pf" 2>/dev/null || true
    fi
  done
fi

# === 开机恢复 mangle POSTROUTING 规则（MSS + DSCP）===
# 策略：先 flush 所有后端的 mangle POSTROUTING，再统一写入，彻底避免重复
if [ -f "$CONFIG_FILE" ]; then
  IPT="${IPT_BACKEND:-iptables}"
  command -v "$IPT" >/dev/null 2>&1 || IPT="iptables"
  IFACE="${CLAMP_IFACE:-}"

  IP6_CMD=""
  if [ "$IPT" = "iptables-legacy" ] && command -v ip6tables-legacy >/dev/null 2>&1; then
    IP6_CMD="ip6tables-legacy"
  elif command -v ip6tables >/dev/null 2>&1; then
    IP6_CMD="ip6tables"
  fi

  # --- 第一步：flush 所有后端的 mangle POSTROUTING ---
  modprobe ip_tables 2>/dev/null || true
  modprobe iptable_mangle 2>/dev/null || true
  modprobe ip6_tables 2>/dev/null || true
  modprobe ip6table_mangle 2>/dev/null || true

  # 日志：flush 前规则数
  _pre_cnt="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
  logger -t net-optimize "BOOT: flush前 TCPMSS=$_pre_cnt"

  for _fc in iptables iptables-legacy iptables-nft; do
    command -v "$_fc" >/dev/null 2>&1 && "$_fc" -w 2 -t mangle -F POSTROUTING 2>/dev/null || true
  done
  for _fc in ip6tables ip6tables-legacy ip6tables-nft; do
    command -v "$_fc" >/dev/null 2>&1 && "$_fc" -w 2 -t mangle -F POSTROUTING 2>/dev/null || true
  done

  # 日志：flush 后规则数
  _post_flush="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
  logger -t net-optimize "BOOT: flush后 TCPMSS=$_post_flush"

  # --- 第二步：写入 MSS Clamping ---
  if [ "${ENABLE_MSS_CLAMP:-0}" = "1" ]; then
    MSS="${MSS_VALUE:-1452}"
    IPV6_MSS=$((MSS - 20))

    # IPv4 TCPMSS
    if command -v "$IPT" >/dev/null 2>&1; then
      if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
        "$IPT" -t mangle -A POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
      else
        "$IPT" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
      fi
    fi

    # IPv6 TCPMSS
    if [ -n "$IP6_CMD" ] && command -v "$IP6_CMD" >/dev/null 2>&1; then
      if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
        "$IP6_CMD" -t mangle -A POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$IPV6_MSS" 2>/dev/null || true
      else
        "$IP6_CMD" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$IPV6_MSS" 2>/dev/null || true
      fi
    fi
  fi

  # --- 第三步：写入 DSCP EF（QUIC UDP 443）---
  _dscp_opts="-p udp --dport 443 -j DSCP --set-dscp-class EF"

  if command -v "$IPT" >/dev/null 2>&1; then
    if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
      "$IPT" -t mangle -A POSTROUTING -o "$IFACE" $_dscp_opts 2>/dev/null || true
    else
      "$IPT" -t mangle -A POSTROUTING $_dscp_opts 2>/dev/null || true
    fi
  fi

  if [ -n "$IP6_CMD" ] && command -v "$IP6_CMD" >/dev/null 2>&1; then
    if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
      "$IP6_CMD" -t mangle -A POSTROUTING -o "$IFACE" $_dscp_opts 2>/dev/null || true
    else
      "$IP6_CMD" -t mangle -A POSTROUTING $_dscp_opts 2>/dev/null || true
    fi
  fi

  # 日志：add 后规则数
  _post_add="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
  _post_ef="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -c 'DSCP' || true)"
  logger -t net-optimize "BOOT: add后 TCPMSS=$_post_add DSCP=$_post_ef"
fi
if [ -f "$CONFIG_FILE" ]; then
  _cwnd="${INITCWND:-20}"
  _strip_route_params() {
    echo "$1" | sed -E \
      's/ initcwnd [0-9]+//g;
       s/ initrwnd [0-9]+//g;
       s/ expires [0-9]+sec//g;
       s/ hoplimit [0-9]+//g;
       s/ pref [a-z]+//g'
  }
  _dgw="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
  if [ -n "$_dgw" ]; then
    _dgw_clean="$(_strip_route_params "$_dgw")"
    ip route change $_dgw_clean initcwnd "$_cwnd" initrwnd "$_cwnd" 2>/dev/null || true
  fi
  # IPv6：RA 路由可能在开机后几秒才到达，等待最多 10 秒
  _dgw6=""
  for _wait in 1 2 3 4 5 6 7 8 9 10; do
    _dgw6="$(ip -6 route show default 2>/dev/null | head -n1 || true)"
    [ -n "$_dgw6" ] && break
    sleep 1
  done
  if [ -n "$_dgw6" ]; then
    _dgw6_clean="$(_strip_route_params "$_dgw6")"
    ip -6 route change $_dgw6_clean initcwnd "$_cwnd" initrwnd "$_cwnd" 2>/dev/null || true
  fi
fi

# === 游戏 QoS 恢复（cake / prio 双方案）===
if [ -f "$CONFIG_FILE" ]; then
  _qos_scheme="${GAME_QOS_SCHEME:-none}"
  IFACE="${CLAMP_IFACE:-}"

  if [ "$_qos_scheme" = "cake" ]; then
    modprobe sch_cake 2>/dev/null || true
    if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
      tc qdisc replace dev "$IFACE" root cake bandwidth unlimited diffserv4 nat nowash no-split-gso 2>/dev/null || true
    fi
  elif [ "$_qos_scheme" = "prio" ]; then
    if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
      tc qdisc replace dev "$IFACE" root handle 1: prio bands 3 priomap \
        1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 2>/dev/null || true
      tc qdisc replace dev "$IFACE" parent 1:1 handle 10: fq_codel 2>/dev/null || true
      tc qdisc replace dev "$IFACE" parent 1:2 handle 20: fq_codel 2>/dev/null || true
      tc qdisc replace dev "$IFACE" parent 1:3 handle 30: fq_codel 2>/dev/null || true
      tc filter del dev "$IFACE" parent 1: 2>/dev/null || true
      tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 \
        match ip tos 0xb8 0xfc flowid 1:1 2>/dev/null || true
      tc filter add dev "$IFACE" parent 1: protocol ip prio 2 u32 \
        match ip tos 0x88 0xfc flowid 1:1 2>/dev/null || true
      tc filter add dev "$IFACE" parent 1: protocol ip prio 3 u32 \
        match ip protocol 17 0xff match u16 0x0000 0xff80 at 2 flowid 1:1 2>/dev/null || true
    fi
  fi

  # 恢复游戏 DSCP 标记（AF41 = UDP 小包非 443）
  if [ "$_qos_scheme" != "none" ]; then
    IPT="${IPT_BACKEND:-iptables}"
    command -v "$IPT" >/dev/null 2>&1 || IPT="iptables"

    IP6_CMD=""
    if [ "$IPT" = "iptables-legacy" ] && command -v ip6tables-legacy >/dev/null 2>&1; then
      IP6_CMD="ip6tables-legacy"
    elif command -v ip6tables >/dev/null 2>&1; then
      IP6_CMD="ip6tables"
    fi

    _game_dscp="-p udp ! --dport 443 -m length --length 0:200 -j DSCP --set-dscp-class AF41"

    # --- IPv4 AF41 ---
    if command -v "$IPT" >/dev/null 2>&1; then
      # 清理旧 AF41（所有 IPv4 后端都清）
      for _af41_clean in iptables iptables-nft iptables-legacy; do
        command -v "$_af41_clean" >/dev/null 2>&1 || continue
        _af41_old="$("$_af41_clean" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x22|dscp-class AF41|set-dscp 34' || true)"
        if [ -n "$_af41_old" ]; then
          while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            del="${rule/-A POSTROUTING/-D POSTROUTING}"
            read -r -a parts <<<"$del"
            "$_af41_clean" -t mangle "${parts[@]}" 2>/dev/null || true
          done <<<"$_af41_old"
        fi
      done
      # 写入
      if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
        "$IPT" -t mangle -A POSTROUTING -o "$IFACE" $_game_dscp 2>/dev/null || true
      else
        "$IPT" -t mangle -A POSTROUTING $_game_dscp 2>/dev/null || true
      fi
      # 去重（所有后端检查）
      for _af41_dedup in iptables iptables-nft iptables-legacy; do
        command -v "$_af41_dedup" >/dev/null 2>&1 || continue
        _af41_dd=0
        while :; do
          _af41_cnt="$("$_af41_dedup" -t mangle -S POSTROUTING 2>/dev/null | grep -cE '0x22|dscp-class AF41|set-dscp 34' || true)"
          _af41_cnt="${_af41_cnt%%$'\n'*}"; _af41_cnt="${_af41_cnt:-0}"
          [ "$_af41_cnt" -le 1 ] && break
          _af41_dd=$((_af41_dd + 1)); [ "$_af41_dd" -gt 20 ] && break
          _af41_f="$("$_af41_dedup" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x22|dscp-class AF41|set-dscp 34' | head -n1 || true)"
          [ -z "$_af41_f" ] && break
          _af41_d="${_af41_f/-A POSTROUTING/-D POSTROUTING}"
          read -r -a _af41_p <<<"$_af41_d"
          "$_af41_dedup" -t mangle "${_af41_p[@]}" 2>/dev/null || break
        done
      done
    fi

    # --- IPv6 AF41 ---
    if [ -n "$IP6_CMD" ]; then
      _af41_6_old="$("$IP6_CMD" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x22|dscp-class AF41|set-dscp 34' || true)"
      if [ -n "$_af41_6_old" ]; then
        while IFS= read -r rule; do
          [ -z "$rule" ] && continue
          del="${rule/-A POSTROUTING/-D POSTROUTING}"
          read -r -a parts <<<"$del"
          "$IP6_CMD" -t mangle "${parts[@]}" 2>/dev/null || true
        done <<<"$_af41_6_old"
      fi
      if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
        "$IP6_CMD" -t mangle -A POSTROUTING -o "$IFACE" $_game_dscp 2>/dev/null || true
      else
        "$IP6_CMD" -t mangle -A POSTROUTING $_game_dscp 2>/dev/null || true
      fi
      # 去重
      _af41_6_dd=0
      while :; do
        _af41_6_cnt="$("$IP6_CMD" -t mangle -S POSTROUTING 2>/dev/null | grep -cE '0x22|dscp-class AF41|set-dscp 34' || true)"
        _af41_6_cnt="${_af41_6_cnt%%$'\n'*}"; _af41_6_cnt="${_af41_6_cnt:-0}"
        [ "$_af41_6_cnt" -le 1 ] && break
        _af41_6_dd=$((_af41_6_dd + 1)); [ "$_af41_6_dd" -gt 20 ] && break
        _af41_6_f="$("$IP6_CMD" -t mangle -S POSTROUTING 2>/dev/null | grep -E '0x22|dscp-class AF41|set-dscp 34' | head -n1 || true)"
        [ -z "$_af41_6_f" ] && break
        _af41_6_d="${_af41_6_f/-A POSTROUTING/-D POSTROUTING}"
        read -r -a _af41_6_p <<<"$_af41_6_d"
        "$IP6_CMD" -t mangle "${_af41_6_p[@]}" 2>/dev/null || break
      done
    fi
  fi
fi

# === 最终去重（兜底：清除所有后端中多余的 TCPMSS 和 DSCP 规则）===
if [ -f "$CONFIG_FILE" ]; then
  _dedup_ipt="${IPT_BACKEND:-iptables}"
  command -v "$_dedup_ipt" >/dev/null 2>&1 || _dedup_ipt="iptables"

  _dedup_ip6=""
  if [ "$_dedup_ipt" = "iptables-legacy" ] && command -v ip6tables-legacy >/dev/null 2>&1; then
    _dedup_ip6="ip6tables-legacy"
  elif command -v ip6tables >/dev/null 2>&1; then
    _dedup_ip6="ip6tables"
  fi

  # 对每个后端，TCPMSS/DSCP 各只保留 1 条
  for _dd_pattern in TCPMSS '0x2e|dscp-class EF|set-dscp 46' '0x22|dscp-class AF41|set-dscp 34'; do
    for _dd_cmd in iptables iptables-legacy iptables-nft; do
      command -v "$_dd_cmd" >/dev/null 2>&1 || continue
      _dd_r=0
      while :; do
        _dd_cnt="$("$_dd_cmd" -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -cE "$_dd_pattern" || true)"
        _dd_cnt="${_dd_cnt%%$'\n'*}"; _dd_cnt="${_dd_cnt:-0}"
        [ "$_dd_cnt" -le 1 ] && break
        _dd_r=$((_dd_r + 1)); [ "$_dd_r" -gt 20 ] && break
        _dd_first="$("$_dd_cmd" -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -E "$_dd_pattern" | head -n1 || true)"
        [ -z "$_dd_first" ] && break
        _dd_del="${_dd_first/-A POSTROUTING/-D POSTROUTING}"
        read -r -a _dd_parts <<<"$_dd_del"
        "$_dd_cmd" -w 2 -t mangle "${_dd_parts[@]}" 2>/dev/null || break
      done
    done
    for _dd_cmd in ip6tables ip6tables-legacy ip6tables-nft; do
      command -v "$_dd_cmd" >/dev/null 2>&1 || continue
      _dd_r=0
      while :; do
        _dd_cnt="$("$_dd_cmd" -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -cE "$_dd_pattern" || true)"
        _dd_cnt="${_dd_cnt%%$'\n'*}"; _dd_cnt="${_dd_cnt:-0}"
        [ "$_dd_cnt" -le 1 ] && break
        _dd_r=$((_dd_r + 1)); [ "$_dd_r" -gt 20 ] && break
        _dd_first="$("$_dd_cmd" -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -E "$_dd_pattern" | head -n1 || true)"
        [ -z "$_dd_first" ] && break
        _dd_del="${_dd_first/-A POSTROUTING/-D POSTROUTING}"
        read -r -a _dd_parts <<<"$_dd_del"
        "$_dd_cmd" -w 2 -t mangle "${_dd_parts[@]}" 2>/dev/null || break
      done
    done
  done
fi

# 日志：最终规则数
_final_tcpmss="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
_final_ef="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -cE '0x2e|dscp-class EF|set-dscp 46' || true)"
_final_af41="$(iptables-legacy -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -cE '0x22|dscp-class AF41|set-dscp 34' || true)"
logger -t net-optimize "BOOT: 最终 TCPMSS=$_final_tcpmss EF=$_final_ef AF41=$_final_af41"

echo "[$(date)] Net-Optimize v3.7.0 开机优化完成"
APPLYEOF

  chmod +x "$APPLY_SCRIPT"

  cat > /etc/systemd/system/net-optimize.service <<'EOF'
[Unit]
Description=Net-Optimize Ultimate Boot Optimization
After=network-online.target systemd-sysctl.service cloud-init.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/net-optimize-apply
RemainAfterExit=yes
StandardOutput=journal
TimeoutSec=45

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable net-optimize.service >/dev/null 2>&1

  echo "✅ 开机自启服务配置完成"
}

# === 13. 状态检查 ===
print_status() {
  echo ""
  echo "==================== 优 化 状 态 报 告 ===================="

  printf "📊 基 础 状 态 :\n"
  if [ "${AGGRESSIVE_MODE:-0}" = "1" ]; then
    printf "  ⚡ %-20s : %s\n" "激进模式" "已开启"
  fi
  printf "  %-22s : %s\n" "TCP 拥塞算法" "$(get_sysctl net.ipv4.tcp_congestion_control)"
  printf "  %-22s : %s\n" "默认队列" "$(get_sysctl net.core.default_qdisc)"
  printf "  %-22s : %s\n" "文件句柄限制" "$(ulimit -n)"
  printf "  %-22s : %s bytes\n" "rmem_default" "$(get_sysctl net.core.rmem_default)"
  printf "  %-22s : %s\n" "tcp_window_scaling" "$(get_sysctl net.ipv4.tcp_window_scaling)"
  printf "  %-22s : %s\n" "tcp_sack" "$(get_sysctl net.ipv4.tcp_sack)"
  printf "  %-22s : %s\n" "tcp_notsent_lowat" "$(get_sysctl net.ipv4.tcp_notsent_lowat)"
  echo ""

  printf "🌐 网 络 状 态 :\n"
  printf "  %-22s : %s\n" "IP 转发" "$(get_sysctl net.ipv4.ip_forward)"
  printf "  %-22s : %s\n" "rp_filter" "$(get_sysctl net.ipv4.conf.all.rp_filter)"
  printf "  %-22s : %s\n" "IPv6 禁用" "$(get_sysctl net.ipv6.conf.all.disable_ipv6)"
  printf "  %-22s : %s\n" "TCP ECN" "$(get_sysctl net.ipv4.tcp_ecn)"
  printf "  %-22s : %s\n" "TCP FastOpen" "$(get_sysctl net.ipv4.tcp_fastopen)"
  echo ""

  printf "🔗 连 接 跟 踪 (conntrack):\n"
  if conntrack_available; then
    printf "  ✅ conntrack 可用（模块或内建）\n"
    printf "  %-30s : %s\n" "nf_conntrack_max" "$(get_sysctl net.netfilter.nf_conntrack_max)"
    printf "  %-30s : %s\n" "udp_timeout" "$(get_sysctl net.netfilter.nf_conntrack_udp_timeout)"
    printf "  %-30s : %s\n" "udp_timeout_stream" "$(get_sysctl net.netfilter.nf_conntrack_udp_timeout_stream)"
    printf "  %-30s : %s\n" "tcp_timeout_established" "$(get_sysctl net.netfilter.nf_conntrack_tcp_timeout_established)"

    if have_cmd conntrack; then
      local ct_total
      ct_total="$(conntrack -C 2>/dev/null || echo "N/A")"
      printf "  %-30s : %s\n" "总连接数 (conntrack -C)" "$ct_total"
    fi

    if [ -f /proc/net/nf_conntrack ]; then
      local tcp_c udp_c total_c other_c
      tcp_c="$(grep -c '^tcp' /proc/net/nf_conntrack 2>/dev/null || true)"
      udp_c="$(grep -c '^udp' /proc/net/nf_conntrack 2>/dev/null || true)"
      total_c="$(wc -l /proc/net/nf_conntrack 2>/dev/null | awk '{print $1}' || echo 0)"

      tcp_c="${tcp_c%%$'\n'*}"; tcp_c="${tcp_c:-0}"
      udp_c="${udp_c%%$'\n'*}"; udp_c="${udp_c:-0}"
      total_c="${total_c%%$'\n'*}"; total_c="${total_c:-0}"
      other_c=$(( total_c - tcp_c - udp_c ))
      [ "$other_c" -lt 0 ] && other_c=0

      printf "  /proc 表记录数:\n"
      printf "    TCP entries = %s\n" "$tcp_c"
      printf "    UDP entries = %s\n" "$udp_c"
      printf "    Other       = %s\n" "$other_c"
      printf "    Total       = %s\n" "$total_c"
    else
      printf "  ℹ️ /proc/net/nf_conntrack 不存在（可能是 nft / 内核暴露差异）\n"
    fi

    if have_cmd lsmod; then
      if lsmod | grep -q '^nf_conntrack'; then
        printf "  ✅ lsmod 可见 nf_conntrack（非内建）\n"
      else
        printf "  ℹ️ lsmod 未显示 nf_conntrack（可能是内建，正常）\n"
      fi
    fi
  else
    printf "  ⚠️ conntrack 不可用（内核未启用 netfilter conntrack）\n"
  fi
  echo ""

  printf "🎮 游戏 QoS 状态:\n"
  local _qos_scheme_status="none"
  if [ -f "$CONFIG_FILE" ]; then
    _qos_scheme_status="$(grep '^GAME_QOS_SCHEME=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "none")"
  fi
  if [ "$_qos_scheme_status" = "cake" ]; then
    printf "  ✅ 方案: cake diffserv4（4 档自动分流）\n"
    local _cake_iface
    _cake_iface="$(detect_outbound_iface 2>/dev/null || true)"
    if [ -n "$_cake_iface" ]; then
      tc -s qdisc show dev "$_cake_iface" 2>/dev/null | head -n5 || true
    fi
  elif [ "$_qos_scheme_status" = "prio" ]; then
    printf "  ✅ 方案: prio + fq_codel（3 档手动分流）\n"
    local _prio_iface
    _prio_iface="$(detect_outbound_iface 2>/dev/null || true)"
    if [ -n "$_prio_iface" ]; then
      printf "  tc qdisc:\n"
      tc qdisc show dev "$_prio_iface" 2>/dev/null | head -n8 || true
    fi
  else
    printf "  ℹ️ 未启用（AGGRESSIVE_MODE=1 或 ENABLE_GAME_QOS=0）\n"
  fi

  # 自适应 QoS 状态
  if systemctl is-active "${ADAPTIVE_QOS_SERVICE:-net-optimize-adaptive-qos}" >/dev/null 2>&1; then
    printf "\n🔄 自适应 QoS：运行中\n"
    printf "  → 阈值: $(( ${ADAPTIVE_QOS_THRESHOLD:-1048576} / 1024 )) KB/s  采样: ${ADAPTIVE_QOS_INTERVAL:-2}s\n"
    printf "  → 高流量→pfifo_fast(抢带宽)  低流量→cake/prio(游戏低延迟)\n"
  fi

  # DSCP 规则概览
  local _dscp_v4_cnt=0 _dscp_v6_cnt=0
  for _ds_cmd in iptables iptables-legacy iptables-nft; do
    have_cmd "$_ds_cmd" || continue
    _dscp_v4_cnt="$("$_ds_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'DSCP' || true)"
    _dscp_v4_cnt="${_dscp_v4_cnt%%$'\n'*}"
    [ "${_dscp_v4_cnt:-0}" -gt 0 ] && break
  done
  for _ds6_cmd in ip6tables ip6tables-legacy; do
    have_cmd "$_ds6_cmd" || continue
    _dscp_v6_cnt="$("$_ds6_cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -c 'DSCP' || true)"
    _dscp_v6_cnt="${_dscp_v6_cnt%%$'\n'*}"
    [ "${_dscp_v6_cnt:-0}" -gt 0 ] && break
  done
  printf "  DSCP 规则: IPv4=%s条 IPv6=%s条 (EF=QUIC加速, AF41=游戏小包)\n" \
    "${_dscp_v4_cnt:-0}" "${_dscp_v6_cnt:-0}"
  echo ""

  printf "📡 MSS Clamping 规则:\n"
  local _ps_found=0
  for _ps_cmd in iptables iptables-legacy iptables-nft; do
    have_cmd "$_ps_cmd" || continue
    if "$_ps_cmd" -t mangle -L POSTROUTING -n 2>/dev/null | grep -q TCPMSS; then
      printf "  ✅ 后端: %s\n" "$_ps_cmd"
      "$_ps_cmd" -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -E 'Chain|pkts|bytes|TCPMSS' || true
      _ps_found=1
      break
    fi
  done
  if [ "$_ps_found" -eq 0 ]; then
    printf "  ⚠️ 未找到 MSS 规则（所有后端均未检测到）\n"
  fi
  echo ""

  printf "💻 系 统 信 息 :\n"
  printf "  %-14s : %s\n" "内核版本" "$(uname -r)"
  printf "  %-14s : %s\n" "发行版" "$(detect_distro)"
  printf "  %-14s : %s\n" "内存" "$(free -h | awk '/^Mem:/ {print $2}')"
  printf "  %-14s : %s\n" "可用内存" "$(free -h | awk '/^Mem:/ {print $7}')"

  echo "========================================================="
  echo ""
}

# === 14. 主流程 ===

# 低内存环境保障：总内存 < 2GB 且无 swap 时自动创建 512MB 临时 swap
_ensure_swap() {
  local total_kb swap_kb swap_file="/tmp/.net-optimize-swap"
  total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 4194304)"
  swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 1)"
  [ "$total_kb" -lt 2097152 ] && [ "$swap_kb" -eq 0 ] || return 0
  echo "⚠️ 内存 ${total_kb}KB 且无 swap，自动创建 512MB 临时 swap..."
  if dd if=/dev/zero of="$swap_file" bs=1M count=512 status=none 2>/dev/null \
     && chmod 600 "$swap_file" \
     && mkswap "$swap_file" >/dev/null 2>&1 \
     && swapon "$swap_file" 2>/dev/null; then
    echo "  ✅ 临时 swap 已启用"
    trap 'swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"' EXIT
  else
    rm -f "$swap_file"
    echo "  ℹ️ swap 创建失败，继续运行"
  fi
}

main() {
  require_root
  _ensure_swap

  echo "🚀 Net-Optimize-Ultimate v3.7.1 启动..."
  echo "========================================================"

  clean_old_config
  maybe_install_tools
  setup_ulimit
  setup_tcp_congestion
  write_sysctl_conf
  converge_sysctl_authority
  force_apply_sysctl_runtime
  setup_conntrack
  setup_nic_offload
  setup_rps_rfs
  setup_cpu_governor
  setup_mptcp
  setup_mss_clamping
  setup_dscp_marking
  setup_initcwnd
  setup_aggressive_tc
  setup_game_qos
  setup_adaptive_qos
  fix_nginx_repo
  install_boot_service

  print_status

  echo "✅ 所有优化配置完成！"
  echo ""
  echo "📌 重要提示："
  echo "  1. 缓冲区大小已按内存自动计算，重启后完全生效"
  echo "  2. 检查状态: systemctl status net-optimize"
  echo "  3. 查看连接: cat /proc/net/nf_conntrack | head -20"
  echo "  4. 验证MSS: iptables -t mangle -L -n -v"
  echo "  5. 查看 CPU 调频: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  echo ""

  if [ -t 0 ]; then
    read -r -p "🔄 是否立即重启以生效所有优化？(y/N): " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      echo "🌀 系统将在3秒后重启..."
      sleep 3
      reboot
    else
      echo "📌 请稍后手动重启以应用所有优化"
    fi
  else
    echo "📌 非交互模式，请手动重启以应用优化"
  fi
}

# === 15. 执行 ===
main