#!/bin/bash
# Script to install and configure unattended-upgrades

set -e

EMAIL="mazur.informatyka@gmail.com"
REBOOT_TIME="06:00"
UPGRADE_TIMER="*-*-* 5:00"

# Updating package cache
apt update -y

# Installing unattended-upgrades
apt install -y unattended-upgrades

# Enabling unattended-upgrades
dpkg-reconfigure --priority=low unattended-upgrades

# Starting and enabling unattended-upgrades service
systemctl enable --now unattended-upgrades

# Configuring /etc/apt/apt.conf.d/20auto-upgrades (ensure options set to 1)
# Ensure both periodic update and upgrade are enabled
cat <<EOF >/etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Copying 50unattended-upgrades to 99unattended-upgrades
cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/99unattended-upgrades

# Editing 99unattended-upgrades
# Use sed to uncomment and update necessary values
sed -i \
    -e "s|^//Unattended-Upgrade::AutoFixInterruptedDpkg.*|Unattended-Upgrade::AutoFixInterruptedDpkg \"true\";|" \
    -e "s|^//Unattended-Upgrade::Mail \".*|Unattended-Upgrade::Mail \"$EMAIL\";|" \
    -e "s|^//Unattended-Upgrade::MailReport.*|Unattended-Upgrade::MailReport \"only-on-error\";|" \
    -e "s|^//Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies \"true\";|" \
    -e "s|^//Unattended-Upgrade::Remove-New-Unused-Dependencies.*|Unattended-Upgrade::Remove-New-Unused-Dependencies \"true\";|" \
    -e "s|^//Unattended-Upgrade::Automatic-Reboot \".*|Unattended-Upgrade::Automatic-Reboot \"true\";|" \
    -e "s|^//Unattended-Upgrade::Automatic-Reboot-WithUsers.*|Unattended-Upgrade::Automatic-Reboot-WithUsers \"true\";|" \
    -e "s|^//Unattended-Upgrade::Automatic-Reboot-Time.*|Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\";|" \
    /etc/apt/apt.conf.d/99unattended-upgrades

# Editing apt-daily-upgrade.timer
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat <<EOF >/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
[Timer]
OnCalendar=$UPGRADE_TIMER
RandomizedDelaySec=15m
Persistent=true

# Anything between here and the comment below
EOF

# Reloading systemd
systemctl daemon-reload

# Restarting unattended-upgrades service
systemctl restart unattended-upgrades

# Checking status of unattended-upgrades
systemctl status unattended-upgrades --no-pager

# Performing a test run
unattended-upgrade --dry-run --debug

echo "=== Configuration complete ==="
