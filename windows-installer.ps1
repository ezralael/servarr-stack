[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$stackRoot = $PSScriptRoot
$enginePath = Join-Path $stackRoot "install.ps1"
$composePath = Join-Path $stackRoot "docker-compose.yml"
$envPath = Join-Path $stackRoot ".env"

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
    throw "The graphical installer requires Windows. Linux users should run ./install.sh."
}
if (-not (Test-Path -LiteralPath $enginePath) -or -not (Test-Path -LiteralPath $composePath)) {
    throw "install.ps1 and docker-compose.yml must be beside windows-installer.ps1."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

if ($SelfTest) {
    Write-Output "PASS: Windows Forms loaded and all installer components are present."
    exit 0
}

function Add-TextField {
    param(
        [Windows.Forms.Control]$Parent,
        [string]$Label,
        [int]$Top,
        [string]$Default = "",
        [switch]$Browse,
        [switch]$Secret
    )
    $caption = [Windows.Forms.Label]::new()
    $caption.Text = $Label
    $caption.Location = [Drawing.Point]::new(18, $Top)
    $caption.Size = [Drawing.Size]::new(180, 22)
    $Parent.Controls.Add($caption)

    $field = [Windows.Forms.TextBox]::new()
    $field.Text = $Default
    $field.Location = [Drawing.Point]::new(205, $Top - 3)
    $field.Size = [Drawing.Size]::new($(if ($Browse) { 430 } else { 500 }), 24)
    $field.UseSystemPasswordChar = $Secret
    $Parent.Controls.Add($field)

    if ($Browse) {
        $button = [Windows.Forms.Button]::new()
        $button.Text = "Browse..."
        $button.Location = [Drawing.Point]::new(645, $Top - 5)
        $button.Size = [Drawing.Size]::new(85, 28)
        $button.Add_Click({
            $dialog = [Windows.Forms.FolderBrowserDialog]::new()
            $dialog.Description = $Label
            if (Test-Path -LiteralPath $field.Text) { $dialog.SelectedPath = $field.Text }
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $field.Text = $dialog.SelectedPath
            }
            $dialog.Dispose()
        }.GetNewClosure())
        $Parent.Controls.Add($button)
        $field.Tag = $button
    }
    return $field
}

$form = [Windows.Forms.Form]::new()
$form.Text = "Servarr Stack Installer"
$form.StartPosition = "CenterScreen"
$form.ClientSize = [Drawing.Size]::new(760, 720)
$form.MinimumSize = [Drawing.Size]::new(776, 759)
$form.Font = [Drawing.Font]::new("Segoe UI", 9)
$form.AutoScaleMode = "Dpi"

$title = [Windows.Forms.Label]::new()
$title.Text = "Install Servarr Stack"
$title.Font = [Drawing.Font]::new("Segoe UI Semibold", 18)
$title.Location = [Drawing.Point]::new(18, 14)
$title.Size = [Drawing.Size]::new(500, 38)
$form.Controls.Add($title)

$intro = [Windows.Forms.Label]::new()
$intro.Text = "Configure persistent storage and the VPN. The installer validates Docker, pulls images, and starts the stack without deleting existing data."
$intro.Location = [Drawing.Point]::new(21, 55)
$intro.Size = [Drawing.Size]::new(710, 42)
$form.Controls.Add($intro)

$defaultData = Join-Path $stackRoot "data"
$mediaField = Add-TextField $form "Media directory" 110 (Join-Path $defaultData "media") -Browse
$downloadsField = Add-TextField $form "Downloads directory" 150 (Join-Path $defaultData "downloads") -Browse
$configField = Add-TextField $form "Application config directory" 190 (Join-Path $defaultData "config") -Browse

$vpnGroup = [Windows.Forms.GroupBox]::new()
$vpnGroup.Text = "VPN connection (required for qBittorrent)"
$vpnGroup.Location = [Drawing.Point]::new(18, 230)
$vpnGroup.Size = [Drawing.Size]::new(714, 245)
$form.Controls.Add($vpnGroup)

$providerMap = [ordered]@{
    "Private Internet Access" = "private internet access"
    "Proton VPN" = "protonvpn"
    "NordVPN" = "nordvpn"
    "Surfshark" = "surfshark"
    "Mullvad" = "mullvad"
    "Windscribe" = "windscribe"
    "IVPN" = "ivpn"
    "AirVPN" = "airvpn"
}
$providerLabel = [Windows.Forms.Label]::new()
$providerLabel.Text = "VPN provider"
$providerLabel.Location = [Drawing.Point]::new(18, 32)
$providerLabel.Size = [Drawing.Size]::new(180, 22)
$vpnGroup.Controls.Add($providerLabel)
$providerField = [Windows.Forms.ComboBox]::new()
$providerField.DropDownStyle = "DropDown"
$providerField.AutoCompleteMode = "SuggestAppend"
$providerField.AutoCompleteSource = "ListItems"
[void]$providerField.Items.AddRange([object[]]@($providerMap.Keys))
$providerField.Location = [Drawing.Point]::new(205, 29)
$providerField.Size = [Drawing.Size]::new(330, 24)
$vpnGroup.Controls.Add($providerField)

