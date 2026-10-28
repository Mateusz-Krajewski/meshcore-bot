# Proxmox VE (Alpine LXC)

Run the bot in a small unprivileged Alpine Linux container on Proxmox VE, managed by
OpenRC. No Docker inside the container: the bot runs from a Python virtualenv, using the
same directory layout as the [systemd service](service-installation.md).

Two scripts in `scripts/proxmox/` do the work:

| Script | Runs on | Does |
|--------|---------|------|
| `create-lxc.sh` | Proxmox host | Downloads the newest Alpine template, creates and starts the CT, then runs `install-alpine.sh` inside it |
| `install-alpine.sh` | Alpine host or CT | Installs (or upgrades) the bot, its virtualenv and the `meshcore-bot` OpenRC service |

## Requirements

- Proxmox VE 8 or newer (USB serial passthrough with `--serial` needs 8.1+)
- About 512 MB RAM and 2 GB disk for the container
- A radio reachable over TCP, or a USB serial radio on the Proxmox host. BLE inside an
  LXC is not covered here.

## Quick start

On the Proxmox host, as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/agessaman/meshcore-bot/main/scripts/proxmox/create-lxc.sh
bash create-lxc.sh
```

That creates a CT with the next free ID, DHCP networking and the latest release. Run
`bash create-lxc.sh --help` for every option. Common ones:

```bash
bash create-lxc.sh --ctid 120 --ip 192.168.1.50/24 --gw 192.168.1.1 \
  --nameserver 192.168.1.1 --serial /dev/serial/by-id/usb-Espressif_...-if00
```

With a new config the service is enabled but **not started**. Set `[Connection]` and
`[Bot]` first, then start it:

```bash
pct exec <ctid> -- vi /etc/meshcore-bot/config.ini
pct exec <ctid> -- rc-service meshcore-bot start
```

For a serial radio, set `serial_port` to the same path you passed to `--serial`.

## Installing into an existing Alpine CT

Copy `install-alpine.sh` and `meshcore-bot.openrc` into the CT and run, as root:

```bash
sh install-alpine.sh                    # latest release
sh install-alpine.sh --version v1.1.0   # a specific tag or branch
```

## Where everything lives

| Path | Contents | Owner / mode |
|------|----------|--------------|
| `/opt/meshcore-bot/` | Bot source for the installed version | root, read-only for the bot |
| `/opt/meshcore-bot/venv/` | Python virtualenv with all dependencies | root |
| `/opt/meshcore-bot/.version_info` | Installed tag, shown by the `version` command and web viewer | root |
| `/opt/meshcore-bot.old/` | Previous version, kept after an upgrade for rollback | root |
| `/etc/meshcore-bot/config.ini` | Configuration (API keys, broker passwords) | `meshcore`, `0600` |
| `/etc/meshcore-bot/config.ini.bak.*` | Backups written when the installer rewrites paths | `meshcore`, `0600` |
| `/var/lib/meshcore-bot/meshcore_bot.db` | SQLite database: contacts, stats, packet history, web viewer data | `meshcore` |
| `/var/lib/meshcore-bot/local/` | [Local plugins](local-plugins.md) and local translations | `meshcore` |
| `/var/log/meshcore-bot/meshcore_bot.log` | Bot log (`[Logging] log_file`), rotated by the bot | `meshcore` |
| `/etc/init.d/meshcore-bot` | OpenRC service | root |
| `/etc/conf.d/meshcore-bot` | Optional overrides (`MESHCORE_BOT_CONFIG`, `MESHCORE_BOT_DIR`, `MESHCORE_BOT_CONSOLE_LOG`) | root |

The bot runs as the system user `meshcore`, which is in the `dialout` group for serial
access. Back up `/etc/meshcore-bot` and `/var/lib/meshcore-bot`; everything else is
recreated by the installer.

## Managing the service

```bash
rc-service meshcore-bot status|start|stop|restart
rc-service meshcore-bot reload     # SIGHUP: reload config.ini without restarting
tail -f /var/log/meshcore-bot/meshcore_bot.log
```

Like the systemd unit, the supervisor restarts the bot after a crash but gives up after
3 restarts in 60 seconds, so a bot that cannot reach its radio ends up `stopped` instead
of looping.

Everything the bot logs goes to `meshcore_bot.log`. Its duplicate console output is
discarded; if the bot stops before it starts logging (for example a broken config), run
it once in the foreground, or capture the console while you debug:

```bash
su -s /bin/sh meshcore -c 'cd /opt/meshcore-bot && venv/bin/python meshcore_bot.py --config /etc/meshcore-bot/config.ini --validate-config'
echo 'MESHCORE_BOT_CONSOLE_LOG=/var/log/meshcore-bot/console.log' >> /etc/conf.d/meshcore-bot
```

## Upgrading

Run the installer again inside the CT. It builds the new version next to the running
one, then swaps them with a brief restart; config, database and logs are kept.

```bash
pct exec <ctid> -- sh -c 'wget -qO- https://raw.githubusercontent.com/agessaman/meshcore-bot/main/scripts/proxmox/install-alpine.sh | sh'
```

To roll back, stop the service, swap `/opt/meshcore-bot.old` back to
`/opt/meshcore-bot`, and start it again.

## Migrating from Docker

Stop the Docker container first, so the database is not being written while you copy
it. Then pass its config and database to `create-lxc.sh` (or to `install-alpine.sh`):

```bash
docker stop meshcore-bot && docker update --restart=no meshcore-bot
# copy data/config/config.ini and data/databases/meshcore_bot.db to the Proxmox host, then:
bash create-lxc.sh --config ./config.ini --database ./meshcore_bot.db
```

The installer rewrites the [Docker volume paths](docker.md) (`/data/databases/...`,
`/data/logs/...`) to the layout above, and checks the copied database with SQLite's
`integrity_check`. Because the config is imported, the service starts straight away.

A companion radio accepts only one TCP client at a time: keep the Docker container
stopped once the LXC is running.
