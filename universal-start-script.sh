#!/bin/bash
set -euo pipefail

# ==========================
# Universal Linux Server Setup (Hardened)
# Supports: Fedora/RHEL/Alma/Rocky, Ubuntu/Debian, Proxmox VE
# ==========================

# ---------- Configuration ----------
NEW_HOSTNAME="my-server"
USERNAME="deploy"
USER_PASSWORD=""  # Leave empty to disable password login
SSH_PORT=5022
AUTHORIZED_KEYS_URL="https://raw.githubusercontent.com/Aspoleczny777/Pub_keys/main/authorized_keys"

# Optional: expected SHA256 of authorized_keys (leave empty to skip check)
AUTHORIZED_KEYS_SHA256=""

# ---------- Base Checks ----------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "Unsupported system: /etc/os-release missing"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required. Install it first."
    exit 1
fi

# ---------- OS Detection ----------
source /etc/os-release
DISTRO_ID="${ID,,}"
IS_PROXMOX=0

# Detect Proxmox reliably
if [[ -d /etc/pve ]] && command -v pveversion >/dev/null 2>&1; then
    DISTRO_ID="proxmox"
    IS_PROXMOX=1
fi

# ---------- Proxmox Repo & Nag Fix ----------
if [[ "$IS_PROXMOX" -eq 1 ]]; then
    echo "Configuring Proxmox No-Subscription repositories..."

    # Disable enterprise repo
    if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
        sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/pve-enterprise.list
    fi

    CODENAME="${VERSION_CODENAME:-bookworm}"

    # Add no-subscription repo if missing
    if ! grep -q "pve-no-subscription" /etc/apt/sources.list; then
        echo "deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription" >> /etc/apt/sources.list
    fi

    # Disable subscription nag (best-effort, non-fatal)
    PVE_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    if [[ -f "$PVE_JS" ]]; then
        cp "$PVE_JS" "${PVE_JS}.bak" || true
        sed -Ezi \
            "s/Ext\.Msg\.show\(\{\s+title: 'No valid subscription'/void\(\{\s+title: 'No valid subscription'/g" \
            "$PVE_JS" || true
    fi
fi

# ---------- OS-Specific Configs ----------
case "$DISTRO_ID" in
    fedora|rhel|centos|rocky|almalinux)
        PKG_MGR="dnf"
        PKG_UPDATE=(dnf -y upgrade --refresh)
        PKG_INSTALL=(dnf -y install)
        FIREWALL_BACKEND="firewalld"
        SSH_SERVICE="sshd"
        SUDO_GROUP="wheel"
        SELINUX_ENABLED=1
        ;;
    ubuntu|debian)
        PKG_MGR="apt"
        PKG_UPDATE=(bash -c "apt update -qq && apt upgrade -y -qq")
        PKG_INSTALL=(apt install -y)
        FIREWALL_BACKEND="ufw"
        SSH_SERVICE="ssh"
        SUDO_GROUP="sudo"
        SELINUX_ENABLED=0
        ;;
    proxmox)
        PKG_MGR="apt"
        PKG_UPDATE=(bash -c "apt update -qq && apt upgrade -y -qq")
        PKG_INSTALL=(apt install -y)
        FIREWALL_BACKEND="none"
        SSH_SERVICE="ssh"
        SUDO_GROUP="sudo"
        SELINUX_ENABLED=0
        ;;
    *)
        echo "Unsupported distro: $ID"
        exit 1
        ;;
esac

echo "Detected system: $PRETTY_NAME"

# ---------- System Update & Prerequisites ----------
echo "Updating system and installing prerequisites..."
"${PKG_UPDATE[@]}"

if [[ "$PKG_MGR" == "dnf" ]]; then
    "${PKG_INSTALL[@]}" policycoreutils-python-utils nano htop wget git curl dnf-automatic
elif [[ "$IS_PROXMOX" -eq 1 ]]; then
    "${PKG_INSTALL[@]}" nano htop wget git curl
