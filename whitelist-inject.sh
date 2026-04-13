#!/bin/bash
# whitelist-inject.sh v1.0
# 在 v2ray-agent sing-box 屏蔽中国域名规则前注入白名单放行规则
# 用法: bash whitelist-inject.sh

CONFIG="/etc/v2ray-agent/sing-box/conf/config.json"
BACKUP="${CONFIG}.bak.$(date +%s)"

# ===== 白名单规则集（按需增减，对应 .srs 文件名）=====
WHITELIST_TAGS=(
  "wechat"
  "douyin"
  "bilibili"
  "zhihu"
  "xiaohongshu"
  "baidu"
  "alibabacloud"
  "tencent"
)

# 规则集 URL 前缀（可换成 gh.669588.xyz 代理）
URL_PREFIX="https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite"

# ================================================================

set -e

if [[ ! -f "$CONFIG" ]]; then
  echo "[错误] 配置文件不存在: $CONFIG"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "[信息] 安装 jq..."
  apt-get update -qq && apt-get install -y -qq jq
fi

# 备份
cp "$CONFIG" "$BACKUP"
echo "[信息] 已备份到 $BACKUP"

# 先清除之前注入的白名单规则（幂等，可重复执行）
CLEAN=$(jq '
  .route.rule_set = [.route.rule_set[] | select(.tag | startswith("whitelist-") | not)] |
  .route.rules = [.route.rules[] | select(
    if .rule_set then
      (.rule_set | if type == "array" then any(startswith("whitelist-")) else startswith("whitelist-") end) | not
    else true end
  )]
' "$CONFIG")

echo "$CLEAN" > "$CONFIG"

# 构建 rule_set 条目 JSON
RULE_SET_JSON="[]"
for tag in "${WHITELIST_TAGS[@]}"; do
  RULE_SET_JSON=$(echo "$RULE_SET_JSON" | jq \
    --arg tag "whitelist-${tag}" \
    --arg url "${URL_PREFIX}/${tag}.srs" \
    '. + [{
      "type": "remote",
      "tag": $tag,
      "format": "binary",
      "url": $url,
      "download_detour": "01_direct_outbound"
    }]')
done

# 构建 rule_set 引用数组
REFS_JSON="[]"
for tag in "${WHITELIST_TAGS[@]}"; do
  REFS_JSON=$(echo "$REFS_JSON" | jq --arg t "whitelist-${tag}" '. + [$t]')
done

# 注入：rule_set 追加定义，rules 中在 cn_block 规则前插入白名单
jq --argjson rsets "$RULE_SET_JSON" \
   --argjson refs "$REFS_JSON" \
   '
   # 追加 rule_set 定义
   .route.rule_set += $rsets |

   # 找到 cn_block 规则的位置，在其前面插入白名单
   .route.rules as $rules |
   ($rules | to_entries | map(select(.value.rule_set? == "cn_cn_block_route")) | .[0].key // 1) as $idx |
   .route.rules = ($rules[:$idx] + [{"rule_set": $refs, "outbound": "01_direct_outbound"}] + $rules[$idx:])
   ' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

echo ""
echo "[完成] 白名单注入成功！"
echo "放行标签: ${WHITELIST_TAGS[*]}"
echo ""
echo "当前路由规则顺序:"
jq -r '.route.rules[] | if .rule_set then "  → rule_set: \(.rule_set) → \(.outbound)" elif .domain_regex then "  → domain_regex → \(.outbound)" elif .action then "  → action: \(.action)" else "  → \(.)" end' "$CONFIG"
echo ""

# 重启
echo "[信息] 重启 sing-box..."
systemctl restart sing-box && echo "[完成] sing-box 已重启" || echo "[错误] 重启失败，请检查配置"
