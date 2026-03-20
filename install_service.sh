#!/bin/bash

set -euo pipefail

SERVICE_NAME="marzban"
SERVICE_DESCRIPTION="Marzban Service"
SERVICE_DOCUMENTATION="https://github.com/gozargah/marzban"
MAIN_PY_PATH="$PWD/main.py"
PYTHON_PATH="${PWD}/.venv/bin/python"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

if [ ! -x "$PYTHON_PATH" ]; then
    PYTHON_PATH="/usr/bin/env python3"
fi

# Create the service file
cat > $SERVICE_FILE <<EOF
[Unit]
Description=$SERVICE_DESCRIPTION
Documentation=$SERVICE_DOCUMENTATION
After=network.target nss-lookup.target

[Service]
ExecStart=$PYTHON_PATH $MAIN_PY_PATH
Restart=on-failure
WorkingDirectory=$PWD

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "Service file created at: $SERVICE_FILE"
