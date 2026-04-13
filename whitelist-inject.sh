#!/bin/bash
# whitelist-inject.sh v1.2
# 在 v2ray-agent sing-box 屏蔽中国域名规则前注入白名单放行规则
# 用法: bash whitelist-inject.sh
# 注意: 每次 vasma 修改配置后需重新执行

CONFIG="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"
BACKUP="${CONFIG}.bak.$(date +%s)"

# ===== 白名单规则集（按需增减，对应 .srs 文件名）=====
WHITELIST_TAGS=(
  "wechat"
  "douyin"
  "bilibili"
  "zhihu"
  "xiaohongshu"
  "baidu"
  "alibaba"
  "tencent"
  "taobao"
  "alipay"
  "jd"
  "netease"
  "sina"
)

# 规则集 URL 前缀
URL_PREFIX="https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite"

# ================================================================

set -e

if [[ ! -f "$CONFIG" ]]; then
  echo "[错误] 配置文件不存在: $CONFIG"
  exit 1
fi

if [[ ! -x "$SINGBOX_BIN" ]]; then
  echo "[错误] sing-box 二进制不存在: $SINGBOX_BIN"
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

# 构建 rule_set 条目 JSON（与现有 cn_cn_block_route 格式一致）
RULE_SET_JSON="[]"
for tag in "${WHITELIST_TAGS[@]}"; do
  RULE_SET_JSON=$(echo "$RULE_SET_JSON" | jq \
    --arg tag "whitelist-${tag}" \
    --arg url "${URL_PREFIX}/${tag}.srs" \
    '. + [{
      "type": "remote",
      "tag": $tag,
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

# 校验配置
echo "[信息] 校验配置..."
CHECK_RESULT=$("$SINGBOX_BIN" check -c "$CONFIG" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "[错误] 配置校验失败，回滚！"
  echo "$CHECK_RESULT"
  cp "$BACKUP" "$CONFIG"
  echo "[信息] 已回滚到备份"
  exit 1
fi
echo "[信息] 配置校验通过"

# 重启
echo "[信息] 重启 sing-box..."
systemctl restart sing-box

# 等待 sing-box 启动完成（最长等 60 秒）
echo "[信息] 等待 sing-box 启动..."
for i in $(seq 1 30); do
  sleep 2
  if systemctl is-active --quiet sing-box; then
    echo "[完成] sing-box 运行中 ✓（等待了 $((i*2)) 秒）"
    exit 0
  fi
done

echo "[错误] sing-box 60秒内未启动，回滚！"
cp "$BACKUP" "$CONFIG"
systemctl restart sing-box
echo "[信息] 已回滚并重启"
exit 1
