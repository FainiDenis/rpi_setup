#!/usr/bin/env bash
# ============================================================
# Raspberry Pi 4 Full Setup Script (Debian-based)
# Docker, Docker Compose, Portainer CE, Cockpit + File Sharing
# UFW firewall
# Run as root or with sudo
# ============================================================

set -euo pipefail

# --- Configuration variables ---
NEW_HOSTNAME="rpi4"
COCKPIT_FILE_SHARING_VERSION="4.3.2"
COCKPIT_FILE_SHARING_DEB="cockpit-file-sharing_${COCKPIT_FILE_SHARING_VERSION}-2focal_all.deb"

PACKAGES=(
  git curl wget ufw net-tools avahi-daemon openssh-server unzip samba
  python3 python3-pip ca-certificates gnupg lsb-release apt-transport-https
  cockpit
)

# --- Helpers / logging ---
log() { echo -e "\n[+] $*"; }
step() { echo -e "\n\033[1;34m▶ $*\033[0m"; }
progress() { echo -n "....."; }

# --- Steps ---
update_system() {
  step "Updating system packages"
  progress; apt update -y > /dev/null 2>&1
  progress; DEBIAN_FRONTEND=noninteractive apt full-upgrade -y > /dev/null 2>&1
  progress; apt autoremove -y > /dev/null 2>&1
  log "System updated successfully"
}

set_hostname() {
  step "Setting hostname to ${NEW_HOSTNAME}"
  progress; hostnamectl set-hostname "${NEW_HOSTNAME}"
  if ! grep -q "127.0.1.1 ${NEW_HOSTNAME}" /etc/hosts 2>/dev/null; then
    progress; echo "127.0.1.1 ${NEW_HOSTNAME}" >> /etc/hosts
  fi
  log "Hostname set to ${NEW_HOSTNAME}"
}

install_base_packages() {
  step "Installing base packages"
  progress; apt install -y "${PACKAGES[@]}" > /dev/null 2>&1
  log "Base packages installed"
}

install_docker() {
  step "Installing Docker and docker-compose plugin"
  
  progress; apt remove -y docker docker.io containerd runc > /dev/null 2>&1 || true

  progress; install -m 0755 -d /etc/apt/keyrings
  progress; curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg > /dev/null 2>&1
  progress; chmod a+r /etc/apt/keyrings/docker.gpg

  progress; echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  progress; apt update -y > /dev/null 2>&1
  progress; apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1

  progress; systemctl enable docker > /dev/null 2>&1
  progress; systemctl start docker > /dev/null 2>&1

  progress; usermod -aG docker "${SUDO_USER:-$USER}" > /dev/null 2>&1 || true
  log "Docker installed successfully"
}

install_portainer() {
  step "Installing Portainer CE"
  progress; docker volume create portainer_data > /dev/null 2>&1 || true
  progress; docker stop portainer > /dev/null 2>&1 || true
  progress; docker rm portainer > /dev/null 2>&1 || true
  progress; docker run -d \
    -p 9443:9443 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v portainer_data:/data \
    portainer/portainer-ce:lts > /dev/null 2>&1
  log "Portainer installed and running on port 9443"
}

install_cockpit_plugins() {
  step "Installing Cockpit plugins"
  
  progress; cd /tmp
  if curl -f -LO "https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator_0.5.10-1focal_all.deb" > /dev/null 2>&1; then
    progress; apt install -y ./cockpit-navigator_0.5.10-1focal_all.deb > /dev/null 2>&1 || log "Cockpit navigator installation failed, continuing..."
    progress; rm -f ./cockpit-navigator_0.5.10-1focal_all.deb
  else
    log "Failed to download cockpit-navigator, skipping..."
  fi
  
  progress; apt install -y cockpit-packagekit > /dev/null 2>&1 || true
  log "Cockpit plugins installed"
}

install_cockpit_file_sharing() {
  step "Installing Cockpit File Sharing plugin"
  progress; cd /tmp
  if curl -f -LO "https://github.com/45Drives/cockpit-file-sharing/releases/download/v${COCKPIT_FILE_SHARING_VERSION}/${COCKPIT_FILE_SHARING_DEB}" > /dev/null 2>&1; then
    progress; apt install -y "./${COCKPIT_FILE_SHARING_DEB}" > /dev/null 2>&1 || log "Cockpit file sharing installation failed, continuing..."
    progress; rm -f "./${COCKPIT_FILE_SHARING_DEB}"
    log "Cockpit File Sharing installed"
  else
    log "Failed to download cockpit-file-sharing, skipping..."
  fi
}

install_tailscale(){
  step "Installing Tailscale"
  progress; curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
  progress; systemctl enable --now tailscaled > /dev/null 2>&1
  log "Tailscale installed"
}

