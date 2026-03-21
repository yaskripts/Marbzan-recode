#!/usr/bin/env bash

set -euo pipefail

if [[ "${TRACE-0}" == "1" ]]; then
    set -x
fi

APP_DIR="${APP_DIR:-/opt/marbzan-recode}"
APP_USER="${APP_USER:-marzban}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
REPO_URL="${REPO_URL:-https://github.com/yaskripts/Marbzan-recode.git}"
BRANCH="${BRANCH:-main}"
SERVICE_NAME="${SERVICE_NAME:-marzban}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_SITE_NAME="${NGINX_SITE_NAME:-$SERVICE_NAME}"
NGINX_SITE_FILE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
UVICORN_PORT="${UVICORN_PORT:-8000}"
DOMAIN="${DOMAIN:-}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
EMAIL="${EMAIL:-}"
ENABLE_SSL="${ENABLE_SSL:-false}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
INSTALL_NODE="${INSTALL_NODE:-true}"
DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
NODE_MAJOR_REQUIRED="${NODE_MAJOR_REQUIRED:-18}"
NODE_MAX_OLD_SPACE_SIZE="${NODE_MAX_OLD_SPACE_SIZE:-1536}"
SETUPTOOLS_SPEC="${SETUPTOOLS_SPEC:-setuptools<81}"
INSTALL_MTPROXY="${INSTALL_MTPROXY:-true}"
MTPROXY_PORT="${MTPROXY_PORT:-8443}"
MTPROXY_IMAGE="${MTPROXY_IMAGE:-arm64builds/mtproxy:latest}"
MTPROXY_CONTAINER_NAME="${MTPROXY_CONTAINER_NAME:-mtproto-proxy}"
MTPROXY_FAKE_TLS_DOMAIN="${MTPROXY_FAKE_TLS_DOMAIN:-cdnjs.cloudflare.com}"
MTPROXY_PUBLIC_HOST_VALUE=""
MTPROXY_INTERNAL_SECRET_VALUE="${MTPROXY_INTERNAL_SECRET_VALUE:-}"
MTPROXY_PUBLIC_SECRET_VALUE=""
INSTALL_HYSTERIA2="${INSTALL_HYSTERIA2:-true}"
HYSTERIA2_PORT="${HYSTERIA2_PORT:-8443}"
HYSTERIA2_SERVICE_NAME="${HYSTERIA2_SERVICE_NAME:-hysteria-server.service}"
HYSTERIA2_CONFIG_FILE="${HYSTERIA2_CONFIG_FILE:-/etc/hysteria/config.yaml}"
HYSTERIA2_CERT_DIR="${HYSTERIA2_CERT_DIR:-/etc/hysteria/certs}"
HYSTERIA2_CERT_FILE="${HYSTERIA2_CERT_DIR}/server.crt"
HYSTERIA2_KEY_FILE="${HYSTERIA2_CERT_DIR}/server.key"
HYSTERIA2_PUBLIC_HOST_VALUE=""
HYSTERIA2_SNI_VALUE=""
HYSTERIA2_CERT_FILE_VALUE=""
HYSTERIA2_KEY_FILE_VALUE=""
HYSTERIA2_INSECURE_VALUE="False"
HYSTERIA2_PIN_SHA256_VALUE=""
HYSTERIA2_OBFS_PASSWORD_VALUE=""
HYSTERIA2_AUTH_SECRET_VALUE=""

usage() {
    cat <<EOF
Usage: sudo bash setup.sh [options]

Options:
  --domain example.com        Domain for nginx/server_name
  --public-host 1.2.3.4      Public IP/host when installing without a domain
  --email admin@example.com   Email for certbot
  --enable-ssl                Request Let's Encrypt certificate via certbot
  --admin-user admin          Dashboard username
  --admin-pass secret         Dashboard password
  --app-dir /opt/app          Install directory
  --app-user marzban          Linux user for systemd service
  --repo URL                  Git repository URL
  --branch main               Git branch
  --port 8000                 Local uvicorn port behind nginx
  --mtproxy-port 8443         TCP port for standalone MTProxy with Fake TLS
  --mtproxy-domain host       Fake TLS domain for MTProxy
  --disable-mtproxy           Skip MTProxy installation/configuration
  --hysteria2-port 8443       UDP port for Hysteria2
  --disable-hysteria2         Skip Hysteria2 installation/configuration
  --no-node                   Skip node/npm installation and dashboard rebuild
  --help                      Show this help
EOF
}

