#!/usr/bin/env bash
# Create a Proxmox LXC and install SimpleX SMP (optional XFTP).
# Run on the Proxmox VE host as root.
#
# Usage:
#   bash create-simplex-lxc.sh
#   CTID=120 HOSTNAME=simplex FQDN=smp.example.com bash create-simplex-lxc.sh
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mikeybob/proxmox-simplex/main/create-simplex-lxc.sh)"
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/mikeybob/proxmox-simplex/main}"
INSTALL_SCRIPT_URL="${INSTALL_SCRIPT_URL:-${REPO_RAW}/install-simplex.sh}"

APP="SimpleX"
DEFAULT_HOSTNAME="simplex"
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_DISK=8
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE=""
DEFAULT_TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
DEFAULT_UNPRIVILEGED=1

# Colors
if [[ -t 1 ]]; then
  GN=$'\033[0;32m'
  YW=$'\033[1;33m'
  BL=$'\033[1;34m'
  RD=$'\033[0;31m'
  CL=$'\033[0m'
else
  GN=""; YW=""; BL=""; RD=""; CL=""
fi

msg_info() { echo -e "${BL}[INFO]${CL} $*"; }
msg_ok() { echo -e "${GN}[OK]${CL} $*"; }
msg_warn() { echo -e "${YW}[WARN]${CL} $*"; }
msg_error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Run this script as root on a Proxmox VE host."
    exit 1
  fi
}

require_proxmox() {
  if ! command -v pct >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
    msg_error "Proxmox VE tools (pct/pvesm) not found."
    exit 1
  fi
}

next_ctid() {
  local id=100
  while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; do
    id=$((id + 1))
  done
  echo "$id"
}

default_storage() {
  # Prefer a storage that supports container rootdirs.
  pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3 ~ /active|available/ {print $1; exit}'
}

prompt() {
  local var="$1" prompt_text="$2" default="${3:-}"
  local value
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${prompt_text} [${default}]: " value
    value="${value:-$default}"
  else
    read -r -p "${prompt_text}: " value
  fi
  printf -v "$var" '%s' "$value"
}

select_template() {
  local storage="$1"
  local templates
  templates="$(pveam list "$storage" 2>/dev/null | awk 'NR>1 {print $1}' | sed "s|^${storage}:vztmpl/||" || true)"

  if echo "$templates" | grep -qx "$DEFAULT_TEMPLATE"; then
    echo "$DEFAULT_TEMPLATE"
    return 0
  fi

  # Prefer any ubuntu 22.04 amd64 template already present.
  local found
  found="$(echo "$templates" | grep -E 'ubuntu-22\.04.*amd64.*\.tar\.(zst|gz|xz)$' | head -n1 || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  echo "$DEFAULT_TEMPLATE"
}

ensure_template() {
  local storage="$1"
  local template="$2"
  if pveam list "$storage" 2>/dev/null | grep -q "${template}"; then
    return 0
  fi
  msg_info "Downloading template ${template} to storage ${storage}"
  pveam update >/dev/null
  pveam download "$storage" "$template"
  msg_ok "Template ready"
}

