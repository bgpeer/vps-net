#!/usr/bin/env bash
# ==============================================================================
# 🚀 Net-Optimize-Ultimate v3.4.0
# 功能：深度整合优化 + UDP活跃修复 + 智能检测 + 安全持久化
# 基于 v3.3.0 修复：
#   1) check_dpkg_clean 增强：先修→修不好再移除→清理后继续
#   2) force_apply_sysctl_runtime 增强：逐接口强制覆盖 rp_filter（防云厂商覆盖）
#   3) apply 开机脚本同步 rp_filter 逐接口覆盖逻辑
#   4) config 持久化 RP_FILTER 值供 apply 脚本读取
# 历史修复（v3.3.0）：
#   1) 自动更新增加 SHA256SUMS 签名校验
#   2) openssl sha256 解析兼容（$NF 兜底）
#   3) apply 脚本与主脚本 MSS 逻辑统一（只用默认 iptables 写 1 条）
#   4) conntrack 触发规则统一（apply + 主脚本一致：INVALID DROP）
#   5) 清理 BBR 下无效的旧参数（tcp_low_latency / tcp_fack / tcp_frto）
#   6) rp_filter 改为可配置（默认 2 松散模式）
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

echo "🚀 Net-Optimize-Ultimate v3.4.0 开始执行..."
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

  # 第二轮：提取卡住的包名，逐个强制移除
  echo "⚠️ 常规修复失败，强制移除无法修复的包..."
  local pkg
  dpkg -l 2>/dev/null | awk '/^[hiuFH]/{print $2}' | while read -r pkg; do
    [ -z "$pkg" ] && continue
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
    [[ -n "${want[$k]:-}" ]] && sysctl -w "$k=${want[$k]}" >/dev/null 2>&1 || true
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
    if timeout 2s iptables -w 2 -t mangle -S POSTROUTING 2>/dev/null | grep -q TCPMSS; then
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

  if have_cmd iptables; then
    timeout 3s iptables -w 2 -t mangle -S POSTROUTING 2>/dev/null \
      | grep -E '(^-A POSTROUTING .*TCPMSS| TCPMSS )' \
      | while read -r rule; do
          del_rule="${rule/-A POSTROUTING/-D POSTROUTING}"
          iptables -w 2 -t mangle $del_rule 2>/dev/null || true
        done || true
  fi

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

  if [ "$ENABLE_FQ_PIE" = "1" ] && try_set_qdisc fq_pie; then
    FINAL_QDISC="fq_pie"
  elif try_set_qdisc fq; then
    FINAL_QDISC="fq"
  elif try_set_qdisc pie; then
    FINAL_QDISC="pie"
  else
    FINAL_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  fi

  local target_cc="cubic"
  local available_cc
  available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo cubic)"

  if echo "$available_cc" | grep -qw bbrplus; then
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

  local cc qdisc
  cc="${FINAL_CC:-$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)}"
  qdisc="${FINAL_QDISC:-$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq)}"

  {
    echo "# ========================================================="
    echo "# 🚀 Net-Optimize Ultimate v3.4.0 - Kernel Parameters"
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
    echo "net.ipv4.tcp_max_tw_buckets = 5000"
    echo "net.ipv4.ip_local_port_range = 1024 65535"
    echo

    echo "# === TCP算法优化 ==="
    echo "net.ipv4.tcp_mtu_probing = $ENABLE_MTU_PROBE"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_no_metrics_save = 0"
    echo "net.ipv4.tcp_ecn = 1"
    echo "net.ipv4.tcp_ecn_fallback = 1"
    echo "net.ipv4.tcp_notsent_lowat = 16384"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_timestamps = 1"
    echo "net.ipv4.tcp_autocorking = 0"
    echo "net.ipv4.tcp_orphan_retries = 1"
    echo "net.ipv4.tcp_retries2 = 5"
    echo "net.ipv4.tcp_synack_retries = 1"
    echo "net.ipv4.tcp_rfc1337 = 0"
    echo "net.ipv4.tcp_early_retrans = 3"
    echo
    # 注：tcp_low_latency 在 4.14+ 已移除；tcp_fack / tcp_frto 在 BBR 下无实际作用
    # 不再写入，避免 sysctl -e 报 unknown key 警告

    echo "# === 内存缓冲区优化（64MB方案）==="
    echo "net.core.rmem_max = 67108864"
    echo "net.core.wmem_max = 67108864"
    echo "net.core.rmem_default = 67108864"
    echo "net.core.wmem_default = 67108864"
    echo "net.core.optmem_max = 65536"
    echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
    echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
    echo "net.ipv4.udp_rmem_min = 16384"
    echo "net.ipv4.udp_wmem_min = 16384"
    echo "net.ipv4.udp_mem = 65536 131072 262144"
    echo

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
    echo "vm.overcommit_memory = 1"
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

setup_mss_clamping() {
  if [ "${ENABLE_MSS_CLAMP:-0}" != "1" ]; then
    echo "⏭️ 跳过MSS Clamping"
    return 0
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

  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
ENABLE_MSS_CLAMP=1
CLAMP_IFACE=$iface
MSS_VALUE=$MSS_VALUE
RP_FILTER=$RP_FILTER
EOF

  # 收集可用后端
  local ipt_cmds=()
  for c in iptables iptables-nft iptables-legacy; do
    have_cmd "$c" && ipt_cmds+=("$c")
  done
  [ "${#ipt_cmds[@]}" -eq 0 ] && { echo "⚠️ iptables 不可用，跳过"; return 0; }

  # 1) 所有后端先强制清理
  for cmd in "${ipt_cmds[@]}"; do
    _nopt_clear_all_tcpmss "$cmd"
  done

  # 2) 只用默认 iptables 写 1 条（和 apply 脚本统一）
  if _nopt_apply_one_tcpmss "iptables" "$iface" "$MSS_VALUE"; then
    echo "✅ MSS 规则已写入（iptables）"
  else
    echo "⚠️ 写入失败（iptables），尝试其他后端..."
    local ok=0
    for cmd in "${ipt_cmds[@]}"; do
      [ "$cmd" = "iptables" ] && continue
      if _nopt_apply_one_tcpmss "$cmd" "$iface" "$MSS_VALUE"; then
        ok=1; echo "✅ MSS 规则已写入（$cmd）"; break
      fi
    done
    [ "$ok" -eq 1 ] || { echo "❌ MSS 写入失败"; return 1; }
  fi

  # 3) 验证 + 自动去重（保留最后 1 条，删除多余）
  local cnt dedup_round=0
  while :; do
    cnt="$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
    cnt="${cnt%%$'\n'*}"; cnt="${cnt:-0}"
    [ "$cnt" -le 1 ] && break

    dedup_round=$((dedup_round + 1))
    [ "$dedup_round" -gt 20 ] && { echo "⚠️ TCPMSS 去重超限，跳过"; break; }

    # 删除第一条匹配的 TCPMSS 规则（保留最后写入的那条）
    local first_rule
    first_rule="$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep 'TCPMSS' | head -n1 || true)"
    [ -z "$first_rule" ] && break
    local del_rule="${first_rule/-A POSTROUTING/-D POSTROUTING}"
    local -a del_parts
    read -r -a del_parts <<<"$del_rule"
    iptables -t mangle "${del_parts[@]}" 2>/dev/null || break
  done

  if [ "$cnt" -eq 1 ]; then
    echo "✅ TCPMSS 规则数量：1（正常）"
  elif [ "$cnt" -eq 0 ]; then
    echo "⚠️ TCPMSS 规则数量：0（写入可能失败）"
  else
    echo "⚠️ TCPMSS 规则数量：$cnt（仍有重复，可能有其他服务在加）"
  fi

  echo "✅ MSS Clamping 设置完成"
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
set -euo pipefail

MODULES_FILE="/etc/net-optimize/modules.list"
if [ -f "$MODULES_FILE" ]; then
  while IFS= read -r module; do
    [ -n "$module" ] && modprobe "$module" 2>/dev/null || true
  done <"$MODULES_FILE"
fi

sysctl -e --system >/dev/null 2>&1 || true

# === 强制覆盖 rp_filter（防止 cloud-init/systemd-networkd 按接口覆盖）===
CONFIG_FILE="/etc/net-optimize/config"
if [ -f "$CONFIG_FILE" ]; then
  . "$CONFIG_FILE"
fi
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

# === MSS Clamping（与主脚本统一：只用默认 iptables 写 1 条）===
if [ -f "$CONFIG_FILE" ]; then
  . "$CONFIG_FILE"

  if [ "${ENABLE_MSS_CLAMP:-0}" = "1" ]; then
    MSS="${MSS_VALUE:-1452}"
    IFACE="${CLAMP_IFACE:-}"

    if command -v iptables >/dev/null 2>&1; then
      modprobe ip_tables 2>/dev/null || true
      modprobe iptable_mangle 2>/dev/null || true

      # 清理所有旧 TCPMSS（所有后端）
      for cmd in iptables iptables-nft iptables-legacy; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        while :; do
          rules="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E 'TCPMSS' || true)"
          [ -z "$rules" ] && break
          while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            del="${rule/-A POSTROUTING/-D POSTROUTING}"
            read -r -a parts <<<"$del"
            "$cmd" -t mangle "${parts[@]}" 2>/dev/null || true
          done <<<"$rules"
        done
      done

      # 只用默认 iptables 写 1 条（与主脚本一致）
      if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
        iptables -t mangle -A POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
      else
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
          -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
      fi

      # 自动去重（保留最后 1 条，删除多余）
      local _dedup_cnt _dedup_r=0
      while :; do
        _dedup_cnt="$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
        _dedup_cnt="${_dedup_cnt%%$'\n'*}"; _dedup_cnt="${_dedup_cnt:-0}"
        [ "$_dedup_cnt" -le 1 ] && break
        _dedup_r=$((_dedup_r + 1))
        [ "$_dedup_r" -gt 20 ] && break
        local _first
        _first="$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep 'TCPMSS' | head -n1 || true)"
        [ -z "$_first" ] && break
        local _del="${_first/-A POSTROUTING/-D POSTROUTING}"
        read -r -a _parts <<<"$_del"
        iptables -t mangle "${_parts[@]}" 2>/dev/null || break
      done
    fi
  fi
fi

echo "[$(date)] Net-Optimize v3.4.0 开机优化完成"
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
TimeoutSec=30

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
  printf "  %-22s : %s\n" "TCP 拥塞算法" "$(get_sysctl net.ipv4.tcp_congestion_control)"
  printf "  %-22s : %s\n" "默认队列" "$(get_sysctl net.core.default_qdisc)"
  printf "  %-22s : %s\n" "文件句柄限制" "$(ulimit -n)"
  printf "  %-22s : %s bytes\n" "rmem_default" "$(get_sysctl net.core.rmem_default)"
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

  printf "📡 MSS Clamping 规则（默认后端 iptables）:\n"
  if have_cmd iptables && iptables -t mangle -L POSTROUTING -n 2>/dev/null | grep -q TCPMSS; then
    iptables -t mangle -L POSTROUTING -n -v 2>/dev/null | grep -E 'Chain|pkts|bytes|TCPMSS' || true
  else
    printf "  ⚠️ 未找到 MSS 规则（可用 iptables-nft/iptables-legacy 再看）\n"
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
main() {
  require_root

  echo "🚀 Net-Optimize-Ultimate v3.4.0 启动..."
  echo "========================================================"

  clean_old_config
  maybe_install_tools
  setup_ulimit
  setup_tcp_congestion
  write_sysctl_conf
  converge_sysctl_authority
  force_apply_sysctl_runtime
  setup_conntrack
  setup_mss_clamping
  fix_nginx_repo
  install_boot_service

  print_status

  echo "✅ 所有优化配置完成！"
  echo ""
  echo "📌 重要提示："
  echo "  1. 64MB缓冲区需要重启后完全生效"
  echo "  2. 检查状态: systemctl status net-optimize"
  echo "  3. 查看连接: cat /proc/net/nf_conntrack | head -20"
  echo "  4. 验证MSS: iptables -t mangle -L -n -v"
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