log() {
    printf '[setup] %s\n' "$*"
}

die() {
    printf '[setup] ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "run this script as root"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                DOMAIN="${2:-}"
                shift 2
                ;;
            --public-host)
                PUBLIC_HOST="${2:-}"
                shift 2
                ;;
            --email)
                EMAIL="${2:-}"
                shift 2
                ;;
            --enable-ssl)
                ENABLE_SSL=true
                shift
                ;;
            --admin-user)
                ADMIN_USERNAME="${2:-}"
                shift 2
                ;;
            --admin-pass)
                ADMIN_PASSWORD="${2:-}"
                shift 2
                ;;
            --app-dir)
                APP_DIR="${2:-}"
                shift 2
                ;;
            --app-user)
                APP_USER="${2:-}"
                APP_GROUP="$APP_USER"
                shift 2
                ;;
            --repo)
                REPO_URL="${2:-}"
                shift 2
                ;;
            --branch)
                BRANCH="${2:-}"
                shift 2
                ;;
            --port)
                UVICORN_PORT="${2:-}"
                shift 2
                ;;
            --mtproxy-port)
                MTPROXY_PORT="${2:-}"
                shift 2
                ;;
            --mtproxy-domain)
                MTPROXY_FAKE_TLS_DOMAIN="${2:-}"
                shift 2
                ;;
            --disable-mtproxy)
                INSTALL_MTPROXY=false
                shift
                ;;
            --hysteria2-port)
                HYSTERIA2_PORT="${2:-}"
                shift 2
                ;;
            --disable-hysteria2)
                INSTALL_HYSTERIA2=false
                shift
                ;;
            --no-node)
                INSTALL_NODE=false
                shift
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

random_password() {
    openssl rand -hex 12
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
            log "using public host ${PUBLIC_HOST}"
            return
        fi
    done
}

run_as_app() {
    su -s /bin/bash "$APP_USER" -c "$*"
}

apt_install() {
    if [[ "$APT_UPDATED" -eq 0 ]]; then
        apt-get update
        APT_UPDATED=1
    fi
    apt-get install -y --no-install-recommends "$@"
}

is_ipv4_address() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

