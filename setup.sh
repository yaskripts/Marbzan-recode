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
EMAIL="${EMAIL:-}"
ENABLE_SSL="${ENABLE_SSL:-false}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
INSTALL_NODE="${INSTALL_NODE:-true}"
DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
NODE_MAJOR_REQUIRED="${NODE_MAJOR_REQUIRED:-18}"

usage() {
    cat <<EOF
Usage: sudo bash setup.sh [options]

Options:
  --domain example.com        Domain for nginx/server_name
  --email admin@example.com   Email for certbot
  --enable-ssl                Request Let's Encrypt certificate via certbot
  --admin-user admin          Dashboard username
  --admin-pass secret         Dashboard password
  --app-dir /opt/app          Install directory
  --app-user marzban          Linux user for systemd service
  --repo URL                  Git repository URL
  --branch main               Git branch
  --port 8000                 Local uvicorn port behind nginx
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
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
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

    bash -c "$(curl -fsSL https://deb.nodesource.com/setup_20.x)"
    apt-get install -y --no-install-recommends nodejs
    log "installed Node.js $(node -v) and npm $(npm -v)"
}

create_user_if_missing() {
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        log "creating system user $APP_USER"
        useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
    fi
}

clone_or_update_repo() {
    if [[ -d "$APP_DIR/.git" ]]; then
        log "updating repository in $APP_DIR"
        git -C "$APP_DIR" fetch --all --prune
        git -C "$APP_DIR" checkout "$BRANCH"
        git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
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

    subscription_prefix="http://${DOMAIN:-_}"
    if [[ "$ENABLE_SSL" == "true" && -n "$DOMAIN" ]]; then
        subscription_prefix="https://${DOMAIN}"
    elif [[ -n "$DOMAIN" ]]; then
        subscription_prefix="http://${DOMAIN}"
    fi

    allowed_origins="http://127.0.0.1,http://localhost"
    if [[ -n "$DOMAIN" ]]; then
        allowed_origins="${allowed_origins},http://${DOMAIN},https://${DOMAIN}"
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

install_python_app() {
    log "creating virtualenv and installing python dependencies"
    run_as_app "python3 -m venv '$APP_DIR/.venv'"
    run_as_app "'$APP_DIR/.venv/bin/pip' install --upgrade pip setuptools wheel"
    run_as_app "cd '$APP_DIR' && '$APP_DIR/.venv/bin/pip' install -r requirements.txt"
}

build_dashboard() {
    if [[ "$INSTALL_NODE" != "true" ]]; then
        log "skipping dashboard rebuild and using bundled app/dashboard/build"
        return
    fi

    log "building dashboard"
    run_as_app "cd '$APP_DIR/app/dashboard' && if [[ -f package-lock.json ]]; then npm ci; else npm install; fi"
    run_as_app "cd '$APP_DIR/app/dashboard' && VITE_BASE_API=/api/ npm run build -- --outDir build --assetsDir statics"
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

print_summary() {
    local protocol host
    protocol="http"
    host="${DOMAIN:-SERVER_IP}"

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
}

main() {
    require_root
    parse_args "$@"

    if ! command -v apt-get >/dev/null 2>&1; then
        die "this setup.sh currently supports Debian/Ubuntu hosts with apt-get"
    fi

    log "installing system packages"
    apt_install ca-certificates curl git nginx openssl python3 python3-pip python3-venv unzip

    if [[ "$ENABLE_SSL" == "true" ]]; then
        apt_install certbot python3-certbot-nginx
    fi

    ensure_nodejs

    create_user_if_missing
    clone_or_update_repo
    install_xray
    configure_env
    install_python_app
    build_dashboard
    run_migrations
    write_systemd_unit
    write_nginx_config
    maybe_enable_ssl
    print_summary
}

main "$@"