else
    "${PKG_INSTALL[@]}" nano htop wget git curl unattended-upgrades
fi

# ---------- Disable IPv6 for SSH ----------
echo "Disabling IPv6 for SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.pre-change.bak" 2>/dev/null || true

# Ensure AddressFamily line exists and is set to inet
if grep -qE '^[#[:space:]]*AddressFamily' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*AddressFamily.*/AddressFamily inet/' "$SSHD_CONFIG"
else
    echo "AddressFamily inet" >> "$SSHD_CONFIG"
fi

# Ensure ListenAddress IPv4 line exists
if grep -qE '^[#[:space:]]*ListenAddress' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*ListenAddress.*/ListenAddress 0.0.0.0/' "$SSHD_CONFIG"
else
    echo "ListenAddress 0.0.0.0" >> "$SSHD_CONFIG"
fi

# ---------- Hostname Fix ----------
CURRENT_HOSTNAME="$(hostname)"
if [[ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"

    # Ensure /etc/hosts has a sane entry
    if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
        echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    fi

    # Replace old hostname safely (escape for sed)
    ESC_CURRENT_HOSTNAME=$(printf '%s\n' "$CURRENT_HOSTNAME" | sed 's/[.[\*^$()+?{}|\\/]/\\&/g')
    ESC_NEW_HOSTNAME=$(printf '%s\n' "$NEW_HOSTNAME" | sed 's/[.[\*^$()+?{}|\\/]/\\&/g')
    sed -i "s/\b$ESC_CURRENT_HOSTNAME\b/$ESC_NEW_HOSTNAME/g" /etc/hosts || true

    echo "Hostname set to $NEW_HOSTNAME"
fi

# ---------- Automatic Updates ----------
echo "Configuring automatic updates..."
if [[ "$PKG_MGR" == "dnf" ]]; then
    systemctl enable --now dnf-automatic.timer || true
    TIMER_SRC="$(systemctl show -p FragmentPath dnf-automatic.timer 2>/dev/null | cut -d= -f2 || true)"
    if [[ -n "$TIMER_SRC" && -f "$TIMER_SRC" ]]; then
        mkdir -p /etc/systemd/system
        cp "$TIMER_SRC" /etc/systemd/system/dnf-automatic.timer
        sed -i 's|^OnCalendar=.*|OnCalendar=*-*-* 23:00:00|' /etc/systemd/system/dnf-automatic.timer
        systemctl daemon-reload
        systemctl enable --now dnf-automatic.timer || true
    else
        echo "Warning: Could not locate dnf-automatic.timer unit; leaving default timer configuration."
    fi
elif [[ "$IS_PROXMOX" -eq 0 ]]; then
    systemctl enable --now unattended-upgrades || true
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
fi

# ---------- User Creation ----------
if ! id "$USERNAME" &>/dev/null; then
    echo "Creating user $USERNAME"
    useradd -m -s /bin/bash "$USERNAME"
    if [[ -n "$USER_PASSWORD" ]]; then
        echo "$USERNAME:$USER_PASSWORD" | chpasswd
    else
        passwd -d "$USERNAME"
    fi
    usermod -aG "$SUDO_GROUP" "$USERNAME"
    echo "User $USERNAME created successfully"
else
    echo "User $USERNAME already exists"
fi

# ---------- SSH Configuration (with rollback protection) ----------
echo "Configuring SSH on port $SSH_PORT..."

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak" 2>/dev/null || true

# Port
if grep -qE '^[#[:space:]]*Port' "$SSHD_CONFIG"; then
    sed -i "s/^[#[:space:]]*Port.*/Port $SSH_PORT/" "$SSHD_CONFIG"
else
    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
fi

# Root login
if grep -qE '^[#[:space:]]*PermitRootLogin' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
else
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
fi

# Password auth
if grep -qE '^[#[:space:]]*PasswordAuthentication' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
else
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
fi

# Pubkey auth
if grep -qE '^[#[:space:]]*PubkeyAuthentication' "$SSHD_CONFIG"; then
    sed -i 's/^[#[:space:]]*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
else
    echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
fi

# ---------- SSH Keys ----------
SSH_DIR="/home/$USERNAME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

echo "Downloading authorized keys..."
TMP_KEYS="$(mktemp)"
if ! curl -fsSL "$AUTHORIZED_KEYS_URL" -o "$TMP_KEYS"; then
    echo "CRITICAL: Failed to download SSH keys. Aborting."
    rm -f "$TMP_KEYS"
    # Restore sshd_config if we changed it
    cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG" 2>/dev/null || true
    exit 1
fi

# Optional integrity check
if [[ -n "$AUTHORIZED_KEYS_SHA256" ]]; then
    DOWNLOADED_SHA256="$(sha256sum "$TMP_KEYS" | awk '{print $1}')"
    if [[ "$DOWNLOADED_SHA256" != "$AUTHORIZED_KEYS_SHA256" ]]; then
        echo "CRITICAL: authorized_keys SHA256 mismatch. Aborting."
        rm -f "$TMP_KEYS"
        cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG" 2>/dev/null || true
        exit 1
    fi
fi

if ! grep -qE "ssh-(rsa|ed25519|ecdsa)" "$TMP_KEYS"; then
    echo "CRITICAL: No valid SSH keys found in downloaded file. Aborting."
    rm -f "$TMP_KEYS"
    cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG" 2>/dev/null || true
    exit 1
fi

mv "$TMP_KEYS" "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$USERNAME":"$USERNAME" "$SSH_DIR"

# ---------- Firewall ----------
echo "Configuring firewall..."
case "$FIREWALL_BACKEND" in
    firewalld)
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="$SSH_PORT/tcp" || true
            firewall-cmd --reload || true
            echo "firewalld: Port $SSH_PORT/tcp opened"
        else
            echo "Warning: firewalld not active; no firewall rule added."
        fi
        ;;
    ufw)
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "$SSH_PORT/tcp" || true
            ufw --force enable 2>/dev/null || true
            echo "ufw: Port $SSH_PORT/tcp opened"
        else
            echo "Warning: ufw not installed; no firewall rule added."
        fi
        ;;
    none)
        echo "Proxmox detected — NO firewall changes made (Proxmox firewall untouched)"
        ;;
