#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-mtproto-proxy}"
IMAGE="${IMAGE:-arm64builds/mtproxy:latest}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PORT="${PORT:-8443}"
FAKE_DOMAIN="${FAKE_DOMAIN:-cdnjs.cloudflare.com}"
RAW_SECRET="${RAW_SECRET:-}"
OUTPUT_FILE="${OUTPUT_FILE:-$HOME/mtproxy_config.txt}"

usage() {
    cat <<EOF
Usage: bash start-mtproxy.sh [options]

Options:
  --host 1.2.3.4             Public IP or domain used by Telegram clients
  --port 8443                TCP port to expose on the host
  --domain cdn.example.com   Fake TLS domain
  --raw-secret hex           32 hex chars for the MTProxy container secret
  --container-name name      Docker container name
  --image image:tag          Docker image
  --output /path/file.txt    Where to save the generated client config
  --help                     Show this help
EOF
}

log() {
    printf '[mtproxy] %s\n' "$*"
}

die() {
    printf '[mtproxy] ERROR: %s\n' "$*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                PUBLIC_HOST="${2:-}"
                shift 2
                ;;
            --port)
                PORT="${2:-}"
                shift 2
                ;;
            --domain)
                FAKE_DOMAIN="${2:-}"
                shift 2
                ;;
            --raw-secret)
                RAW_SECRET="${2:-}"
                shift 2
                ;;
            --container-name)
                CONTAINER_NAME="${2:-}"
                shift 2
                ;;
            --image)
                IMAGE="${2:-}"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="${2:-}"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_ipv4_address() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

detect_public_host() {
    local candidate

    if [[ -n "$PUBLIC_HOST" ]]; then
        return
    fi

    for resolver in \
        "curl -4fsS --max-time 5 https://api.ipify.org" \
        "curl -4fsS --max-time 5 https://ipv4.icanhazip.com" \
        "hostname -I | awk '{print \$1}'" \
        "ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if (\$i == \"src\") {print \$(i+1); exit}}'"
    do
        candidate="$(bash -lc "$resolver" 2>/dev/null | tr -d '\r\n' || true)"
        candidate="${candidate%% *}"
        if [[ -n "$candidate" ]]; then
            PUBLIC_HOST="$candidate"
            return
        fi
    done

    die "unable to detect public host, rerun with --host"
}

ensure_raw_secret() {
    RAW_SECRET="${RAW_SECRET:-$(openssl rand -hex 16)}"
    RAW_SECRET="$(printf '%s' "$RAW_SECRET" | tr '[:upper:]' '[:lower:]')"

    if [[ ! "$RAW_SECRET" =~ ^[0-9a-f]{32}$ ]]; then
        die "--raw-secret must be exactly 32 hexadecimal characters"
    fi
}

hex_encode() {
    printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

check_port() {
    if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)$PORT$"; then
        die "TCP port ${PORT} is already in use"
    fi
}

remove_old_container() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

run_container() {
    local args=()

    docker pull "$IMAGE" >/dev/null

    args=(
        docker run -d
        --name "$CONTAINER_NAME"
        --restart unless-stopped
        -p "${PORT}:8888"
        -e "SECRET=${RAW_SECRET}"
        -e "DOMAIN=${FAKE_DOMAIN}"
        -e "HOST_PORT=${PORT}"
    )

    if is_ipv4_address "$PUBLIC_HOST"; then
        args+=(-e "PUBLIC_IP=${PUBLIC_HOST}")
    fi

    args+=("$IMAGE")
    "${args[@]}" >/dev/null
}

wait_for_container() {
    local attempt

    for attempt in {1..10}; do
        if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
            return
        fi
        sleep 1
    done

    docker logs "$CONTAINER_NAME" || true
    die "container failed to start"
}

write_output() {
    local domain_hex public_secret tg_url web_url

    domain_hex="$(hex_encode "$FAKE_DOMAIN")"
    public_secret="ee${RAW_SECRET}${domain_hex}"
    tg_url="tg://proxy?server=${PUBLIC_HOST}&port=${PORT}&secret=${public_secret}"
    web_url="https://t.me/proxy?server=${PUBLIC_HOST}&port=${PORT}&secret=${public_secret}"

    install -d -m 0755 "$(dirname "$OUTPUT_FILE")"
    cat >"$OUTPUT_FILE" <<EOF
SERVER=${PUBLIC_HOST}
PORT=${PORT}
RAW_SECRET=${RAW_SECRET}
SECRET=${public_secret}
FAKE_TLS_DOMAIN=${FAKE_DOMAIN}
TG_LINK=${tg_url}
WEB_LINK=${web_url}
IMAGE=${IMAGE}
CONTAINER_NAME=${CONTAINER_NAME}
EOF

    log "MTProxy is running"
    printf 'Server: %s\n' "$PUBLIC_HOST"
    printf 'Port: %s\n' "$PORT"
    printf 'Secret: %s\n' "$public_secret"
    printf 'Fake TLS domain: %s\n' "$FAKE_DOMAIN"
    printf 'Telegram link: %s\n' "$tg_url"
    printf 'Saved config: %s\n' "$OUTPUT_FILE"
}

main() {
    parse_args "$@"

    require_command docker
    require_command curl
    require_command openssl
    require_command ss

    detect_public_host
    ensure_raw_secret
    remove_old_container
    check_port
    run_container
    wait_for_container
    write_output
}

main "$@"
