#!/usr/bin/env bash

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
SERVICE_NAME="${SERVICE_NAME:-marzban}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

echo "[1/5] Checking dependencies"
require_command "$PYTHON_BIN"

if [ ! -d "$VENV_DIR" ]; then
    echo "[2/5] Creating virtual environment at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    echo "[2/5] Reusing virtual environment at $VENV_DIR"
fi

echo "[3/5] Installing Python requirements"
"$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
"$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

if [ ! -f "$APP_DIR/.env" ] && [ -f "$APP_DIR/.env.example" ]; then
    echo "[4/5] Creating .env from .env.example"
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
else
    echo "[4/5] Keeping existing .env"
fi

if [ -d "$APP_DIR/app/dashboard" ] && command -v npm >/dev/null 2>&1; then
    echo "[5/5] Building dashboard"
    (
        cd "$APP_DIR/app/dashboard"
        if [ -f package-lock.json ]; then
            npm ci
        else
            npm install
        fi
        VITE_BASE_API=/api/ npm run build -- --outDir build --assetsDir statics
        cp "./build/index.html" "./build/404.html"
    )
else
    echo "[5/5] Skipping dashboard build because npm is not available"
fi

if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    echo "[service] Creating systemd unit at $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Marzban Service
Documentation=https://github.com/gozargah/marzban
After=network.target nss-lookup.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py
Restart=on-failure
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo "[service] Created. Enable with:"
    echo "systemctl enable --now $SERVICE_NAME"
else
    echo "[service] Skipped systemd unit creation"
fi

echo
echo "Install finished."
echo "Run locally with:"
echo "$VENV_DIR/bin/python $APP_DIR/main.py"
