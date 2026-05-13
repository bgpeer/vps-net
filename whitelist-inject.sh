#!/bin/bash
# whitelist-inject.sh v2.5
# v2ray-agent sing-box：在中国域名/IP 屏蔽规则前注入白名单放行规则，并屏蔽广告
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/whitelist-inject.sh)

set -Eeuo pipefail

CONFIG="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"
BACKUP="${CONFIG}.bak.$(date +%s)"

WHITELIST_TAGS=(
  "douyin"
  "tiktok"
  "wildrift"
  "bilibili"
  "xiaohongshu"
  "alibaba"
  "tencent"
  "kuaishou"
)

AD_BLOCK_TAGS=(
  "category-ads-all"
)

URL_PREFIX="https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite"

SCRIPT_INSTALL="/usr/local/sbin/whitelist-inject.sh"
SCRIPT_URL="https://raw.githubusercontent.com/bgpeer/vps-net/main/whitelist-inject.sh"
CRON_FILE="/etc/cron.d/whitelist-inject"
CRON_LOG="/var/log/whitelist-inject.log"

TMP_CONFIG=""
cleanup() {
  [[ -n "${TMP_CONFIG:-}" && -f "$TMP_CONFIG" ]] && rm -f "$TMP_CONFIG"
}
trap cleanup EXIT

log() { echo "[信息] $*"; }
warn() { echo "[警告] $*"; }
err() { echo "[错误] $*"; }

