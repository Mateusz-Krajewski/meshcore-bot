#!/bin/sh
# Install or upgrade meshcore-bot as an OpenRC service on Alpine Linux.
#
# Runs inside the Alpine host or LXC, as root. Uses the same layout as
# install-service.sh: code in /opt/meshcore-bot, config in /etc/meshcore-bot,
# state in /var/lib/meshcore-bot, logs in /var/log/meshcore-bot.
#
# Usage:
#   sh install-alpine.sh [--version vX.Y.Z|BRANCH] [--config FILE]
#                        [--database FILE] [--no-start]
#
#   --version   Release tag or branch to install (default: latest release)
#   --config    Import an existing config.ini (Docker /data/... paths are rewritten)
#   --database  Import an existing SQLite database into /var/lib/meshcore-bot
#   --no-start  Install and enable the service, but do not (re)start it
#
# Running it again upgrades in place; config, database and logs are kept.

set -eu
umask 022

REPO="agessaman/meshcore-bot"
INSTALL_DIR="/opt/meshcore-bot"
CONF_DIR="/etc/meshcore-bot"
STATE_DIR="/var/lib/meshcore-bot"
LOG_DIR="/var/log/meshcore-bot"
CONFIG_FILE="$CONF_DIR/config.ini"
SERVICE_USER="meshcore"

VERSION=""
IMPORT_CONFIG=""
IMPORT_DB=""
START=true

info() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die() {
    printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --config) IMPORT_CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --database) IMPORT_DB="${2:?--database needs a file}"; shift 2 ;;
    --no-start) START=false; shift ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root"
[ -f /etc/alpine-release ] || die "This installer is for Alpine Linux; use install-service.sh elsewhere"
[ -z "$IMPORT_CONFIG" ] || [ -f "$IMPORT_CONFIG" ] || die "Config not found: $IMPORT_CONFIG"
[ -z "$IMPORT_DB" ] || [ -f "$IMPORT_DB" ] || die "Database not found: $IMPORT_DB"

info "Installing system packages"
apk add --no-cache python3 curl ca-certificates tar tzdata >/dev/null
ok "System packages installed ($(python3 --version))"

if [ -z "$VERSION" ]; then
    VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$VERSION" ] || die "Could not determine the latest release; pass --version"
fi
info "Installing meshcore-bot $VERSION"

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    addgroup -S "$SERVICE_USER"
    adduser -S -D -H -h "$STATE_DIR" -s /sbin/nologin -G "$SERVICE_USER" "$SERVICE_USER"
    ok "Created system user $SERVICE_USER"
fi
# Serial adapters passed into the container are group dialout (gid 20).
addgroup "$SERVICE_USER" dialout 2>/dev/null || true

# Build the new tree next to the running one so the bot stays up during the
# dependency install, then swap with a short stop/start.
STAGE="$INSTALL_DIR.new"
rm -rf "$STAGE"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$STAGE"' EXIT
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$VERSION" -o "$TMP/src.tar.gz" ||
    die "Download failed for $VERSION"
tar -xzf "$TMP/src.tar.gz" -C "$TMP"
mv "$TMP"/meshcore-bot-*/ "$STAGE"
printf '{"installer_version": "%s"}\n' "$VERSION" >"$STAGE/.version_info"
# Releases older than this installer do not ship the init script; fall back to
# the copy next to this file, then to the one already installed.
initd="$STAGE/scripts/proxmox/meshcore-bot.openrc"
[ -f "$initd" ] || initd="$(dirname "$0")/meshcore-bot.openrc"
[ -f "$initd" ] || initd="/etc/init.d/meshcore-bot"
[ -f "$initd" ] || die "meshcore-bot.openrc not found in $VERSION or next to $0"

info "Creating Python environment (this takes a few minutes)"
python3 -m venv "$STAGE/venv"
"$STAGE/venv/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip
"$STAGE/venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$STAGE/requirements.txt" ||
    die "Dependency install failed; the running installation was left untouched"
ok "Python dependencies installed"

install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$CONF_DIR" "$STATE_DIR"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$LOG_DIR"

if [ -n "$IMPORT_CONFIG" ]; then
    [ ! -f "$CONFIG_FILE" ] || cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak-$(date +%Y%m%d%H%M%S)"
    cp "$IMPORT_CONFIG" "$CONFIG_FILE"
    # Map the Docker volume layout (docs/docker.md) onto the service layout.
    sed -i -e "s|/data/databases/|$STATE_DIR/|g" -e "s|/data/logs/|$LOG_DIR/|g" "$CONFIG_FILE"
    ok "Imported config from $IMPORT_CONFIG"
elif [ ! -f "$CONFIG_FILE" ]; then
    cp "$STAGE/config.ini.example" "$CONFIG_FILE"
    START=false
    warn "Created $CONFIG_FILE from config.ini.example - edit [Connection] and [Bot] before starting"
fi
python3 "$STAGE/scripts/migrate_service_layout.py" --config "$CONFIG_FILE" \
    --legacy-base "$CONF_DIR" --state-dir "$STATE_DIR" --log-dir "$LOG_DIR"

if [ -n "$IMPORT_DB" ]; then
    target="$STATE_DIR/$(basename "$IMPORT_DB")"
    [ ! -f "$target" ] || mv "$target" "$target.bak-$(date +%Y%m%d%H%M%S)"
    python3 - "$IMPORT_DB" "$target" <<'EOF'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
result = dst.execute("PRAGMA integrity_check").fetchone()[0]
sys.exit(0 if result == "ok" else f"integrity_check failed: {result}")
EOF
    ok "Imported database to $target"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
# config.ini and its backups hold API keys and broker passwords.
chmod 0600 "$CONF_DIR"/*

[ "$initd" = /etc/init.d/meshcore-bot ] || install -m 0755 "$initd" /etc/init.d/meshcore-bot

if rc-service meshcore-bot status >/dev/null 2>&1; then
    rc-service meshcore-bot stop >/dev/null
fi
rm -rf "$INSTALL_DIR.old"
if [ -d "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$INSTALL_DIR.old"
    info "Previous version kept in $INSTALL_DIR.old"
fi
mv "$STAGE" "$INSTALL_DIR"
chown -R root:root "$INSTALL_DIR"
chmod -R go-w "$INSTALL_DIR"
rc-update add meshcore-bot default >/dev/null 2>&1 || true
ok "Installed meshcore-bot $VERSION to $INSTALL_DIR"

if [ "$START" = true ]; then
    rc-service meshcore-bot start
    ok "Service started - logs: $LOG_DIR"
else
    info "Start the bot with: rc-service meshcore-bot start"
fi
