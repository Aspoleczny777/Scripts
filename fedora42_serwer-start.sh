#!/bin/bash
set -e

# ==========================
# Define before use
# ==========================

# Hostname
NEW_HOSTNAME="my-server"

# SSH
USERNAME="deploy"
USER_PASSWORD=""
SSH_PORT=5022
SSH_DIR="/root/mykeys/deploy_ssh"
KEY_TYPE="ed25519"

# ==========================
# System Update & Essentials
# ==========================
dnf upgrade -y
dnf update -y

# Install essentials
dnf install -y policycoreutils-python-utils cockpit-navigator nano htop wget git curl dnf5-plugin-automatic

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
    echo "User $USERNAME created."
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

# Restart SSH
systemctl restart sshd || { echo "Failed to restart sshd"; exit 1; }

# Generate SSH key pair
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$SSH_DIR/id_$KEY_TYPE" ]; then
    ssh-keygen -t "$KEY_TYPE" -f "$SSH_DIR/id_$KEY_TYPE" -N "" -C "$USERNAME@server"
    echo "SSH key pair generated at $SSH_DIR."
else
    echo "SSH key pair already exists at $SSH_DIR, skipping generation."
fi

chmod 600 "$SSH_DIR/id_$KEY_TYPE"
chmod 644 "$SSH_DIR/id_$KEY_TYPE.pub"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# Add firewall rule for SSH
firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
firewall-cmd --reload

# Final SSH restart check
systemctl restart sshd || { echo "Failed to restart sshd"; exit 1; }

# ==========================
# Last messages
# ==========================

# Instructions for client
echo "=============================="
echo "Private key is at: $SSH_DIR/id_$KEY_TYPE"
echo "Copy this private key to your client machine (e.g., ~/.ssh/id_$KEY_TYPE)"
echo "Then login using:"
echo "ssh -i ~/.ssh/id_$KEY_TYPE -p $SSH_PORT $USERNAME@server"
echo "=============================="

echo "Setup complete! DNF automatic updates are scheduled at $DNF_AUTO_TIME"
