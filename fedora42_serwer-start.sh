#!/bin/bash
set -e

# Update system
dnf upgrade -y

# Install essentials
dnf install -y \
    dnf5-plugin-automatic \
    cockpit-navigator \
    git \
    nano \
    htop \
    wget \
    curl

# ==========================
# dnf5-automatic.timer setup
# ==========================

# Enable services
systemctl enable --now dnf5-automatic.timer

# Configure automatic updates to apply all updates
sed -i 's/^upgrade_type.*/upgrade_type = default/' /etc/dnf/automatic.conf
sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf

# Override the timer to run daily at 1:00 AM
mkdir -p /etc/systemd/system/dnf5-automatic.timer.d
cat <<EOF >/etc/systemd/system/dnf5-automatic.timer.d/override.conf
[Timer]
OnCalendar=
OnCalendar=*-*-* 01:00:00
EOF

# Reload systemd and restart timer
systemctl daemon-reload
systemctl restart dnf5-automatic.timer

#Verification
systemctl list-timers --all | grep dnf5-automatic

# ==========================
# SSH setup
# ==========================

# Configurable variables
USERNAME="deploy"                    # Non-root user
USER_PASSWORD=""                     # Optional password; leave empty for key-only login
SSH_PORT=5022                        # SSH port
SSH_DIR="/root/mykeys/deploy_ssh"    # Where to store the SSH key pair
KEY_TYPE="ed25519"                   # Key type (ed25519 recommended)

# Create non-root user if not exists
if ! id "$USERNAME" &>/dev/null; then
    useradd -m "$USERNAME"
    if [ -n "$USER_PASSWORD" ]; then
        echo "$USERNAME:$USER_PASSWORD" | chpasswd
        echo "Password set for user $USERNAME."
    else
        passwd -d "$USERNAME"  # Remove password for key-only login
        echo "Password login disabled for user $USERNAME."
    fi
    usermod -aG wheel "$USERNAME"
    echo "User $USERNAME created."
else
    echo "User $USERNAME already exists, skipping creation."
fi

# Configure SSH
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Set SSH port
sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
# Disable root login and password authentication
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

systemctl restart sshd

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

# Set correct ownership if directory is outside user home
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# Instructions for client
echo "=============================="
echo "Private key is at: $SSH_DIR/id_$KEY_TYPE"
echo "Copy this private key to your client machine (e.g., ~/.ssh/id_$KEY_TYPE)"
echo "Then login using:"
echo "ssh -i ~/.ssh/id_$KEY_TYPE -p $SSH_PORT $USERNAME@server"
echo "=============================="

# Adding firewall rule
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --reload
fi

# Final Check
systemctl restart sshd || { echo "Failed to restart sshd"; exit 1; }

# ==========================
# Last message
# ==========================
echo "Setup complete!"
