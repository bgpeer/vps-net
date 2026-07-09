#!/bin/bash
# whitelist-inject.sh v2.7.1
# v2ray-agent(mack-a) sing-box：注入广告屏蔽 + 白名单放行规则
# 规则顺序：广告屏蔽 → 白名单放行 → CN 屏蔽（广告优先，白名单内服务的广告同样被拦截）
#
# 与 mack-a 脚本共存：本脚本安装在 /usr/local/sbin、定时任务在 /etc/cron.d，
# 均在 /etc/v2ray-agent 目录之外——mack-a 更新/重装不会删除本脚本；
# 若 mack-a 重写了 config.json 冲掉注入规则，每日 03:00 的 cron 会自动重新注入。
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/whitelist-inject.sh)
#     交互执行弹出菜单：1=安装  2=更新  0=删除
#   也可直接带参数（脚本/cron 调用）：
#     ... whitelist-inject.sh 1|install   安装（注入规则 + 配置每日自动刷新）
#     ... whitelist-inject.sh 2|update    更新（拉最新脚本与规则集后重新注入）
#     ... whitelist-inject.sh 0|remove    删除（移除注入规则、定时任务与本地脚本）
#   非交互且无参数（如 cron / 管道）默认执行「更新」。

set -Eeuo pipefail

CONFIG="/etc/v2ray-agent/sing-box/conf/config.json"
SINGBOX_BIN="/etc/v2ray-agent/sing-box/sing-box"
BACKUP="${CONFIG}.bak.$(date +%s)"

WHITELIST_TAGS=(
  "bytedance"
  "tiktok"
  "category-games-!cn"
  "bilibili"
  "xiaohongshu"
  "alibaba"
  "tencent"
  "kuaishou"
  "geolocation-!cn"
)

AD_BLOCK_TAGS=(
  "category-ads-all"
)

URL_PREFIX="https://raw.githubusercontent.com/bgpeer/rules/main/geo/geosite"

SCRIPT_INSTALL="/usr/local/sbin/whitelist-inject.sh"
SCRIPT_URL="https://raw.githubusercontent.com/bgpeer/vps-net/main/whitelist-inject.sh"
SHA256SUMS_URL="https://raw.githubusercontent.com/bgpeer/vps-net/main/SHA256SUMS"
CRON_FILE="/etc/cron.d/whitelist-inject"
CRON_LOG="/var/log/whitelist-inject.log"
LOGROTATE_FILE="/etc/logrotate.d/whitelist-inject"

# --- 自更新（带 SHA256SUMS 校验）---
# cron 每天跑的是本地副本，仓库里改了 WHITELIST_TAGS 等名单后，
# 必须先拉最新脚本再执行，否则名单永远停留在部署那一刻。
# 注意：下载内容落盘后再算哈希（命令替换会剥末尾换行导致校验永远失败）。
auto_update() {
  command -v curl >/dev/null 2>&1 || return 0
  command -v sha256sum >/dev/null 2>&1 || return 0

  local tmp remote_hash local_hash sums expected
  tmp="$(mktemp 2>/dev/null)" || return 0

  if ! curl -fsSL --max-time 30 "$SCRIPT_URL" -o "$tmp" || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    return 0
  fi

  remote_hash="$(sha256sum "$tmp" | cut -d' ' -f1)"
  local_hash="$([ -f "$SCRIPT_INSTALL" ] && sha256sum "$SCRIPT_INSTALL" 2>/dev/null | cut -d' ' -f1 || echo "")"

  # 已是最新：跳过
  if [ -n "$remote_hash" ] && [ "$remote_hash" = "$local_hash" ]; then
    rm -f "$tmp"
    return 0
  fi

  sums="$(curl -fsSL --max-time 30 "$SHA256SUMS_URL" 2>/dev/null || true)"
  expected="$(printf '%s\n' "$sums" | grep -E '(^|[[:space:]])whitelist-inject\.sh$' | awk '{print $1}' | head -n1)"
  if [ -z "${expected:-}" ]; then
    echo "[警告] SHA256SUMS 中未找到 whitelist-inject.sh 条目，跳过自更新"
    rm -f "$tmp"
    return 0
  fi

  if [ "$remote_hash" != "$expected" ]; then
    echo "[警告] 远程脚本 SHA256 校验失败，拒绝自更新（期望 $expected 实际 $remote_hash）"
    rm -f "$tmp"
    return 0
  fi

  if ! bash -n "$tmp" 2>/dev/null; then
    echo "[警告] 远程脚本语法检查失败，跳过自更新"
    rm -f "$tmp"
    return 0
  fi

  echo "[信息] 检测到新版本脚本（SHA256 校验通过），更新并重新执行..."
  install -m755 "$tmp" "$SCRIPT_INSTALL"
  rm -f "$tmp"
  exec "$SCRIPT_INSTALL" "$@"
}