setup_auto_refresh() {
  echo ""
  echo "[定时] 配置每日自动刷新（北京时间 03:00）..."

  mkdir -p "$(dirname "$SCRIPT_INSTALL")"

  local src="${BASH_SOURCE[0]:-$0}"
  local src_real=""
  local install_real=""

  src_real="$(readlink -f "$src" 2>/dev/null || echo "$src")"
  install_real="$(readlink -f "$SCRIPT_INSTALL" 2>/dev/null || echo "$SCRIPT_INSTALL")"

  if [[ -f "$src" && "$src" != /dev/fd/* && "$src" != /proc/* && "$src" != "bash" ]]; then
    if [[ "$src_real" != "$install_real" ]]; then
      cp "$src" "$SCRIPT_INSTALL"
    fi
  else
    if ! curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_INSTALL"; then
      warn "下载脚本失败，跳过定时任务安装"
      return 0
    fi
  fi

  chmod 755 "$SCRIPT_INSTALL"

  cat > "$CRON_FILE" <<CRON_EOF
# whitelist-inject 规则集每日自动刷新
# 执行时间: 北京时间 03:00（UTC 19:00）
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
CRON_TZ=UTC
0 19 * * * root $SCRIPT_INSTALL >> $CRON_LOG 2>&1
CRON_EOF

  chmod 644 "$CRON_FILE"

  echo "[定时] ✓ 定时任务已安装"
  echo "       时间: 每天北京时间 03:00（UTC 19:00）"
  echo "       脚本: $SCRIPT_INSTALL"
  echo "       日志: $CRON_LOG"
}

has_outbound_tag() {
  local tag="$1"
  jq -e --arg tag "$tag" 'any(.outbounds[]?; .tag == $tag)' "$CONFIG" >/dev/null
}

detect_outbound_by_type() {
  local type="$1"
  shift
  local candidates_json="[]"
  local c=""

  for c in "$@"; do
    candidates_json="$(printf '%s' "$candidates_json" | jq -c --arg c "$c" '. + [$c]')"
  done

  jq -r --arg type "$type" --argjson candidates "$candidates_json" '
    [ .outbounds[]? | select(.type == $type) | .tag ] as $tags |
    ($candidates | map(select(. as $x | $tags | index($x))) | .[0]) //
    ($tags[0] // "")
  ' "$CONFIG"
}

ensure_outbound_exists() {
  local tag="$1"
  local type="$2"

  if has_outbound_tag "$tag"; then
    return 0
  fi

  TMP_CONFIG="$(mktemp)"
  jq --arg tag "$tag" --arg type "$type" '
    .outbounds //= [] |
    .outbounds += [{"type": $type, "tag": $tag}]
  ' "$CONFIG" > "$TMP_CONFIG"
  mv "$TMP_CONFIG" "$CONFIG"
  TMP_CONFIG=""
}

precheck_tags() {
  local label="$1"
  shift
  local tags=("$@")
  local valid=()
  local skip=()
  local status=""
  local url=""

  echo "[信息] 预检${label}规则集..." >&2

  for tag in "${tags[@]}"; do
    url="${URL_PREFIX}/${tag}.srs"

    if ! status="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)"; then
      status="000"
    fi

    if [[ "$status" == "200" ]]; then
      valid+=("$tag")
    else
      skip+=("$tag")
      echo "[跳过] ${tag}.srs (HTTP ${status})" >&2
    fi
  done

  echo "[信息] ${label}有效 (${#valid[@]}/${#tags[@]}): ${valid[*]:-无}" >&2
  [[ ${#skip[@]} -gt 0 ]] && echo "[信息] ${label}跳过 (${#skip[@]}): ${skip[*]}" >&2

  echo "${valid[*]}"
}

if [[ ! -f "$CONFIG" ]]; then
  err "配置文件不存在: $CONFIG"
  exit 1
fi

if [[ ! -x "$SINGBOX_BIN" ]]; then
  err "sing-box 二进制不存在: $SINGBOX_BIN"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  log "安装 jq..."
  apt-get update -qq && apt-get install -y -qq jq
fi

if ! jq empty "$CONFIG" >/dev/null 2>&1; then
  err "当前配置不是合法 JSON: $CONFIG"
  exit 1
fi

VALID_WL_STR="$(precheck_tags "白名单" "${WHITELIST_TAGS[@]}")"
VALID_WL=($VALID_WL_STR)
echo ""

VALID_AD_STR="$(precheck_tags "广告屏蔽" "${AD_BLOCK_TAGS[@]}")"
VALID_AD=($VALID_AD_STR)
echo ""

if [[ ${#VALID_WL[@]} -eq 0 && ${#VALID_AD[@]} -eq 0 ]]; then
  err "所有规则集均不可用，退出"
  exit 1
fi

cp "$CONFIG" "$BACKUP"
log "已备份到 $BACKUP"

DIRECT_OUTBOUND="$(detect_outbound_by_type "direct" "01_direct_outbound" "direct" "direct_outbound" "DIRECT" "🇨🇳直连" "🎯直连")"

if [[ -z "$DIRECT_OUTBOUND" ]]; then
  DIRECT_OUTBOUND="direct_outbound"
  ensure_outbound_exists "$DIRECT_OUTBOUND" "direct"
  warn "未检测到 direct 出站，已自动添加: $DIRECT_OUTBOUND"
else
  log "检测到直连出站: $DIRECT_OUTBOUND"
fi

BLOCK_OUTBOUND="$(detect_outbound_by_type "block" "block_ip_outbound" "block" "block_outbound" "reject")"

if [[ ${#VALID_AD[@]} -gt 0 ]]; then
  if [[ -z "$BLOCK_OUTBOUND" ]]; then
    BLOCK_OUTBOUND="block_ip_outbound"
    ensure_outbound_exists "$BLOCK_OUTBOUND" "block"
    warn "未检测到 block 出站，已自动添加: $BLOCK_OUTBOUND"
  else
    log "检测到拦截出站: $BLOCK_OUTBOUND"
  fi
fi

TMP_CONFIG="$(mktemp)"

jq '
  .route //= {} |

  .route.rule_set = (
    (.route.rule_set // []) |
    map(select(
      (((.tag // "") | startswith("whitelist-")) or ((.tag // "") | startswith("adblock-"))) | not
    ))
  ) |

  .route.rules = (
    (.route.rules // []) |
    map(select(
      if .rule_set then
        if (.rule_set | type) == "array" then
          (.rule_set | any(
            (type == "string") and
            (startswith("whitelist-") or startswith("adblock-"))
          )) | not
        elif (.rule_set | type) == "string" then
          (((.rule_set // "") | startswith("whitelist-")) or ((.rule_set // "") | startswith("adblock-"))) | not
        else
          true
        end
      else
        true
      end
    ))
  )
' "$CONFIG" > "$TMP_CONFIG"

mv "$TMP_CONFIG" "$CONFIG"
TMP_CONFIG=""

WL_RSETS_JSON="[]"
for tag in "${VALID_WL[@]}"; do
  WL_RSETS_JSON="$(printf '%s' "$WL_RSETS_JSON" | jq -c \
    --arg tag "whitelist-${tag}" \
    --arg url "${URL_PREFIX}/${tag}.srs" \
    --arg detour "$DIRECT_OUTBOUND" \
    '. + [{"type":"remote","tag":$tag,"format":"binary","url":$url,"download_detour":$detour,"update_interval":"24h"}]')"
done

WL_REFS_JSON="[]"
for tag in "${VALID_WL[@]}"; do
  WL_REFS_JSON="$(printf '%s' "$WL_REFS_JSON" | jq -c --arg t "whitelist-${tag}" '. + [$t]')"
done

AD_RSETS_JSON="[]"
for tag in "${VALID_AD[@]}"; do
  AD_RSETS_JSON="$(printf '%s' "$AD_RSETS_JSON" | jq -c \
    --arg tag "adblock-${tag}" \
    --arg url "${URL_PREFIX}/${tag}.srs" \
    --arg detour "$DIRECT_OUTBOUND" \
    '. + [{"type":"remote","tag":$tag,"format":"binary","url":$url,"download_detour":$detour,"update_interval":"24h"}]')"
done

AD_REFS_JSON="[]"
for tag in "${VALID_AD[@]}"; do
  AD_REFS_JSON="$(printf '%s' "$AD_REFS_JSON" | jq -c --arg t "adblock-${tag}" '. + [$t]')"
done

TMP_CONFIG="$(mktemp)"

jq --argjson wl_rsets "$WL_RSETS_JSON" \
   --argjson wl_refs  "$WL_REFS_JSON"  \
   --argjson ad_rsets "$AD_RSETS_JSON" \
   --argjson ad_refs  "$AD_REFS_JSON"  \
   --arg     direct_out "$DIRECT_OUTBOUND" \
   --arg     block_out  "$BLOCK_OUTBOUND" \
   '
   .route //= {} |
   .route.rule_set //= [] |
   .route.rules //= [] |

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
     (if ($wl_refs | length) > 0 then [{"rule_set": $wl_refs, "outbound": $direct_out}] else [] end) +
     (if ($ad_refs | length) > 0 then [{"rule_set": $ad_refs, "outbound": $block_out}] else [] end) +
     $rules[$idx:]
   )
   ' "$CONFIG" > "$TMP_CONFIG"

mv "$TMP_CONFIG" "$CONFIG"
TMP_CONFIG=""

echo ""
echo "[完成] 注入成功！"
[[ ${#VALID_WL[@]} -gt 0 ]] && echo "白名单放行: ${VALID_WL[*]} → $DIRECT_OUTBOUND"
[[ ${#VALID_AD[@]} -gt 0 ]] && echo "广告屏蔽:   ${VALID_AD[*]} → $BLOCK_OUTBOUND"
echo ""

echo "当前路由规则顺序:"
jq -r '(.route.rules // [])[] |
  if .rule_set then
    "  → rule_set: \(if (.rule_set|type)=="array" then (.rule_set|join(",")) else .rule_set end) → \(.outbound // "-")"
  elif .domain_regex then
    "  → domain_regex (\(.domain_regex|length) 条) → \(.outbound // "-")"
  elif .action then
    "  → action: \(.action)"
  else
    "  → \(.)"
  end' "$CONFIG"

echo ""

echo "[信息] 校验配置..."
set +e
CHECK_RESULT="$("$SINGBOX_BIN" check -c "$CONFIG" 2>&1)"
CHECK_STATUS=$?
set -e

if [[ $CHECK_STATUS -ne 0 ]]; then
  err "配置校验失败，回滚！"
  echo "$CHECK_RESULT"
  cp "$BACKUP" "$CONFIG"
  log "已回滚到备份"
  exit 1
fi

log "配置校验通过"

echo "[信息] 重启 sing-box..."
if ! systemctl restart sing-box; then
  err "sing-box 重启失败，回滚！"
  cp "$BACKUP" "$CONFIG"
  systemctl restart sing-box || true
  log "已回滚并尝试重启"
  exit 1
fi

echo "[信息] 等待 sing-box 启动..."
for i in $(seq 1 30); do
  sleep 2
  if systemctl is-active --quiet sing-box; then
    echo "[完成] sing-box 运行中 ✓（等待了 $((i*2)) 秒）"
    setup_auto_refresh
    exit 0
  fi
done

err "sing-box 60 秒内未启动，回滚！"
cp "$BACKUP" "$CONFIG"
systemctl restart sing-box || true
log "已回滚并尝试重启"
exit 1