wait_for_network() {
  local ctid="$1"
  local i
  for i in $(seq 1 60); do
    if pct exec "$ctid" -- bash -c 'getent hosts github.com >/dev/null 2>&1 || ping -c1 -W1 1.1.1.1 >/dev/null 2>&1'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

main() {
  require_root
  require_proxmox

  echo
  echo -e "${BL}${APP} Proxmox LXC creator${CL}"
  echo "Creates an Ubuntu LXC and installs SimpleX server binaries."
  echo

  local CTID HOSTNAME CORES MEMORY DISK BRIDGE STORAGE TEMPLATE UNPRIVILEGED FQDN INSTALL_XFTP PW
  CTID="${CTID:-}"
  HOSTNAME="${HOSTNAME:-}"
  CORES="${CORES:-}"
  MEMORY="${MEMORY:-}"
  DISK="${DISK:-}"
  BRIDGE="${BRIDGE:-}"
  STORAGE="${STORAGE:-${DEFAULT_STORAGE}}"
  TEMPLATE="${TEMPLATE:-}"
  UNPRIVILEGED="${UNPRIVILEGED:-$DEFAULT_UNPRIVILEGED}"
  FQDN="${FQDN:-}"
  INSTALL_XFTP="${INSTALL_XFTP:-0}"
  PW="${PW:-}"

  prompt CTID "Container ID" "$(next_ctid)"
  prompt HOSTNAME "Hostname" "$DEFAULT_HOSTNAME"
  prompt CORES "CPU cores" "$DEFAULT_CORES"
  prompt MEMORY "Memory (MiB)" "$DEFAULT_MEMORY"
  prompt DISK "Root disk (GiB)" "$DEFAULT_DISK"
  prompt BRIDGE "Network bridge" "$DEFAULT_BRIDGE"

  if [[ -z "$STORAGE" ]]; then
    STORAGE="$(default_storage || true)"
  fi
  prompt STORAGE "Container storage" "${STORAGE:-local-lvm}"

  if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE="$(select_template "$STORAGE")"
  fi
  prompt TEMPLATE "Ubuntu template" "$TEMPLATE"

  if [[ -z "${FQDN}" ]]; then
    read -r -p "Server FQDN for smp-server init (optional, Enter to skip): " FQDN || true
  fi

  if [[ -z "${INSTALL_XFTP}" || "$INSTALL_XFTP" == "0" ]]; then
    read -r -p "Also install XFTP file server? [y/N]: " ans || true
    case "${ans:-}" in
      y|Y|yes|YES) INSTALL_XFTP=1 ;;
      *) INSTALL_XFTP=0 ;;
    esac
  fi

  if pct status "$CTID" &>/dev/null; then
    msg_error "CTID ${CTID} already exists."
    exit 1
  fi

  ensure_template "$STORAGE" "$TEMPLATE"

  if [[ -z "$PW" ]]; then
    PW="$(openssl rand -base64 18 | tr -d '=+/')"
  fi

  msg_info "Creating LXC ${CTID} (${HOSTNAME})"
  pct create "$CTID" "${STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --onboot 1 \
    --start 1 \
    --password "$PW" \
    --timezone host \
    --tags "simplex;privacy"

  msg_ok "Container created and started"

  msg_info "Waiting for network"
  if ! wait_for_network "$CTID"; then
    msg_error "Container network did not come up. Check DHCP/DNS on ${BRIDGE}."
    exit 1
  fi
  msg_ok "Network is up"

  msg_info "Installing SimpleX inside CT ${CTID}"
  pct exec "$CTID" -- bash -c "curl -fsSL '${INSTALL_SCRIPT_URL}' -o /tmp/install-simplex.sh && chmod +x /tmp/install-simplex.sh && FQDN='${FQDN}' INSTALL_XFTP='${INSTALL_XFTP}' /tmp/install-simplex.sh && rm -f /tmp/install-simplex.sh"
  msg_ok "SimpleX install finished"

  local IP
  IP="$(pct exec "$CTID" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"

  cat <<EOF

${GN}Done.${CL} ${APP} LXC is ready.

  CTID:      ${CTID}
  Hostname:  ${HOSTNAME}
  IP:        ${IP:-unknown}
  Root PW:   ${PW}
  Console:   pct enter ${CTID}

Firewall / NAT (host or router): allow TCP 80, 443, 5223 to this CT.
Docs: https://simplex.chat/docs/server.html

EOF

  if [[ -n "$FQDN" ]]; then
    echo "FQDN was set to ${FQDN}. If init succeeded, check:"
    echo "  pct exec ${CTID} -- su smp -c 'smp-server --help'"
    echo "  pct exec ${CTID} -- systemctl status smp-server --no-pager"
  else
    echo "Next: point a domain at the CT, then initialize the server:"
    echo "  pct enter ${CTID}"
    echo "  su smp -c 'smp-server init --yes --store-log --no-password --control-port --fqdn=smp.example.com'"
    echo "  systemctl enable --now smp-server"
  fi
  echo
}

main "$@"