auto_update "$@"

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
0 19 * * * root $SCRIPT_INSTALL update >> $CRON_LOG 2>&1
CRON_EOF

  chmod 644 "$CRON_FILE"

  # 日志轮转：每月一次或超过 1MB 时轮转，保留 3 份压缩归档，防止无限增长
  cat > "$LOGROTATE_FILE" <<'LOGR_EOF'
/var/log/whitelist-inject.log {
    monthly
    maxsize 1M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
LOGR_EOF
  chmod 644 "$LOGROTATE_FILE"

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

require_env() {
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
}

# 移除本脚本注入的 whitelist-/adblock- rule_set 定义与引用
strip_injected() {
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
}

# 校验配置并重启 sing-box；任何一步失败都回滚备份。
# 配置与备份完全一致时跳过重启（避免每日 cron 无谓中断连接）。
validate_and_restart() {
  if cmp -s "$CONFIG" "$BACKUP"; then
    log "配置无变化，跳过校验与重启"
    return 0
  fi

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
  local i
  for i in $(seq 1 30); do
    sleep 2
    if systemctl is-active --quiet sing-box; then
      echo "[完成] sing-box 运行中 ✓（等待了 $((i*2)) 秒）"
      return 0
    fi
  done

  err "sing-box 60 秒内未启动，回滚！"
  cp "$BACKUP" "$CONFIG"
  systemctl restart sing-box || true
  log "已回滚并尝试重启"
  exit 1
}

do_inject() {
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

  strip_injected

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

  # 注入并整理 route.rules 顺序：
  # [0] sniff
  # [1] 原有放行/其它前置规则，例如 Apple 放行
  # [2] 广告屏蔽（置于白名单之前：白名单含 geolocation-!cn 等大范围
  #     直连规则，若白名单在前，非 CN 广告域名会先命中直连绕过屏蔽）
  # [3] 白名单放行
  # [4] 中国域名屏蔽
  # [5] 中国 IP 屏蔽
  # [6] 原本在 CN 屏蔽后面的其它规则，保持在后面
  jq --argjson wl_rsets "$WL_RSETS_JSON" \
     --argjson wl_refs  "$WL_REFS_JSON"  \
     --argjson ad_rsets "$AD_RSETS_JSON" \
     --argjson ad_refs  "$AD_REFS_JSON"  \
     --arg     direct_out "$DIRECT_OUTBOUND" \
     --arg     block_out  "$BLOCK_OUTBOUND" \
     '
     def arr(x): if (x|type)=="array" then x else [x] end;
     def refs: if .rule_set? then arr(.rule_set) else [] end;

     def is_sniff:
       .action? == "sniff";

     def is_cn_domain_block:
       (.rule_set? != null) and
       (refs | any(
         . == "cn_cn_block_route" or
         test("(^|[-_])geosite[-_]?cn($|[-_])"; "i") or
         test("^cn[_-]cn[_-]block[_-]route$"; "i") or
         test("(^|[-_])cn[-_]?block[-_]?route$"; "i")
       ));

     def is_cn_ip_block:
       (.rule_set? != null) and
       (refs | any(
         . == "geoip_cn_cn_block_ip_route" or
         test("(^|[-_])geoip[-_]?cn($|[-_])"; "i") or
         test("cn[-_]?block[-_]?ip"; "i")
       ));

     .route //= {} |
     .route.rule_set //= [] |
     .route.rules //= [] |

     .route.rule_set += $ad_rsets + $wl_rsets |

     .route.rules as $rules |

     (
       $rules
       | to_entries
       | map(select(.value | (is_cn_domain_block or is_cn_ip_block)))
       | .[0].key // ($rules | length)
     ) as $cn_idx |

     ($rules | map(select(is_sniff))) as $sniff_rules |
     ($rules | map(select(is_cn_domain_block))) as $cn_domain_rules |
     ($rules | map(select(is_cn_ip_block))) as $cn_ip_rules |

     ($rules[:$cn_idx] | map(select((is_sniff or is_cn_domain_block or is_cn_ip_block) | not))) as $before_cn |
     ($rules[$cn_idx:] | map(select((is_sniff or is_cn_domain_block or is_cn_ip_block) | not))) as $after_cn |

     .route.rules = (
       $sniff_rules +
       $before_cn +
       (if ($ad_refs | length) > 0 then [{"rule_set": $ad_refs, "outbound": $block_out}] else [] end) +
       (if ($wl_refs | length) > 0 then [{"rule_set": $wl_refs, "outbound": $direct_out}] else [] end) +
       $cn_domain_rules +
       $cn_ip_rules +
       $after_cn
     )
     ' "$CONFIG" > "$TMP_CONFIG"

  mv "$TMP_CONFIG" "$CONFIG"
  TMP_CONFIG=""

  echo ""
  echo "[完成] 注入成功！"
  [[ ${#VALID_AD[@]} -gt 0 ]] && echo "广告屏蔽:   ${VALID_AD[*]} → $BLOCK_OUTBOUND"
  [[ ${#VALID_WL[@]} -gt 0 ]] && echo "白名单放行: ${VALID_WL[*]} → $DIRECT_OUTBOUND"
  echo ""

  echo "当前路由规则顺序:"
  jq -r '
    (.route.rules // []) as $rules |
    range(0; $rules|length) as $i |
    $rules[$i] as $r |
    if $r.rule_set then
      "  [" + ($i|tostring) + "] rule_set=" +
      (if ($r.rule_set|type)=="array" then ($r.rule_set|join(",")) else $r.rule_set end) +
      "  outbound=" + ($r.outbound // "-")
    elif $r.domain_regex then
      "  [" + ($i|tostring) + "] domain_regex (" + (($r.domain_regex|length)|tostring) + " 条)  outbound=" + ($r.outbound // "-")
    elif $r.action then
      "  [" + ($i|tostring) + "] action=" + $r.action
    else
      "  [" + ($i|tostring) + "] " + ($r|tostring)
    end
  ' "$CONFIG"

  echo ""

  validate_and_restart
  setup_auto_refresh
}

do_remove() {
  cp "$CONFIG" "$BACKUP"
  log "已备份到 $BACKUP"

  strip_injected
  log "已从配置中移除全部 whitelist-/adblock- 注入规则"

  validate_and_restart

  rm -f "$CRON_FILE"
  log "已删除定时任务: $CRON_FILE"

  rm -f "$LOGROTATE_FILE"
  log "已删除日志轮转配置: $LOGROTATE_FILE"

  # 最后删除本地脚本（正在执行的副本删除后不再读取新内容，安全）
  rm -f "$SCRIPT_INSTALL"
  log "已删除本地脚本: $SCRIPT_INSTALL"

  echo ""
  echo "[完成] 卸载完成，sing-box 配置已恢复为无注入状态"
  exit 0
}

# ── 动作选择：参数优先，交互弹菜单，非交互（cron/管道）默认更新 ──────────────
ACTION="${1:-}"
case "$ACTION" in
  1|install)          ACTION="install" ;;
  2|update)           ACTION="update" ;;
  0|remove|uninstall) ACTION="remove" ;;
  "")
    if [ -t 0 ]; then
      echo ""
      echo "========= whitelist-inject v2.7.1 ========="
      echo "  1. 安装（注入规则 + 每日自动刷新）"
      echo "  2. 更新（拉最新脚本与规则集后重新注入）"
      echo "  0. 删除（移除注入规则、定时任务与本地脚本）"
      echo "========================================="
      while true; do
        read -r -p "请选择 [1/2/0]: " _choice || _choice=""
        case "$_choice" in
          1) ACTION="install"; break ;;
          2) ACTION="update";  break ;;
          0) ACTION="remove";  break ;;
          *) echo "无效输入，请输入 1、2 或 0" ;;
        esac
      done
    else
      ACTION="update"
    fi
    ;;
  *)
    err "未知参数: $ACTION（可用: 1|install  2|update  0|remove）"
    exit 1
    ;;
esac

require_env

case "$ACTION" in
  install)
    log "执行安装..."
    do_inject
    ;;
  update)
    log "执行更新..."
    do_inject
    ;;
  remove)
    log "执行卸载..."
    do_remove
    ;;
esac
