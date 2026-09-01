# Servarr Stack

A portable Docker Compose stack for automated media organization and playback. It runs qBittorrent inside Gluetun's VPN network namespace, with Prowlarr, Sonarr, Radarr, Jellyfin, and Seerr on a private Compose network.

> [!WARNING]
> You are responsible for complying with copyright law, your VPN provider's terms, indexer rules, and all other laws that apply where you live. This project does not provide media, indexers, or VPN access.

## Quick start

### Windows

Install and start Docker Desktop, then open PowerShell:

```powershell
git clone https://github.com/ezralael/servarr-stack.git
cd servarr-stack
.\install.ps1
```

### Linux

Install Docker Engine with the Compose plugin, then:

```bash
git clone https://github.com/ezralael/servarr-stack.git
cd servarr-stack
chmod +x install.sh
./install.sh
```

Both installers prompt for media, download, config, and VPN settings; create directories and a private `.env`; validate Compose; pull images; and start the stack. Rerunning an installer reuses `.env` and existing data without deleting or overwriting it.

For non-interactive examples, run `Get-Help .\install.ps1 -Detailed` or `./install.sh --help`. Use `-NoLaunch` (Windows) or `--no-launch` (Linux) to create and validate the configuration without pulling or starting containers.

## Requirements

- A 64-bit Windows 10/11 or modern Linux host
- Docker Desktop on Windows, or Docker Engine plus Docker Compose v2 on Linux
- Git for the quick-start commands
- A paid or free VPN account supported by Gluetun
- At least 4 GB RAM available to Docker; 8 GB or more is recommended
- Several GB of free space for images/configuration, plus storage sized for your media
- For Jellyfin transcoding, a capable CPU or supported GPU; this baseline Compose file uses CPU transcoding for portability

On Windows, share the selected drives with Docker Desktop if prompted. Linux users should set paths on a local filesystem and make sure the account running Docker can read and write them.

## Folder layout

The defaults keep runtime data below the clone, but every root is configurable:

```text
servarr-stack/
â”œâ”€â”€ data/
â”‚   â”œâ”€â”€ config/
â”‚   â”‚   â”œâ”€â”€ gluetun/
â”‚   â”‚   â”œâ”€â”€ qbittorrent/
â”‚   â”‚   â”œâ”€â”€ prowlarr/
â”‚   â”‚   â”œâ”€â”€ sonarr/
â”‚   â”‚   â”œâ”€â”€ radarr/
â”‚   â”‚   â”œâ”€â”€ jellyfin/
â”‚   â”‚   â””â”€â”€ seerr/
â”‚   â”œâ”€â”€ downloads/
â”‚   â”‚   â”œâ”€â”€ complete/
â”‚   â”‚   â””â”€â”€ incomplete/
â”‚   â””â”€â”€ media/
â”‚       â”œâ”€â”€ movies/
â”‚       â””â”€â”€ tv/
â”œâ”€â”€ .env                 # local only; never commit
â””â”€â”€ docker-compose.yml
```

Inside qBittorrent, Sonarr, and Radarr, downloads are always `/downloads`. Inside Sonarr, Radarr, and Jellyfin, organized media is always `/media`. Those consistent container paths avoid remote-path mappings and let imports work regardless of host path syntax. Hardlinks require downloads and media to be on the same underlying filesystem; otherwise imports use copies.

## Service URLs

| Service | Default local URL | Purpose |
|---|---|---|
| qBittorrent | <http://localhost:8080> | Download client; port is published by Gluetun |
| Prowlarr | <http://localhost:9696> | Indexer manager |
| Sonarr | <http://localhost:8989> | TV library automation |
| Radarr | <http://localhost:7878> | Movie library automation |
| Jellyfin | <http://localhost:8096> | Media server |
| Seerr | <http://localhost:5055> | Media requests and discovery |

Gluetun has no Web UI. Check its status with `docker compose ps` and `docker compose logs gluetun`.

## VPN configuration

