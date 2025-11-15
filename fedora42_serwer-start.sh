#!/bin/bash
set -e

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# This script is tailored for Fedora Server 43
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# ==========================
# Define before use
# ==========================

# Hostname
NEW_HOSTNAME="my-server"

# SSH
USERNAME="deploy"
USER_PASSWORD=""
SSH_PORT=5022
SSH_DIR="/home/$USERNAME/.ssh"
AUTHORIZED_KEYS_URL="https://raw.githubusercontent.com/Aspoleczny777/Pub_keys/main/authorized_keys"

# ==========================
# System Update & Essentials
# ==========================
dnf upgrade -y

# Install essentials
dnf install -y \
    policycoreutils-python-utils \
    cockpit \
    nano \
    htop \
    wget \
    git \
    curl \
    dnf5-plugin-automatic \
    || true

# ==========================
# Changes hostname
# ==========================
if [ "$(hostname)" != "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    echo "Hostname changed to $NEW_HOSTNAME"
fi

# ==========================
# DNF5 Automatic Updates
# ==========================

# Enable timer
systemctl enable --now dnf5-automatic.timer

# Create DNF5 automatic configuration
mkdir -p /etc/dnf/automatic.conf.d
cat <<EOF >/etc/dnf/automatic.conf.d/00-updates.conf
[commands]
upgrade_type = default
apply_updates = yes

[emitters]
system_name = $(hostname)
emit_via = stdio
EOF

# Modify timer directly (Cockpit-friendly)
cp /usr/lib/systemd/system/dnf5-automatic.timer /etc/systemd/system/dnf5-automatic.timer
sed -i 's|OnCalendar=.*|OnCalendar=*-*-* 23:00:00|' /etc/systemd/system/dnf5-automatic.timer
systemctl daemon-reload
systemctl restart dnf5-automatic.timer

# Verification
systemctl list-timers dnf5-automatic.timer

# ==========================
# SSH Setup
# ==========================

# Create non-root user if not exists
if ! id "$USERNAME" &>/dev/null; then
    useradd -m "$USERNAME"
    if [ -n "$USER_PASSWORD" ]; then
        echo "$USERNAME:$USER_PASSWORD" | chpasswd
        echo "Password set for user $USERNAME."
    else
        passwd -d "$USERNAME"
        echo "Password login disabled for user $USERNAME."
    fi
    usermod -aG wheel "$USERNAME"
else
    echo "User $USERNAME already exists, skipping creation."
fi

# Backup SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Configure SSH
sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# SELinux: allow custom SSH port
semanage port -a -t ssh_port_t -p tcp $SSH_PORT 2>/dev/null || true

# Prepare SSH directory
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# Download authorized_keys from your GitHub repo
curl -fsSL "$AUTHORIZED_KEYS_URL" -o "$SSH_DIR/authorized_keys"

chmod 600 "$SSH_DIR/authorized_keys"
chown "$USERNAME:$USERNAME" "$SSH_DIR/authorized_keys"

echo "Downloaded authorized_keys from GitHub."

# Restart SSH
systemctl restart sshd || { echo "Failed to restart sshd"; exit 1; }

# Add firewall rule for SSH
firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
firewall-cmd --reload

# Final SSH restart check
systemctl restart sshd || { echo "Failed to restart sshd"; exit 1; }

# ==========================
# Last messages
# ==========================

echo "=============================="
echo "Authorized keys installed from GitHub."
echo "SSH now listens on port $SSH_PORT."
echo "Login using:"
echo "ssh -p $SSH_PORT $USERNAME@server"
echo "=============================="

echo "Setup complete! DNF automatic updates are scheduled."
