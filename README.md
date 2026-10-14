# proxmox-simplex

Proxmox VE helper that creates an Ubuntu LXC and installs a [SimpleX](https://simplex.chat) SMP server (optional XFTP).

There is still no official entry in [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) ([request #722](https://github.com/community-scripts/ProxmoxVE/discussions/722)). This repo fills that gap with a small standalone script.

## Requirements

- Proxmox VE host (run as root)
- Ubuntu **22.04 or 24.04** amd64 CT template (SimpleX publishes Ubuntu x86_64 binaries only)
- Outbound HTTPS from the CT
- For a public server: a domain with A/AAAA records, plus TCP **80 / 443 / 5223** forwarded to the CT

## Quick start

On the Proxmox host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mikeybob/proxmox-simplex/main/create-simplex-lxc.sh)"
```

Or clone and run locally:

```bash
git clone https://github.com/mikeybob/proxmox-simplex.git
cd proxmox-simplex
chmod +x create-simplex-lxc.sh install-simplex.sh
./create-simplex-lxc.sh
```

### Non-interactive example

```bash
CTID=120 \
HOSTNAME=simplex \
FQDN=smp.example.com \
INSTALL_XFTP=0 \
STORAGE=local-lvm \
BRIDGE=vmbr0 \
bash create-simplex-lxc.sh
```

## What it does

1. Creates an Ubuntu LXC (`pct create`) with nesting enabled
2. Waits for network
3. Runs `install-simplex.sh` inside the CT, which:
   - Downloads official `smp-server` (and optional `xftp-server`) release binaries
   - Creates `smp` / `xftp` users and config dirs
   - Installs systemd units and the upstream update/uninstall helpers
   - Optionally runs `smp-server init` when `FQDN` is set

### Why not the upstream `install.sh` alone?

The official installer:

- Prompts interactively for SMP vs XFTP
- Uses `uname -p`, which often returns `unknown` inside LXC and then fails architecture detection

`install-simplex.sh` is a non-interactive wrapper that uses `uname -m` and the same release URLs / systemd units as upstream.

## After install

If you skipped `FQDN` during create:

```bash
pct enter <CTID>
su smp -c 'smp-server init --yes --store-log --no-password --control-port --source-code --fqdn=smp.example.com'
systemctl enable --now smp-server
```

Then follow the official guide for TLS/Caddy/Tor as needed:

- [Hosting your own SMP server](https://simplex.chat/docs/server.html)
- [XFTP server](https://simplex.chat/docs/xftp-server.html)

Update binaries later:

```bash
pct enter <CTID>
simplex-servers-update
```

## Files

| File | Where it runs | Purpose |
|------|---------------|---------|
| `create-simplex-lxc.sh` | Proxmox host | Create CT + kick off install |
| `install-simplex.sh` | Inside CT | Install SimpleX server bits |

## License

MIT
