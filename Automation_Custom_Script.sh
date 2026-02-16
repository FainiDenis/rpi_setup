#!/bin/bash
set -euo pipefail

# ========= Defaults (override via env) =========
HOSTNAME="${HOSTNAME:-rpi4}"
NEW_USERNAME="${NEW_USERNAME:-fainidenis}"
OLD_USERNAME="${OLD_USERNAME:-dietpi}"
SHARE_DIR="${SHARE_DIR:-/mnt/4TB_HDD}"
SMB_CONF_URL="${SMB_CONF_URL:-https://raw.githubusercontent.com/FainiDenis/rpi_setup/main/smb.conf}"
SMB_CONF_SHA256="${SMB_CONF_SHA256:-}"   # optional
# ===============================================

log() { echo -e "\n\033[1;34m▶\033[0m $*"; }
ok()  { echo -e "\033[1;32m✅\033[0m $*"; }
die() { echo -e "\033[1;31m❌\033[0m $*" >&2; exit 1; }
warn(){ echo -e "\033[1;33m⚠️\033[0m $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run with sudo"; }

apt_quiet() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Use-Pty=0 "$@" >/dev/null 2>&1
}

set_hostname() {
  log "Setting hostname: ${HOSTNAME}"
  hostnamectl set-hostname "${HOSTNAME}" >/dev/null 2>&1 || true
  grep -qE "127\.0\.0\.1\s+${HOSTNAME}" /etc/hosts 2>/dev/null || \
    echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
  ok "Hostname set"
}

rename_user() {
  log "Renaming default username from ${OLD_USERNAME} to ${NEW_USERNAME}"
  if id "${NEW_USERNAME}" >/dev/null 2>&1; then
    warn "User ${NEW_USERNAME} already exists"
  else
    id "${OLD_USERNAME}" >/dev/null 2>&1 || die "Old user not found"
    usermod -l "${NEW_USERNAME}" -d "/home/${NEW_USERNAME}" -m "${OLD_USERNAME}"
    getent group "${OLD_USERNAME}" >/dev/null 2>&1 && \
      groupmod -n "${NEW_USERNAME}" "${OLD_USERNAME}" || true
  fi
  usermod -aG sudo "${NEW_USERNAME}" >/dev/null 2>&1 || true
  ok "Renamed user to ${NEW_USERNAME}"
}

add_user_to_app_groups() {
  log "Adding ${NEW_USERNAME} to known app groups"

  APP_GROUPS="navidrome docker sambashare beets gitea"

  for group in ${APP_GROUPS}; do
    if getent group "${group}" >/dev/null 2>&1; then
      usermod -aG "${group}" "${NEW_USERNAME}" >/dev/null 2>&1 || true
      echo "  → Added to group: ${group}"
    fi
  done

  ok "App group assignment complete"
}


download_smb_conf() {
  local tmp
  tmp="$(mktemp /tmp/smb.conf.XXXXXX)"

  log "Downloading smb.conf"
  wget -q --tries=3 --timeout=15 -O "$tmp" "$SMB_CONF_URL" \
    || die "Failed to download smb.conf"

  if [[ -n "$SMB_CONF_SHA256" ]]; then
    echo "${SMB_CONF_SHA256}  $tmp" | sha256sum -c - >/dev/null 2>&1 \
      || die "smb.conf SHA256 mismatch"
  fi

  grep -q "^\[global\]" "$tmp" || die "Invalid smb.conf (missing [global])"

  if command -v testparm >/dev/null 2>&1; then
    testparm -s "$tmp" >/dev/null 2>&1 || die "smb.conf validation failed"
  fi

  mv "$tmp" /etc/samba/smb.conf
  chmod 644 /etc/samba/smb.conf
  ok "smb.conf applied"
}

setup_samba() {
  log "Installing Samba"
  apt_quiet update
  apt_quiet install wget samba smbclient

  [[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.bak ]] && \
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

  download_smb_conf

  mkdir -p "${SHARE_DIR}"
  chown -R "${NEW_USERNAME}:${NEW_USERNAME}" "${SHARE_DIR}"
  chmod -R 775 "${SHARE_DIR}"
  ok "Share directory ready: ${SHARE_DIR}"

  if ! pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "${NEW_USERNAME}"; then
    if [[ -z "${SAMBA_PASSWORD:-}" ]]; then
      read -rsp "Enter Samba password for ${NEW_USERNAME}: " SAMBA_PASSWORD
      echo
    fi
    printf '%s\n%s\n' "${SAMBA_PASSWORD}" "${SAMBA_PASSWORD}" | \
      smbpasswd -a -s "${NEW_USERNAME}" >/dev/null
    ok "Samba user created"
  else
    warn "Samba user already exists"
  fi

  systemctl enable --now smbd nmbd >/dev/null 2>&1 || true
  systemctl restart smbd nmbd >/dev/null 2>&1 || true
  ok "Samba running"
}

set_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW firewall"
    apt_quiet install ufw
    ufw ufw default deny incoming >/dev/null 2>&1 || die "Failed to set UFW default policy"
    ufw default allow outgoing >/dev/null 2>&1 || die "Failed to set UFW default policy"
    ufw allow 80/tcp >/dev/null 2>&1 || die "Failed to allow HTTP in UFW"
    ufw allow 443/tcp >/dev/null 2>&1 || die "Failed to allow HTTPS in UFW"
    ufw allow in on tailscale0 to any >/dev/null 2>&1 || die "Failed to allow Tailscale interface in UFW"
    ufw allow from 192.168.1.0/24 to any  >/dev/null 2>&1 || die "Failed to allow local network in UFW"
    ufw --force enable >/dev/null 2>&1 || die "Failed to enable UFW"
    ufw reload >/dev/null 2>&1 || die "Failed to reload UFW"
    ok "Firewall configured"
  else
    warn "UFW not found, skipping firewall configuration"
  fi
}

install_cloudflared() {
  log "Installing Cloudflare Tunnel (cloudflared)"

  apt_quiet update
  apt_quiet install curl ca-certificates gnupg

  # Create keyrings directory
  mkdir -p --mode=0755 /usr/share/keyrings

  # Add Cloudflare GPG key (only if not already present)
  if [[ ! -f /usr/share/keyrings/cloudflare-public-v2.gpg ]]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloudflare-public-v2.gpg \
      || die "Failed to add Cloudflare GPG key"
  fi

  # Add repository (only if not already added)
  if [[ ! -f /etc/apt/sources.list.d/cloudflared.list ]]; then
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list
  fi

  # Install cloudflared
  apt_quiet update
  apt_quiet install cloudflared

  ok "Cloudflared installed successfully"
}


main() {
  require_root
  echo -e "\n\033[1;36m🚀 Running Automation Custom Script from Git Repo\033[0m"
  set_hostname
  rename_user
  setup_samba
  add_user_to_app_groups
  set_firewall
  install_cloudflared
  ok "Setup complete"
  echo "Reboot recommended if you renamed the current user."
}

main "$@"
