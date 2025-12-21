#!/usr/bin/env bash
# ==============================================================================
# 🚀 Net-Optimize-Ultimate v3.2.2 (最终整合版)
# 功能：深度整合优化 + UDP活跃修复 + 智能检测 + 安全持久化
# 关键修复：
#   1) conntrack 检测不依赖 lsmod（兼容内建）
#   2) qdisc 判断用“真实写入尝试”而不是 lsmod
#   3) sysctl 权威收敛：自动扫描 /etc/sysctl.d/*.conf（保留指定文件）
#   4) MSS Clamping 三后端一致：iptables / iptables-nft / iptables-legacy
#   5) 修复你之前遇到的：grep -c 输出 0\n0 + 算术爆炸、MSS 返回码反了、count 写法错误
# ==============================================================================

set -euo pipefail

# === 1. 自动更新机制 ===
SCRIPT_PATH="/usr/local/sbin/net-optimize-ultimate.sh"
REMOTE_URL="https://raw.githubusercontent.com/bgpeer/vps-net-optimize/main/net-optimize-ultimate.sh"

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
    openssl dgst -sha256 | awk '{print $2}'
  else
    echo ""
  fi
}

remote_buf="$(fetch_raw "$REMOTE_URL" || true)"
if [ -n "${remote_buf:-}" ]; then
  remote_hash="$(printf "%s" "$remote_buf" | sha256_of)"
  local_hash="$([ -f "$SCRIPT_PATH" ] && sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo "")"
  if [ -n "$remote_hash" ] && [ "$remote_hash" != "$local_hash" ]; then
    echo "🌀 检测到新版本，正在更新..."
    printf "%s" "$remote_buf" >"$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    exec "$SCRIPT_PATH" "$@"
    exit 0
  fi
fi

# 当你用 bash <(curl ...) 运行时，$0 可能是 /dev/fd/*，这里允许失败
install -Dm755 "$0" "$SCRIPT_PATH" 2>/dev/null || true

trap 'code=$?; echo "❌ 出错：第 ${BASH_LINENO[0]} 行 -> ${BASH_COMMAND} (退出码 $code)"; exit $code' ERR

echo "🚀 Net-Optimize-Ultimate v3.2.2 开始执行..."
echo "========================================================"

# === 2. 全局配置开关 ===
: "${ENABLE_FQ_PIE:=1}"
: "${ENABLE_MTU_PROBE:=1}"
: "${ENABLE_MSS_CLAMP:=1}"
: "${MSS_VALUE:=1452}"
: "${ENABLE_CONNTRACK_TUNE:=1}"
: "${NFCT_MAX:=262144}"
: "${ENABLE_NGINX_REPO:=1}"
: "${SKIP_APT:=1}"
: "${APPLY_AT_BOOT:=1}"

# 路径定义
CONFIG_DIR="/etc/net-optimize"
CONFIG_FILE="$CONFIG_DIR/config"
MODULES_FILE="$CONFIG_DIR/modules.list"
APPLY_SCRIPT="/usr/local/sbin/net-optimize-apply"

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
  if have_cmd dpkg && dpkg --audit 2>/dev/null | grep -q .; then
    echo "⚠️ 检测到 dpkg 状态异常，请先执行修复："
    echo "  dpkg --configure -a"
    echo "  apt-get --fix-broken install -y"
    exit 1
  fi
}

# === v3.2.2：conntrack 可用性检测（不依赖 lsmod）===
conntrack_available() {
  has_sysctl_key net.netfilter.nf_conntrack_max && return 0

  if [ -d /proc/sys/net/netfilter ] && ls /proc/sys/net/netfilter/nf_conntrack* >/dev/null 2>&1; then
    return 0
  fi

  [ -f /proc/net/nf_conntrack ] && return 0
  return 1
}

# === v3.2.2：qdisc 真实可设置探测（不依赖 lsmod）===
try_set_qdisc() {
  local q="$1"
  has_sysctl_key net.core.default_qdisc || return 1
  sysctl -w net.core.default_qdisc="$q" >/dev/null 2>&1
}

# === 3.5 Sysctl 权威收敛（避免多脚本互相覆盖）===
SYSCTL_BACKUP_DIR="/etc/net-optimize/sysctl-backup"
SYSCTL_AUTH_FILE="/etc/sysctl.d/99-net-optimize.conf"

# 你要强制收敛的关键项（按需加减）
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
}

