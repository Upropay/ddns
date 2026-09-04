#!/usr/bin/env bash
# 本脚本用于更新 Cloudflare 域名的 A 记录，支持定时任务与多 IP 负载均衡（DNS Round Robin）
set -euo pipefail

SCRIPT_URL="${SCRIPT_URL:-https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh}"
INSTALL_PATH="/root/aws-ddns-adv.sh"
LOG_PATH="/root/aws-ddns-adv.log"
ORIGIN_PREFIX="origin:"

usage() {
    cat <<'EOF'
用法:
  推荐使用 API 令牌（Bearer Token）:
    单次执行:  aws-ddns-adv.sh --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]

  兼容旧版 Global API Key:
    单次执行:  aws-ddns-adv.sh <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]

环境变量:
  CF_API_TOKEN   API 令牌；与 --token 等价，可省略 --token
  ORIGIN_ID      服务器唯一标识；与 --origin-id 等价，多机负载均衡场景必填
  SCRIPT_URL     自定义脚本下载地址（仅 --install-cron 使用）

API 令牌所需权限:
  Zone : Zone : Read   定位 zone
  Zone : DNS  : Edit   读取与更新 A 记录

多机负载均衡 (DNS Round Robin) 说明:
  在多台服务器上同时运行本脚本并分别指定不同的 --origin-id，即可实现一个
  二级域名解析到多个公网 IP。每台服务器只会创建/更新/清理属于自己的那条
  A 记录（通过 DNS 记录的 comment 字段标记归属：origin:<origin-id>），
  不会触碰其他服务器的记录，并发安全。

示例:
  服务器 A:  aws-ddns-adv.sh --token XXX --origin-id server-a example.com home.example.com
  服务器 B:  aws-ddns-adv.sh --token XXX --origin-id server-b example.com home.example.com
EOF
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少依赖命令: $1" >&2
        exit 1
    }
}

