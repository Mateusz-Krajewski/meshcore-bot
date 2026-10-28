#!/usr/bin/env bash
# Create an Alpine LXC on a Proxmox VE host and install meshcore-bot in it.
#
# Run on the Proxmox host as root:
#   bash create-lxc.sh [options]
#
# Options (defaults in brackets):
#   --ctid N            Container ID [next free ID]
#   --hostname NAME     [meshcore-bot]
#   --storage NAME      Root filesystem storage [local-lvm]
#   --disk GB           [2]
#   --cores N           [1]
#   --memory MB         [512]
#   --bridge NAME       [vmbr0]
#   --ip CIDR|dhcp      [dhcp]
#   --gw IP             Gateway, with a static --ip
#   --nameserver IP     DNS server(s), space separated [inherit from host]
#   --serial DEVICE     Pass a USB serial radio into the container, e.g.
#                       /dev/serial/by-id/usb-...  (Proxmox VE 8.1+)
#   --version TAG       meshcore-bot release tag or branch [latest release]
#   --config FILE       Existing config.ini to import (e.g. from Docker)
#   --database FILE     Existing meshcore_bot.db to import (stop the old bot first)

set -euo pipefail

INSTALLER_URL="${MESHCORE_BOT_INSTALLER_URL:-https://raw.githubusercontent.com/agessaman/meshcore-bot/main/scripts/proxmox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CTID=""
CT_HOSTNAME="meshcore-bot"
STORAGE="local-lvm"
DISK=2
CORES=1
MEMORY=512
BRIDGE="vmbr0"
IP="dhcp"
GW=""
NAMESERVER=""
SERIAL=""
INSTALL_ARGS=()
IMPORT_CONFIG=""
IMPORT_DB=""

die() {
    echo "Error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) CT_HOSTNAME="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --gw) GW="$2"; shift 2 ;;
    --nameserver) NAMESERVER="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --version) INSTALL_ARGS+=(--version "$2"); shift 2 ;;
    --config) IMPORT_CONFIG="$2"; shift 2 ;;
    --database) IMPORT_DB="$2"; shift 2 ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
    esac
done

command -v pct >/dev/null || die "pct not found - run this on a Proxmox VE host"
[[ $EUID -eq 0 ]] || die "Run as root"
[[ -z "$IMPORT_CONFIG" || -f "$IMPORT_CONFIG" ]] || die "Config not found: $IMPORT_CONFIG"
[[ -z "$IMPORT_DB" || -f "$IMPORT_DB" ]] || die "Database not found: $IMPORT_DB"
[[ -z "$SERIAL" || -e "$SERIAL" ]] || die "Serial device not found: $SERIAL"
CTID="${CTID:-$(pvesh get /cluster/nextid)}"

echo "Looking up the newest Alpine template"
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep -E '^alpine-3\.[0-9]+-default' | sort -V | tail -n 1)
[[ -n "$TEMPLATE" ]] || die "No Alpine template offered by pveam"
if ! pveam list local | grep -q "$TEMPLATE"; then
    pveam download local "$TEMPLATE" >/dev/null
fi

NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[[ -z "$GW" ]] || NET+=",gw=$GW"
CREATE_ARGS=(
    --hostname "$CT_HOSTNAME" --ostype alpine --unprivileged 1
    --cores "$CORES" --memory "$MEMORY" --swap 256
    --rootfs "$STORAGE:$DISK" --net0 "$NET"
    --onboot 1 --tags meshcore
)
[[ -z "$NAMESERVER" ]] || CREATE_ARGS+=(--nameserver "$NAMESERVER")

echo "Creating CT $CTID ($CT_HOSTNAME) from $TEMPLATE"
pct create "$CTID" "local:vztmpl/$TEMPLATE" "${CREATE_ARGS[@]}" >/dev/null
# gid 20 is dialout on Alpine; the service user is a member.
[[ -z "$SERIAL" ]] || pct set "$CTID" --dev0 "$SERIAL,gid=20,mode=0660" >/dev/null
pct start "$CTID"

echo "Waiting for network in CT $CTID"
for _ in $(seq 1 30); do
    pct exec "$CTID" -- apk update >/dev/null 2>&1 && break
    sleep 2
done
pct exec "$CTID" -- apk update >/dev/null 2>&1 || die "CT $CTID has no working network/DNS"

pct exec "$CTID" -- mkdir -p /root/meshcore-install
for f in install-alpine.sh meshcore-bot.openrc; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        pct push "$CTID" "$SCRIPT_DIR/$f" "/root/meshcore-install/$f"
    else
        pct exec "$CTID" -- wget -qO "/root/meshcore-install/$f" "$INSTALLER_URL/$f"
    fi
done
if [[ -n "$IMPORT_CONFIG" ]]; then
    pct push "$CTID" "$IMPORT_CONFIG" /root/meshcore-install/config.ini --perms 0600
    INSTALL_ARGS+=(--config /root/meshcore-install/config.ini)
fi
if [[ -n "$IMPORT_DB" ]]; then
    pct push "$CTID" "$IMPORT_DB" "/root/meshcore-install/$(basename "$IMPORT_DB")" --perms 0600
    INSTALL_ARGS+=(--database "/root/meshcore-install/$(basename "$IMPORT_DB")")
fi

pct exec "$CTID" -- sh /root/meshcore-install/install-alpine.sh "${INSTALL_ARGS[@]}"
pct exec "$CTID" -- rm -rf /root/meshcore-install

ADDR=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)
cat <<EOF

meshcore-bot is installed in CT $CTID ($CT_HOSTNAME, ${ADDR:-no IPv4 yet}).
  Config:  pct exec $CTID -- vi /etc/meshcore-bot/config.ini
  Service: pct exec $CTID -- rc-service meshcore-bot restart
  Logs:    pct exec $CTID -- tail -f /var/log/meshcore-bot/meshcore_bot.log
  Upgrade: pct exec $CTID -- sh -c 'wget -qO- $INSTALLER_URL/install-alpine.sh | sh'
EOF
