#!/usr/bin/env bash
set -Eeuo pipefail

stack_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="$stack_root/.env"
media_path=""
downloads_path=""
config_path=""
timezone="Etc/UTC"
vpn_provider=""
vpn_type="openvpn"
openvpn_user=""
openvpn_password=""
wireguard_private_key=""
wireguard_addresses=""
non_interactive=false
no_launch=false

usage() {
  printf '%s\n' "Usage: ./install.sh [--media PATH] [--downloads PATH] [--config PATH]" \
    "  [--vpn-provider NAME] [--vpn-type openvpn|wireguard] [--timezone ZONE]" \
    "  [--non-interactive] [--no-launch]"
}

while (($#)); do
  case "$1" in
    --media) media_path=${2:?Missing value}; shift 2 ;;
    --downloads) downloads_path=${2:?Missing value}; shift 2 ;;
    --config) config_path=${2:?Missing value}; shift 2 ;;
    --timezone) timezone=${2:?Missing value}; shift 2 ;;
    --vpn-provider) vpn_provider=${2:?Missing value}; shift 2 ;;
    --vpn-type) vpn_type=${2:?Missing value}; shift 2 ;;
    --openvpn-user) openvpn_user=${2:?Missing value}; shift 2 ;;
    --openvpn-password) openvpn_password=${2:?Missing value}; shift 2 ;;
    --wireguard-private-key) wireguard_private_key=${2:?Missing value}; shift 2 ;;
    --wireguard-addresses) wireguard_addresses=${2:?Missing value}; shift 2 ;;
    --non-interactive) non_interactive=true; shift ;;
    --no-launch) no_launch=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$vpn_type" == openvpn || "$vpn_type" == wireguard ]] || {
  printf 'VPN type must be openvpn or wireguard.\n' >&2; exit 2;
}
command -v docker >/dev/null 2>&1 || {
  printf 'Docker was not found. Install Docker Engine or Docker Desktop.\n' >&2; exit 1;
}
docker info --format '{{.ServerVersion}}' >/dev/null
docker compose version >/dev/null

prompt() {
  local label=$1 current=$2 default=$3 answer
  if [[ -n "$current" ]]; then printf '%s' "$current"; return; fi
  if $non_interactive; then printf '%s' "$default"; return; fi
  read -r -p "$label${default:+ [$default]}: " answer
  printf '%s' "${answer:-$default}"
}

prompt_secret() {
  local label=$1 current=$2 answer
  if [[ -n "$current" ]]; then printf '%s' "$current"; return; fi
  if $non_interactive; then return; fi
  read -r -s -p "$label: " answer; printf '\n' >&2
  printf '%s' "$answer"
}

env_quote() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || {
    printf 'Environment values cannot contain newlines.\n' >&2; exit 2;
  }
  printf "'%s'" "${1//\'/\\\'}"
}

if [[ -f "$env_file" ]]; then
  printf 'Using the existing .env. No values or data were overwritten.\n'
else
  media_path=$(prompt "Media directory" "$media_path" "$stack_root/data/media")
  downloads_path=$(prompt "Downloads directory" "$downloads_path" "$stack_root/data/downloads")
  config_path=$(prompt "Application config directory" "$config_path" "$stack_root/data/config")
  vpn_provider=$(prompt "Gluetun VPN provider identifier" "$vpn_provider" "your-provider")
  if [[ "$vpn_type" == openvpn ]]; then
    openvpn_user=$(prompt "OpenVPN service username" "$openvpn_user" "")
    openvpn_password=$(prompt_secret "OpenVPN service password" "$openvpn_password")
  else
    wireguard_private_key=$(prompt_secret "WireGuard private key" "$wireguard_private_key")
    wireguard_addresses=$(prompt "WireGuard address (for example 10.0.0.2/32)" "$wireguard_addresses" "")
  fi

  mkdir -p -- "$media_path" "$downloads_path" "$config_path"
  mkdir -p -- "$media_path/movies" "$media_path/tv" "$downloads_path/complete" "$downloads_path/incomplete"
  for app in gluetun qbittorrent prowlarr sonarr radarr jellyfin seerr; do
    mkdir -p -- "$config_path/$app"
  done
  media_path=$(cd -- "$media_path" && pwd -P)
  downloads_path=$(cd -- "$downloads_path" && pwd -P)
  config_path=$(cd -- "$config_path" && pwd -P)
  puid=$(id -u); pgid=$(id -g)
  umask 077
  {
    printf 'MEDIA_ROOT=%s\n' "$(env_quote "$media_path")"
    printf 'DOWNLOADS_ROOT=%s\n' "$(env_quote "$downloads_path")"
    printf 'CONFIG_ROOT=%s\n' "$(env_quote "$config_path")"
    printf 'PUID=%s\nPGID=%s\nTZ=%s\n' "$puid" "$pgid" "$(env_quote "$timezone")"
    printf 'VPN_SERVICE_PROVIDER=%s\nVPN_TYPE=%s\nSERVER_COUNTRIES=\x27\x27\n' "$(env_quote "$vpn_provider")" "$(env_quote "$vpn_type")"
    printf 'OPENVPN_USER=%s\nOPENVPN_PASSWORD=%s\n' "$(env_quote "$openvpn_user")" "$(env_quote "$openvpn_password")"
    printf 'WIREGUARD_PRIVATE_KEY=%s\nWIREGUARD_ADDRESSES=%s\n' "$(env_quote "$wireguard_private_key")" "$(env_quote "$wireguard_addresses")"
    printf '%s\n' 'QBITTORRENT_WEBUI_PORT=8080' 'TORRENTING_PORT=6881' 'PROWLARR_PORT=9696' \
      'SONARR_PORT=8989' 'RADARR_PORT=7878' 'JELLYFIN_PORT=8096' 'SEERR_PORT=5055'
  } >"$env_file"
  printf 'Created %s. Keep it private.\n' "$env_file"
fi

docker compose --env-file "$env_file" -f "$stack_root/docker-compose.yml" config --quiet
if $no_launch; then
  printf 'Validation complete; --no-launch prevented pulls and container changes.\n'
  exit 0
fi
docker compose --env-file "$env_file" -f "$stack_root/docker-compose.yml" pull
docker compose --env-file "$env_file" -f "$stack_root/docker-compose.yml" up -d

env_port() {
  local name=$1 default=$2 value
  value=$(sed -n "s/^${name}=//p" "$env_file" | tail -n 1)
  value=${value#\'}; value=${value%\'}; value=${value#\"}; value=${value%\"}
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || value=$default
  printf '%s' "$value"
}

printf '\nServarr stack started:\n'
printf '  qBittorrent  http://localhost:%s\n' "$(env_port QBITTORRENT_WEBUI_PORT 8080)"
printf '  Prowlarr      http://localhost:%s\n' "$(env_port PROWLARR_PORT 9696)"
printf '  Sonarr        http://localhost:%s\n' "$(env_port SONARR_PORT 8989)"
printf '  Radarr        http://localhost:%s\n' "$(env_port RADARR_PORT 7878)"
printf '  Jellyfin      http://localhost:%s\n' "$(env_port JELLYFIN_PORT 8096)"
printf '  Seerr         http://localhost:%s\n' "$(env_port SEERR_PORT 5055)"
printf 'Gluetun has no Web UI. Check it with: docker compose ps\n'

