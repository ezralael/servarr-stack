# Servarr Stack

A portable Docker Compose stack for automated media organization and playback. It can route qBittorrent through Gluetun's VPN network namespace (recommended) or run qBittorrent directly, with Prowlarr, Sonarr, Radarr, Jellyfin, and Seerr on a private Compose network.

> [!WARNING]
> You are responsible for complying with copyright law, your VPN provider's terms, indexer rules, and all other laws that apply where you live. This project does not provide media, indexers, or VPN access.

## Quick start

### Windows graphical installer

1. Install and start Docker Desktop.
2. Download this repository with **Code → Download ZIP**, then extract it.
3. Double-click **`Install-ServarrStack.cmd`**.
4. Choose one shared data folder, a separate application-config folder, one administrator login, and the connection mode. If VPN protection is selected, enter the VPN settings. Select **Install**.

The graphical installer creates the Jellyfin account and libraries, configures qBittorrent, enables hardlinks, connects Sonarr/Radarr/Prowlarr, initializes Seerr, and then opens Seerr. API keys are discovered locally and never shown or sent away. Windows may show a standard warning because this community script is not code-signed; its complete source is included as `windows-installer.ps1`.

Alternatively, install from PowerShell:

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

The graphical Windows installer, PowerShell engine, and Linux installer prompt for a shared data root, a separate config root, and VPN settings; create directories; prove the selected data root can hardlink between downloads and media; create a private `.env`; validate Compose; pull images; and start the stack. Rerunning an installer reuses `.env` and existing data without deleting or overwriting it.

The folder fields are prefilled with a hardlink-compatible layout. VPN protection is selected by default, but users without a VPN can choose direct mode after acknowledging the public-IP warning. The administrator password stays in memory during installation and is saved only by the local applications that need it; it is not written to `.env` or this repository.

For non-interactive examples, run `Get-Help .\install.ps1 -Detailed` or `./install.sh --help`. On Linux, pass `--without-vpn` to select direct mode. Use `-NoLaunch` (Windows) or `--no-launch` (Linux) to create and validate the configuration without pulling or starting containers.

## Requirements

- A 64-bit Windows 10/11 or modern Linux host
- Docker Desktop on Windows, or Docker Engine plus Docker Compose v2 on Linux
- Git for the quick-start commands
- Optional but recommended: a VPN account supported by Gluetun
- At least 4 GB RAM available to Docker; 8 GB or more is recommended
- Several GB of free space for images/configuration, plus storage sized for your media
- For Jellyfin transcoding, a capable CPU or supported GPU; this baseline Compose file uses CPU transcoding for portability

On Windows, share the selected drives with Docker Desktop if prompted. Linux users should set paths on a local filesystem and make sure the account running Docker can read and write them.

## Folder layout

The defaults keep runtime data below the clone, but both roots are configurable. Downloads and organized media intentionally live beneath one data root:

```text
servarr-stack/
├── config/
│   ├── gluetun/
│   ├── qbittorrent/
│   ├── prowlarr/
│   ├── sonarr/
│   ├── radarr/
│   ├── jellyfin/
│   └── seerr/
├── data/
│   ├── downloads/
│   │   ├── complete/
│   │   └── incomplete/
│   └── media/
│       ├── movies/
│       └── tv/
├── .env                 # local only; never commit
└── docker-compose.yml
```

qBittorrent, Sonarr, and Radarr all receive the same host data root as one `/data` bind mount. Use `/data/downloads` for downloads, `/data/media/tv` for Sonarr, and `/data/media/movies` for Radarr. This single-mount layout allows Sonarr and Radarr to hardlink completed files instead of making a second full copy. Jellyfin receives only the organized `data/media` subtree as `/media`.

Hardlinks still require a host filesystem that supports them. Keep `data/downloads` and `data/media` together under the selected local data root; do not replace either one with a separate disk, network share, or independent Docker mount. Moving or deleting one hardlink does not delete the file data while another link remains.

### Migrating from the older separate-folder layout

Older releases used separate `MEDIA_ROOT` and `DOWNLOADS_ROOT` mounts, which cannot reliably hardlink across the container mount boundary. The installers deliberately refuse to rewrite that existing `.env` automatically because moving a media library is a data-sensitive operation.

