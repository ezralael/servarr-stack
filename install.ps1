[CmdletBinding()]
param(
    [string]$DataPath,
    [string]$ConfigPath,
    [string]$TimeZone = "Etc/UTC",
    [string]$VpnProvider,
    [ValidateSet("openvpn", "wireguard")]
    [string]$VpnType = "openvpn",
    [string]$OpenVpnUser,
    [string]$OpenVpnPassword,
    [string]$WireGuardPrivateKey,
    [string]$WireGuardAddresses,
    [ValidateSet("vpn", "direct")]
    [string]$NetworkMode = "vpn",
    [int]$Puid = 1000,
    [int]$Pgid = 1000,
    [string]$AdminUsername,
    [string]$AdminPassword,
    [string]$AdminEmail,
    [switch]$ConfigureApplications,
    [switch]$NonInteractive,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$stackRoot = $PSScriptRoot
$envFile = Join-Path $stackRoot ".env"
$createdEnvironment = $false

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

function Get-EnvRawSetting {
    param([string]$Name, [string]$Default)
    if (-not (Test-Path -LiteralPath $envFile)) { return $Default }
    $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -Last 1
    if (-not $line) { return $Default }
    $value = ($line -split "=", 2)[1].Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq "'" -and $value[-1] -eq "'") -or ($value[0] -eq '"' -and $value[-1] -eq '"'))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Test-HardlinkLayout {
    param([string]$Root)
    $token = ".servarr-hardlink-test-$([guid]::NewGuid().ToString('N')).tmp"
    $source = Join-Path $Root "downloads/complete/$token"
    $link = Join-Path $Root "media/movies/$token"
    try {
        New-Item -ItemType File -Path $source -ErrorAction Stop | Out-Null
        New-Item -ItemType HardLink -Path $link -Target $source -ErrorAction Stop | Out-Null
    } catch {
        throw "The selected data directory does not support hardlinks across its downloads and media folders. Choose one local NTFS/ext4/XFS-style data root instead of separate disks or a network share. $($_.Exception.Message)"
    } finally {
        foreach ($testFile in @($link, $source)) {
            if (Test-Path -LiteralPath $testFile -PathType Leaf) { Remove-Item -LiteralPath $testFile -Force }
        }
    }
    Write-Host "Verified hardlink support in the selected data directory."
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
    if (-not (Select-String -LiteralPath $envFile -Pattern '^DATA_ROOT=' -Quiet)) {
        throw "This .env uses the older separate media/download mounts. Back up the stack and follow the hardlink migration section in README.md before rerunning the installer."
    }
    $activeProfile = Get-EnvRawSetting "COMPOSE_PROFILES" "vpn"
    if ($activeProfile -notin @("vpn", "direct")) { throw "COMPOSE_PROFILES in .env must be vpn or direct." }
    if (-not (Select-String -LiteralPath $envFile -Pattern '^COMPOSE_PROFILES=' -Quiet)) {
        Add-Content -LiteralPath $envFile -Value "COMPOSE_PROFILES='vpn'"
        Write-Host "Added the new VPN profile setting to the existing .env; all prior values were preserved."
    }
} else {
    $defaultData = Join-Path $stackRoot "data"
    $DataPath = Read-Value "Shared data directory (contains media and downloads)" $DataPath $defaultData
    $ConfigPath = Read-Value "Application config directory" $ConfigPath (Join-Path $stackRoot "config")
    if ($NetworkMode -eq "vpn") {
        $VpnProvider = Read-Value "Gluetun VPN provider identifier" $VpnProvider "your-provider"
        if ($VpnType -eq "openvpn") {
            $OpenVpnUser = Read-Value "OpenVPN service username" $OpenVpnUser ""
            $OpenVpnPassword = Read-Value "OpenVPN service password" $OpenVpnPassword "" -Secret
        } else {
            $WireGuardPrivateKey = Read-Value "WireGuard private key" $WireGuardPrivateKey "" -Secret
            $WireGuardAddresses = Read-Value "WireGuard address (for example 10.0.0.2/32)" $WireGuardAddresses ""
        }
    } else {
        $VpnProvider = "not-configured"
        Write-Warning "DIRECT MODE: qBittorrent traffic will not use a VPN, and torrent peers can see this connection's public IP address."
    }

    $fullDataPath = [IO.Path]::GetFullPath($DataPath).TrimEnd('\', '/')
    $fullConfigPath = [IO.Path]::GetFullPath($ConfigPath).TrimEnd('\', '/')
    if ($fullDataPath -eq [IO.Path]::GetPathRoot($fullDataPath).TrimEnd('\', '/')) {
        throw "Choose a data folder below the drive root; the installer will not mount an entire drive."
    }
    $dataPrefix = $fullDataPath + [IO.Path]::DirectorySeparatorChar
    $configPrefix = $fullConfigPath + [IO.Path]::DirectorySeparatorChar
    if ($fullDataPath -eq $fullConfigPath -or
        $fullConfigPath.StartsWith($dataPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $fullDataPath.StartsWith($configPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The data and application-config folders must be separate and must not contain one another."
    }
    $DataPath = $fullDataPath.Replace('\', '/')
    $ConfigPath = $fullConfigPath.Replace('\', '/')
    @($DataPath, $ConfigPath) | ForEach-Object {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
    @("movies", "tv") | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $DataPath "media/$_") -Force | Out-Null
    }
    @("complete", "incomplete") | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $DataPath "downloads/$_") -Force | Out-Null
    }
    Test-HardlinkLayout $DataPath
    @("gluetun", "qbittorrent", "prowlarr", "sonarr", "radarr", "jellyfin", "seerr") | ForEach-Object {
        New-Item -ItemType Directory -Path (Join-Path $ConfigPath $_) -Force | Out-Null
    }

    $lines = @(
        "DATA_ROOT=$(ConvertTo-EnvValue $DataPath)",
        "CONFIG_ROOT=$(ConvertTo-EnvValue $ConfigPath)",
        "PUID=$Puid", "PGID=$Pgid", "TZ=$(ConvertTo-EnvValue $TimeZone)",
        "COMPOSE_PROFILES=$(ConvertTo-EnvValue $NetworkMode)",
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
    $createdEnvironment = $true
    $activeProfile = $NetworkMode
    Write-Host "Created $envFile. Keep it private."
}

docker compose --profile $activeProfile --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") config --quiet
if ($LASTEXITCODE -ne 0) { throw "The resolved Compose configuration is invalid." }

if ($NoLaunch) {
    Write-Host "Validation complete; -NoLaunch prevented pulls and container changes."
    exit 0
}

docker compose --profile $activeProfile --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") pull
if ($LASTEXITCODE -ne 0) { throw "One or more images could not be pulled." }
docker compose --profile $activeProfile --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") up -d
if ($LASTEXITCODE -ne 0) { throw "The stack did not start successfully." }

$qbitInitialPassword = ""
if ($createdEnvironment) {
    $qbitService = if ($activeProfile -eq "vpn") { "qbittorrent-vpn" } else { "qbittorrent" }
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $qbitLogs = docker compose --profile $activeProfile --env-file $envFile -f (Join-Path $stackRoot "docker-compose.yml") logs --no-color --tail 100 $qbitService 2>$null | Out-String
        $passwordMatch = [regex]::Match($qbitLogs, 'temporary password[^:]*:\s*(\S+)', 'IgnoreCase')
        if ($passwordMatch.Success) {
            $qbitInitialPassword = $passwordMatch.Groups[1].Value
            Write-Host "qBittorrent first-login username: admin"
            if (-not $ConfigureApplications) {
                Write-Host "qBittorrent temporary password: $qbitInitialPassword"
                Write-Host "Change that password in qBittorrent after signing in."
            }
            break
        }
        Start-Sleep -Seconds 2
    }
}

if ($ConfigureApplications -and $createdEnvironment) {
    if (-not $AdminUsername -or -not $AdminPassword -or -not $AdminEmail) {
        throw "Administrator username, password, and email are required for automatic application setup."
    }
    if (-not $qbitInitialPassword) { throw "qBittorrent did not provide its first-run password in time." }
    $configurationScript = Join-Path $stackRoot "configure-stack.ps1"
    if (-not (Test-Path -LiteralPath $configurationScript)) { throw "configure-stack.ps1 is missing." }
    & $configurationScript -AdminUsername $AdminUsername -AdminPassword $AdminPassword -AdminEmail $AdminEmail -QbitInitialPassword $qbitInitialPassword -EnvFile $envFile -NoBrowser
    if ($LASTEXITCODE -ne 0) { throw "Automatic application setup did not complete." }
}

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
