#!/bin/bash
# whitelist-inject.sh v1.5
# 在 v2ray-agent sing-box 屏蔽中国域名/IP 规则前注入白名单放行规则
# 用法: bash whitelist-inject.sh
# 注意: 每次 vasma 修改配置后需重新执行

CONFIG="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"
BACKUP="${CONFIG}.bak.$(date +%s)"

# ===== 白名单规则集（按需增减，对应 .srs 文件名）=====
WHITELIST_TAGS=(
  "douyin"
  "tiktok"
  "wildrift"
  "bilibili"
  "zhihu"
  "xiaohongshu"
  "baidu"
  "alibaba"
  "tencent"
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

# 预检：过滤掉仓库中不存在的规则集（HTTP 非 200 则跳过）
echo "[信息] 预检规则集可用性..."
VALID_TAGS=()
SKIP_TAGS=()
for tag in "${WHITELIST_TAGS[@]}"; do
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    "${URL_PREFIX}/${tag}.srs")
  if [[ "$status" == "200" ]]; then
    VALID_TAGS+=("$tag")
  else
    SKIP_TAGS+=("$tag")
    echo "[跳过] ${tag}.srs (HTTP ${status})"
  fi
done

if [[ ${#VALID_TAGS[@]} -eq 0 ]]; then
  echo "[错误] 所有规则集均不可用，退出"
  exit 1
fi

echo "[信息] 有效标签 (${#VALID_TAGS[@]}/${#WHITELIST_TAGS[@]}): ${VALID_TAGS[*]}"
[[ ${#SKIP_TAGS[@]} -gt 0 ]] && echo "[信息] 已跳过 (${#SKIP_TAGS[@]}): ${SKIP_TAGS[*]}"
echo ""

# 备份
cp "$CONFIG" "$BACKUP"
echo "[信息] 已备份到 $BACKUP"

# 先清除之前注入的白名单规则（幂等，可重复执行）
CLEAN=$(jq '
  .route.rule_set = [.route.rule_set[] | select(.tag | startswith("whitelist-") | not)] |
  .route.rules = [.route.rules[] | select(
    if .rule_set then
      (if (.rule_set | type) == "array"
       then (.rule_set | any(startswith("whitelist-"))) | not
       else (.rule_set | startswith("whitelist-")) | not
       end)
    else true end
  )]
' "$CONFIG")

echo "$CLEAN" > "$CONFIG"

# 构建 rule_set 条目 JSON（仅使用预检通过的标签）
RULE_SET_JSON="[]"
for tag in "${VALID_TAGS[@]}"; do
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
for tag in "${VALID_TAGS[@]}"; do
  REFS_JSON=$(echo "$REFS_JSON" | jq --arg t "whitelist-${tag}" '. + [$t]')
done

# 注入：
# 找到 geoip 封锁 或 cn_block 规则中最靠前的位置，在其前面插入白名单
# 这样白名单优先于 IP 封锁和域名封锁两道规则
jq --argjson rsets "$RULE_SET_JSON" \
   --argjson refs "$REFS_JSON" \
   '
   # 追加 rule_set 定义
   .route.rule_set += $rsets |

   # 找到第一个封锁规则（geoip 或 cn_block），在其前面插入白名单
   .route.rules as $rules |
   (
     $rules | to_entries | map(select(
       .value.rule_set? == "cn_cn_block_route" or
       .value.rule_set? == "geoip_cn_cn_block_ip_route" or
       ((.value.rule_set? | type) == "array" and (
         .value.rule_set | any(. == "cn_cn_block_route" or . == "geoip_cn_cn_block_ip_route")
       ))
     )) | .[0].key // 1
   ) as $idx |
   .route.rules = ($rules[:$idx] + [{"rule_set": $refs, "outbound": "01_direct_outbound"}] + $rules[$idx:])
   ' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

echo ""
echo "[完成] 白名单注入成功！"
echo "放行标签: ${VALID_TAGS[*]}"
echo ""
echo "当前路由规则顺序:"
jq -r '.route.rules[] |
  if .rule_set then
    "  → rule_set: \(if (.rule_set|type)=="array" then (.rule_set|join(",")) else .rule_set end) → \(.outbound)"
  elif .domain_regex then
    "  → domain_regex (\(.domain_regex|length) 条) → \(.outbound)"
  elif .action then
    "  → action: \(.action)"
  else
    "  → \(.)"
  end' "$CONFIG"
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

# 等待 sing-box 启动（最长 60 秒）
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