# === 4. 清理旧配置 ===
clean_old_config() {
  echo "🧹 清理旧配置..."

  # 清理旧服务
  systemctl stop net-optimize.service 2>/dev/null || true
  systemctl disable net-optimize.service 2>/dev/null || true
  rm -f /etc/systemd/system/net-optimize.service

  # 清理旧规则（只动当前默认后端的 iptables）
  if have_cmd iptables; then
    iptables -t mangle -S POSTROUTING 2>/dev/null | grep -E '(^-A POSTROUTING .*TCPMSS| TCPMSS )' | while read -r rule; do
      del_rule="${rule/-A POSTROUTING/-D POSTROUTING}"
      # shellcheck disable=SC2086
      iptables -t mangle $del_rule 2>/dev/null || true
    done
  fi

  # 不要 rm -rf 整个目录（否则 sysctl-backup 也会被删）
  mkdir -p "$CONFIG_DIR"
  rm -f "$CONFIG_FILE" "$MODULES_FILE"
}

# === 5. 工具安装（可选）===
maybe_install_tools() {
  if [ "$SKIP_APT" = "1" ]; then
    echo "⏭️ 跳过工具安装（SKIP_APT=1）"
    return 0
  fi

  if ! have_cmd apt-get; then
    echo "ℹ️ 非APT系统，跳过工具安装"
    return 0
  fi

  echo "🧰 安装必要工具..."
  check_dpkg_clean

  DEBIAN_FRONTEND=noninteractive apt-get update -y || echo "⚠️ apt update 失败"

  local packages=""
  packages+=" ca-certificates curl wget gnupg2 lsb-release"
  packages+=" ethtool iproute2 irqbalance chrony"
  packages+=" nftables conntrack iptables"
  packages+=" software-properties-common apt-transport-https"

  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages || echo "⚠️ 部分包安装失败"

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

# === 7. 拥塞控制与队列算法（真实验证版）===
setup_tcp_congestion() {
  echo "📶 设置TCP拥塞算法和队列..."

  # qdisc：真实尝试写入
  if [ "$ENABLE_FQ_PIE" = "1" ] && try_set_qdisc fq_pie; then
    :
  elif try_set_qdisc fq; then
    :
  elif try_set_qdisc pie; then
    :
  else
    :
  fi

  # 拥塞算法：BBRplus > BBR > Cubic
  local target_cc="cubic"
  local available_cc
  available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "cubic")

  if echo "$available_cc" | grep -qw bbrplus; then
    target_cc="bbrplus"
  elif echo "$available_cc" | grep -qw bbr; then
    target_cc="bbr"
  fi

  if has_sysctl_key net.ipv4.tcp_congestion_control; then
    sysctl -w net.ipv4.tcp_congestion_control="$target_cc" >/dev/null 2>&1 || true
  fi

  local current_cc current_qdisc
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")

  echo "✅ 最终生效拥塞算法: $current_cc"
  echo "✅ 最终生效队列算法: $current_qdisc"

  if [[ "$target_cc" == "bbr"* ]] && [[ "$current_cc" != "$target_cc" ]]; then
    echo "⚠️ 提示: 尝试启用 $target_cc 失败，系统自动回退到了 $current_cc"
  fi
}

