#!/usr/bin/env bash
set -euo pipefail

echo "Setting up root-level systemd service..."

SERVICE_FILE="/etc/systemd/system/groqtype.service"
SCRIPT_PATH="/var/home/neilluo/.local/bin/GroqType/groqtype.py"
PYTHON_PATH="/usr/bin/python3"

# Create the service file using sudo
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=GroqType Daemon
After=network.target

[Service]
ExecStart=$PYTHON_PATH $SCRIPT_PATH daemon
Restart=always
User=root
Group=root
WorkingDirectory=/var/home/neilluo
# Environment for the user session (required for wl-copy/paste)
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1001
Environment=WAYLAND_DISPLAY=wayland-0
Environment=YDOTOOL_SOCKET=/run/.ydotool_socket
Environment=PATH=/var/home/neilluo/.local/bin:/usr/local/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin
# Point root to the user's python packages
Environment=PYTHONPATH=/var/home/neilluo/.local/lib/python3.14/site-packages

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now groqtype.service
echo "GroqType service is now running as ROOT."