$providerGuide = [Windows.Forms.LinkLabel]::new()
$providerGuide.Text = "Where do I find VPN credentials?"
$providerGuide.Location = [Drawing.Point]::new(545, 32)
$providerGuide.Size = [Drawing.Size]::new(155, 22)
$providerGuide.Add_LinkClicked({
    Start-Process "https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers"
})
$vpnGroup.Controls.Add($providerGuide)

$typeLabel = [Windows.Forms.Label]::new()
$typeLabel.Text = "VPN type"
$typeLabel.Location = [Drawing.Point]::new(18, 72)
$typeLabel.Size = [Drawing.Size]::new(180, 22)
$vpnGroup.Controls.Add($typeLabel)
$typeField = [Windows.Forms.ComboBox]::new()
$typeField.DropDownStyle = "DropDownList"
$typeField.Items.AddRange(@("OpenVPN", "WireGuard"))
$typeField.SelectedIndex = 0
$typeField.Location = [Drawing.Point]::new(205, 69)
$typeField.Size = [Drawing.Size]::new(220, 24)
$vpnGroup.Controls.Add($typeField)

$credentialOneLabel = [Windows.Forms.Label]::new()
$credentialOneLabel.Location = [Drawing.Point]::new(18, 112)
$credentialOneLabel.Size = [Drawing.Size]::new(180, 22)
$vpnGroup.Controls.Add($credentialOneLabel)
$credentialOneField = [Windows.Forms.TextBox]::new()
$credentialOneField.Location = [Drawing.Point]::new(205, 109)
$credentialOneField.Size = [Drawing.Size]::new(480, 24)
$vpnGroup.Controls.Add($credentialOneField)

$credentialTwoLabel = [Windows.Forms.Label]::new()
$credentialTwoLabel.Location = [Drawing.Point]::new(18, 152)
$credentialTwoLabel.Size = [Drawing.Size]::new(180, 22)
$vpnGroup.Controls.Add($credentialTwoLabel)
$credentialTwoField = [Windows.Forms.TextBox]::new()
$credentialTwoField.Location = [Drawing.Point]::new(205, 149)
$credentialTwoField.Size = [Drawing.Size]::new(480, 24)
$vpnGroup.Controls.Add($credentialTwoField)

$credentialHelp = [Windows.Forms.Label]::new()
$credentialHelp.Text = "Use the manual/service credentials supplied by your VPN provider; these may differ from your website login."
$credentialHelp.Location = [Drawing.Point]::new(205, 182)
$credentialHelp.Size = [Drawing.Size]::new(480, 38)
$credentialHelp.ForeColor = [Drawing.Color]::DimGray
$vpnGroup.Controls.Add($credentialHelp)

$setCredentialLabels = {
    $wireGuard = $typeField.SelectedItem -eq "WireGuard"
    $credentialOneLabel.Text = if ($wireGuard) { "WireGuard private key" } else { "OpenVPN username" }
    $credentialTwoLabel.Text = if ($wireGuard) { "WireGuard address" } else { "OpenVPN password" }
    $credentialOneField.UseSystemPasswordChar = $wireGuard
    $credentialTwoField.UseSystemPasswordChar = -not $wireGuard
}
$typeField.Add_SelectedIndexChanged($setCredentialLabels)
& $setCredentialLabels

$validateOnly = [Windows.Forms.CheckBox]::new()
$validateOnly.Text = "Validate only (do not pull images or start containers)"
$validateOnly.Location = [Drawing.Point]::new(22, 490)
$validateOnly.Size = [Drawing.Size]::new(360, 24)
$form.Controls.Add($validateOnly)

$openJellyfin = [Windows.Forms.CheckBox]::new()
$openJellyfin.Text = "Open Jellyfin setup when installation finishes"
$openJellyfin.Checked = $true
$openJellyfin.Location = [Drawing.Point]::new(390, 490)
$openJellyfin.Size = [Drawing.Size]::new(340, 24)
$form.Controls.Add($openJellyfin)

$existingNotice = [Windows.Forms.Label]::new()
$existingNotice.Location = [Drawing.Point]::new(22, 520)
$existingNotice.Size = [Drawing.Size]::new(710, 34)
$existingNotice.ForeColor = [Drawing.Color]::FromArgb(120, 70, 0)
$form.Controls.Add($existingNotice)

$progress = [Windows.Forms.ProgressBar]::new()
$progress.Location = [Drawing.Point]::new(22, 560)
$progress.Size = [Drawing.Size]::new(558, 25)
$progress.Style = "Blocks"
$form.Controls.Add($progress)

$installButton = [Windows.Forms.Button]::new()
$installButton.Text = "Install"
$installButton.Location = [Drawing.Point]::new(595, 556)
$installButton.Size = [Drawing.Size]::new(135, 34)
$form.AcceptButton = $installButton
$form.Controls.Add($installButton)

$outputBox = [Windows.Forms.TextBox]::new()
$outputBox.Location = [Drawing.Point]::new(22, 603)
$outputBox.Size = [Drawing.Size]::new(708, 95)
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.ReadOnly = $true
$outputBox.BackColor = [Drawing.Color]::White
$outputBox.Text = "Ready. Docker Desktop must be installed and running."
$form.Controls.Add($outputBox)