esac

# ---------- SSH Restart with Rollback ----------
echo "Restarting SSH service with safety check..."
if ! systemctl restart "$SSH_SERVICE"; then
    echo "ERROR: Failed to restart $SSH_SERVICE. Restoring previous sshd_config."
    cp "${SSHD_CONFIG}.bak" "$SSHD_CONFIG" 2>/dev/null || true
    systemctl restart "$SSH_SERVICE" || true
    echo "Aborting to avoid lockout."
    exit 1
fi

# ---------- Final Status ----------
echo "================================="
echo "✓ Setup complete!"
echo "✓ Hostname: $NEW_HOSTNAME"
echo "✓ SSH: ssh -p $SSH_PORT $USERNAME@$NEW_HOSTNAME (IPv6 DISABLED)"
echo "✓ SSH hardened: No root/password, keys only"
if [[ "$PKG_MGR" == "dnf" ]]; then
    echo "✓ Auto-updates: dnf-automatic (23:00, if timer unit found)"
elif [[ "$IS_PROXMOX" -eq 1 ]]; then
    echo "✓ Auto-updates: disabled (Proxmox-safe)"
    echo "✓ Firewall: Proxmox firewall UNTOUCHED"
else
    echo "✓ Auto-updates: unattended-upgrades"
    echo "✓ Firewall: Port $SSH_PORT/tcp open (if backend available)"
fi
echo "================================="
echo "Connect with: ssh -p $SSH_PORT $USERNAME@$NEW_HOSTNAME"