json_val() {
    local raw="$1" key="$2" scope="${3:-}"
    local hay="$raw"
    local tail

    if [[ "$scope" == "result0" ]]; then
        hay="$(printf '%s' "$raw" | sed -nE 's/.*"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{/\{/; s/\}[[:space:]]*\].*//p' | head -n1)"
        if [[ -z "$hay" ]]; then
            printf ''
            return
        fi
    fi

    tail="${hay#*\"$key\"}"
    if [[ "$tail" == "$hay" ]]; then
        printf ''
        return
    fi
    tail="${tail#*:}"
    tail="$(printf '%s' "$tail" | sed -E 's/^[[:space:]]+//')"

    if [[ "$tail" =~ ^\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$tail" =~ ^(true|false|null|-?[0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    printf ''
}

json_errors_message() {
    printf '%s' "$1" | sed -nE 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
}

json_extract_records() {
    local raw="$1"
    printf '%s' "$raw" \
        | awk 'BEGIN{ RS="{"; ORS="" }
             {
                 line=$0
                 id=""
                 content=""
                 proxied=""
                 comment=""
                 have_type=0
                 type_val=""

                 while (match(line, /"id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{32}"/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"id"[[:space:]]*:[[:space:]]*"/, "", s)
                     sub(/".*/, "", s)
                     id = s
                     break
                 }
                 if (id == "") next

                 while (match(line, /"type"[[:space:]]*:[[:space:]]*"[A-Z]+"/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"type"[[:space:]]*:[[:space:]]*"/, "", s)
                     sub(/".*/, "", s)
                     have_type=1
                     type_val=s
                     break
                 }
                 if (have_type == 0 || type_val != "A") next

                 while (match(line, /"content"[[:space:]]*:[[:space:]]*"[0-9.]+"/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"content"[[:space:]]*:[[:space:]]*"/, "", s)
                     sub(/".*/, "", s)
                     content = s
                     break
                 }
                 if (content == "") next

                 while (match(line, /"proxied"[[:space:]]*:[[:space:]]*(true|false)/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"proxied"[[:space:]]*:[[:space:]]*/, "", s)
                     proxied = s
                     break
                 }

                 if (match(line, /"comment"[[:space:]]*:[[:space:]]*null/)) comment = ""
                 else if (match(line, /"comment"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                     s = substr(line, RSTART, RLENGTH); sub(/.*"comment"[[:space:]]*:[[:space:]]*"/, "", s); sub(/".*/, "", s); comment = s
                 } else comment = ""

                 printf "%s\t%s\t%s\t%s\n", id, content, (proxied=="" ? "false" : proxied), comment
             }'
}

setup_cf_headers() {
    cf_headers=()
    if [[ -n "${cf_api_token:-}" ]]; then
        cf_headers+=(-H "Authorization: Bearer ${cf_api_token}")
    else
        cf_headers+=(-H "X-Auth-Email: ${auth_email}")
        cf_headers+=(-H "X-Auth-Key: ${auth_key}")
    fi
    cf_headers+=(-H "Content-Type: application/json")
}

CURL_API_OPTS=(--connect-timeout 5 --max-time 20 --retry 2 --retry-delay 1 --retry-max-time 40)
CURL_IP_OPTS=(--connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 --retry-max-time 30)

cf_fail_help() {
    local code="$1"
    echo "Cloudflare API 返回 HTTP ${code}。" >&2
    if [[ -n "${cf_api_token:-}" ]]; then
        case "$code" in
            401|403)
                echo "API 令牌鉴权失败。请确认:" >&2
                echo "  1) 令牌未过期、未撤销" >&2
                echo "  2) 拥有 Zone:Zone:Read 与 Zone:DNS:Edit 权限" >&2
                echo "  3) 权限的 Zone Resources 覆盖目标 zone（或选择 All zones）" >&2
                ;;
            429) echo "请求过于频繁，已被限流。" >&2 ;;
        esac
    else
        case "$code" in
            401|403)
                echo "Global API Key 鉴权失败。请确认邮箱与密钥正确；" >&2
                echo "建议改用 API 令牌: --token <token> 或 export CF_API_TOKEN=<token>" >&2
                ;;
        esac
    fi
}

cf_http_get() {
    local url="$1"
    local tmp body code
    tmp="$(mktemp)"
    code="$(curl -sS "${CURL_API_OPTS[@]}" -o "$tmp" -w "%{http_code}" -X GET "$url" "${cf_headers[@]}")" || {
        rm -f "$tmp"
        return 1
    }
    body="$(cat "$tmp")"
    rm -f "$tmp"
    case "$code" in
        200) printf '%s' "$body" ;;
        *)
            echo "请求失败: GET $url" >&2
            echo "响应: $body" >&2
            local errm
            errm="$(json_errors_message "$body")"
            [[ -n "$errm" ]] && echo "API 说明: $errm" >&2
            cf_fail_help "$code"
            exit 1
            ;;
    esac
}

cf_http_body() {
    local method="$1"
    local url="$2"
    local data="$3"
    local tmp body code
    tmp="$(mktemp)"
    code="$(curl -sS "${CURL_API_OPTS[@]}" -o "$tmp" -w "%{http_code}" -X "$method" "$url" "${cf_headers[@]}" --data "$data")" || {
        rm -f "$tmp"
        return 1
    }
    body="$(cat "$tmp")"
    rm -f "$tmp"
    case "$code" in
        200|201) printf '%s' "$body" ;;
        *)
            echo "请求失败: $method $url" >&2
            echo "响应: $body" >&2
            local errm
            errm="$(json_errors_message "$body")"
            [[ -n "$errm" ]] && echo "API 说明: $errm" >&2
            cf_fail_help "$code"
            exit 1
            ;;
    esac
}

cf_http_delete() {
    local url="$1"
    local tmp body code
    tmp="$(mktemp)"
    code="$(curl -sS "${CURL_API_OPTS[@]}" -o "$tmp" -w "%{http_code}" -X DELETE "$url" "${cf_headers[@]}")" || {
        rm -f "$tmp"
        return 1
    }
    body="$(cat "$tmp")"
    rm -f "$tmp"
    case "$code" in
        200) printf '%s' "$body" ;;
        *)
            echo "请求失败: DELETE $url" >&2
            echo "响应: $body" >&2
            local errm
            errm="$(json_errors_message "$body")"
            [[ -n "$errm" ]] && echo "API 说明: $errm" >&2
            cf_fail_help "$code"
            exit 1
            ;;
    esac
}