configure_firewall() {
  step "Configuring UFW firewall"
  
  progress; ufw --force reset > /dev/null 2>&1
  progress; ufw default deny incoming > /dev/null 2>&1
  progress; ufw default allow outgoing > /dev/null 2>&1

  progress; ufw allow from 192.168.1.0/24 to any port 22 proto tcp > /dev/null 2>&1
  progress; ufw allow 80/tcp > /dev/null 2>&1
  progress; ufw allow 443/tcp > /dev/null 2>&1
  progress; ufw allow from 192.168.1.0/24 to any port 9090 proto tcp > /dev/null 2>&1
  progress; ufw allow from 192.168.1.0/24 to any port 9443 proto tcp > /dev/null 2>&1
  progress; ufw allow in on tailscale0 > /dev/null 2>&1
  progress; ufw allow from 192.168.1.0/24 to any port 445 proto tcp > /dev/null 2>&1

  progress; ufw --force enable > /dev/null 2>&1
  log "Firewall configured successfully"
}

hardening_sshd() {
  step "Backup SSH configuration"
  progress; cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak > /dev/null 2>&1
  log "SSH configuration backed up to /etc/ssh/sshd_config.bak"

  step "Remove SSH config file"
  progress; rm /etc/ssh/sshd_config > /dev/null 2>&1
  log "SSH config file removed"

  step "Copy new SSH config file"
  progress; cp ./sshd_config /etc/ssh/sshd_config > /dev/null 2>&1
  log "New SSH config file copied"

  progress; systemctl restart ssh > /dev/null 2>&1
  log "SSH hardened and restarted"
}

setup_samba_shares() {
  step "Backing up original Samba configuration"
  progress; cp /etc/samba/smb.conf /etc/samba/smb.conf.bak > /dev/null 2>&1
  log "Samba configuration backed up to /etc/samba/smb.conf.bak"

  step "Copy new Samba configuration"
  progress; cp ./smb.conf /etc/samba/smb.conf > /dev/null 2>&1
  log "New Samba configuration copied"

  step "Create a directory for external drive"
  progress; mkdir -p /mnt/4TB_HDD > /dev/null 2>&1
  log "External drive directory created"

  step "Set ownership for /mnt/4TB_HDD"
  progress; chown -R "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" /mnt/4TB_HDD > /dev/null 2>&1
  log "Ownership for /mnt/4TB_HDD set to ${SUDO_USER:-$USER}"

  step "Setting Samba password for user ${SUDO_USER:-$USER}"
  smbpasswd -a "${SUDO_USER:-$USER}"
  log "Samba password set for user ${SUDO_USER:-$USER}"

  progress; systemctl restart smbd > /dev/null 2>&1
  log "Samba services restarted"
}

enable_services() {
  step "Enabling services"
  progress; systemctl enable ssh > /dev/null 2>&1
  progress; systemctl start ssh > /dev/null 2>&1
  progress; systemctl enable avahi-daemon > /dev/null 2>&1
  progress; systemctl start avahi-daemon > /dev/null 2>&1
  progress; systemctl enable cockpit.socket > /dev/null 2>&1
  progress; systemctl start cockpit.socket > /dev/null 2>&1
  progress; systemctl enable docker > /dev/null 2>&1
  progress; systemctl start docker > /dev/null 2>&1
  log "Services enabled and started"
}

final_message() {
  echo
  log "=== Setup complete ==="
  echo "Hostname: ${NEW_HOSTNAME}"
  echo
  echo "Access:"
  echo "  Cockpit:   https://$(hostname -I | awk '{print $1}'):9090"
  echo "  Portainer: https://$(hostname -I | awk '{print $1}'):9443"
  echo
  echo "SSH: ssh ${SUDO_USER:-$USER}@$(hostname -I | awk '{print $1}')"
  echo
  echo "Note: You may need to reboot for all changes to take effect."
  echo "      Run: sudo reboot"
}

# --- Main ---
main() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)." >&2
    exit 2
  fi

  echo -e "\n\033[1;36m🚀 Starting Raspberry Pi 4 Setup\033[0m"
  echo "=========================================="
  
  update_system
  set_hostname
  install_base_packages
  install_docker
  install_portainer
  install_cockpit_plugins
  install_cockpit_file_sharing
  hardening_sshd
  setup_samba_shares
  install_tailscale
  configure_firewall
  enable_services

  step "Performing final cleanup"
  progress; apt autoremove -y > /dev/null 2>&1
  progress; apt autoclean -y > /dev/null 2>&1

  final_message
  echo -e "\n\033[1;32m✅ Setup completed successfully!\033[0m"
}

main "$@"
