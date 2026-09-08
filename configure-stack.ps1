[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$AdminUsername,
    [Parameter(Mandatory)] [string]$AdminPassword,
    [Parameter(Mandatory)] [string]$AdminEmail,
    [string]$QbitInitialPassword,
    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),
    [string]$ComposeProjectName,
    [switch]$SkipQbitConfiguration,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$composeFile = Join-Path (Split-Path -Parent $EnvFile) "docker-compose.yml"
if (-not (Test-Path -LiteralPath $composeFile)) { $composeFile = Join-Path $PSScriptRoot "docker-compose.yml" }

function Get-EnvSetting {
    param([string]$Name, [string]$Default = "")
    $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -Last 1
    if (-not $line) { return $Default }
    $value = ($line -split "=", 2)[1].Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq "'" -and $value[-1] -eq "'") -or ($value[0] -eq '"' -and $value[-1] -eq '"'))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Wait-Endpoint {
    param([string]$Uri, [hashtable]$Headers = @{}, [int]$Seconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try { return Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 5 }
        catch { Start-Sleep -Seconds 2 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Uri"
}

function Invoke-Json {
    param(
        [string]$Uri,
        [ValidateSet("Get", "Post", "Put")] [string]$Method = "Get",
        [object]$Body,
        [hashtable]$Headers = @{},
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )
    $parameters = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = 30 }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    if ($WebSession) { $parameters.WebSession = $WebSession }
    try { return Invoke-RestMethod @parameters }
    catch {
        $details = ""
        try {
            if ($_.Exception.Response) {
                $reader = [IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $details = $reader.ReadToEnd()
                $reader.Dispose()
            }
        } catch { }
        foreach ($secret in @($AdminPassword, $QbitInitialPassword, $sonarrKey, $radarrKey, $prowlarrKey)) {
            if ($secret) { $details = $details -replace [regex]::Escape($secret), "[redacted]" }
        }
        throw "$Method $Uri failed: $($_.Exception.Message) $details"
    }
}

function Invoke-JsonRetry {
    param([string]$Uri, [string]$Method = "Get", [object]$Body, [hashtable]$Headers = @{}, [int]$Seconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try { return Invoke-Json -Uri $Uri -Method $Method -Body $Body -Headers $Headers }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Seconds 2
        }
    } while ($true)
}

function Get-ApiKey {
    param([string]$Application, [string]$ConfigRoot)
    $path = Join-Path $ConfigRoot "$Application/config.xml"
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        if (Test-Path -LiteralPath $path) {
            try {
                $xml = [xml](Get-Content -LiteralPath $path -Raw)
                if ($xml.Config.ApiKey) { return [string]$xml.Config.ApiKey }
            } catch { }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Application to generate its local API key."
}

function Set-ProviderField {
    param([object]$Provider, [string]$Name, [object]$Value)
    $field = @($Provider.fields | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if ($field) {
        if ($field.PSObject.Properties["value"]) { $field.value = $Value }
        else { $field | Add-Member -NotePropertyName value -NotePropertyValue $Value }
    }
}

function Add-RootFolder {
    param([string]$BaseUrl, [hashtable]$Headers, [string]$Path)
    $existing = @((Invoke-Json "$BaseUrl/rootfolder" -Headers $Headers) | ForEach-Object { $_ })
    if (-not ($existing | Where-Object { $_.path -eq $Path })) {
        [void](Invoke-Json "$BaseUrl/rootfolder" -Method Post -Headers $Headers -Body @{ path = $Path })
    }
}

function Enable-Hardlinks {
    param([string]$BaseUrl, [hashtable]$Headers)
    $settings = Invoke-Json "$BaseUrl/config/mediamanagement" -Headers $Headers
    if (-not $settings.copyUsingHardlinks) {
        $settings.copyUsingHardlinks = $true
        [void](Invoke-Json "$BaseUrl/config/mediamanagement/$($settings.id)" -Method Put -Headers $Headers -Body $settings)
    }
}

function Add-QbitClient {
    param(
        [string]$BaseUrl, [hashtable]$Headers, [string]$Category,
        [string]$CategoryField, [string]$QbitHost
    )
    $existing = @((Invoke-Json "$BaseUrl/downloadclient" -Headers $Headers) | ForEach-Object { $_ })
    if ($existing | Where-Object { $_.implementation -eq "QBittorrent" }) { return }
    $schemas = @((Invoke-Json "$BaseUrl/downloadclient/schema" -Headers $Headers) | ForEach-Object { $_ })
    $client = $schemas | Where-Object { $_.implementation -eq "QBittorrent" } | Select-Object -First 1
    if (-not $client) { throw "qBittorrent schema was not returned by $BaseUrl" }
    $client | Add-Member -NotePropertyName name -NotePropertyValue "qBittorrent" -Force
    $client | Add-Member -NotePropertyName enable -NotePropertyValue $true -Force
    $client | Add-Member -NotePropertyName priority -NotePropertyValue 1 -Force
    $client | Add-Member -NotePropertyName removeCompletedDownloads -NotePropertyValue $true -Force
    $client | Add-Member -NotePropertyName removeFailedDownloads -NotePropertyValue $true -Force
    Set-ProviderField $client "host" $QbitHost
    Set-ProviderField $client "port" 8080
    Set-ProviderField $client "useSsl" $false
    Set-ProviderField $client "username" $AdminUsername
    Set-ProviderField $client "password" $AdminPassword
    Set-ProviderField $client $CategoryField $Category
    [void](Invoke-Json "$BaseUrl/downloadclient" -Method Post -Headers $Headers -Body $client)
}

function Add-ProwlarrApplication {
    param([string]$Name, [string]$ApplicationUrl, [string]$ApiKey, [object[]]$Schemas, [string]$ProwlarrBase, [hashtable]$Headers)
    $existing = @((Invoke-Json "$ProwlarrBase/applications" -Headers $Headers) | ForEach-Object { $_ })
    if ($existing | Where-Object { $_.implementation -eq $Name }) { return }
    $application = $Schemas | Where-Object { $_.implementation -eq $Name } | Select-Object -First 1
    if (-not $application) { throw "$Name application schema was not returned by Prowlarr." }
    $application | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force
    $application.enable = $true
    $application.syncLevel = "fullSync"
    Set-ProviderField $application "prowlarrUrl" "http://prowlarr:9696"
    Set-ProviderField $application "baseUrl" $ApplicationUrl
    Set-ProviderField $application "apiKey" $ApiKey
    [void](Invoke-Json "$ProwlarrBase/applications" -Method Post -Headers $Headers -Body $application)
}

if (-not (Test-Path -LiteralPath $EnvFile)) { throw ".env was not found at $EnvFile" }
if ($AdminUsername -notmatch '^[A-Za-z0-9._-]{3,32}$') { throw "Administrator username must be 3-32 characters using letters, numbers, dots, underscores, or hyphens." }
if ($AdminPassword.Length -lt 12) { throw "Administrator password must be at least 12 characters." }
if ($AdminEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "Enter a valid administrator email address." }

$envRoot = Split-Path -Parent ([IO.Path]::GetFullPath($EnvFile))
$configSetting = Get-EnvSetting "CONFIG_ROOT"
$configRoot = if ([IO.Path]::IsPathRooted($configSetting)) { $configSetting } else { Join-Path $envRoot $configSetting }
$profile = Get-EnvSetting "COMPOSE_PROFILES" "vpn"
$qbitService = if ($profile -eq "vpn") { "qbittorrent-vpn" } else { "qbittorrent" }
$qbitHost = if ($profile -eq "vpn") { "gluetun" } else { "qbittorrent" }
$qbitPort = [int](Get-EnvSetting "QBITTORRENT_WEBUI_PORT" "8080")
$sonarrPort = [int](Get-EnvSetting "SONARR_PORT" "8989")
$radarrPort = [int](Get-EnvSetting "RADARR_PORT" "7878")
$prowlarrPort = [int](Get-EnvSetting "PROWLARR_PORT" "9696")
$jellyfinPort = [int](Get-EnvSetting "JELLYFIN_PORT" "8096")
$seerrPort = [int](Get-EnvSetting "SEERR_PORT" "5055")

$sonarrKey = Get-ApiKey "sonarr" $configRoot
$radarrKey = Get-ApiKey "radarr" $configRoot
$prowlarrKey = Get-ApiKey "prowlarr" $configRoot
$sonarrBase = "http://localhost:$sonarrPort/api/v3"
$radarrBase = "http://localhost:$radarrPort/api/v3"
$prowlarrBase = "http://localhost:$prowlarrPort/api/v1"
$sonarrHeaders = @{ "X-Api-Key" = $sonarrKey }
$radarrHeaders = @{ "X-Api-Key" = $radarrKey }
$prowlarrHeaders = @{ "X-Api-Key" = $prowlarrKey }
[void](Wait-Endpoint "$sonarrBase/system/status" $sonarrHeaders)
[void](Wait-Endpoint "$radarrBase/system/status" $radarrHeaders)
[void](Wait-Endpoint "$prowlarrBase/system/status" $prowlarrHeaders)

Write-Host "Configuring Jellyfin administrator and libraries..."
$jellyfinBase = "http://localhost:$jellyfinPort"
$publicInfo = Wait-Endpoint "$jellyfinBase/System/Info/Public"
if (-not $publicInfo.StartupWizardCompleted) {
    [void](Invoke-JsonRetry "$jellyfinBase/Startup/Configuration" -Method Post -Body @{ ServerName = "Servarr Stack"; UICulture = "en-US"; MetadataCountryCode = "US"; PreferredMetadataLanguage = "en" })
    [void](Invoke-JsonRetry "$jellyfinBase/Startup/User" -Method Get)
    [void](Invoke-JsonRetry "$jellyfinBase/Startup/User" -Method Post -Body @{ Name = $AdminUsername; Password = $AdminPassword })
    [void](Invoke-JsonRetry "$jellyfinBase/Startup/RemoteAccess" -Method Post -Body @{ EnableRemoteAccess = $true; EnableAutomaticPortMapping = $false })
    [void](Invoke-JsonRetry "$jellyfinBase/Startup/Complete" -Method Post -Body @{})
}
$deviceId = [guid]::NewGuid().ToString("N")
$authHeader = "MediaBrowser Client=`"Servarr Stack Installer`", Device=`"Windows`", DeviceId=`"$deviceId`", Version=`"1.0`""
$jellyfinAuth = Invoke-Json "$jellyfinBase/Users/AuthenticateByName" -Method Post -Headers @{ Authorization = $authHeader } -Body @{ Username = $AdminUsername; Pw = $AdminPassword }
$jellyfinHeaders = @{ Authorization = $authHeader; "X-Emby-Token" = $jellyfinAuth.AccessToken }
$virtualFolders = @((Invoke-Json "$jellyfinBase/Library/VirtualFolders" -Headers $jellyfinHeaders) | ForEach-Object { $_ })
foreach ($library in @(@{ Name = "Movies"; Type = "movies"; Path = "/media/movies" }, @{ Name = "TV Shows"; Type = "tvshows"; Path = "/media/tv" })) {
    if (-not ($virtualFolders | Where-Object { $_.Name -eq $library.Name })) {
        $queryName = [uri]::EscapeDataString($library.Name)
        $uri = "$jellyfinBase/Library/VirtualFolders?name=$queryName&collectionType=$($library.Type)&refreshLibrary=false"
        [void](Invoke-Json $uri -Method Post -Headers $jellyfinHeaders -Body @{ LibraryOptions = @{ PathInfos = @(@{ Path = $library.Path }) } })
    }
}

if (-not $SkipQbitConfiguration) {
  Write-Host "Configuring qBittorrent paths and login..."
  if (-not $QbitInitialPassword) {
    $composeArguments = @("compose")
    if ($ComposeProjectName) { $composeArguments += @("-p", $ComposeProjectName) }
    $composeArguments += @("--profile", $profile, "--env-file", $EnvFile, "-f", $composeFile, "logs", "--no-color", "--tail", "150", $qbitService)
    $qbitLogs = (& docker @composeArguments 2>$null | Out-String)
    $passwordMatch = [regex]::Match($qbitLogs, 'temporary password[^:]*:\s*(\S+)', 'IgnoreCase')
    if (-not $passwordMatch.Success) { throw "Could not retrieve qBittorrent's temporary password for first-time setup." }
    $QbitInitialPassword = $passwordMatch.Groups[1].Value
  }
  $qbitSession = $null
  $qbitHeaders = @{ Host = "localhost:8080"; Referer = "http://localhost:8080/" }
  foreach ($credentials in @(
    @{ username = "admin"; password = $QbitInitialPassword },
    @{ username = $AdminUsername; password = $AdminPassword },
    @{ username = "admin"; password = $AdminPassword }
  )) {
    if (-not $credentials.password) { continue }
    try {
        $candidateSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $login = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$qbitPort/api/v2/auth/login" -Method Post -Headers $qbitHeaders -Body $credentials -WebSession $candidateSession
        if ($login.Content.Trim() -eq "Ok.") { $qbitSession = $candidateSession; break }
    } catch { }
  }
  if (-not $qbitSession) { throw "qBittorrent rejected both its first-run login and the chosen administrator login." }
  $qbitPreferences = @{ save_path = "/data/downloads/complete"; temp_path = "/data/downloads/incomplete"; temp_path_enabled = $true; web_ui_username = $AdminUsername; web_ui_password = $AdminPassword }
  [void](Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$qbitPort/api/v2/app/setPreferences" -Method Post -Headers $qbitHeaders -Body @{ json = ($qbitPreferences | ConvertTo-Json -Compress) } -WebSession $qbitSession)
}

Write-Host "Configuring Sonarr, Radarr, and Prowlarr..."
Add-RootFolder $sonarrBase $sonarrHeaders "/data/media/tv"
Add-RootFolder $radarrBase $radarrHeaders "/data/media/movies"
Enable-Hardlinks $sonarrBase $sonarrHeaders
Enable-Hardlinks $radarrBase $radarrHeaders
if (-not $SkipQbitConfiguration) {
    Add-QbitClient $sonarrBase $sonarrHeaders "tv" "tvCategory" $qbitHost
    Add-QbitClient $radarrBase $radarrHeaders "movies" "movieCategory" $qbitHost
}
$applicationSchemas = @((Invoke-Json "$prowlarrBase/applications/schema" -Headers $prowlarrHeaders) | ForEach-Object { $_ })
Add-ProwlarrApplication "Sonarr" "http://sonarr:8989" $sonarrKey $applicationSchemas $prowlarrBase $prowlarrHeaders
Add-ProwlarrApplication "Radarr" "http://radarr:7878" $radarrKey $applicationSchemas $prowlarrBase $prowlarrHeaders

Write-Host "Connecting Seerr..."
$seerrBase = "http://localhost:$seerrPort/api/v1"
$publicSettings = Wait-Endpoint "$seerrBase/settings/public"
if (-not $publicSettings.initialized) {
  $seerrSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
  [void](Invoke-Json "$seerrBase/auth/jellyfin" -Method Post -WebSession $seerrSession -Body @{ username = $AdminUsername; password = $AdminPassword; hostname = "jellyfin"; port = 8096; useSsl = $false; urlBase = ""; email = $AdminEmail; serverType = 2 })
  [void](Invoke-Json "$seerrBase/settings/jellyfin" -Method Post -WebSession $seerrSession -Body @{ hostname = "http://jellyfin:8096"; externalHostname = "http://localhost:$jellyfinPort"; adminUser = $AdminUsername; adminPass = $AdminPassword })
  $radarrProfiles = @((Invoke-Json "$radarrBase/qualityprofile" -Headers $radarrHeaders) | ForEach-Object { $_ })
  $sonarrProfiles = @((Invoke-Json "$sonarrBase/qualityprofile" -Headers $sonarrHeaders) | ForEach-Object { $_ })
  $radarrProfile = $radarrProfiles | Select-Object -First 1
  $sonarrProfile = $sonarrProfiles | Select-Object -First 1
  if (-not $radarrProfile -or -not $sonarrProfile) { throw "Sonarr or Radarr did not return a quality profile for Seerr." }
    [void](Invoke-Json "$seerrBase/settings/radarr" -Method Post -WebSession $seerrSession -Body @{ name = "Radarr"; hostname = "radarr"; port = 7878; apiKey = $radarrKey; useSsl = $false; baseUrl = ""; activeProfileId = $radarrProfile.id; activeProfileName = $radarrProfile.name; activeDirectory = "/data/media/movies"; is4k = $false; minimumAvailability = "released"; isDefault = $true; externalUrl = "http://localhost:$radarrPort"; syncEnabled = $false; preventSearch = $false })
    [void](Invoke-Json "$seerrBase/settings/sonarr" -Method Post -WebSession $seerrSession -Body @{ name = "Sonarr"; hostname = "sonarr"; port = 8989; apiKey = $sonarrKey; useSsl = $false; baseUrl = ""; activeProfileId = $sonarrProfile.id; activeProfileName = $sonarrProfile.name; activeDirectory = "/data/media/tv"; is4k = $false; enableSeasonFolders = $true; isDefault = $true; externalUrl = "http://localhost:$sonarrPort"; syncEnabled = $false; preventSearch = $false })
  [void](Invoke-Json "$seerrBase/settings/initialize" -Method Post -WebSession $seerrSession -Body @{})
}

Write-Host "Setup complete. Add authorized indexers in Prowlarr, then request media from Seerr."
if (-not $NoBrowser) { Start-Process "http://localhost:$seerrPort" }
