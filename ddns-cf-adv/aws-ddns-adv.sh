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

                 while (match(line, /"id"[[:space:]]*:[[:space:]]*"[0-9a-f]{32}"/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"id"[[:space:]]*:[[:space:]]*"/, "", s)
                     sub(/".*/, "", s)
                     id = s
                     break
                 }

                 while (match(line, /"content"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"content"[[:space:]]*:[[:space:]]*"/, "", s)
                     sub(/".*/, "", s)
                     content = s
                     break
                 }

                 while (match(line, /"proxied"[[:space:]]*:[[:space:]]*(true|false)/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"proxied"[[:space:]]*:[[:space:]]*/, "", s)
                     proxied = s
                     break
                 }

                 while (match(line, /"comment"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                     s = substr(line, RSTART, RLENGTH)
                     sub(/.*"comment"[[:space:]]*:[[:space:]]*"/, "", s)
                     sub(/".*/, "", s)
                     comment = s
                     break
                 }

                 if (id != "") {
                     printf "%s\t%s\t%s\t%s\n", id, content, proxied, comment
                 }
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
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X GET "$url" "${cf_headers[@]}")" || {
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
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" "${cf_headers[@]}" --data "$data")" || {
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
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X DELETE "$url" "${cf_headers[@]}")" || {
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

run_once() {
    setup_cf_headers

    local current_ip="${ip:-}"
    local zone_resp zone_success zone_identifier
    local record_url record_resp record_success
    local create_payload create_resp create_success
    local update_payload update_resp update_success

    if [[ -z "$current_ip" ]]; then
        current_ip="$(curl -fsS https://ipv4.icanhazip.com | tr -d '[:space:]')"
    fi

    if ! [[ "$current_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "IP 不是有效 IPv4: $current_ip" >&2
        exit 1
    fi

    zone_resp="$(cf_http_get "$(curl -sS -o /dev/null -w '%{url_effective}' -G 'https://api.cloudflare.com/client/v4/zones' --data-urlencode "name=${zone_name}")")"
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

    record_url="$(curl -sS -o /dev/null -w '%{url_effective}' -G \
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

    local my_ids=() my_contents=() my_proxieds=()
    local i
    for (( i = 0; i < ${#all_ids[@]}; i++ )); do
        if [[ -n "${origin_id:-}" ]]; then
            if [[ "${all_comments[$i]}" == "$expected_comment" ]]; then
                my_ids+=("${all_ids[$i]}")
                my_contents+=("${all_contents[$i]}")
                my_proxieds+=("${all_proxieds[$i]}")
            fi
        fi
    done

    if [[ -z "${origin_id:-}" ]]; then
        local record_content record_proxied record_identifier

        record_content="$(json_val "$record_resp" "content" result0)"
        record_proxied="$(json_val "$record_resp" "proxied" result0)"
        [[ -z "$record_proxied" ]] && record_proxied="false"

        if (( ${#all_ids[@]} == 0 )); then
            create_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":false}' "$record_name" "$current_ip")"
            create_resp="$(cf_http_body POST "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records" "$create_payload")"
            create_success="$(json_val "$create_resp" "success")"
            if [[ "$create_success" != "true" ]]; then
                echo "创建记录失败: $create_resp" >&2
                exit 1
            fi
            echo "已创建记录: $record_name -> $current_ip"
            exit 0
        fi

        record_identifier="${all_ids[0]}"

        if (( ${#all_ids[@]} > 1 )); then
            echo "检测到 ${#all_ids[@]} 条同名 A 记录，清理多余 $(( ${#all_ids[@]} - 1 )) 条"
            for (( i = 1; i < ${#all_ids[@]}; i++ )); do
                cf_http_delete "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/${all_ids[$i]}" >/dev/null
                echo "已删除重复记录: ${all_ids[$i]}"
            done
        fi

        if [[ "$record_content" == "$current_ip" && ${#all_ids[@]} -eq 1 ]]; then
            echo "记录已是目标 IPv4，无需更新: $record_name -> $current_ip"
            exit 0
        fi

        update_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":%s}' "$record_name" "$current_ip" "$record_proxied")"
        update_resp="$(cf_http_body PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" "$update_payload")"
        update_success="$(json_val "$update_resp" "success")"
        if [[ "$update_success" != "true" ]]; then
            echo "更新记录失败: $update_resp" >&2
            exit 1
        fi
        echo "已更新记录: $record_name $record_content -> $current_ip"
        exit 0
    fi

    echo "[origin:${origin_id}] 检测到 $(( ${#my_ids[@]} )) 条归属自己的记录（总 ${#all_ids[@]} 条同名 A 记录）"

    if (( ${#my_ids[@]} > 1 )); then
        echo "[origin:${origin_id}] 自己的记录重复 $(( ${#my_ids[@]} - 1 )) 条，保留第一条，清理其余"
        for (( i = 1; i < ${#my_ids[@]}; i++ )); do
            cf_http_delete "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/${my_ids[$i]}" >/dev/null
            echo "[origin:${origin_id}] 已删除自己的重复记录: ${my_ids[$i]}"
        done
    fi

    if (( ${#my_ids[@]} == 0 )); then
        if [[ -n "$expected_comment" ]]; then
            create_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":false,"comment":"%s"}' "$record_name" "$current_ip" "$expected_comment")"
        else
            create_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":false}' "$record_name" "$current_ip")"
        fi
        create_resp="$(cf_http_body POST "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records" "$create_payload")"
        create_success="$(json_val "$create_resp" "success")"
        if [[ "$create_success" != "true" ]]; then
            echo "创建记录失败: $create_resp" >&2
            exit 1
        fi
        echo "[origin:${origin_id}] 已创建记录: $record_name -> $current_ip"
        exit 0
    fi

    local my_id="${my_ids[0]}"
    local my_content="${my_contents[0]}"
    local my_proxied="${my_proxieds[0]:-false}"

    if [[ "$my_content" == "$current_ip" ]]; then
        echo "[origin:${origin_id}] 记录已是目标 IPv4，无需更新: $record_name -> $current_ip"
        exit 0
    fi

    if [[ -n "$expected_comment" ]]; then
        update_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":%s,"comment":"%s"}' "$record_name" "$current_ip" "$my_proxied" "$expected_comment")"
    else
        update_payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":%s}' "$record_name" "$current_ip" "$my_proxied")"
    fi
    update_resp="$(cf_http_body PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$my_id" "$update_payload")"
    update_success="$(json_val "$update_resp" "success")"
    if [[ "$update_success" != "true" ]]; then
        echo "更新记录失败: $update_resp" >&2
        exit 1
    fi
    echo "[origin:${origin_id}] 已更新记录: $record_name $my_content -> $current_ip"
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
        curl -fsSLo "$INSTALL_PATH" "$SCRIPT_URL"
        echo "已从 $SCRIPT_URL 下载脚本到: $INSTALL_PATH"
    fi
    chmod +x "$INSTALL_PATH"

    local cron_line existing
    if [[ -n "${cf_api_token:-}" ]]; then
        if [[ -n "${origin_id:-}" ]]; then
            cron_line="0 * * * * CF_API_TOKEN='${cf_api_token}' ORIGIN_ID='${origin_id}' /bin/bash ${INSTALL_PATH} ${zone_name} ${record_name}"
        else
            cron_line="0 * * * * CF_API_TOKEN='${cf_api_token}' /bin/bash ${INSTALL_PATH} ${zone_name} ${record_name}"
        fi
    else
        if [[ -n "${origin_id:-}" ]]; then
            cron_line="0 * * * * ORIGIN_ID='${origin_id}' /bin/bash ${INSTALL_PATH} ${auth_email} ${auth_key} ${zone_name} ${record_name}"
        else
            cron_line="0 * * * * /bin/bash ${INSTALL_PATH} ${auth_email} ${auth_key} ${zone_name} ${record_name}"
        fi
    fi

    if [[ -n "${ip:-}" ]]; then
        cron_line="${cron_line} ${ip}"
    fi

    cron_line="${cron_line} >> ${LOG_PATH} 2>&1"

    existing="$(crontab -l 2>/dev/null || true)"
    existing="$(printf '%s\n' "$existing" | grep -Fv "$INSTALL_PATH" || true)"

    (printf '%s\n' "$existing"; printf '%s\n' "$cron_line") | crontab -

    echo "已安装脚本到: $INSTALL_PATH"
    echo "已写入定时任务: 每小时整点执行一次"
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