hex_encode() {
    printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

repair_package_manager() {
    log "repairing dpkg/apt state"
    dpkg --configure -a || true
    apt-get -f install -y
}

purge_legacy_node_packages() {
    log "removing legacy Node.js packages that conflict with NodeSource"
    apt-get purge -y nodejs npm libnode-dev nodejs-doc || true
    apt-get -f install -y
    apt-get autoremove -y
}

ensure_nodejs() {
    local node_major

    if [[ "$INSTALL_NODE" != "true" ]]; then
        return
    fi

    if command -v node >/dev/null 2>&1; then
        node_major="$(node -p 'process.versions.node.split(".")[0]')"
        if [[ "$node_major" -ge "$NODE_MAJOR_REQUIRED" ]]; then
            log "using existing Node.js $(node -v)"
            return
        fi

        log "existing Node.js $(node -v) is too old, upgrading to Node.js 20"
    else
        log "installing Node.js 20"
    fi

    purge_legacy_node_packages
    bash -c "$(curl -fsSL https://deb.nodesource.com/setup_20.x)"
    apt-get install -y --no-install-recommends nodejs
    log "installed Node.js $(node -v) and npm $(npm -v)"
}

install_docker() {
    if [[ "$INSTALL_MTPROXY" != "true" ]]; then
        return
    fi

    log "installing Docker for standalone MTProxy"
    apt_install docker.io
    systemctl enable --now docker
}

create_user_if_missing() {
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        log "creating system user $APP_USER"
        useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
    fi
}

git_repo() {
    git -c safe.directory="$APP_DIR" -C "$APP_DIR" "$@"
}

backup_local_repo_file_if_dirty() {
    local rel_path="$1"
    local source_path backup_path timestamp

    source_path="$APP_DIR/$rel_path"
    if [[ ! -f "$source_path" ]]; then
        return
    fi

    if git_repo diff --quiet -- "$rel_path"; then
        return
    fi

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_path="${source_path}.pre-update.${timestamp}.bak"
    cp "$source_path" "$backup_path"
    log "backed up local ${rel_path} to ${backup_path}"
    git_repo checkout -- "$rel_path"
}

clone_or_update_repo() {
    if [[ -d "$APP_DIR/.git" ]]; then
        log "updating repository in $APP_DIR"
        backup_local_repo_file_if_dirty "xray_config.json"
        git_repo fetch --all --prune
        git_repo checkout "$BRANCH"
        git_repo pull --ff-only origin "$BRANCH"
    else
        log "cloning repository into $APP_DIR"
        rm -rf "$APP_DIR"
        git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
    fi

    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
}

install_xray() {
    log "installing/updating Xray"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

install_hysteria2_binary() {
    if [[ "$INSTALL_HYSTERIA2" != "true" ]]; then
        return
    fi

    log "installing/updating Hysteria2"
    bash -c "$(curl -fsSL https://get.hy2.sh/)"
}

set_env_value() {
    local key="$1"
    local value="$2"
    local env_file="$APP_DIR/.env"
    local escaped_value

    escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"

    if grep -Eq "^[# ]*${key}[[:space:]]*=" "$env_file"; then
        sed -i "s|^[# ]*${key}[[:space:]]*=.*|${key}=${escaped_value}|" "$env_file"
    else
        printf '%s=%s\n' "$key" "$value" >>"$env_file"
    fi
}

configure_env() {
    local subscription_prefix allowed_origins

    if [[ ! -f "$APP_DIR/.env" ]]; then
        cp "$APP_DIR/.env.example" "$APP_DIR/.env"
        chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"
    fi

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD="$(random_password)"
    fi

    if [[ "$ENABLE_SSL" == "true" && -z "$DOMAIN" ]]; then
        die "--enable-ssl requires --domain"
    fi

    if [[ -z "$DOMAIN" ]]; then
        detect_public_host
        [[ -n "$PUBLIC_HOST" ]] || die "unable to detect public host, rerun setup.sh with --public-host <server-ip>"
    fi

    subscription_prefix="http://${PUBLIC_HOST:-$DOMAIN}"
    if [[ "$ENABLE_SSL" == "true" && -n "$DOMAIN" ]]; then
        subscription_prefix="https://${DOMAIN}"
    elif [[ -n "$DOMAIN" ]]; then
        subscription_prefix="http://${DOMAIN}"
    fi

    allowed_origins="http://127.0.0.1,http://localhost"
    if [[ -n "$DOMAIN" ]]; then
        allowed_origins="${allowed_origins},http://${DOMAIN},https://${DOMAIN}"
    elif [[ -n "$PUBLIC_HOST" ]]; then
        allowed_origins="${allowed_origins},http://${PUBLIC_HOST}"
    fi

    set_env_value "UVICORN_HOST" "127.0.0.1"
    set_env_value "UVICORN_PORT" "$UVICORN_PORT"
    set_env_value "DEBUG" "False"
    set_env_value "SUDO_USERNAME" "$ADMIN_USERNAME"
    set_env_value "SUDO_PASSWORD" "$ADMIN_PASSWORD"
    set_env_value "XRAY_EXECUTABLE_PATH" "/usr/local/bin/xray"
    set_env_value "XRAY_ASSETS_PATH" "/usr/local/share/xray"
    set_env_value "XRAY_SUBSCRIPTION_URL_PREFIX" "\"${subscription_prefix}\""
    set_env_value "ALLOWED_ORIGINS" "\"${allowed_origins}\""

    chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"
}

configure_mtproxy_env() {
    local host domain_hex

    if [[ "$INSTALL_MTPROXY" != "true" ]]; then
        set_env_value "MTPROXY_ENABLED" "False"
        return
    fi

    host="${DOMAIN:-$PUBLIC_HOST}"
    [[ -n "$host" ]] || die "unable to determine host for MTProxy"

    MTPROXY_PUBLIC_HOST_VALUE="$host"
    MTPROXY_FAKE_TLS_DOMAIN="${MTPROXY_FAKE_TLS_DOMAIN:-cdnjs.cloudflare.com}"
    MTPROXY_INTERNAL_SECRET_VALUE="${MTPROXY_INTERNAL_SECRET_VALUE:-$(openssl rand -hex 16)}"
    MTPROXY_INTERNAL_SECRET_VALUE="$(printf '%s' "$MTPROXY_INTERNAL_SECRET_VALUE" | tr '[:upper:]' '[:lower:]')"
    domain_hex="$(hex_encode "$MTPROXY_FAKE_TLS_DOMAIN")"
    [[ -n "$domain_hex" ]] || die "unable to generate MTProxy Fake TLS domain hex"
    MTPROXY_PUBLIC_SECRET_VALUE="ee${MTPROXY_INTERNAL_SECRET_VALUE}${domain_hex}"

    set_env_value "MTPROXY_ENABLED" "True"
    set_env_value "MTPROXY_NAME" "Telegram Proxy"
    set_env_value "MTPROXY_PUBLIC_HOST" "$MTPROXY_PUBLIC_HOST_VALUE"
    set_env_value "MTPROXY_PORT" "$MTPROXY_PORT"
    set_env_value "MTPROXY_SECRET" "$MTPROXY_PUBLIC_SECRET_VALUE"
    set_env_value "MTPROXY_RAW_SECRET" "$MTPROXY_INTERNAL_SECRET_VALUE"
    set_env_value "MTPROXY_FAKE_TLS_DOMAIN" "$MTPROXY_FAKE_TLS_DOMAIN"

    chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"
}

install_mtproxy() {
    if [[ "$INSTALL_MTPROXY" != "true" ]]; then
        return
    fi

    log "starting standalone MTProxy on TCP ${MTPROXY_PORT}"
    bash "$APP_DIR/start-mtproxy.sh" \
        --host "$MTPROXY_PUBLIC_HOST_VALUE" \
        --port "$MTPROXY_PORT" \
        --domain "$MTPROXY_FAKE_TLS_DOMAIN" \
        --container-name "$MTPROXY_CONTAINER_NAME" \
        --image "$MTPROXY_IMAGE" \
        --raw-secret "$MTPROXY_INTERNAL_SECRET_VALUE" \
        --output "$APP_DIR/mtproxy_config.txt"

    chown "$APP_USER:$APP_GROUP" "$APP_DIR/mtproxy_config.txt"
}

compute_hysteria2_pin() {
    local cert_file="$1"
    openssl x509 -in "$cert_file" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d '\r\n'
}

generate_hysteria2_self_signed_cert() {
    local host="$1"
    local san
    local openssl_config

    install -d -m 0755 "$HYSTERIA2_CERT_DIR"

    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        san="IP:${host}"
    else
        san="DNS:${host}"
    fi

    log "generating self-signed certificate for Hysteria2 (${host})"
    openssl_config="$(mktemp)"
    cat >"$openssl_config" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${host}

[v3_req]
subjectAltName = ${san}
EOF

    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HYSTERIA2_KEY_FILE" \
        -out "$HYSTERIA2_CERT_FILE" \
        -days 3650 \
        -config "$openssl_config" \
        -extensions v3_req >/dev/null 2>&1
    rm -f "$openssl_config"
}

configure_hysteria2_env() {
    local host letsencrypt_dir

    if [[ "$INSTALL_HYSTERIA2" != "true" ]]; then
        set_env_value "HYSTERIA2_ENABLED" "False"
        return
    fi

    host="${DOMAIN:-$PUBLIC_HOST}"
    [[ -n "$host" ]] || die "unable to determine host for Hysteria2"

    HYSTERIA2_PUBLIC_HOST_VALUE="$host"
    HYSTERIA2_SNI_VALUE="$host"

    letsencrypt_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -n "$DOMAIN" && -f "${letsencrypt_dir}/fullchain.pem" && -f "${letsencrypt_dir}/privkey.pem" ]]; then
        HYSTERIA2_CERT_FILE_VALUE="${letsencrypt_dir}/fullchain.pem"
        HYSTERIA2_KEY_FILE_VALUE="${letsencrypt_dir}/privkey.pem"
        HYSTERIA2_INSECURE_VALUE="False"
    else
        generate_hysteria2_self_signed_cert "$host"
        HYSTERIA2_CERT_FILE_VALUE="$HYSTERIA2_CERT_FILE"
        HYSTERIA2_KEY_FILE_VALUE="$HYSTERIA2_KEY_FILE"
        HYSTERIA2_INSECURE_VALUE="True"
    fi

    HYSTERIA2_PIN_SHA256_VALUE="$(compute_hysteria2_pin "$HYSTERIA2_CERT_FILE_VALUE")"
    HYSTERIA2_OBFS_PASSWORD_VALUE="${HYSTERIA2_OBFS_PASSWORD_VALUE:-$(random_password)}"
    HYSTERIA2_AUTH_SECRET_VALUE="${HYSTERIA2_AUTH_SECRET_VALUE:-$(openssl rand -hex 16)}"

    set_env_value "HYSTERIA2_ENABLED" "True"
    set_env_value "HYSTERIA2_PUBLIC_HOST" "$HYSTERIA2_PUBLIC_HOST_VALUE"
    set_env_value "HYSTERIA2_PORT" "$HYSTERIA2_PORT"
    set_env_value "HYSTERIA2_SNI" "$HYSTERIA2_SNI_VALUE"
    set_env_value "HYSTERIA2_INSECURE" "$HYSTERIA2_INSECURE_VALUE"
    set_env_value "HYSTERIA2_PIN_SHA256" "$HYSTERIA2_PIN_SHA256_VALUE"
    set_env_value "HYSTERIA2_OBFS_PASSWORD" "$HYSTERIA2_OBFS_PASSWORD_VALUE"
    set_env_value "HYSTERIA2_AUTH_SECRET" "$HYSTERIA2_AUTH_SECRET_VALUE"
    set_env_value "HYSTERIA2_TLS_CERT" "$HYSTERIA2_CERT_FILE_VALUE"
    set_env_value "HYSTERIA2_TLS_KEY" "$HYSTERIA2_KEY_FILE_VALUE"
    set_env_value "HYSTERIA2_CLIENT_UP_Mbps" "100"
    set_env_value "HYSTERIA2_CLIENT_DOWN_Mbps" "100"

    chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"
}