Back up `.env` and the application config root, stop that stack, and choose a new local data root with `downloads` and `media` subfolders. Copy—not delete—the old downloads and media into those subfolders, replace `MEDIA_ROOT` and `DOWNLOADS_ROOT` in `.env` with one `DATA_ROOT`, then recreate the stack. Update the application paths to the `/data/...` values below and verify imports and playback before removing the old copies. Existing duplicated files are not retroactively converted; new imports can use hardlinks.

## Service URLs

| Service | Default local URL | Purpose |
|---|---|---|
| qBittorrent | <http://localhost:8080> | Download client; port is published by Gluetun in VPN mode or qBittorrent in direct mode |
| Prowlarr | <http://localhost:9696> | Indexer manager |
| Sonarr | <http://localhost:8989> | TV library automation |
| Radarr | <http://localhost:7878> | Movie library automation |
| Jellyfin | <http://localhost:8096> | Media server |
| Seerr | <http://localhost:5055> | Media requests and discovery |

Gluetun has no Web UI and runs only in VPN mode. Check its status with `docker compose ps` and `docker compose logs gluetun`.

## Connection modes and VPN configuration

> [!CAUTION]
> **Direct mode does not hide your public IP address from torrent peers.** A VPN is not legally required for lawful downloads, but direct mode provides less network privacy. A VPN does not make unlawful activity lawful and does not guarantee anonymity. Never expose qBittorrent's Web UI directly to the internet.

The installer offers two mutually exclusive modes:

- **VPN mode (recommended):** starts Gluetun and runs `qbittorrent-vpn` inside Gluetun's network namespace. Gluetun owns the host ports and blocks qBittorrent from bypassing the tunnel.
- **Direct mode:** does not start Gluetun. The `qbittorrent` service uses the normal Compose network and publishes its own ports.

The selected mode is stored locally as `COMPOSE_PROFILES=vpn` or `COMPOSE_PROFILES=direct`, so ordinary commands such as `docker compose up -d` continue using that choice. Do not activate both profiles simultaneously because both qBittorrent services share the same configuration and host ports.

