[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$compose = Join-Path $root "docker-compose.yml"
$example = Join-Path $root ".env.example"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "PASS: $Message"
}

docker compose --profile vpn --env-file $example -f $compose config --quiet
Assert-True ($LASTEXITCODE -eq 0) "VPN Compose profile resolves with .env.example"
$vpnResolved = docker compose --profile vpn --env-file $example -f $compose config --format json | ConvertFrom-Json
Assert-True ($LASTEXITCODE -eq 0) "VPN profile JSON is readable"
$directResolved = docker compose --profile direct --env-file $example -f $compose config --format json | ConvertFrom-Json
Assert-True ($LASTEXITCODE -eq 0) "Direct profile JSON is readable"

$qb = $vpnResolved.services.'qbittorrent-vpn'
$directQb = $directResolved.services.qbittorrent
$gt = $vpnResolved.services.gluetun
Assert-True ($qb.network_mode -eq "service:gluetun") "VPN qBittorrent shares Gluetun's network namespace"
Assert-True (-not $qb.PSObject.Properties["ports"]) "VPN qBittorrent publishes no ports directly"
Assert-True ($qb.depends_on.gluetun.condition -eq "service_healthy") "VPN qBittorrent waits for healthy Gluetun"
Assert-True ($gt.cap_add -contains "NET_ADMIN") "Gluetun has NET_ADMIN"
Assert-True (@($gt.ports | Where-Object { $_.target -eq 8080 }).Count -eq 1) "Gluetun publishes qBittorrent Web UI"
Assert-True (-not $directResolved.services.PSObject.Properties["gluetun"]) "Direct profile does not start Gluetun"
Assert-True ($directQb.network_mode -ne "service:gluetun") "Direct qBittorrent has an independent network"
Assert-True (@($directQb.ports | Where-Object { $_.target -eq 8080 }).Count -eq 1) "Direct qBittorrent publishes its Web UI"

$dataMounts = @{}
foreach ($service in @("qbittorrent-vpn", "sonarr", "radarr")) {
    $mount = @($vpnResolved.services.$service.volumes | Where-Object { $_.target -eq "/data" })
    Assert-True ($mount.Count -eq 1 -and $mount[0].type -eq "bind") "$service has one shared /data bind mount"
    $dataMounts[$service] = $mount[0].source
}
$directData = @($directQb.volumes | Where-Object { $_.target -eq "/data" })
Assert-True ($directData.Count -eq 1 -and $directData[0].type -eq "bind") "direct qBittorrent has one shared /data bind mount"
$dataSources = @($dataMounts.Values) + @($directData[0].source)
Assert-True (@($dataSources | Select-Object -Unique).Count -eq 1) "qBittorrent, Sonarr, and Radarr use the identical data mount source"
$jellyfinMedia = @($vpnResolved.services.jellyfin.volumes | Where-Object { $_.target -eq "/media" })
Assert-True ($jellyfinMedia.Count -eq 1 -and $jellyfinMedia[0].type -eq "bind") "Jellyfin has the organized media bind mount"
foreach ($service in @("gluetun", "qbittorrent-vpn", "prowlarr", "sonarr", "radarr", "jellyfin", "seerr")) {
    Assert-True ($vpnResolved.services.$service.restart -eq "unless-stopped") "$service is restart-safe"
}
$configTargets = @{
    gluetun = "/gluetun"; 'qbittorrent-vpn' = "/config"; prowlarr = "/config";
    sonarr = "/config"; radarr = "/config"; jellyfin = "/config"; seerr = "/app/config"
}
foreach ($service in $configTargets.Keys) {
    $configMount = @($vpnResolved.services.$service.volumes | Where-Object { $_.target -eq $configTargets[$service] })
    Assert-True ($configMount.Count -eq 1 -and $configMount[0].type -eq "bind") "$service configuration is a persistent bind mount"
}
$directConfig = @($directQb.volumes | Where-Object { $_.target -eq "/config" })
Assert-True ($directConfig.Count -eq 1 -and $directConfig[0].type -eq "bind") "direct qBittorrent configuration is a persistent bind mount"
$jellyfinCache = @($vpnResolved.services.jellyfin.volumes | Where-Object { $_.target -eq "/cache" })
Assert-True ($jellyfinCache.Count -eq 1 -and $jellyfinCache[0].type -eq "volume") "Jellyfin cache uses an explicit persistent volume"

$required = @(
    "docker-compose.yml", ".env.example", ".gitignore", "install.ps1", "install.sh",
    "Install-ServarrStack.cmd", "windows-installer.ps1", "README.md", "LICENSE"
)
foreach ($file in $required) { Assert-True (Test-Path -LiteralPath (Join-Path $root $file)) "$file exists" }

$files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.Name -ne ".env" -and
        $_.FullName -ne $PSCommandPath
    })
$forbidden = '(?i)[A-Z]:\\Users\\|D:' + '\\Media|tailscale.{0,40}(auth|token|100\.)|100\.\d{1,3}\.\d{1,3}\.\d{1,3}'
$hits = @($files | Select-String -Pattern $forbidden)
Assert-True ($hits.Count -eq 0) "No known personal path, username, or Tailscale pattern is present"

$secretAssignment = '^\s*(OPENVPN_PASSWORD|WIREGUARD_PRIVATE_KEY|API_KEY|AUTH_TOKEN|ACCESS_TOKEN)\s*=\s*[^\s#''"]+'
$secretHits = @($files | Select-String -Pattern $secretAssignment -CaseSensitive)
Assert-True ($secretHits.Count -eq 0) "No non-empty high-risk secret assignment is present"

$psTokens = $null
$psErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root "install.ps1"), [ref]$psTokens, [ref]$psErrors)
Assert-True ($psErrors.Count -eq 0) "install.ps1 parses successfully"
$wizardTokens = $null
$wizardErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root "windows-installer.ps1"), [ref]$wizardTokens, [ref]$wizardErrors)
Assert-True ($wizardErrors.Count -eq 0) "windows-installer.ps1 parses successfully"

$bashCommand = Get-Command bash -ErrorAction SilentlyContinue
if ($bashCommand -and $bashCommand.Source -notmatch '(?i)\\Windows\\system32\\bash\.exe$') {
    bash -n (Join-Path $root "install.sh")
    Assert-True ($LASTEXITCODE -eq 0) "install.sh passes bash syntax validation"
} else {
    Write-Host "SKIP: a working Bash is unavailable; validate install.sh in a Linux container or host."
}

Write-Host "All repository verification checks passed."