install_python_app() {
    log "creating virtualenv and installing python dependencies"
    run_as_app "python3 -m venv '$APP_DIR/.venv'"
    run_as_app "'$APP_DIR/.venv/bin/pip' install --upgrade pip wheel '$SETUPTOOLS_SPEC'"
    run_as_app "cd '$APP_DIR' && '$APP_DIR/.venv/bin/pip' install -r requirements.txt"

    if ! run_as_app "'$APP_DIR/.venv/bin/python' -c 'import pkg_resources'"; then
        log "pkg_resources is missing, reinstalling setuptools compatibility package"
        run_as_app "'$APP_DIR/.venv/bin/pip' install --force-reinstall '$SETUPTOOLS_SPEC'"
        run_as_app "'$APP_DIR/.venv/bin/python' -c 'import pkg_resources'"
    fi
}

build_dashboard() {
    if [[ "$INSTALL_NODE" != "true" ]]; then
        log "skipping dashboard rebuild and using bundled app/dashboard/build"
        return
    fi

    log "building dashboard"
    run_as_app "cd '$APP_DIR/app/dashboard' && if [[ -f package-lock.json ]]; then npm ci; else npm install; fi"

    if ! run_as_app "cd '$APP_DIR/app/dashboard' && NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE} VITE_BASE_API=/api/ npm run build -- --outDir build --assetsDir statics"; then
        if [[ -f "$APP_DIR/app/dashboard/build/index.html" ]]; then
            log "dashboard build failed, using bundled app/dashboard/build"
        else
            die "dashboard build failed and no bundled app/dashboard/build is available"
        fi
    fi

    run_as_app "cp '$APP_DIR/app/dashboard/build/index.html' '$APP_DIR/app/dashboard/build/404.html'"
}