build_comment() {
    local oid="$1"
    [[ -n "$oid" ]] && printf '%s%s' "$ORIGIN_PREFIX" "$oid" || printf ''
}

verify_and_repair_record() {
    local zone_identifier="$1" record_name="$2" record_id="$3" expect_ip="$4" expect_comment="$5" label_prefix="${6:-}"
    local verify_url verify_resp verify_success v_content v_comment v_proxied
    verify_url="https://api.cloudflare.com/client/v4/zones/${zone_identifier}/dns_records/${record_id}"
    verify_resp="$(cf_http_get "$verify_url")"
    verify_success="$(json_val "$verify_resp" "success")"
    if [[ "$verify_success" != "true" ]]; then
        echo "${label_prefix}[警告] 创建/更新后校验失败（GET 单条未成功），将跳过后续补修，下一轮再处理: $verify_resp" >&2
        return 0
    fi
    v_content="$(json_val "$verify_resp" "content" result0)"
    v_proxied="$(json_val "$verify_resp" "proxied" result0)"
    v_comment="$(json_val "$verify_resp" "comment" result0)"
    local mismatch="false"
    if [[ -n "$expect_ip" && "$v_content" != "$expect_ip" ]]; then mismatch="true"; fi
    if [[ -n "$expect_comment" && "$v_comment" != "$expect_comment" ]]; then mismatch="true"; fi

    if [[ "$mismatch" == "false" ]]; then
        echo "${label_prefix}[校验通过] id=$record_id content=$v_content comment=${v_comment:-<空>}"
        return 0
    fi

    echo "${label_prefix}[校验不一致] id=$record_id 期望(content=$expect_ip comment=${expect_comment:-<空>})，实际(content=$v_content comment=${v_comment:-<空>})，自动补 PUT 修复"
    local fix_payload fix_resp fix_success
    fix_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":%s,"comment":"%s"}' \
        "$record_name" \
        "${expect_ip:-$v_content}" \
        "${v_proxied:-false}" \
        "${expect_comment:-${v_comment:-}}")"
    fix_resp="$(cf_http_body PUT "https://api.cloudflare.com/client/v4/zones/${zone_identifier}/dns_records/${record_id}" "$fix_payload")"
    fix_success="$(json_val "$fix_resp" "success")"
    if [[ "$fix_success" == "true" ]]; then
        echo "${label_prefix}[补修成功] id=$record_id 已强制写入 content=${expect_ip:-$v_content} comment=${expect_comment:-${v_comment:-<空>}}"
    else
        echo "${label_prefix}[补修失败] id=$record_id 补 PUT 返回: $fix_resp" >&2
    fi
}

