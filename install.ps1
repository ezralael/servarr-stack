[CmdletBinding()]
param(
    [string]$MediaPath,
    [string]$DownloadsPath,
    [string]$ConfigPath,
    [string]$TimeZone = "Etc/UTC",
    [string]$VpnProvider,
    [ValidateSet("openvpn", "wireguard")]
    [string]$VpnType = "openvpn",
    [string]$OpenVpnUser,
    [string]$OpenVpnPassword,
    [string]$WireGuardPrivateKey,
    [string]$WireGuardAddresses,
    [int]$Puid = 1000,
    [int]$Pgid = 1000,
    [switch]$NonInteractive,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$stackRoot = $PSScriptRoot
$envFile = Join-Path $stackRoot ".env"

function Read-Value {
    param([string]$Prompt, [string]$Current, [string]$Default, [switch]$Secret)
    if ($Current) { return $Current }
    if ($NonInteractive) { return $Default }
    if ($Secret) {
        $secure = Read-Host $Prompt -AsSecureString
        if ($secure.Length -eq 0) { return $Default }
        return [System.Net.NetworkCredential]::new("", $secure).Password
    }
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

function ConvertTo-EnvValue {
    param([string]$Value)
    if ($null -eq $Value) { $Value = "" }
    if ($Value -match "[\r\n]") { throw "Environment values cannot contain newlines." }
    return "'" + ($Value -replace "'", "\\'") + "'"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker was not found. Install Docker Desktop, start it, and rerun this script."
}
docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker is installed but its engine is not reachable." }
docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker Compose v2 ('docker compose') is required." }

if (Test-Path -LiteralPath $envFile) {
    Write-Host "Using the existing .env. No values or data were overwritten."
} else {
    $defaultData = Join-Path $stackRoot "data"
    $MediaPath = Read-Value "Media directory" $MediaPath (Join-Path $defaultData "media")
    $DownloadsPath = Read-Value "Downloads directory" $DownloadsPath (Join-Path $defaultData "downloads")
    $ConfigPath = Read-Value "Application config directory" $ConfigPath (Join-Path $defaultData "config")
    $VpnProvider = Read-Value "Gluetun VPN provider identifier" $VpnProvider "your-provider"

    if ($VpnType -eq "openvpn") {
        $OpenVpnUser = Read-Value "OpenVPN service username" $OpenVpnUser ""
        $OpenVpnPassword = Read-Value "OpenVPN service password" $OpenVpnPassword "" -Secret
    } else {
        $WireGuardPrivateKey = Read-Value "WireGuard private key" $WireGuardPrivateKey "" -Secret
        $WireGuardAddresses = Read-Value "WireGuard address (for example 10.0.0.2/32)" $WireGuardAddresses ""
    }

    $MediaPath = [IO.Path]::GetFullPath($MediaPath).Replace('\', '/')
    $DownloadsPath = [IO.Path]::GetFullPath($DownloadsPath).Replace('\', '/')
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath).Replace('\', '/')
    @($MediaPath, $DownloadsPath, $ConfigPath) | ForEach-Object {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
    @("movies", "tv") | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $MediaPath $_) -Force | Out-Null
    }
    @("complete", "incomplete") | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $DownloadsPath $_) -Force | Out-Null
    }
    @("gluetun", "qbittorrent", "prowlarr", "sonarr", "radarr", "jellyfin", "seerr") | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $ConfigPath $_) -Force | Out-Null
    }

    $lines = @(
        "MEDIA_ROOT=$(ConvertTo-EnvValue $MediaPath)",
        "DOWNLOADS_ROOT=$(ConvertTo-EnvValue $DownloadsPath)",
        "CONFIG_ROOT=$(ConvertTo-EnvValue $ConfigPath)",
        "PUID=$Puid", "PGID=$Pgid", "TZ=$(ConvertTo-EnvValue $TimeZone)",
        "VPN_SERVICE_PROVIDER=$(ConvertTo-EnvValue $VpnProvider)",
        "VPN_TYPE=$(ConvertTo-EnvValue $VpnType)", "SERVER_COUNTRIES=''",
        "OPENVPN_USER=$(ConvertTo-EnvValue $OpenVpnUser)",
        "OPENVPN_PASSWORD=$(ConvertTo-EnvValue $OpenVpnPassword)",
        "WIREGUARD_PRIVATE_KEY=$(ConvertTo-EnvValue $WireGuardPrivateKey)",
        "WIREGUARD_ADDRESSES=$(ConvertTo-EnvValue $WireGuardAddresses)",
        "QBITTORRENT_WEBUI_PORT=8080", "TORRENTING_PORT=6881", "PROWLARR_PORT=9696",
        "SONARR_PORT=8989", "RADARR_PORT=7878", "JELLYFIN_PORT=8096", "SEERR_PORT=5055"
    )
    [IO.File]::WriteAllLines($envFile, $lines, [Text.UTF8Encoding]::new($false))
    Write-Host "Created $envFile. Keep it private."
}

docker compose --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") config --quiet
if ($LASTEXITCODE -ne 0) { throw "The resolved Compose configuration is invalid." }

if ($NoLaunch) {
    Write-Host "Validation complete; -NoLaunch prevented pulls and container changes."
    exit 0
}

docker compose --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") pull
if ($LASTEXITCODE -ne 0) { throw "One or more images could not be pulled." }
docker compose --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") up -d
if ($LASTEXITCODE -ne 0) { throw "The stack did not start successfully." }

function Get-EnvSetting {
    param([string]$Name, [string]$Default)
    $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -Last 1
    if (-not $line) { return $Default }
    $value = ($line -split "=", 2)[1].Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq "'" -and $value[-1] -eq "'") -or ($value[0] -eq '"' -and $value[-1] -eq '"'))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    if ($value -notmatch '^\d{1,5}$') { return $Default }
    return $value
}

Write-Host "`nServarr stack started:"
Write-Host "  qBittorrent  http://localhost:$(Get-EnvSetting 'QBITTORRENT_WEBUI_PORT' '8080')"
Write-Host "  Prowlarr      http://localhost:$(Get-EnvSetting 'PROWLARR_PORT' '9696')"
Write-Host "  Sonarr        http://localhost:$(Get-EnvSetting 'SONARR_PORT' '8989')"
Write-Host "  Radarr        http://localhost:$(Get-EnvSetting 'RADARR_PORT' '7878')"
Write-Host "  Jellyfin      http://localhost:$(Get-EnvSetting 'JELLYFIN_PORT' '8096')"
Write-Host "  Seerr         http://localhost:$(Get-EnvSetting 'SEERR_PORT' '5055')"
Write-Host "Gluetun has no Web UI. Check it with: docker compose ps"