run_migrations() {
    log "running database migrations"
    run_as_app "cd '$APP_DIR' && DEBUG=False '$APP_DIR/.venv/bin/alembic' upgrade head"
}

write_systemd_unit() {
    log "writing systemd unit ${SERVICE_NAME}.service"
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Marzban Recode
After=network.target nss-lookup.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
Environment=DEBUG=False
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
}

write_nginx_config() {
    local server_name
    server_name="${DOMAIN:-_}"

    log "writing nginx config ${NGINX_SITE_FILE}"
    cat >"$NGINX_SITE_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${server_name};

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:${UVICORN_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600;
    }
}
EOF

    ln -sf "$NGINX_SITE_FILE" "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
}

maybe_enable_ssl() {
    if [[ "$ENABLE_SSL" != "true" ]]; then
        return
    fi

    [[ -n "$DOMAIN" ]] || die "--enable-ssl requires --domain"
    [[ -n "$EMAIL" ]] || die "--enable-ssl requires --email"

    log "requesting Let's Encrypt certificate"
    certbot --nginx --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN" --redirect
}

write_hysteria2_config() {
    if [[ "$INSTALL_HYSTERIA2" != "true" ]]; then
        return
    fi

    log "writing Hysteria2 config ${HYSTERIA2_CONFIG_FILE}"
    install -d -m 0755 "$(dirname "$HYSTERIA2_CONFIG_FILE")" "$HYSTERIA2_CERT_DIR"

    cat >"$HYSTERIA2_CONFIG_FILE" <<EOF
listen: :${HYSTERIA2_PORT}

tls:
  cert: ${HYSTERIA2_CERT_FILE_VALUE}
  key: ${HYSTERIA2_KEY_FILE_VALUE}

auth:
  type: http
  http:
    url: http://127.0.0.1:${UVICORN_PORT}/api/hysteria2/${HYSTERIA2_AUTH_SECRET_VALUE}/auth

masquerade:
  type: string
  string:
    content: "404 page not found"
    statusCode: 404

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false
udpIdleTimeout: 120s

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF

    if [[ -n "$HYSTERIA2_OBFS_PASSWORD_VALUE" ]]; then
        cat >>"$HYSTERIA2_CONFIG_FILE" <<EOF

obfs:
  type: salamander
  salamander:
    password: ${HYSTERIA2_OBFS_PASSWORD_VALUE}
EOF
    fi
}