# === 8. Sysctl 深度整合（写入文件，自适应内核能力）===
write_sysctl_conf() {
  echo "📊 写入内核参数配置文件..."

  local sysctl_file="$SYSCTL_AUTH_FILE"
  install -d /etc/sysctl.d

  # 如果 FINAL_CC / FINAL_QDISC 为空，兜底读取当前 runtime
  local cc qdisc
  cc="${FINAL_CC:-$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)}"
  qdisc="${FINAL_QDISC:-$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq)}"

  {
    echo "# ========================================================="
    echo "# 🚀 Net-Optimize Ultimate - Kernel Parameters"
    echo "# Generated: $(date -u '+%F %T UTC')"
    echo "# ========================================================="
    echo

    echo "# === 拥塞控制 / 队列（自适应写入，避免不同内核不一致）==="
    echo "net.core.default_qdisc = $qdisc"
    echo "net.ipv4.tcp_congestion_control = $cc"
    echo

    echo "# === 基础网络设置 ==="
    echo "net.core.netdev_max_backlog = 250000"
    echo "net.core.somaxconn = 1000000"
    echo "net.ipv4.tcp_max_syn_backlog = 819200"
    echo "net.ipv4.tcp_syncookies = 1"
    echo

    echo "# === 网卡收包预算（你参考那套里有，建议保留）==="
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
    echo "net.ipv4.tcp_low_latency = 1"
    echo "net.ipv4.tcp_orphan_retries = 1"
    echo "net.ipv4.tcp_retries2 = 5"
    echo "net.ipv4.tcp_synack_retries = 1"
    echo "net.ipv4.tcp_rfc1337 = 0"
    echo "net.ipv4.tcp_early_retrans = 3"
    echo "net.ipv4.tcp_fack = 1"
    echo "net.ipv4.tcp_frto = 0"
    echo

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

    echo "# === 路由/转发（按你的需求保留）==="
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv4.conf.all.forwarding = 1"
    echo "net.ipv4.conf.default.forwarding = 1"
    echo "net.ipv4.conf.all.route_localnet = 1"
    echo "net.ipv4.conf.all.rp_filter = 0"
    echo "net.ipv4.conf.default.rp_filter = 0"
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

# === 9. 连接跟踪模块加载 ===
setup_conntrack() {
  if [ "$ENABLE_CONNTRACK_TUNE" != "1" ]; then
    echo "⏭️ 跳过连接跟踪调优"
    return 0
  fi

  echo "🔗 加载连接跟踪模块..."

  local modules=("nf_conntrack" "nf_conntrack_ipv4" "nf_conntrack_ipv6" "nf_conntrack_ftp")
  local loaded_modules=()

  for mod in "${modules[@]}"; do
    if modprobe "$mod" 2>/dev/null; then
      loaded_modules+=("$mod")
      echo "  ✅ 加载: $mod"
    fi
  done

  if [ ${#loaded_modules[@]} -gt 0 ]; then
    install -d /etc/modules-load.d
    printf "%s\n" "${loaded_modules[@]}" | sort -u > /etc/modules-load.d/net-optimize.conf
  fi

  printf "%s\n" "${loaded_modules[@]}" | sort -u >"$MODULES_FILE"
  echo "✅ 连接跟踪模块配置完成"
}

# === 10. MSS Clamping 依赖：出口接口探测 ===
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

# === 10.1 MSS Clamping（强制收敛为1条，避免重复叠加）===
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
EOF

    # 收集可用 iptables 后端（至少保证 iptables 本体）
    local ipt_cmds=()
    for c in iptables iptables-nft iptables-legacy; do
        have_cmd "$c" && ipt_cmds+=("$c")
    done
    [ "${#ipt_cmds[@]}" -eq 0 ] && { echo "⚠️ iptables 不可用，跳过"; return 0; }

    # 统一清理：删掉所有 POSTROUTING 里的 TCPMSS（不管之前怎么加的）
    _clear_all_tcp_mss() {
        local cmd="$1"
        local rules round=0

        echo "🧹 [$cmd] 强制清理所有 TCPMSS 规则..."
        while :; do
            rules="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E 'TCPMSS' || true)"
            [ -z "$rules" ] && break

            round=$((round + 1))
            [ "$round" -gt 80 ] && { echo "  ⚠️ [$cmd] 清理轮次过多，停止"; break; }

            while IFS= read -r rule; do
                [ -z "$rule" ] && continue
                local del="${rule/-A POSTROUTING/-D POSTROUTING}"
                local -a parts
                read -r -a parts <<<"$del"
                "$cmd" -t mangle "${parts[@]}" 2>/dev/null || true
            done <<<"$rules"
        done
    }

    # 统一添加：只添加 1 条
    _apply_one_tcp_mss() {
        local cmd="$1"
        echo "➕ [$cmd] 写入 1 条 TCPMSS 规则..."

        if [ -n "$iface" ] && [ "$iface" != "unknown" ]; then
            "$cmd" -t mangle -A POSTROUTING -o "$iface" -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null && return 0
        else
            "$cmd" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --set-mss "$MSS_VALUE" 2>/dev/null && return 0
        fi

        return 1
    }

    # 1) 各后端先强制清理
    for cmd in "${ipt_cmds[@]}"; do
        _clear_all_tcp_mss "$cmd"
    done

    # 2) 只用 “当前默认 iptables” 写入（避免三后端都写导致你看见重复）
    #    如果你坚持三后端都写，那你检测时就必然会看到多条（因为后端其实共用规则集/或转换显示差异）
    if _apply_one_tcp_mss "iptables"; then
        echo "✅ MSS 规则已写入（iptables）"
    else
        echo "⚠️ 写入失败（iptables），尝试其他后端..."
        local ok=0
        for cmd in "${ipt_cmds[@]}"; do
            [ "$cmd" = "iptables" ] && continue
            if _apply_one_tcp_mss "$cmd"; then ok=1; echo "✅ MSS 规则已写入（$cmd）"; break; fi
        done
        [ "$ok" -eq 1 ] || { echo "❌ MSS 写入失败"; return 1; }
    fi

    # 3) 验证：只允许 1 条
    local cnt
    cnt="$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c 'TCPMSS' || true)"
    cnt="${cnt%%$'\n'*}"; cnt="${cnt:-0}"
    if [ "$cnt" -gt 1 ]; then
        echo "⚠️ 仍检测到重复 TCPMSS：$cnt 条（可能有其他脚本/服务在加）"
    else
        echo "✅ TCPMSS 规则数量：$cnt"
    fi

    echo "✅ MSS Clamping 设置完成"
}

# === 11. Nginx 安装 + 自动更新（工程幂等版）===
fix_nginx_repo() {
    if [ "$ENABLE_NGINX_REPO" != "1" ]; then
        echo "⏭️ 跳过 Nginx 管理"
        return 0
    fi

    # 1. 永远保证：自动更新 cron 存在
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

    # 2. 检测 nginx 是否已安装
    if have_cmd nginx; then
        local ver
        ver="$(nginx -v 2>&1 | awk -F/ '{print $2}')"
        echo "ℹ️ 已检测到 Nginx：$ver（保留现有来源）"
        return 0
    fi

    # 3. nginx 未安装 → 是否允许 APT？
    if [ "$SKIP_APT" = "1" ]; then
        echo "❌ 系统未安装 Nginx，但 SKIP_APT=1"
        echo "👉 请使用以下方式之一："
        echo "   1) SKIP_APT=0 bash net-optimize-ultimate.sh"
        echo "   2) 手动安装 nginx 后重新运行脚本"
        return 1
    fi

    # 4. 安装 nginx（最新版，来源自适应）
    if ! have_cmd apt-get; then
        echo "❌ 非 APT 系统，无法自动安装 nginx"
        return 1
    fi

    echo "📦 未检测到 Nginx，开始安装最新版..."

    # ---- 发行版信息 ----
    . /etc/os-release
    local distro="$ID"
    local codename="${VERSION_CODENAME:-stable}"

    # ---- nginx.org 官方源 ----
    local base="http://nginx.org/packages"
    [ "$distro" = "ubuntu" ] && base="$base/ubuntu" || base="$base/debian"

    echo "📌 使用官方源：$base $codename"

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/nginx-official.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] $base $codename nginx
EOF

    cat > /etc/apt/preferences.d/99-nginx-official <<'EOF'
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 1001
EOF

    apt-get update -y
    apt-get install -y nginx

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx >/dev/null 2>&1 || true

    echo "✅ Nginx 最新版安装完成"
}

# === 12. 开机自启服务（同步三后端 MSS 写入）===
install_boot_service() {
  if [ "$APPLY_AT_BOOT" != "1" ]; then
    echo "⏭️ 跳过开机自启配置"
    return 0
  fi

  echo "🛠️ 配置开机自启动服务..."

  cat >"$APPLY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODULES_FILE="/etc/net-optimize/modules.list"
if [ -f "$MODULES_FILE" ]; then
  while IFS= read -r module; do
    [ -n "$module" ] && modprobe "$module" 2>/dev/null || true
  done <"$MODULES_FILE"
fi

sysctl -e --system >/dev/null 2>&1 || true

CONFIG_FILE="/etc/net-optimize/config"
if [ -f "$CONFIG_FILE" ]; then
  . "$CONFIG_FILE"

  if [ "${ENABLE_MSS_CLAMP:-0}" = "1" ]; then
    MSS="${MSS_VALUE:-1452}"
    IFACE="${CLAMP_IFACE:-}"

    # 三后端一致：iptables / iptables-nft / iptables-legacy
    ipt_cmds=()
    for c in iptables iptables-nft iptables-legacy; do
      command -v "$c" >/dev/null 2>&1 && ipt_cmds+=("$c")
    done

    if [ "${#ipt_cmds[@]}" -gt 0 ]; then
      modprobe ip_tables 2>/dev/null || true
      modprobe iptable_mangle 2>/dev/null || true

      for cmd in "${ipt_cmds[@]}"; do
        # 清理旧 TCPMSS
        rules="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E '(^-A POSTROUTING .*TCPMSS| TCPMSS )' || true)"
        if [ -n "$rules" ]; then
          while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            del="${rule/-A POSTROUTING/-D POSTROUTING}"
            read -r -a parts <<<"$del"
            "$cmd" -t mangle "${parts[@]}" 2>/dev/null || true
          done <<<"$rules"
        fi

        # 写入新规则（避免重复）
        if [ -n "$IFACE" ] && [ "$IFACE" != "unknown" ]; then
          "$cmd" -t mangle -C POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null \
            || "$cmd" -t mangle -A POSTROUTING -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
        else
          "$cmd" -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null \
            || "$cmd" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
        fi
      done
    fi
  fi
fi

echo "[$(date)] Net-Optimize 开机优化完成"
EOF

  chmod +x "$APPLY_SCRIPT"

  cat > /etc/systemd/system/net-optimize.service <<'EOF'
[Unit]
Description=Net-Optimize Ultimate Boot Optimization
After=network-online.target
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

# === 13. 状态检查（完整）===
print_status() {
  echo ""
  echo "==================== 优化状态报告 ===================="

  echo "📊 基础状态:"
  echo "  TCP拥塞算法: $(get_sysctl net.ipv4.tcp_congestion_control)"
  echo "  默认队列: $(get_sysctl net.core.default_qdisc)"
  echo "  文件句柄限制: $(ulimit -n)"
  echo "  内存缓冲区: $(get_sysctl net.core.rmem_default) bytes"
  echo ""

  echo "🌐 网络状态:"
  echo "  IP转发: $(get_sysctl net.ipv4.ip_forward)"
  echo "  路由过滤: $(get_sysctl net.ipv4.conf.all.rp_filter)"
  echo "  IPv6状态: $(get_sysctl net.ipv6.conf.all.disable_ipv6)"
  echo "  TCP ECN: $(get_sysctl net.ipv4.tcp_ecn)"
  echo "  TCP FastOpen: $(get_sysctl net.ipv4.tcp_fastopen)"
  echo ""

  echo "🔗 连接跟踪:"
  if conntrack_available; then
    echo "  ✅ conntrack 可用（模块或内建）"
    echo "  最大连接数: $(get_sysctl net.netfilter.nf_conntrack_max)"

    if [ -f /proc/net/nf_conntrack ]; then
      udp_count="$(grep -c '^udp' /proc/net/nf_conntrack 2>/dev/null || true)"
      tcp_count="$(grep -c '^tcp' /proc/net/nf_conntrack 2>/dev/null || true)"

      udp_count="${udp_count%%$'\n'*}"; udp_count="${udp_count:-0}"
      tcp_count="${tcp_count%%$'\n'*}"; tcp_count="${tcp_count:-0}"

      echo "  UDP连接: $udp_count"
      echo "  TCP连接: $tcp_count"
      echo "  总连接数: $((udp_count + tcp_count))"
    else
      echo "  ℹ️ /proc/net/nf_conntrack 不存在（可能是 nftables / 内核暴露差异）"
    fi
  else
    echo "  ⚠️ conntrack 不可用（内核未启用 netfilter conntrack）"
  fi
  echo ""

  echo "📡 MSS Clamping规则（默认后端 iptables）:"
  if have_cmd iptables && iptables -t mangle -L POSTROUTING -n 2>/dev/null | grep -q TCPMSS; then
    iptables -t mangle -L POSTROUTING -n -v 2>/dev/null | grep TCPMSS || true
  else
    echo "  ⚠️ 未找到MSS规则（可能当前默认后端不是 iptables；用 iptables-nft/legacy 看）"
  fi
  echo ""

  echo "💻 系统信息:"
  echo "  内核版本: $(uname -r)"
  echo "  发行版: $(detect_distro)"
  echo "  内存: $(free -h | awk '/^Mem:/ {print $2}')"
  echo "  可用内存: $(free -h | awk '/^Mem:/ {print $7}')"

  echo "======================================================"
  echo ""
}

# === 14. 主流程 ===
main() {
  require_root

  echo "🚀 Net-Optimize-Ultimate v3.2.2 启动..."
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
  echo "  4. 验证MSS: iptables -t mangle -L -n -v / iptables-nft ... / iptables-legacy ..."
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