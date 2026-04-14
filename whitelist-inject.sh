#!/bin/bash
# whitelist-inject.sh v2.0
# 在 v2ray-agent sing-box 屏蔽中国域名/IP 规则前注入白名单放行规则，并屏蔽广告
# 用法: bash whitelist-inject.sh
# 注意: 每次 vasma 修改配置后需重新执行

CONFIG="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"
BACKUP="${CONFIG}.bak.$(date +%s)"

# ===== 白名单规则集（按需增减，对应 .srs 文件名）=====
WHITELIST_TAGS=(
  "douyin"
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

# ===== 广告屏蔽规则集（按需增减，对应 .srs 文件名）=====
AD_BLOCK_TAGS=(
  "category-ads-all"
)

# 广告拦截使用的出站（与 cn_block 相同，直接丢弃流量）
AD_BLOCK_OUTBOUND="block_ip_outbound"

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

# 预检函数：过滤不存在的规则集（HTTP 非 200 则跳过）
precheck_tags() {
  local label="$1"
  shift
  local tags=("$@")
  local valid=()
  local skip=()

  echo "[信息] 预检${label}规则集..."
  for tag in "${tags[@]}"; do
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "${URL_PREFIX}/${tag}.srs")
    if [[ "$status" == "200" ]]; then
      valid+=("$tag")
    else
      skip+=("$tag")
      echo "[跳过] ${tag}.srs (HTTP ${status})"
    fi
  done

  echo "[信息] ${label}有效 (${#valid[@]}/${#tags[@]}): ${valid[*]:-无}"
  [[ ${#skip[@]} -gt 0 ]] && echo "[信息] ${label}跳过 (${#skip[@]}): ${skip[*]}"

  # 通过 stdout 返回有效列表（空格分隔）
  echo "${valid[*]}"
}

# 分别预检白名单和广告屏蔽规则集
VALID_WL_STR=$(precheck_tags "白名单" "${WHITELIST_TAGS[@]}")
VALID_WL=($VALID_WL_STR)
echo ""

VALID_AD_STR=$(precheck_tags "广告屏蔽" "${AD_BLOCK_TAGS[@]}")
VALID_AD=($VALID_AD_STR)
echo ""

if [[ ${#VALID_WL[@]} -eq 0 && ${#VALID_AD[@]} -eq 0 ]]; then
  echo "[错误] 所有规则集均不可用，退出"
  exit 1
fi

# 备份
cp "$CONFIG" "$BACKUP"
echo "[信息] 已备份到 $BACKUP"

# 清除之前注入的规则（幂等，可重复执行）
CLEAN=$(jq '
  .route.rule_set = [.route.rule_set[] | select(
    .tag | (startswith("whitelist-") or startswith("adblock-")) | not
  )] |
  .route.rules = [.route.rules[] | select(
    if .rule_set then
      (if (.rule_set | type) == "array"
       then (.rule_set | any(startswith("whitelist-") or startswith("adblock-"))) | not
       else ((.rule_set | startswith("whitelist-")) or (.rule_set | startswith("adblock-"))) | not
       end)
    else true end
  )]
' "$CONFIG")
echo "$CLEAN" > "$CONFIG"

# 构建白名单 rule_set 条目 JSON
WL_RSETS_JSON="[]"
for tag in "${VALID_WL[@]}"; do
  WL_RSETS_JSON=$(echo "$WL_RSETS_JSON" | jq \
    --arg tag "whitelist-${tag}" \
    --arg url "${URL_PREFIX}/${tag}.srs" \
    '. + [{"type":"remote","tag":$tag,"url":$url,"download_detour":"01_direct_outbound"}]')
done

WL_REFS_JSON="[]"
for tag in "${VALID_WL[@]}"; do
  WL_REFS_JSON=$(echo "$WL_REFS_JSON" | jq --arg t "whitelist-${tag}" '. + [$t]')
done

# 构建广告屏蔽 rule_set 条目 JSON
AD_RSETS_JSON="[]"
for tag in "${VALID_AD[@]}"; do
  AD_RSETS_JSON=$(echo "$AD_RSETS_JSON" | jq \
    --arg tag "adblock-${tag}" \
    --arg url "${URL_PREFIX}/${tag}.srs" \
    '. + [{"type":"remote","tag":$tag,"url":$url,"download_detour":"01_direct_outbound"}]')
done

AD_REFS_JSON="[]"
for tag in "${VALID_AD[@]}"; do
  AD_REFS_JSON=$(echo "$AD_REFS_JSON" | jq --arg t "adblock-${tag}" '. + [$t]')
done

# 注入规则（顺序：白名单 → 广告屏蔽 → CN封锁）
jq --argjson wl_rsets "$WL_RSETS_JSON" \
   --argjson wl_refs  "$WL_REFS_JSON"  \
   --argjson ad_rsets "$AD_RSETS_JSON" \
   --argjson ad_refs  "$AD_REFS_JSON"  \
   --arg     ad_out   "$AD_BLOCK_OUTBOUND" \
   '
   .route.rule_set += $wl_rsets + $ad_rsets |

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

   .route.rules = (
     $rules[:$idx] +
     (if ($wl_refs | length) > 0  then [{"rule_set": $wl_refs, "outbound": "01_direct_outbound"}] else [] end) +
     (if ($ad_refs | length) > 0  then [{"rule_set": $ad_refs, "outbound": $ad_out}]              else [] end) +
     $rules[$idx:]
   )
   ' "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

echo ""
echo "[完成] 注入成功！"
[[ ${#VALID_WL[@]} -gt 0 ]] && echo "白名单放行: ${VALID_WL[*]}"
[[ ${#VALID_AD[@]} -gt 0 ]] && echo "广告屏蔽:   ${VALID_AD[*]}"
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