write_hysteria2_sysctl() {
    if [[ "$INSTALL_HYSTERIA2" != "true" ]]; then
        return
    fi

    log "applying UDP buffer tuning for Hysteria2"
    cat >/etc/sysctl.d/99-hysteria2.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl --system >/dev/null
}

enable_hysteria2_service() {
    if [[ "$INSTALL_HYSTERIA2" != "true" ]]; then
        return
    fi

    systemctl enable --now "$HYSTERIA2_SERVICE_NAME"
    systemctl restart "$HYSTERIA2_SERVICE_NAME"
}

print_summary() {
    local protocol host
    protocol="http"
    host="${DOMAIN:-${PUBLIC_HOST:-SERVER_IP}}"

    if [[ "$ENABLE_SSL" == "true" && -n "$DOMAIN" ]]; then
        protocol="https"
    fi

    cat <<EOF

Setup complete.

Repository: $REPO_URL
Branch:     $BRANCH
Directory:  $APP_DIR
Service:    $SERVICE_NAME
Dashboard:  ${protocol}://${host}/dashboard/
Admin user: $ADMIN_USERNAME
Admin pass: $ADMIN_PASSWORD
Useful commands:
  systemctl status $SERVICE_NAME
  journalctl -u $SERVICE_NAME -f
  nginx -t
EOF

    if [[ "$INSTALL_MTPROXY" == "true" ]]; then
        cat <<EOF
MTProxy:    tg://proxy?server=${MTPROXY_PUBLIC_HOST_VALUE}&port=${MTPROXY_PORT}&secret=${MTPROXY_PUBLIC_SECRET_VALUE} (TCP)
  Fake TLS: ${MTPROXY_FAKE_TLS_DOMAIN}
  docker logs --tail 20 ${MTPROXY_CONTAINER_NAME}
EOF
    fi

    if [[ "$INSTALL_HYSTERIA2" == "true" ]]; then
        cat <<EOF
Hysteria2:  hy2://${host}:${HYSTERIA2_PORT} (UDP)
  systemctl status $HYSTERIA2_SERVICE_NAME
  journalctl -u $HYSTERIA2_SERVICE_NAME -f
EOF
    fi
}

main() {
    require_root
    parse_args "$@"

    if ! command -v apt-get >/dev/null 2>&1; then
        die "this setup.sh currently supports Debian/Ubuntu hosts with apt-get"
    fi

    if [[ "$ENABLE_SSL" == "true" && -z "$DOMAIN" ]]; then
        die "--enable-ssl requires --domain"
    fi

    repair_package_manager

    log "installing system packages"
    apt_install ca-certificates curl git nginx openssl python3 python3-pip python3-venv unzip

    if [[ "$ENABLE_SSL" == "true" ]]; then
        apt_install certbot python3-certbot-nginx
    fi

    ensure_nodejs
    install_docker

    create_user_if_missing
    clone_or_update_repo
    install_xray
    configure_env
    configure_mtproxy_env
    install_mtproxy
    install_python_app
    build_dashboard
    run_migrations
    write_systemd_unit
    write_nginx_config
    maybe_enable_ssl
    install_hysteria2_binary
    configure_hysteria2_env
    log "restarting ${SERVICE_NAME}"
    systemctl restart "$SERVICE_NAME"
    write_hysteria2_config
    write_hysteria2_sysctl
    log "restarting ${HYSTERIA2_SERVICE_NAME}"
    enable_hysteria2_service
    print_summary
}

main "$@"
