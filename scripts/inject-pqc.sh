#!/usr/bin/env bash
# inject-pqc.sh
# 向 Mihomo 主配置注入 support-x25519mlkem768: true
#
# 用法:
#   bash inject-pqc.sh                          # 自动检测常见路径
#   bash inject-pqc.sh /path/to/config.yaml     # 指定路径

set -euo pipefail

KEY="support-x25519mlkem768"

# ── 常见 Mihomo/Clash 配置路径（按优先级）──────────────────────────────────
COMMON_PATHS=(
  "$HOME/.config/mihomo/config.yaml"
  "$HOME/.config/clash/config.yaml"
  "$HOME/.config/clash.meta/config.yaml"
  "/etc/mihomo/config.yaml"
  "/etc/clash/config.yaml"
)

find_config() {
  for p in "${COMMON_PATHS[@]}"; do
    [ -f "$p" ] && echo "$p" && return 0
  done
  return 1
}

# ── 确定配置路径 ────────────────────────────────────────────────────────────
if [ "${1:-}" != "" ]; then
  CONFIG="$1"
else
  if ! CONFIG="$(find_config)"; then
    echo "❌ 未找到 Mihomo 配置文件，请手动指定路径："
    echo "   bash $0 /path/to/config.yaml"
    exit 1
  fi
fi

[ -f "$CONFIG" ] || { echo "❌ 文件不存在: $CONFIG"; exit 1; }

echo "📄 目标配置: $CONFIG"

# ── 检查是否已存在 ───────────────────────────────────────────────────────────
if grep -qE "^${KEY}\s*:" "$CONFIG"; then
  current="$(grep -E "^${KEY}\s*:" "$CONFIG")"
  echo "⚠️  已存在（无需修改）: $current"
  exit 0
fi

# ── 备份 ────────────────────────────────────────────────────────────────────
BAK="${CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$BAK"
echo "💾 已备份到: $BAK"

# ── 注入 ────────────────────────────────────────────────────────────────────
# 策略：插入到文件顶部第一个全局 key 区域末尾。
# 具体做法：找到第一个以 "proxies:" / "proxy-groups:" / "rules:" 开头的行，
# 在其前一行插入；若找不到则追加到第一行之后。
if grep -qE "^(proxies|proxy-groups|proxy-providers|rules|rule-providers):" "$CONFIG"; then
  # 在第一个顶层块之前插入
  first_block="$(grep -nE "^(proxies|proxy-groups|proxy-providers|rules|rule-providers):" "$CONFIG" | head -1 | cut -d: -f1)"
  insert_line=$((first_block - 1))
  if [ "$insert_line" -lt 1 ]; then
    insert_line=1
  fi
  sed -i "${insert_line}a ${KEY}: true" "$CONFIG"
else
  # fallback：加到第一行后
  sed -i "1a ${KEY}: true" "$CONFIG"
fi

# ── 验证 ────────────────────────────────────────────────────────────────────
if grep -qE "^${KEY}\s*:" "$CONFIG"; then
  echo "✅ 注入成功："
  grep -E "^${KEY}\s*:" "$CONFIG"
  echo ""
  echo "ℹ️  重启 Mihomo 后生效（systemctl restart mihomo 或重启客户端 App）"
else
  echo "❌ 注入失败，请手动在配置文件顶部添加："
  echo "   ${KEY}: true"
  exit 1
fi