The installer writes credentials only to the ignored local `.env`. To configure by hand, copy `.env.example` to `.env` and follow the [Gluetun provider setup guide](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

For OpenVPN, set `VPN_SERVICE_PROVIDER`, `VPN_TYPE=openvpn`, `OPENVPN_USER`, and `OPENVPN_PASSWORD`. Many providers issue separate service credentials; your website login may not work. For WireGuard, set `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY`, and `WIREGUARD_ADDRESSES`. Some providers also need `SERVER_COUNTRIES` or provider-specific variables; add only the variables documented by Gluetun to the `gluetun.environment` section and keep their values in `.env`.

Never commit `.env`, `.ovpn` files, WireGuard configurations, private keys, or provider credentials. After editing VPN settings, apply them with:

```console
docker compose up -d --force-recreate gluetun qbittorrent
```

Confirm the VPN before adding downloads:

```console
docker compose ps
docker compose logs --tail 100 gluetun
docker compose exec qbittorrent sh -c "wget -qO- https://ipinfo.io/ip"
```

Compare that last address with your normal public address. qBittorrent cannot create its own network route in this stack: it uses `network_mode: service:gluetun`, has no `ports` block, and starts only after Gluetun is healthy.

## First-time application setup

1. **qBittorrent:** Open port 8080. Find the temporary admin password in `docker compose logs qbittorrent`, sign in, and change it. Set the default save path to `/downloads/complete` and incomplete path to `/downloads/incomplete`. Keep the Web UI port at `8080` inside the container.
2. **Sonarr:** Add `/media/tv` as the root folder. Under **Settings â†’ Download Clients**, add qBittorrent with host `gluetun`, port `8080`, and its Web UI credentials. Use category `tv`.
3. **Radarr:** Add `/media/movies` as the root folder. Add the same qBittorrent endpoint (`gluetun:8080`) with category `movies`.
4. **Prowlarr:** Add only indexers you are authorized to use. Under **Settings â†’ Apps**, add Sonarr at `http://sonarr:8989` and Radarr at `http://radarr:7878`, using the API keys displayed in each app under **Settings â†’ General**.
5. **Jellyfin:** Create a new local administrator, then add a Shows library at `/media/tv` and a Movies library at `/media/movies`. Do not expose Jellyfin directly to the internet without authentication and a properly configured reverse proxy.
6. **Seerr:** Connect Jellyfin at `http://jellyfin:8096`, then connect Sonarr and Radarr using their internal service URLs and API keys.

API keys remain in each application's ignored config directory. They are never part of this repository.

## Networking and VPN isolation

Compose creates one private bridge network for Gluetun, Prowlarr, Sonarr, Radarr, Jellyfin, and Seerr. Those services resolve one another by service name. qBittorrent is different: `network_mode: service:gluetun` makes it share Gluetun's network namespace. It gets no separate IP, no separate default route, and no direct host port publishing. Ports 8080 and 6881 are published on Gluetun instead. Gluetun's firewall blocks non-VPN egress and the health-gated dependency prevents qBittorrent from starting before the tunnel is healthy.

Prowlarr and the media managers do not need the VPN for normal operation and retain direct networking. If your threat model requires more services behind the VPN, review Gluetun's firewall rules and DNS behavior before changing the topology.

## Operations

Run these commands from the repository directory.

Update images and recreate containers without deleting persistent data:

```console
docker compose pull
docker compose up -d
```

Stop, start, or restart:

```console
docker compose stop
docker compose start
docker compose restart
```

See status and logs:

```console
docker compose ps
docker compose logs -f --tail 100
```

### Back up and restore

The chosen `CONFIG_ROOT` contains application databases, settings, users, API keys, and history. Treat backups as secrets. For a consistent backup, stop the stack, copy `CONFIG_ROOT` and `.env` to encrypted storage, then start it again. Media and completed downloads can be backed up separately according to their size and importance. The `jellyfin-cache` Docker volume is disposable and does not need backup.

To restore, install Docker on the destination, clone this repository, restore `.env` and the config directories to the same paths (or update the paths in `.env`), then run `docker compose up -d`. Keep ownership consistent on Linux with the `PUID` and `PGID` values in `.env`.

### Uninstall

Remove the containers and private network while preserving config/media/downloads:

```console
docker compose down
```

If you also want to remove the disposable Jellyfin cache volume, use `docker compose down -v`. Delete the clone and the configured data directories manually only after verifying your backups. The installers never perform those deletions.

## Troubleshooting

### Permission denied or read-only files

On Linux, confirm `PUID=$(id -u)` and `PGID=$(id -g)` in `.env`, then ensure that user owns the config, download, and media directories. Avoid running the installer once with `sudo` and later without it. On Docker Desktop, verify that the selected Windows drive is available to Docker and use forward slashes in `.env` paths, such as `E:/Media`.

### Gluetun is unhealthy

Run `docker compose logs --tail 200 gluetun`. Common causes are an unsupported provider identifier, website credentials instead of VPN service credentials, an incomplete WireGuard address, an unavailable country filter, incorrect system time, or a host firewall blocking the VPN protocol. Correct `.env`, then run `docker compose up -d --force-recreate gluetun qbittorrent`. Do not remove qBittorrent's shared network mode as a workaround.

### qBittorrent Web UI is unreachable or has no connectivity

Gluetun must be healthy because it owns port 8080 and qBittorrent's network. Check `docker compose ps`, then inspect both containers' logs. Make sure no other host process uses the configured Web UI port. Within Sonarr/Radarr, the qBittorrent host is `gluetun`, not `localhost` or `qbittorrent`. If the UI opens but torrents stall, verify the VPN endpoint, provider port-forwarding policy, and that qBittorrent's listening port matches `TORRENTING_PORT`.

### Imports fail or create duplicate copies

Use `/downloads` in qBittorrent, Sonarr, and Radarr. Use `/media/tv` and `/media/movies` as root folders. Do not enter host paths such as drive letters in an application UI. Hardlinks work only when the download and media roots are on the same filesystem and permissions allow them; separate disks or shares require copying.

### Jellyfin cannot see imported media

Confirm the files appear on the host under the configured media root, then run `docker compose exec jellyfin ls -la /media`. Jellyfin libraries must point to `/media/tv` and `/media/movies`, not host paths. On Linux, grant the configured user/group read and directory traversal permissions. After correcting paths or permissions, scan the Jellyfin libraries again.

### A host port is already in use

Change the corresponding value in `.env` (for example `SONARR_PORT=8990`) and run `docker compose up -d`. Container-to-container URLs keep their documented internal ports; only the browser URL changes.

## Security notes

- The service Web UIs bind to all host interfaces by default. Use host firewall rules, authentication, or a secure reverse proxy before allowing access beyond a trusted LAN.
- Never publish qBittorrent directly or add a network to it; doing so can create a VPN bypass.
- Keep Docker, images, and the host operating system updated.
- Backups of `.env` and `CONFIG_ROOT` contain secrets and personal application data.

## License

The orchestration files and installers in this repository are provided under the MIT License. Each container image and application has its own license.

