#!/usr/bin/env bash
# Install SimpleX SMP (and optional XFTP) binaries inside an Ubuntu CT/VM.
# Safe for Proxmox LXC: uses uname -m (official install.sh uses uname -p, which
# often returns "unknown" in containers).
#
# Env:
#   INSTALL_SMP=1|0     default 1
#   INSTALL_XFTP=1|0    default 0
#   FQDN=smp.example.com  optional; runs smp-server init when set
#   VER=latest|vX.Y.Z   default latest
set -euo pipefail

INSTALL_SMP="${INSTALL_SMP:-1}"
INSTALL_XFTP="${INSTALL_XFTP:-0}"
FQDN="${FQDN:-}"
VER="${VER:-latest}"

SCRIPTS="https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/scripts/main"
PATH_BIN="/usr/local/bin"
PATH_SYSTEMD="/etc/systemd/system"
PATH_CONF_INFO="/etc/opt/simplex-info"

GN=$'\033[0;32m'
BL=$'\033[1;34m'
RD=$'\033[0;31m'
CL=$'\033[0m'

msg_info() { echo -e "${BL}[INFO]${CL} $*"; }
msg_ok() { echo -e "${GN}[OK]${CL} $*"; }
msg_error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Must run as root."
    exit 1
  fi
}

detect_platform() {
  # shellcheck source=/dev/null
  . /etc/os-release

  case "${ID:-}" in
    ubuntu) ;;
    *)
      msg_error "SimpleX published binaries target Ubuntu. Found ID=${ID:-unknown}."
      msg_error "Recreate the CT with an Ubuntu 22.04/24.04 template."
      exit 1
      ;;
  esac

  case "${VERSION_ID}" in
    20.04|22.04) ;;
    24.04) VERSION_ID="22.04" ;;
    *)
      msg_error "Unsupported Ubuntu ${VERSION_ID}. Supported: 20.04, 22.04, 24.04."
      exit 1
      ;;
  esac

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="x86-64" ;;
    *)
      msg_error "Unsupported architecture: ${arch}. Official binaries are x86_64 only."
      exit 1
      ;;
  esac

  local version
  version="$(printf '%s' "$VERSION_ID" | tr '.' '_')"

  if [[ "$VER" == "latest" ]]; then
    BIN_BASE="https://github.com/simplex-chat/simplexmq/releases/latest/download"
    REMOTE_VERSION="$(curl --proto '=https' --tlsv1.2 -fsSL https://api.github.com/repos/simplex-chat/simplexmq/releases/latest | awk -F\" '/tag_name/ {print $4; exit}')"
  else
    BIN_BASE="https://github.com/simplex-chat/simplexmq/releases/download/${VER}"
    REMOTE_VERSION="$VER"
  fi

  BIN_SMP="${BIN_BASE}/smp-server-ubuntu-${version}-${arch}"
  BIN_XFTP="${BIN_BASE}/xftp-server-ubuntu-${version}-${arch}"
}

install_component() {
  local name="$1" user="$2" bin_url="$3" conf_dirs="$4" unit_url="$5" unit_path="$6" bin_path="$7"

  msg_info "Installing ${name}"
  curl --proto '=https' --tlsv1.2 -fsSL "$bin_url" -o "$bin_path"
  chmod +x "$bin_path"

  useradd -M "$user" 2>/dev/null || true
  # shellcheck disable=SC2086
  mkdir -p $conf_dirs "$PATH_CONF_INFO"
  # shellcheck disable=SC2086
  chown -R "$user:$user" $conf_dirs

  curl --proto '=https' --tlsv1.2 -fsSL "$unit_url" -o "$unit_path"
  printf "local_version_%s='%s'\n" "$name" "$REMOTE_VERSION" >>"${PATH_CONF_INFO}/release"
  msg_ok "Installed ${name} (${REMOTE_VERSION})"
}

install_helper_scripts() {
  msg_info "Installing update/uninstall helpers"
  curl --proto '=https' --tlsv1.2 -fsSL "${SCRIPTS}/simplex-servers-update" -o "${PATH_BIN}/simplex-servers-update"
  curl --proto '=https' --tlsv1.2 -fsSL "${SCRIPTS}/simplex-servers-uninstall" -o "${PATH_BIN}/simplex-servers-uninstall"
  curl --proto '=https' --tlsv1.2 -fsSL "${SCRIPTS}/simplex-servers-stopscript" -o "${PATH_BIN}/simplex-servers-stopscript"
  chmod +x \
    "${PATH_BIN}/simplex-servers-update" \
    "${PATH_BIN}/simplex-servers-uninstall" \
    "${PATH_BIN}/simplex-servers-stopscript"
  msg_ok "Helpers installed"
}

init_smp_if_requested() {
  if [[ -z "$FQDN" ]]; then
    return 0
  fi

  if [[ -f /etc/opt/simplex/smp-server.ini ]]; then
    msg_info "smp-server already initialized; skipping init"
    return 0
  fi

  msg_info "Initializing smp-server for ${FQDN}"
  su smp -c "smp-server init --yes --store-log --no-password --control-port --source-code --fqdn=${FQDN}"
  systemctl enable --now smp-server
  msg_ok "smp-server initialized and started"
  echo
  echo "Server address / fingerprint are printed above and stored under /etc/opt/simplex/"
}

open_hint() {
  cat <<EOF

${GN}SimpleX binaries are installed.${CL}

Recommended host firewall / port forwards:
  TCP 80, 443, 5223

Official guide:
  https://simplex.chat/docs/server.html

Update later with:
  simplex-servers-update

EOF
}

main() {
  require_root
  export DEBIAN_FRONTEND=noninteractive

  msg_info "Refreshing apt indexes"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl >/dev/null
  msg_ok "Base packages ready"

  detect_platform
  mkdir -p "$PATH_CONF_INFO"
  : >"${PATH_CONF_INFO}/release"

  if [[ "$INSTALL_SMP" == "1" ]]; then
    install_component \
      "smp" \
      "smp" \
      "$BIN_SMP" \
      "/etc/opt/simplex /var/opt/simplex" \
      "${SCRIPTS}/smp-server.service" \
      "${PATH_SYSTEMD}/smp-server.service" \
      "${PATH_BIN}/smp-server"
  fi

  if [[ "$INSTALL_XFTP" == "1" ]]; then
    install_component \
      "xftp" \
      "xftp" \
      "$BIN_XFTP" \
      "/etc/opt/simplex-xftp /var/opt/simplex-xftp /srv/xftp" \
      "${SCRIPTS}/xftp-server.service" \
      "${PATH_SYSTEMD}/xftp-server.service" \
      "${PATH_BIN}/xftp-server"
  fi

  install_helper_scripts
  systemctl daemon-reload
  init_smp_if_requested
  open_hint
}

main "$@"