run_once() {
    local lock_key lock_dir lock_errcode=0
    lock_key="$(printf '%s|%s|%s' "$zone_name" "$record_name" "${origin_id:-__no_origin__}" | base64 | tr -d '\n=/')"
    lock_dir="/tmp/.aws-ddns-adv-${lock_key}.lock"
    local pid_file="$lock_dir/pid"

    acquire_lock() {
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s' "$$" > "$pid_file"
            return 0
        fi
        local old_pid=""
        if [[ -f "$pid_file" ]]; then
            old_pid="$(cat "$pid_file" 2>/dev/null || true)"
        fi
        local recovered="false"
        if [[ -z "$old_pid" ]]; then
            echo "[锁修复] 锁目录 $lock_dir 存在但没有 pid 文件，当作僵尸锁清理并重新获取"
            rm -rf "$lock_dir"
            if mkdir "$lock_dir" 2>/dev/null; then
                printf '%s' "$$" > "$pid_file"
                recovered="true"
            fi
        elif ! kill -0 "$old_pid" 2>/dev/null; then
            echo "[锁修复] 持有锁的进程 pid=$old_pid 已不存在（卡死/被杀），清理僵尸锁并重新获取"
            rm -rf "$lock_dir"
            if mkdir "$lock_dir" 2>/dev/null; then
                printf '%s' "$$" > "$pid_file"
                recovered="true"
            fi
        fi
        if [[ "$recovered" == "true" ]]; then return 0; fi
        return 1
    }

    if ! acquire_lock; then
        echo "[跳过] 已有相同任务在执行中（锁目录: $lock_dir，pid=$(cat "$pid_file" 2>/dev/null || echo '?')），避免并发创建重复记录" >&2
        exit 0
    fi
    trap 'rm -rf "$lock_dir"' EXIT

    setup_cf_headers

    local current_ip="${ip:-}"
    local zone_resp zone_success zone_identifier
    local record_url record_resp record_success
    local create_payload create_resp create_success
    local update_payload update_resp update_success

    if [[ -z "$current_ip" ]]; then
        current_ip="$(curl -fsS "${CURL_IP_OPTS[@]}" https://ipv4.icanhazip.com | tr -d '[:space:]')"
    fi

    if ! [[ "$current_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "IP 不是有效 IPv4: $current_ip" >&2
        exit 1
    fi

    zone_resp="$(cf_http_get "$(curl -sS "${CURL_API_OPTS[@]}" -o /dev/null -w '%{url_effective}' -G 'https://api.cloudflare.com/client/v4/zones' --data-urlencode "name=${zone_name}")")"
    zone_success="$(json_val "$zone_resp" "success")"
    if [[ "$zone_success" != "true" ]]; then
        echo "查询 Zone 失败: $zone_resp" >&2
        exit 1
    fi

    zone_identifier="$(json_val "$zone_resp" "id" result0)"
    if [[ -z "$zone_identifier" ]]; then
        echo "未找到 Zone: $zone_name" >&2
        exit 1
    fi

    record_url="$(curl -sS "${CURL_API_OPTS[@]}" -o /dev/null -w '%{url_effective}' -G \
        "https://api.cloudflare.com/client/v4/zones/${zone_identifier}/dns_records" \
        --data-urlencode "type=A" \
        --data-urlencode "name=${record_name}")"
    record_resp="$(cf_http_get "$record_url")"
    record_success="$(json_val "$record_resp" "success")"
    if [[ "$record_success" != "true" ]]; then
        echo "查询 DNS 记录失败: $record_resp" >&2
        exit 1
    fi

    local expected_comment
    expected_comment="$(build_comment "${origin_id:-}")"

    local all_ids=() all_contents=() all_proxieds=() all_comments=()
    local records_tsv line rid rcontent rproxied rcomment
    records_tsv="$(json_extract_records "$record_resp")"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r rid rcontent rproxied rcomment <<< "$line"
        [[ -z "$rid" ]] && continue
        all_ids+=("$rid")
        all_contents+=("$rcontent")
        all_proxieds+=("${rproxied:-false}")
        all_comments+=("$rcomment")
    done <<< "$records_tsv"

    if (( ${#all_ids[@]} == 0 )); then
        local fallback_id fallback_content fallback_proxied
        fallback_id="$(json_val "$record_resp" "id" result0)"
        fallback_content="$(json_val "$record_resp" "content" result0)"
        fallback_proxied="$(json_val "$record_resp" "proxied" result0)"
        if [[ -n "$fallback_id" && -n "$fallback_content" ]]; then
            all_ids+=("$fallback_id")
            all_contents+=("$fallback_content")
            all_proxieds+=("${fallback_proxied:-false}")
            all_comments+=("")
        fi
    fi

    if [[ -z "${origin_id:-}" ]]; then
        echo "检测到 ${#all_ids[@]} 条同名 A 记录（当前目标 IP: $current_ip）"

        local existing_idx=""
        local i
        for (( i = 0; i < ${#all_ids[@]}; i++ )); do
            if [[ "${all_contents[$i]}" == "$current_ip" ]]; then
                existing_idx="$i"
                break
            fi
        done

        if [[ -n "$existing_idx" ]]; then
            echo "当前 IP 已在记录中（索引 ${existing_idx}，id=${all_ids[$existing_idx]}），无需更新: $record_name -> $current_ip"
            exit 0
        fi

        if (( ${#all_ids[@]} > 0 )); then
            echo "当前 IP 不在 ${#all_ids[@]} 条已有记录中，新增记录"
        fi

        create_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":false}' "$record_name" "$current_ip")"
        create_resp="$(cf_http_body POST "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records" "$create_payload")"
        create_success="$(json_val "$create_resp" "success")"
        if [[ "$create_success" != "true" ]]; then
            echo "创建记录失败: $create_resp" >&2
            exit 1
        fi
        local created_id=""
        created_id="$(json_val "$create_resp" "id" result0)"
        echo "已创建记录: $record_name -> $current_ip（id=$created_id，当前总计 $(( ${#all_ids[@]} + 1 )) 条同名 A 记录）"
        if [[ -n "$created_id" ]]; then
            verify_and_repair_record "$zone_identifier" "$record_name" "$created_id" "$current_ip" "" ""
        fi
        exit 0
    fi

    # ========= Preflight：宽松匹配强制去重（兜底，不依赖解析器精确 comment 相等） =========
    # Cloudflare UI / 历史写入 / 不同机器并发导致同 origin:xxx 名下出现 2+ 条，
    # 即使 json_extract_records 的 comment 精确匹配因转义/换行等漏算，这里也用
    # case 字符串包含匹配 expected_comment 做二次扫描，多于 1 条时只保留第 1 条，
    # 其余全部 DELETE，保证同 origin-id 名下最终只剩 1 条。
    if [[ -n "${origin_id:-}" && -n "$expected_comment" && ${#all_ids[@]} -gt 1 ]]; then
        local loose_mine_ids=() loose_mine_contents=() i c
        for (( i = 0; i < ${#all_ids[@]}; i++ )); do
            c="${all_comments[$i]:-}"
            if [[ "$c" == "$expected_comment" || "$c" == *"$expected_comment"* ]]; then
                loose_mine_ids+=("${all_ids[$i]}")
                loose_mine_contents+=("${all_contents[$i]}")
            fi
        done
        if (( ${#loose_mine_ids[@]} > 1 )); then
            echo "[origin:${origin_id}] [Preflight宽松去重] 检测到归属名下 ${#loose_mine_ids[@]} 条记录，保留 id=${loose_mine_ids[0]} (IP=${loose_mine_contents[0]})，删除剩余 $(( ${#loose_mine_ids[@]} - 1 )) 条"
            for (( i = 1; i < ${#loose_mine_ids[@]}; i++ )); do
                cf_http_delete "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/${loose_mine_ids[$i]}" >/dev/null || true
                echo "[origin:${origin_id}] [Preflight宽松去重] 已删除重复记录 id=${loose_mine_ids[$i]} (IP=${loose_mine_contents[$i]})"
            done
            # 删除之后重新拉一次 list，刷新 all_* 数组，避免后面分类还带着已删 id
            local refreshed
            record_resp="$(cf_http_get "$record_url")" || refreshed="fail"
            if [[ "${refreshed:-}" != "fail" ]]; then
                record_success="$(json_val "$record_resp" "success")"
                if [[ "$record_success" == "true" ]]; then
                    local _ids=() _contents=() _proxieds=() _comments=()
                    local _tsv _line _rid _rcontent _rproxied _rcomment
                    _tsv="$(json_extract_records "$record_resp")"
                    while IFS= read -r _line; do
                        [[ -z "$_line" ]] && continue
                        IFS=$'\t' read -r _rid _rcontent _rproxied _rcomment <<< "$_line"
                        [[ -z "$_rid" ]] && continue
                        _ids+=("$_rid")
                        _contents+=("$_rcontent")
                        _proxieds+=("${_rproxied:-false}")
                        _comments+=("$_rcomment")
                    done <<< "$_tsv"
                    all_ids=("${_ids[@]}")
                    all_contents=("${_contents[@]}")
                    all_proxieds=("${_proxieds[@]}")
                    all_comments=("${_comments[@]}")
                    unset _ids _contents _proxieds _comments _tsv _line _rid _rcontent _rproxied _rcomment
                fi
            fi
        fi
    fi

    local my_ids=() my_contents=() my_proxieds=() my_comments=()
    local unassigned_ids=() unassigned_contents=() unassigned_proxieds=()
    declare -A other_origin_counts=()
    local i
    for (( i = 0; i < ${#all_ids[@]}; i++ )); do
        local c="${all_comments[$i]}"
        if [[ "$c" == "$expected_comment" ]]; then
            my_ids+=("${all_ids[$i]}")
            my_contents+=("${all_contents[$i]}")
            my_proxieds+=("${all_proxieds[$i]}")
            my_comments+=("$c")
        elif [[ -z "$c" ]]; then
            unassigned_ids+=("${all_ids[$i]}")
            unassigned_contents+=("${all_contents[$i]}")
            unassigned_proxieds+=("${all_proxieds[$i]}")
        else
            if [[ -n "${other_origin_counts[$c]:-}" ]]; then
                other_origin_counts[$c]=$(( other_origin_counts[$c] + 1 ))
            else
                other_origin_counts[$c]=1
            fi
        fi
    done

    local oc_info="" oc_k
    for oc_k in "${!other_origin_counts[@]}"; do
        [[ -n "$oc_info" ]] && oc_info="${oc_info}, "
        oc_info="${oc_info}${oc_k}=${other_origin_counts[$oc_k]}"
    done

    local adopted="" adopted_idx_in_unassigned=""
    if (( ${#my_ids[@]} == 0 )) && (( ${#unassigned_ids[@]} > 0 )); then
        local j
        for (( j = 0; j < ${#unassigned_ids[@]}; j++ )); do
            if [[ "${unassigned_contents[$j]}" == "$current_ip" ]]; then
                adopted_idx_in_unassigned="$j"
                break
            fi
        done
        if [[ -n "$adopted_idx_in_unassigned" ]]; then
            adopted="1"
            my_ids+=("${unassigned_ids[$adopted_idx_in_unassigned]}")
            my_contents+=("${unassigned_contents[$adopted_idx_in_unassigned]}")
            my_proxieds+=("${unassigned_proxieds[$adopted_idx_in_unassigned]}")
            my_comments+=("")
            echo "[origin:${origin_id}] 接管 1 条无归属历史记录（IP 与当前公网 IP 一致: $current_ip，id=${unassigned_ids[$adopted_idx_in_unassigned]}），将在本次写入归属 comment"
        fi
    fi

    echo "[origin:${origin_id}] 检测到 $(( ${#my_ids[@]} )) 条归属自己的记录（总 ${#all_ids[@]} 条同名 A 记录；无归属 ${#unassigned_ids[@]} 条；其他 origin: ${oc_info:-无}）"

    if (( ${#my_ids[@]} > 1 )); then
        echo "[origin:${origin_id}] 归属自己的记录重复 $(( ${#my_ids[@]} - 1 )) 条，保留第 1 条（id=${my_ids[0]}，IP=${my_contents[0]}），清理其余"
        for (( i = 1; i < ${#my_ids[@]}; i++ )); do
            cf_http_delete "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/${my_ids[$i]}" >/dev/null
            echo "[origin:${origin_id}] 已删除自己的重复记录: id=${my_ids[$i]} (IP=${my_contents[$i]})"
        done
    fi

    if (( ${#my_ids[@]} == 0 )); then
        create_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":false,"comment":"%s"}' "$record_name" "$current_ip" "$expected_comment")"
        create_resp="$(cf_http_body POST "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records" "$create_payload")"
        create_success="$(json_val "$create_resp" "success")"
        if [[ "$create_success" != "true" ]]; then
            echo "创建记录失败: $create_resp" >&2
            exit 1
        fi
        local created_id=""
        created_id="$(json_val "$create_resp" "id" result0)"
        echo "[origin:${origin_id}] 已创建记录: $record_name -> $current_ip (id=$created_id)"
        if [[ -n "$created_id" ]]; then
            verify_and_repair_record "$zone_identifier" "$record_name" "$created_id" "$current_ip" "$expected_comment" "[origin:${origin_id}] "
        fi
        exit 0
    fi

    local my_id="${my_ids[0]}"
    local my_content="${my_contents[0]}"
    local my_proxied="${my_proxieds[0]:-false}"
    local need_comment_patch="false"
    if [[ "${my_comments[0]}" != "$expected_comment" ]]; then
        need_comment_patch="true"
    fi

    if [[ "$my_content" == "$current_ip" && "$need_comment_patch" == "false" ]]; then
        echo "[origin:${origin_id}] 记录已是目标 IPv4，无需更新: $record_name -> $current_ip (id=$my_id)"
        exit 0
    fi

    update_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":%s,"comment":"%s"}' "$record_name" "$current_ip" "$my_proxied" "$expected_comment")"
    update_resp="$(cf_http_body PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$my_id" "$update_payload")"
    update_success="$(json_val "$update_resp" "success")"
    if [[ "$update_success" != "true" ]]; then
        echo "更新记录失败: $update_resp" >&2
        exit 1
    fi
    if [[ "$my_content" == "$current_ip" ]]; then
        echo "[origin:${origin_id}] IP 未变化，已补写归属 comment: $record_name -> $current_ip (id=$my_id)"
    else
        echo "[origin:${origin_id}] 已更新记录: $record_name $my_content -> $current_ip (id=$my_id, 仅操作自己的记录)"
    fi
    verify_and_repair_record "$zone_identifier" "$record_name" "$my_id" "$current_ip" "$expected_comment" "[origin:${origin_id}] "
}

install_cron() {
    require_cmd crontab
    require_cmd chmod

    local self_path=""
    if [[ -f "$0" ]]; then
        self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    fi

    if [[ -n "$self_path" && "$self_path" != "$INSTALL_PATH" ]]; then
        cp -f "$self_path" "$INSTALL_PATH"
        echo "已从本地复制脚本到: $INSTALL_PATH"
    elif [[ "$self_path" == "$INSTALL_PATH" ]]; then
        echo "脚本已位于: $INSTALL_PATH"
    else
        if [[ -z "$SCRIPT_URL" ]]; then
            echo "无法定位脚本来源：$0 不是普通文件，且未设置 SCRIPT_URL。" >&2
            echo "请直接以本地文件方式执行，或 export SCRIPT_URL=<你的下载地址>" >&2
            exit 1
        fi
        require_cmd curl
        curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 -o "$INSTALL_PATH" "$SCRIPT_URL"
        echo "已从 $SCRIPT_URL 下载脚本到: $INSTALL_PATH"
    fi
    chmod +x "$INSTALL_PATH"

    local cron_line existing tmp_cron
    if [[ -n "${cf_api_token:-}" ]]; then
        if [[ -n "${origin_id:-}" ]]; then
            cron_line="*/1 * * * * CF_API_TOKEN='${cf_api_token}' ORIGIN_ID='${origin_id}' /bin/bash ${INSTALL_PATH} ${zone_name} ${record_name}"
        else
            cron_line="*/1 * * * * CF_API_TOKEN='${cf_api_token}' /bin/bash ${INSTALL_PATH} ${zone_name} ${record_name}"
        fi
    else
        if [[ -n "${origin_id:-}" ]]; then
            cron_line="*/1 * * * * ORIGIN_ID='${origin_id}' /bin/bash ${INSTALL_PATH} ${auth_email} ${auth_key} ${zone_name} ${record_name}"
        else
            cron_line="*/1 * * * * /bin/bash ${INSTALL_PATH} ${auth_email} ${auth_key} ${zone_name} ${record_name}"
        fi
    fi

    if [[ -n "${ip:-}" ]]; then
        cron_line="${cron_line} ${ip}"
    fi

    # cron 规范：% 会被 crond 当成换行，需要转义为 \%（日志路径里常见但我们用 >> $LOG_PATH，LOG_PATH 默认无%）
    cron_line="${cron_line//%/\\%}"
    cron_line="${cron_line} >> ${LOG_PATH} 2>&1"

    # 读现有 crontab：空 crontab/首次安装 crontab -l 会 exit 1，兜底为空
    existing=""
    existing="$(crontab -l 2>/dev/null || true)"

    # 用临时文件构造新 crontab，避免管道子 shell + grep 空输入返回 1 触发 set -euo pipefail
    tmp_cron="$(mktemp)"
    # 先把原有非当前脚本的行写进去（避免已有任务被覆盖/空 crontab 导致 grep 返回码 1 触发 set -e）
    if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing" | grep -Fv "$INSTALL_PATH" > "$tmp_cron" 2>/dev/null || true
    fi
    # 追加新 cron 行，保证 tmp_cron 最后一定以换行结尾（crontab 规范）
    printf '%s\n' "$cron_line" >> "$tmp_cron"
    # 安装，并输出安装后 crontab 中对应行做自检
    if crontab "$tmp_cron" 2>/dev/null; then
        echo "已写入 crontab，安装后匹配的任务行:"
        crontab -l 2>/dev/null | grep -F "$INSTALL_PATH" || true
    else
        echo "安装 crontab 失败，尝试用管道方式回退写入:" >&2
        crontab -l 2>/dev/null | { cat; echo "$cron_line"; } | crontab - 2>/dev/null || {
            echo "crontab 写入失败，请检查系统是否安装 cron 服务或 /usr/bin/crontab 是否有 setuid 权限" >&2
            rm -f "$tmp_cron"
            exit 1
        }
        echo "（回退方式）已写入，安装后匹配的任务行:"
        crontab -l 2>/dev/null | grep -F "$INSTALL_PATH" || true
    fi
    rm -f "$tmp_cron"

    echo "已安装脚本到: $INSTALL_PATH"
    echo "已写入定时任务: 每分钟执行一次（日志: $LOG_PATH）"
    [[ -n "${origin_id:-}" ]] && echo "  服务器标识: origin:${origin_id}"

    local prev_origin="${ORIGIN_ID:-}"
    if [[ -n "${origin_id:-}" ]]; then
        ORIGIN_ID="${origin_id}"
    fi

    if [[ -n "${cf_api_token:-}" ]]; then
        CF_API_TOKEN="${cf_api_token}" /bin/bash "$INSTALL_PATH" "$zone_name" "$record_name" ${ip:+$ip}
    else
        /bin/bash "$INSTALL_PATH" "$auth_email" "$auth_key" "$zone_name" "$record_name" ${ip:+$ip}
    fi

    if [[ -n "${prev_origin:-}" ]]; then
        ORIGIN_ID="$prev_origin"
    else
        unset ORIGIN_ID
    fi
}

cf_api_token="${CF_API_TOKEN:-}"
origin_id="${ORIGIN_ID:-}"
auth_email=""
auth_key=""
zone_name=""
record_name=""
ip=""
install_mode=0

args=()
while (( $# )); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --install-cron)
            install_mode=1
            shift
            ;;
        --origin-id)
            [[ $# -ge 2 ]] || { echo "--origin-id 需要参数" >&2; exit 1; }
            origin_id="$2"
            shift 2
            ;;
        --origin-id=*)
            origin_id="${1#*=}"
            shift
            ;;
        --token)
            [[ $# -ge 2 ]] || { echo "--token 需要参数" >&2; exit 1; }
            cf_api_token="$2"
            shift 2
            ;;
        --token=*)
            cf_api_token="${1#*=}"
            shift
            ;;
        --)
            shift
            while (( $# )); do args+=("$1"); shift; done
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

if [[ -n "$cf_api_token" ]]; then
    if (( ${#args[@]} < 2 || ${#args[@]} > 3 )); then
        echo "令牌模式参数数量错误，需要 2 或 3 个位置参数: <zone_name> <record_name> [ip]" >&2
        usage
        exit 1
    fi
    zone_name="${args[0]}"
    record_name="${args[1]}"
    ip="${args[2]:-}"
else
    if (( ${#args[@]} < 4 || ${#args[@]} > 5 )); then
        echo "未提供 API 令牌，按 Global API Key 模式需要 4 或 5 个位置参数" >&2
        usage
        exit 1
    fi
    auth_email="${args[0]}"
    auth_key="${args[1]}"
    zone_name="${args[2]}"
    record_name="${args[3]}"
    ip="${args[4]:-}"
fi

require_cmd curl
require_cmd sed
require_cmd awk

if (( install_mode )); then
    install_cron
else
    run_once
fi
