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

docker compose --env-file $example -f $compose config --quiet
Assert-True ($LASTEXITCODE -eq 0) "Compose resolves with .env.example"
$resolved = docker compose --env-file $example -f $compose config --format json | ConvertFrom-Json
Assert-True ($LASTEXITCODE -eq 0) "Resolved Compose JSON is readable"

$qb = $resolved.services.qbittorrent
$gt = $resolved.services.gluetun
Assert-True ($qb.network_mode -eq "service:gluetun") "qBittorrent shares Gluetun's network namespace"
Assert-True (-not $qb.PSObject.Properties["ports"]) "qBittorrent publishes no ports directly"
Assert-True ($qb.depends_on.gluetun.condition -eq "service_healthy") "qBittorrent waits for healthy Gluetun"
Assert-True ($gt.cap_add -contains "NET_ADMIN") "Gluetun has NET_ADMIN"
Assert-True (@($gt.ports | Where-Object { $_.target -eq 8080 }).Count -eq 1) "Gluetun publishes qBittorrent Web UI"

foreach ($service in @("qbittorrent", "sonarr", "radarr")) {
    $targets = @($resolved.services.$service.volumes | ForEach-Object { $_.target })
    Assert-True ($targets -contains "/downloads") "$service has the shared /downloads path"
}
foreach ($service in @("qbittorrent", "sonarr", "radarr", "jellyfin")) {
    $targets = @($resolved.services.$service.volumes | ForEach-Object { $_.target })
    Assert-True ($targets -contains "/media") "$service has the shared /media path"
}
foreach ($service in @("gluetun", "qbittorrent", "prowlarr", "sonarr", "radarr", "jellyfin", "seerr")) {
    Assert-True ($resolved.services.$service.restart -eq "unless-stopped") "$service is restart-safe"
}
$configTargets = @{
    gluetun = "/gluetun"; qbittorrent = "/config"; prowlarr = "/config";
    sonarr = "/config"; radarr = "/config"; jellyfin = "/config"; seerr = "/app/config"
}
foreach ($service in $configTargets.Keys) {
    $configMount = @($resolved.services.$service.volumes | Where-Object { $_.target -eq $configTargets[$service] })
    Assert-True ($configMount.Count -eq 1 -and $configMount[0].type -eq "bind") "$service configuration is a persistent bind mount"
}
$jellyfinCache = @($resolved.services.jellyfin.volumes | Where-Object { $_.target -eq "/cache" })
Assert-True ($jellyfinCache.Count -eq 1 -and $jellyfinCache[0].type -eq "volume") "Jellyfin cache uses an explicit persistent volume"

$required = @("docker-compose.yml", ".env.example", ".gitignore", "install.ps1", "install.sh", "README.md", "LICENSE")
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

$bashCommand = Get-Command bash -ErrorAction SilentlyContinue
if ($bashCommand -and $bashCommand.Source -notmatch '(?i)\\Windows\\system32\\bash\.exe$') {
    bash -n (Join-Path $root "install.sh")
    Assert-True ($LASTEXITCODE -eq 0) "install.sh passes bash syntax validation"
} else {
    Write-Host "SKIP: a working Bash is unavailable; validate install.sh in a Linux container or host."
}

Write-Host "All repository verification checks passed."