$configurationControls = @(
    $mediaField, $mediaField.Tag, $downloadsField, $downloadsField.Tag,
    $configField, $configField.Tag, $providerField,
    $typeField, $credentialOneField, $credentialTwoField
)
$existingEnvironment = Test-Path -LiteralPath $envPath
if ($existingEnvironment) {
    $existingNotice.Text = "Existing .env detected. The installer will reuse it and will not overwrite configuration or application data."
    foreach ($control in $configurationControls) { $control.Enabled = $false }
    $installButton.Text = "Start / update"
} else {
    $existingNotice.Text = "Credentials are written only to the ignored local .env file. They are never sent to this project or GitHub."
}

$script:wizardPowerShell = $null
$script:wizardAsync = $null
$script:installing = $false

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 300
$timer.Add_Tick({
    if (-not $script:wizardAsync -or -not $script:wizardAsync.IsCompleted) { return }
    $timer.Stop()
    $progress.Style = "Blocks"
    try {
        $result = $script:wizardPowerShell.EndInvoke($script:wizardAsync)
        $messages = @($result | ForEach-Object { $_.ToString() })
        $errors = @($script:wizardPowerShell.Streams.Error | ForEach-Object { $_.ToString() })
        $outputBox.Text = (@($messages + $errors) -join [Environment]::NewLine)
        if ($script:wizardPowerShell.HadErrors) {
            [Windows.Forms.MessageBox]::Show(
                "Installation did not complete. Review the details in the installer window.",
                "Servarr Stack", "OK", "Error"
            ) | Out-Null
        } else {
            $installButton.Text = "Completed"
            if (-not $validateOnly.Checked -and $openJellyfin.Checked) {
                Start-Process "http://localhost:8096"
            }
            [Windows.Forms.MessageBox]::Show(
                "Servarr Stack setup completed successfully.",
                "Servarr Stack", "OK", "Information"
            ) | Out-Null
        }
    } catch {
        $outputBox.Text = $_.Exception.Message
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Servarr Stack", "OK", "Error") | Out-Null
    } finally {
        $script:installing = $false
        $installButton.Enabled = $true
        $script:wizardPowerShell.Dispose()
        $script:wizardPowerShell = $null
        $script:wizardAsync = $null
    }
})

$installButton.Add_Click({
    if ($script:installing) { return }
    if (-not $existingEnvironment) {
        foreach ($field in @($mediaField, $downloadsField, $configField, $providerField)) {
            if ([string]::IsNullOrWhiteSpace($field.Text)) {
                [Windows.Forms.MessageBox]::Show("Choose the three folders and your VPN provider.", "Servarr Stack", "OK", "Warning") | Out-Null
                return
            }
        }
        if ([string]::IsNullOrWhiteSpace($credentialOneField.Text) -or [string]::IsNullOrWhiteSpace($credentialTwoField.Text)) {
            [Windows.Forms.MessageBox]::Show("Enter the credentials required for the selected VPN type.", "Servarr Stack", "OK", "Warning") | Out-Null
            return
        }
    }

    $arguments = @{ NonInteractive = $true }
    if (-not $existingEnvironment) {
        $arguments.MediaPath = $mediaField.Text
        $arguments.DownloadsPath = $downloadsField.Text
        $arguments.ConfigPath = $configField.Text
        $providerName = $providerField.Text.Trim()
        $arguments.VpnProvider = if ($providerMap.Contains($providerName)) { $providerMap[$providerName] } else { $providerName.ToLowerInvariant() }
        if ($typeField.SelectedItem -eq "WireGuard") {
            $arguments.VpnType = "wireguard"
            $arguments.WireGuardPrivateKey = $credentialOneField.Text
            $arguments.WireGuardAddresses = $credentialTwoField.Text
        } else {
            $arguments.VpnType = "openvpn"
            $arguments.OpenVpnUser = $credentialOneField.Text
            $arguments.OpenVpnPassword = $credentialTwoField.Text
        }
    }
    if ($validateOnly.Checked) { $arguments.NoLaunch = $true }

    $script:installing = $true
    $installButton.Enabled = $false
    $installButton.Text = "Working..."
    $progress.Style = "Marquee"
    $outputBox.Text = "Validating Docker and preparing the stack. Image downloads may take several minutes..."

    $runner = @'
param($InstallerPath, $InstallerArguments)
& $InstallerPath @InstallerArguments *>&1 | ForEach-Object { $_.ToString() }
'@
    $script:wizardPowerShell = [PowerShell]::Create()
    [void]$script:wizardPowerShell.AddScript($runner).AddArgument($enginePath).AddArgument($arguments)
    $script:wizardAsync = $script:wizardPowerShell.BeginInvoke()
    $timer.Start()
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:installing) {
        $eventArgs.Cancel = $true
        [Windows.Forms.MessageBox]::Show("Wait for the current installation step to finish before closing.", "Servarr Stack") | Out-Null
    }
})

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