In VPN mode, the installer writes credentials only to the ignored local `.env`. To configure by hand, copy `.env.example` to `.env` and follow the [Gluetun provider setup guide](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

For OpenVPN, set `VPN_SERVICE_PROVIDER`, `VPN_TYPE=openvpn`, `OPENVPN_USER`, and `OPENVPN_PASSWORD`. Many providers issue separate service credentials; your website login may not work. For WireGuard, set `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY`, and `WIREGUARD_ADDRESSES`. Some providers also need `SERVER_COUNTRIES` or provider-specific variables; add only the variables documented by Gluetun to the `gluetun.environment` section and keep their values in `.env`.

Never commit `.env`, `.ovpn` files, WireGuard configurations, private keys, or provider credentials. After editing VPN settings, apply them with:

```console
docker compose up -d --force-recreate gluetun qbittorrent-vpn
```

Confirm the VPN before adding downloads:

```console
docker compose ps
docker compose logs --tail 100 gluetun
docker compose exec qbittorrent-vpn sh -c "wget -qO- https://ipinfo.io/ip"
```

Compare that last address with your normal public address. In VPN mode, `qbittorrent-vpn` cannot create its own network route: it uses `network_mode: service:gluetun`, has no `ports` block, and starts only after Gluetun is healthy.

## First-time application setup

The Windows graphical installer completes the repetitive setup automatically:

- Creates the Jellyfin administrator and the Movies and TV Shows libraries.
- Changes qBittorrent from its temporary login to the chosen administrator login and sets `/data/downloads/complete` and `/data/downloads/incomplete`.
- Adds `/data/media/tv` to Sonarr and `/data/media/movies` to Radarr, explicitly enables hardlinks, and connects both to qBittorrent with separate categories.
- Connects Prowlarr to Sonarr and Radarr using API keys read only from the local config directories.
- Connects Seerr to Jellyfin, Sonarr, and Radarr, selects the first available quality profile, and opens Seerr.

The remaining user step is to add indexers or sources that the user is authorized to access in Prowlarr. Those choices and credentials cannot be safely guessed or bundled. After that, ordinary use is **open Seerr → request a movie or show → watch it in Jellyfin**.

PowerShell users can request the same automation with `-ConfigureApplications` plus `-AdminUsername`, `-AdminPassword`, and `-AdminEmail`. Linux users currently use the manual application setup below; the graphical zero-API-key wizard is Windows-only. API keys remain in the ignored application config directories and are never part of this repository.

### Linux or manual fallback

1. In qBittorrent, change the temporary login and set the save paths to `/data/downloads/complete` and `/data/downloads/incomplete`.
2. In Sonarr, add `/data/media/tv`; in Radarr, add `/data/media/movies`; keep **Use Hardlinks instead of Copy** enabled.
3. Add qBittorrent to each manager at `gluetun:8080` in VPN mode or `qbittorrent:8080` in direct mode, using categories `tv` and `movies`.
4. In Prowlarr, connect Sonarr at `http://sonarr:8989` and Radarr at `http://radarr:7878` using their locally displayed API keys.
5. Create the Jellyfin administrator and add Movies at `/media/movies` and TV Shows at `/media/tv`.
6. In Seerr, connect Jellyfin at `http://jellyfin:8096`, then add Sonarr and Radarr using their internal hostnames and local API keys.

## Networking and VPN isolation

Compose creates one private bridge network for Prowlarr, Sonarr, Radarr, Jellyfin, and Seerr. Those services resolve one another by service name. In VPN mode, qBittorrent shares Gluetun's network namespace, gets no separate IP or route, and publishes no ports itself; Gluetun publishes ports 8080 and 6881 and its firewall blocks non-VPN egress. In direct mode, Gluetun is inactive and qBittorrent joins the private bridge network as `qbittorrent` while publishing those ports itself.

Prowlarr and the media managers retain direct networking in both modes. Switching modes later requires updating the qBittorrent hostname in Sonarr and Radarr as described above.

### Switch connection mode later

Stop the current profile before changing modes so two qBittorrent containers never use the same config or ports. For example, to change from VPN to direct mode:

```console
docker compose --profile vpn down
```

Change `COMPOSE_PROFILES=vpn` to `COMPOSE_PROFILES=direct` in `.env`, then run `docker compose up -d`. To switch back, run `docker compose --profile direct down`, restore `COMPOSE_PROFILES=vpn`, and run `docker compose up -d`. Finally, change the qBittorrent host in Sonarr and Radarr to `qbittorrent` for direct mode or `gluetun` for VPN mode. These commands preserve the mounted application data, media, and downloads.

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

In VPN mode, run `docker compose logs --tail 200 gluetun`. Common causes are an unsupported provider identifier, website credentials instead of VPN service credentials, an incomplete WireGuard address, an unavailable country filter, incorrect system time, or a host firewall blocking the VPN protocol. Correct `.env`, then run `docker compose up -d --force-recreate gluetun qbittorrent-vpn`.

### qBittorrent Web UI is unreachable or has no connectivity

In VPN mode, Gluetun must be healthy because it owns port 8080 and qBittorrent's network. Check `docker compose ps`, then inspect both containers' logs. In direct mode, Gluetun should not be running. Make sure no other host process uses the configured Web UI port. Within Sonarr/Radarr, use host `gluetun` for VPN mode or `qbittorrent` for direct mode—never `localhost`. If the UI opens but torrents stall, verify the selected mode and that qBittorrent's listening port matches `TORRENTING_PORT`.

### Imports fail or create duplicate copies

Use `/data/downloads` in qBittorrent, Sonarr, and Radarr. Use `/data/media/tv` and `/data/media/movies` as the Sonarr and Radarr root folders. Do not enter host paths such as drive letters in an application UI. Enable **Use Hardlinks instead of Copy** under **Settings → Media Management** in Sonarr and Radarr. If imports still copy, confirm the source and destination both begin with `/data`, the host data root is a local hardlink-capable filesystem, and permissions allow link creation.

### Jellyfin cannot see imported media

Confirm the files appear on the host under the configured media root, then run `docker compose exec jellyfin ls -la /media`. Jellyfin libraries must point to `/media/tv` and `/media/movies`, not host paths. On Linux, grant the configured user/group read and directory traversal permissions. After correcting paths or permissions, scan the Jellyfin libraries again.

### A host port is already in use

Change the corresponding value in `.env` (for example `SONARR_PORT=8990`) and run `docker compose up -d`. Container-to-container URLs keep their documented internal ports; only the browser URL changes.

## Security notes

- The service Web UIs bind to all host interfaces by default. Use host firewall rules, authentication, or a secure reverse proxy before allowing access beyond a trusted LAN.
- Do not forward qBittorrent's Web UI port through your router or expose it directly to the internet.
- Keep Docker, images, and the host operating system updated.
- Backups of `.env` and `CONFIG_ROOT` contain secrets and personal application data.

## License

The orchestration files and installers in this repository are provided under the MIT License. Each container image and application has its own license.
