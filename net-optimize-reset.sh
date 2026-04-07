#!/usr/bin/env bash
# ==============================================================================
# 🧹 Net-Optimize 完整卸载/重置脚本
# 配合 net-optimize-ultimate.sh v3.5.0 使用
# 清除所有优化配置，恢复系统默认状态
# ==============================================================================
set -euo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "❌ 请使用 root 用户运行"; exit 1; }

echo "🧹 开始清除所有 Net-Optimize 配置..."
echo "============================================================"

# === 1. 停止并删除 systemd 服务 ===
echo "🔧 [1] 清理 systemd 服务..."
systemctl stop net-optimize.service 2>/dev/null || true
systemctl disable net-optimize.service 2>/dev/null || true
rm -f /etc/systemd/system/net-optimize.service
rm -f /usr/local/sbin/net-optimize-apply
systemctl daemon-reload 2>/dev/null || true
echo "  ✅ 已移除 net-optimize.service"

# === 2. 清理 iptables / ip6tables 规则（TCPMSS + DSCP，所有后端）===
echo "🔧 [2] 清理 iptables 规则（TCPMSS + DSCP）..."
for cmd in iptables iptables-legacy iptables-nft ip6tables ip6tables-legacy ip6tables-nft; do
  command -v "$cmd" >/dev/null 2>&1 || continue
  local_rules="$("$cmd" -t mangle -S POSTROUTING 2>/dev/null | grep -E 'TCPMSS|DSCP' || true)"
  [ -z "$local_rules" ] && continue
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    del="${rule/-A POSTROUTING/-D POSTROUTING}"
    read -r -a parts <<<"$del"
    "$cmd" -t mangle "${parts[@]}" 2>/dev/null || true
  done <<<"$local_rules"
  echo "  ✅ 已清理 $cmd TCPMSS/DSCP 规则"
done

# 也清理 conntrack INVALID DROP 规则
for cmd in iptables iptables-legacy; do
  command -v "$cmd" >/dev/null 2>&1 || continue
  "$cmd" -t filter -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
  "$cmd" -t filter -D OUTPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
done
echo "  ✅ 已清理 conntrack INVALID DROP 规则"

# === 3. 清理 sysctl 配置 ===
echo "🔧 [3] 清理 sysctl 配置..."
rm -f /etc/sysctl.d/99-net-optimize.conf
rm -f /etc/sysctl.d/zzz-net-optimize-override.conf
echo "  ✅ 已删除 sysctl 配置文件"

# 恢复被禁用的冲突文件
shopt -s nullglob
for f in /etc/sysctl.d/*.disabled-by-net-optimize-*; do
  orig="${f%.disabled-by-net-optimize-*}.conf"
  # 如果原文件不存在才恢复，避免覆盖
  if [ ! -f "$orig" ]; then
    mv "$f" "$orig"
    echo "  ✅ 已恢复: $orig"
  else
    rm -f "$f"
    echo "  🗑 已删除残留: $f"
  fi
done
shopt -u nullglob

# 恢复 /etc/sysctl.conf 中被注释掉的行
if [ -f /etc/sysctl.conf ]; then
  sed -i 's/^# net-optimize disabled: //' /etc/sysctl.conf 2>/dev/null || true
  echo "  ✅ 已恢复 /etc/sysctl.conf 中被注释的行"
fi

# 重新加载 sysctl（恢复系统默认）
sysctl --system >/dev/null 2>&1 || true
echo "  ✅ sysctl 已重新加载"

# === 4. 清理 ulimit / limits.d ===
echo "🔧 [4] 清理 ulimit 配置..."
rm -f /etc/security/limits.d/99-net-optimize.conf
# 清理 systemd DefaultLimitNOFILE
sed -i '/^DefaultLimitNOFILE/d' /etc/systemd/system.conf 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
echo "  ✅ 已清理 ulimit 配置"

# === 5. 清理 conntrack 模块加载 ===
echo "🔧 [5] 清理 conntrack 配置..."
rm -f /etc/modules-load.d/conntrack.conf
echo "  ✅ 已删除 conntrack 模块开机加载配置"

# === 6. 清理 NIC offload / RPS/RFS 持久化 ===
echo "🔧 [6] 清理网卡持久化配置..."
rm -f /etc/udev/rules.d/99-net-optimize-offload.rules
rm -f /etc/tmpfiles.d/net-optimize-rps.conf
echo "  ✅ 已删除 offload/RPS/RFS 持久化规则"

# === 7. 清理 initcwnd 路由参数 ===
echo "🔧 [7] 清理 initcwnd 路由参数..."
_strip_route_params() {
  echo "$1" | sed -E \
    's/ initcwnd [0-9]+//g;
     s/ initrwnd [0-9]+//g;
     s/ expires [0-9]+sec//g;
     s/ hoplimit [0-9]+//g;
     s/ pref [a-z]+//g'
}

# IPv4
dgw="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
if [ -n "$dgw" ] && echo "$dgw" | grep -q 'initcwnd'; then
  clean="$(_strip_route_params "$dgw")"
  ip route change $clean 2>/dev/null || true
  echo "  ✅ 已清除 IPv4 initcwnd"
fi

# IPv6
dgw6="$(ip -6 route show default 2>/dev/null | head -n1 || true)"
if [ -n "$dgw6" ] && echo "$dgw6" | grep -q 'initcwnd'; then
  clean6="$(_strip_route_params "$dgw6")"
  ip -6 route change $clean6 2>/dev/null || true
  echo "  ✅ 已清除 IPv6 initcwnd"
fi

# === 8. 清理 Nginx 自动更新 cron ===
echo "🔧 [8] 清理 Nginx 自动更新 cron..."
rm -f /etc/cron.d/net-optimize-nginx-update
echo "  ✅ 已删除 Nginx 自动更新 cron"

# === 9. 删除配置目录和主脚本 ===
echo "🔧 [9] 删除脚本和配置..."
rm -rf /etc/net-optimize
rm -f /usr/local/sbin/net-optimize-ultimate.sh
# 备份目录
rm -rf /etc/net-optimize-backup
echo "  ✅ 已删除 /etc/net-optimize 和主脚本"

# === 10. 清理 sysctl 备份目录 ===
echo "🔧 [10] 清理备份..."
rm -rf /etc/net-optimize-backup 2>/dev/null || true
echo "  ✅ 已清理备份目录"

echo ""
echo "============================================================"
echo "🎉 所有 Net-Optimize 配置已清除，系统已恢复默认状态"
echo ""
echo "📌 建议重启以完全生效："
echo "    reboot"
echo ""
echo "📌 重启后可以验证："
echo "    sysctl net.core.default_qdisc"
echo "    sysctl net.ipv4.tcp_congestion_control"
echo "    iptables-legacy -t mangle -L -n -v"
echo "    systemctl status net-optimize.service"
echo "============================================================"
