#requires -Version 5.1

<#
.SYNOPSIS
    Idempotently installs the current Ubuntu Desktop release on Hyper-V.

.DESCRIPTION
    This Windows PowerShell 5.1 entry point prepares Hyper-V, creates or reuses
    a working network, downloads and verifies the official Ubuntu Desktop ISO,
    builds a bootable autoinstall ISO, installs Ubuntu Desktop without manual
    input, configures ubuntu/ubuntu with graphical automatic login, verifies the
    guest over SSH, and opens VMConnect only after the desktop is ready.

    The script owns only resources recorded below DataRoot. Existing managed
    resources are reused; an unrelated VM with the same name is never removed
    unless -ForceRecreate is explicit.

.PARAMETER UbuntuRelease
    Latest discovers the newest numbered release directory and highest Desktop
    AMD64 ISO published by releases.ubuntu.com. A family such as 26.04 may be
    pinned.

.PARAMETER ForceRecreate
    Recreates a managed VM when its verified ISO or provisioning inputs change.
    An unmanaged VM with the same name still requires this explicit switch.

.PARAMETER RestartIfRequired
    Automatically registers a one-time logon resume task and restarts Windows
    when enabling a required Windows feature needs a reboot.

.NOTES
    The default credentials are deliberately fixed at ubuntu / ubuntu because
    that is the requested lab image. Do not expose this VM to an untrusted
    network. The generated ISO contains the requested password hash.
#>

[CmdletBinding()]
param(
    [string]$VMName = 'Ubuntu-Desktop-Auto',
    [string]$UbuntuRelease = 'Latest',
    [int]$MemoryGB = 8,
    [int]$CpuCount = 4,
    [int]$DiskGB = 80,
    [string]$VirtualSwitchName = 'Ubuntu-Desktop-Auto-NAT',
    [string]$DataRoot = "$env:ProgramData\Ubuntu-HyperV-Desktop-Provisioner",
    [int]$ReadyTimeoutMinutes = 90,
    [bool]$RestartIfRequired = $true,
    [switch]$ForceRecreate,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '1.0.5'
$ResumeTaskName = 'UbuntuHyperVDesktopProvisioner-Resume'
$UbuntuReleaseRoot = 'https://releases.ubuntu.com'
$GuestUsername = 'ubuntu'
$GuestPassword = 'ubuntu'
# SHA-512 crypt hash for the literal password ubuntu, as documented by the
# official Ubuntu autoinstall quick start.
$GuestPasswordHash = '$6$exDY1mhS4KUCE/2$zmn9ToZwTKLhCw.b4/b.ZRTIZM30JZ4QrOQ2aOXJ8yk96xpcCof0kxKwuX1kqLG/ygbJ1f8wxED22bTL4F46P0'
$ReadyMarker = '/var/lib/ubuntu-hyperv-desktop-provisioner.ready'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = 'Gray'
    if ($Level -eq 'WARN') { $color = 'Yellow' }
    if ($Level -eq 'ERROR') { $color = 'Red' }
    Write-Host "[$stamp] [$Level] $Message" -ForegroundColor $color
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $fullPath = (Get-FullPath $Path).TrimEnd('\') + '\'
    $fullRoot = (Get-FullPath $Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-SafePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-PathUnderRoot -Path $Path -Root $Root)) {
        throw "Refusing to remove a path outside the managed root: $Path"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = New-Object Security.Cryptography.SHA256Managed
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated Windows PowerShell 5.1 window.'
    }
}

function Assert-WindowsPowerShell5 {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'This project must be run by Windows PowerShell 5.1 (powershell.exe), not pwsh.'
    }
}

function Save-ResumeConfiguration {
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        throw 'Automatic reboot recovery requires running this script from a .ps1 file.'
    }
    $resumePath = Join-Path $DataRoot 'resume.json'
    $config = [ordered]@{
        VMName = $VMName
        UbuntuRelease = $UbuntuRelease
        MemoryGB = $MemoryGB
        CpuCount = $CpuCount
        DiskGB = $DiskGB
        VirtualSwitchName = $VirtualSwitchName
        DataRoot = $DataRoot
        ReadyTimeoutMinutes = $ReadyTimeoutMinutes
        RestartIfRequired = $RestartIfRequired
        ForceRecreate = [bool]$ForceRecreate
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resumePath -Encoding UTF8

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Resume -DataRoot "{1}"' -f $PSCommandPath, $DataRoot
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
        Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    } else {
        $runOnce = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        $command = '"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}" -Resume -DataRoot "{2}"' -f $psExe, $PSCommandPath, $DataRoot
        Set-ItemProperty -Path $runOnce -Name $ResumeTaskName -Value $command -Force
    }
    Write-Log 'Windows will resume this run automatically after the required reboot.'
}

function Restore-ResumeConfiguration {
    if (-not $Resume) { return }
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $resumePath = Join-Path $DataRoot 'resume.json'
    if (-not (Test-Path -LiteralPath $resumePath)) {
        throw "Resume was requested but the resume configuration is missing: $resumePath"
    }
    $config = Get-Content -LiteralPath $resumePath -Raw | ConvertFrom-Json
    $VMName = [string]$config.VMName
    $UbuntuRelease = [string]$config.UbuntuRelease
    $MemoryGB = [int]$config.MemoryGB
    $CpuCount = [int]$config.CpuCount
    $DiskGB = [int]$config.DiskGB
    $VirtualSwitchName = [string]$config.VirtualSwitchName
    $DataRoot = [string]$config.DataRoot
    $ReadyTimeoutMinutes = [int]$config.ReadyTimeoutMinutes
    $RestartIfRequired = [bool]$config.RestartIfRequired
    $ForceRecreate = [bool]$config.ForceRecreate
    Remove-Item -LiteralPath $resumePath -Force
    Write-Log 'Resumed automatically after Windows feature installation.'
}

function Ensure-HyperVHost {
    $restartNeeded = $false
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $feature = Get-WindowsFeature -Name Hyper-V
        if (-not $feature.Installed) {
            Write-Log 'Installing the Hyper-V role and management tools.'
            $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false
            if ($result.RestartNeeded -eq 'Yes' -or $result.ExitCode -eq 'SuccessRestartRequired') { $restartNeeded = $true }
        }
    } else {
        foreach ($featureName in @('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell')) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
            if ($feature.State -ne 'Enabled') {
                Write-Log "Enabling Windows feature $featureName."
                $result = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart
                if ($result.RestartNeeded) { $restartNeeded = $true }
            }
        }
    }

    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue) -or -not (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue)) {
        $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($capability -and $capability.State -eq 'NotPresent') {
            Write-Log 'Installing the Windows OpenSSH client.'
            $result = Add-WindowsCapability -Online -Name $capability.Name
            if ($result.RestartNeeded) { $restartNeeded = $true }
        }
    }

    if ($restartNeeded) {
        if (-not $RestartIfRequired) { throw 'Windows requires a reboot to finish host preparation.' }
        Save-ResumeConfiguration
        Write-Log 'Restarting Windows to complete required feature installation.' 'WARN'
        Restart-Computer -Force
        exit 0
    }

    Import-Module Hyper-V -ErrorAction Stop
    foreach ($serviceName in @('vmms', 'vmcompute')) {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        if ($service.StartType -eq 'Disabled') { Set-Service -Name $serviceName -StartupType Automatic }
        if ($service.Status -ne 'Running') { Start-Service -Name $serviceName }
    }
}

function Get-FreeNatNetwork {
    $candidates = @(
        @{ Gateway = '192.168.200.1'; Prefix = '192.168.200.0/24' },
        @{ Gateway = '192.168.201.1'; Prefix = '192.168.201.0/24' },
        @{ Gateway = '172.28.240.1'; Prefix = '172.28.240.0/24' },
        @{ Gateway = '172.28.241.1'; Prefix = '172.28.241.0/24' },
        @{ Gateway = '192.168.240.1'; Prefix = '192.168.240.0/24' }
    )
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DestinationPrefix)
    foreach ($candidate in $candidates) {
        $networkPrefix = $candidate.Prefix.Split('/')[0].Substring(0, $candidate.Prefix.Split('/')[0].LastIndexOf('.') + 1)
        if (-not ($addresses | Where-Object { $_ -like "$networkPrefix*" }) -and -not ($routes -contains $candidate.Prefix)) { return $candidate }
    }
    throw 'No unused private /24 network was available for a new Hyper-V NAT switch.'
}

function Ensure-InternalNat {
    param([Parameter(Mandatory = $true)][string]$SwitchName)
    $adapterAlias = "vEthernet ($SwitchName)"
    $adapter = $null
    for ($i = 0; $i -lt 30 -and $null -eq $adapter; $i++) {
        $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
        if ($null -eq $adapter) { Start-Sleep -Seconds 1 }
    }
    if ($null -eq $adapter) { throw "The virtual adapter for '$SwitchName' did not appear." }
    $existingNat = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "$SwitchName-NAT" }
    if ($existingNat) { return $existingNat.InternalIPInterfaceAddressPrefix }
    $existingAddress = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixLength -eq 24 -and $_.IPAddress -notmatch '^169\.' } | Select-Object -First 1
    if ($existingAddress) {
        $networkPrefix = $existingAddress.IPAddress.Substring(0, $existingAddress.IPAddress.LastIndexOf('.') + 1)
        $network = @{ Gateway = $existingAddress.IPAddress; Prefix = $networkPrefix + '0/24' }
    } else { $network = Get-FreeNatNetwork }
    if (-not (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $network.Gateway })) {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $network.Gateway -PrefixLength 24 | Out-Null
    }
    if (-not (Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $network.Prefix })) {
        New-NetNat -Name "$SwitchName-NAT" -InternalIPInterfaceAddressPrefix $network.Prefix | Out-Null
    }
    return $network.Prefix
}

function Ensure-VirtualSwitch {
    $preferred = Get-VMSwitch -Name $VirtualSwitchName -ErrorAction SilentlyContinue
    if ($preferred) {
        if ($preferred.SwitchType -eq 'Internal') { Ensure-InternalNat -SwitchName $preferred.Name | Out-Null }
        Write-Log "Using existing Hyper-V switch '$($preferred.Name)'."
        return $preferred.Name
    }
    $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($defaultSwitch) { Write-Log "Using existing Hyper-V switch '$($defaultSwitch.Name)'."; return $defaultSwitch.Name }
    $external = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($external) { Write-Log "Using existing external Hyper-V switch '$($external.Name)'."; return $external.Name }
    Write-Log "Creating internal NAT switch '$VirtualSwitchName'."
    New-VMSwitch -Name $VirtualSwitchName -SwitchType Internal | Out-Null
    $prefix = Ensure-InternalNat -SwitchName $VirtualSwitchName
    Write-Log "NAT is ready on $prefix."
    return $VirtualSwitchName
}

function Get-GuestNetworkConfig {
    param([Parameter(Mandatory = $true)][string]$SwitchName)
    if ($SwitchName -eq 'Default Switch') { return $null }
    $vSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    if ($vSwitch.SwitchType -ne 'Internal') { return $null }
    $adapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
    if ($null -eq $adapter) { throw "The host adapter vEthernet ($SwitchName) is missing." }
    $gateway = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^169\.' -and $_.PrefixLength -ge 1 } | Select-Object -First 1
    if ($null -eq $gateway) { throw "The internal switch '$SwitchName' has no IPv4 gateway address." }
    $octets = $gateway.IPAddress.Split('.')
    $usedAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    $guestLastOctet = 2
    while ($guestLastOctet -lt 254) {
        $candidate = "$($octets[0]).$($octets[1]).$($octets[2]).$guestLastOctet"
        if ($usedAddresses -notcontains $candidate) { break }
        $guestLastOctet++
    }
    if ($guestLastOctet -ge 254) { throw "No unused static guest address is available on $($gateway.IPAddress)/$($gateway.PrefixLength)." }
    $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -Unique -First 2)
    if ($dnsServers.Count -eq 0) { $dnsServers = @('1.1.1.1', '8.8.8.8') }
    return [pscustomobject]@{
        Mode = 'StaticNat'
        GuestIp = "$($octets[0]).$($octets[1]).$($octets[2]).$guestLastOctet"
        Gateway = $gateway.IPAddress
        PrefixLength = [int]$gateway.PrefixLength
        DnsServers = $dnsServers
    }
}

function Resolve-UbuntuDesktopRelease {
    param([Parameter(Mandatory = $true)][string]$Requested)
    $familyCandidates = @()
    if ($Requested -ne 'Latest') {
        if ($Requested -notmatch '^\d+\.\d+$') { throw "UbuntuRelease must be Latest or a family such as 26.04." }
        $familyCandidates = @($Requested)
    } else {
        try {
            $root = Invoke-WebRequest -UseBasicParsing -Uri "$UbuntuReleaseRoot/"
            $familyCandidates = @([regex]::Matches($root.Content, 'href=["''](\d+\.\d+)/["'']', [Text.RegularExpressions.RegexOptions]::IgnoreCase) |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object { [version]$_ } -Descending -Unique)
        } catch { Write-Log "Could not enumerate the Ubuntu release index: $($_.Exception.Message)" 'WARN' }
        if ($familyCandidates.Count -eq 0) { $familyCandidates = @('26.04', '25.10', '24.04', '22.04') }
    }

    foreach ($family in $familyCandidates) {
        try {
            $page = Invoke-WebRequest -UseBasicParsing -Uri "$UbuntuReleaseRoot/$family/"
            $isoMatches = @([regex]::Matches($page.Content, 'href=["'']([^"'']*ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop-amd64\.iso)["'']', [Text.RegularExpressions.RegexOptions]::IgnoreCase))
            $isoNames = @($isoMatches | ForEach-Object { [IO.Path]::GetFileName($_.Groups[1].Value) } | Sort-Object -Unique)
            $isoName = $isoNames | Sort-Object { [version]([regex]::Match($_, 'ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop').Groups[1].Value) } -Descending | Select-Object -First 1
            if ([string]::IsNullOrEmpty($isoName)) { continue }
            $sumsResponse = Invoke-WebRequest -UseBasicParsing -Uri "$UbuntuReleaseRoot/$family/SHA256SUMS"
            $sums = $sumsResponse.Content
            if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
            else { $sums = [string]$sums }
            $sumPattern = '(?m)^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($isoName) + '\s*$'
            $sumMatch = [regex]::Match($sums, $sumPattern)
            if (-not $sumMatch.Success) { throw "SHA256SUMS did not contain $isoName." }
            $versionMatch = [regex]::Match($isoName, 'ubuntu-(\d+\.\d+(?:\.\d+)?)-desktop')
            return [pscustomobject]@{
                Family = $family
                Version = $versionMatch.Groups[1].Value
                IsoName = $isoName
                Url = "$UbuntuReleaseRoot/$family/$isoName"
                Sha256 = $sumMatch.Groups[1].Value.ToLowerInvariant()
            }
        } catch {
            if ($Requested -ne 'Latest') { throw }
            Write-Log "Skipping Ubuntu release family ${family}: $($_.Exception.Message)" 'WARN'
        }
    }
    throw 'Could not resolve an official Ubuntu Desktop AMD64 ISO release.'
}

function Ensure-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][psobject]$Release,
        [Parameter(Mandatory = $true)][string]$CacheRoot
    )
    $path = Join-Path $CacheRoot $Release.IsoName
    $partial = "$path.download"
    $hash = $null
    if (Test-Path -LiteralPath $path) { $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    if ($hash -eq $Release.Sha256) {
        Write-Log 'Verified Ubuntu Desktop ISO already exists; skipping download.'
        return $path
    }
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    Write-Log "Downloading official Ubuntu Desktop $($Release.Version) ISO. This is about 6 GB."
    Invoke-WebRequest -UseBasicParsing -Uri $Release.Url -OutFile $partial
    $downloadHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $Release.Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw "Ubuntu Desktop ISO SHA256 mismatch. Expected $($Release.Sha256), got $downloadHash."
    }
    Move-Item -LiteralPath $partial -Destination $path -Force
    return $path
}

function Ensure-GuestKeyPair {
    param([Parameter(Mandatory = $true)][string]$KeyRoot)
    Ensure-Directory -Path $KeyRoot
    $keyPath = Join-Path $KeyRoot 'id_ed25519'
    $publicPath = "$keyPath.pub"
    if (-not (Test-Path -LiteralPath $keyPath) -or -not (Test-Path -LiteralPath $publicPath)) {
        $sshKeygen = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $sshKeygen
        $startInfo.Arguments = '-q -t ed25519 -f "{0}" -N "" -C "ubuntu-hyperv-desktop-provisioner"' -f $keyPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "ssh-keygen failed: $($stderr.Trim())" }
    }
    return [pscustomobject]@{ PrivateKey = $keyPath; PublicKey = (Get-Content -LiteralPath $publicPath -Raw).Trim() }
}

function New-AutoinstallFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SeedRoot,
        [Parameter(Mandatory = $true)][string]$VMNameForGuest,
        [Parameter(Mandatory = $true)][string]$PublicKey,
        [Parameter(Mandatory = $true)][string]$ImageId,
        [psobject]$Network
    )
    Ensure-Directory -Path $SeedRoot
    $networkYaml = if ($Network -and $Network.Mode -eq 'StaticNat') {
        $dnsYaml = $Network.DnsServers -join ', '
        @"
  network:
    version: 2
    ethernets:
      hyperv:
        match:
          name: "e*"
        dhcp4: false
        addresses:
          - $($Network.GuestIp)/$($Network.PrefixLength)
        routes:
          - to: 0.0.0.0/0
            via: $($Network.Gateway)
        nameservers:
          addresses: [$dnsYaml]
"@
    } else {
        @"
  network:
    version: 2
    ethernets:
      hyperv:
        match:
          name: "e*"
        dhcp4: true
"@
    }

    $userData = @"
#cloud-config
autoinstall:
  version: 1
  source:
    id: ubuntu-desktop
  locale: en_US.UTF-8
  keyboard:
    layout: us
    variant: ''
  timezone: Asia/Jerusalem
  refresh-installer:
    update: false
  identity:
    hostname: $VMNameForGuest
    realname: Ubuntu
    username: $GuestUsername
    password: '$GuestPasswordHash'
$networkYaml
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - $PublicKey
  storage:
    layout:
      name: lvm
      sizing-policy: all
  packages:
    - openssh-server
    - cloud-init
    - ca-certificates
    - curl
    - wget
    - git
    - vim
    - htop
    - unzip
    - build-essential
  user-data:
    manage_etc_hosts: true
    package_update: true
    package_upgrade: false
    ssh_pwauth: true
    users:
      - default
      - name: $GuestUsername
        groups: [adm, cdrom, sudo, dip, plugdev, video, audio, netdev]
        sudo: 'ALL=(ALL) NOPASSWD:ALL'
        shell: /bin/bash
        lock_passwd: false
        plain_text_passwd: '$GuestPassword'
        ssh_authorized_keys:
          - $PublicKey
    chpasswd:
      expire: false
      users:
        - name: $GuestUsername
          password: '$GuestPassword'
          type: text
    write_files:
      - path: /etc/gdm3/custom.conf
        owner: root:root
        permissions: '0644'
        content: |
          [daemon]
          AutomaticLoginEnable=true
          AutomaticLogin=$GuestUsername
          WaylandEnable=true
      - path: /home/$GuestUsername/.config/gnome-initial-setup-done
        owner: $GuestUsername`:$GuestUsername
        permissions: '0644'
        content: |
          Ubuntu Hyper-V Desktop provisioner completed GNOME initial setup.
      - path: /etc/systemd/system/ubuntu-hyperv-desktop-ready.service
        owner: root:root
        permissions: '0644'
        content: |
          [Unit]
          Description=Ubuntu Hyper-V Desktop readiness marker
          Wants=graphical.target ssh.service
          After=graphical.target ssh.service
          [Service]
          Type=oneshot
          ExecStart=/usr/bin/touch $ReadyMarker
          RemainAfterExit=yes
          [Install]
          WantedBy=graphical.target
    runcmd:
      - [ bash, -lc, "install -d -m 0755 -o $GuestUsername -g $GuestUsername /home/$GuestUsername/.config/gnome-initial-setup && version=`$(. /etc/os-release; printf '%s' `${VERSION_ID}) && printf '%s\\n' 'Ubuntu Hyper-V Desktop provisioner completed GNOME initial setup.' > /home/$GuestUsername/.config/gnome-initial-setup-done && printf '%s\\n' 'Ubuntu Hyper-V Desktop provisioner completed the release upgrade setup.' > /home/$GuestUsername/.config/gnome-initial-setup/upgrade-`$version-done && chown $GuestUsername`:$GuestUsername /home/$GuestUsername/.config/gnome-initial-setup-done /home/$GuestUsername/.config/gnome-initial-setup/upgrade-`$version-done" ]
      - [ bash, -lc, "systemctl set-default graphical.target" ]
      - [ bash, -lc, "systemctl daemon-reload" ]
      - [ bash, -lc, "systemctl enable gdm3" ]
      - [ bash, -lc, "systemctl enable --now ssh" ]
      - [ bash, -lc, "systemctl enable --now ubuntu-hyperv-desktop-ready.service" ]
      - [ bash, -lc, "systemctl restart gdm3" ]
  shutdown: poweroff
"@
    $metaData = "instance-id: ubuntu-hyperv-desktop-$($ImageId.Substring(0, 12))`nlocal-hostname: $VMNameForGuest`n"
    [IO.File]::WriteAllText((Join-Path $SeedRoot 'user-data'), $userData, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $SeedRoot 'meta-data'), $metaData, [Text.Encoding]::ASCII)
    return [pscustomobject]@{ UserData = $userData; MetaData = $metaData }
}

function Get-WslDistro {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { return $null }
    $names = @(& $wsl.Source --list --quiet 2>$null | ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) { return $null }
    return $names[0]
}

function Ensure-WslXorriso {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { throw 'WSL is required to rebuild the Ubuntu ISO and is not installed.' }
    $distro = Get-WslDistro
    if ([string]::IsNullOrEmpty($distro)) { throw 'WSL is installed but has no Linux distribution. Install Ubuntu once, then rerun this script.' }
    $check = @('-d', $distro, '--', 'bash', '-lc', 'command -v xorriso')
    $found = (& $wsl.Source @check 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrEmpty([string]$found)) {
        Write-Log "Installing xorriso inside WSL distribution '$distro'."
        $install = @('-d', $distro, '--', 'bash', '-lc', 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xorriso')
        & $wsl.Source @install | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not install xorriso inside WSL.' }
    }
    return [pscustomobject]@{ Executable = $wsl.Source; Distro = $distro }
}

function Invoke-XorrisoProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$CommandArguments
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = (@($CommandArguments | ForEach-Object {
        $argument = [string]$_
        if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if (-not [string]::IsNullOrEmpty($stdout)) { Write-Host $stdout.TrimEnd() }
    if (-not [string]::IsNullOrEmpty($stderr)) { Write-Host $stderr.TrimEnd() }
    return [int]$process.ExitCode
}

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = (Get-FullPath $Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "The path is not a Windows drive path: $Path" }
    return '/mnt/' + $matches[1].ToLowerInvariant() + '/' + ($matches[2] -replace '\\', '/')
}

function Get-IsoGrubConfig {
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $image = Mount-DiskImage -ImagePath $IsoPath -PassThru -StorageType ISO
    try {
        $volume = $image | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
        if ($null -eq $volume) { throw 'The Ubuntu ISO did not receive a drive letter when mounted.' }
        $source = Join-Path ("$($volume.DriveLetter):\") 'boot\grub\grub.cfg'
        if (-not (Test-Path -LiteralPath $source)) { throw "Ubuntu ISO does not contain $source." }
        Copy-Item -LiteralPath $source -Destination $Destination -Force
        $destinationFile = Get-Item -LiteralPath $Destination -Force
        $destinationFile.IsReadOnly = $false
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    }
}

function New-AutoinstallGrubConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    $original = Get-Content -LiteralPath $Path -Raw
    $original = [regex]::Replace($original, '(?mi)^\s*set\s+timeout\s*=.*$', 'set timeout=1')
    $original = [regex]::Replace($original, '(?mi)^\s*set\s+default\s*=.*$', 'set default=0')
    $entry = @'
set default=0
set timeout=1
menuentry "Ubuntu Hyper-V Desktop (automatic installation)" {
    set gfxpayload=keep
    linux /casper/vmlinuz layerfs-path=minimal.standard.live.squashfs autoinstall ds=nocloud\;s=/cdrom/nocloud/ ---
    initrd /casper/initrd
}

'@
    Set-Content -LiteralPath $Path -Value ($entry + $original) -Encoding ASCII
}

function Ensure-AutoinstallIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceIso,
        [Parameter(Mandatory = $true)][psobject]$Release,
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [Parameter(Mandatory = $true)][string]$VMNameForGuest,
        [Parameter(Mandatory = $true)][string]$PublicKey,
        [psobject]$Network
    )
    $configToken = Get-TextSha256 -Text ($ScriptVersion + $Release.Sha256 + $VMNameForGuest + $GuestUsername + $GuestPassword + $PublicKey + ($Network | Out-String))
    $buildRoot = Join-Path $CacheRoot ("desktop-autoinstall-$($Release.Sha256.Substring(0, 12))-$($configToken.Substring(0, 12))")
    $seedRoot = Join-Path $buildRoot 'nocloud'
    $grubPath = Join-Path $buildRoot 'grub.cfg'
    $outputIso = Join-Path $CacheRoot ("ubuntu-$($Release.Version)-desktop-amd64-hyperv-autoinstall.iso")
    $metaPath = "$outputIso.json"
    if ((Test-Path -LiteralPath $outputIso) -and (Test-Path -LiteralPath $metaPath)) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
            $cachedLength = [int64](Get-Item -LiteralPath $outputIso).Length
            $lengthMatches = (-not $meta.OutputLength) -or ([int64]$meta.OutputLength -eq $cachedLength)
            if ($cachedLength -gt 1GB -and $lengthMatches -and $meta.SourceSha256 -eq $Release.Sha256 -and $meta.ConfigToken -eq $configToken) {
                Write-Log 'Verified Ubuntu Desktop autoinstall ISO already exists; skipping rebuild.'
                return $outputIso
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $outputIso) { Remove-Item -LiteralPath $outputIso -Force }
    Ensure-Directory -Path $buildRoot
    Ensure-Directory -Path $seedRoot
    New-AutoinstallFiles -SeedRoot $seedRoot -VMNameForGuest $VMNameForGuest -PublicKey $PublicKey -ImageId $Release.Sha256 -Network $Network | Out-Null
    Get-IsoGrubConfig -IsoPath $SourceIso -Destination $grubPath
    New-AutoinstallGrubConfig -Path $grubPath

    $xorriso = Ensure-WslXorriso
    $args = @(
        '-d', $xorriso.Distro,
        '--', 'xorriso',
        '-indev', (Convert-ToWslPath $SourceIso),
        '-outdev', (Convert-ToWslPath $outputIso),
        '-map', (Convert-ToWslPath $seedRoot), '/nocloud',
        '-map', (Convert-ToWslPath $grubPath), '/boot/grub/grub.cfg',
        '-boot_image', 'any', 'replay',
        '-padding', '0'
    )
    Write-Log 'Building the bootable Ubuntu Desktop autoinstall ISO.'
    $xorrisoExit = Invoke-XorrisoProcess -Executable $xorriso.Executable -CommandArguments $args
    if ($xorrisoExit -ne 0 -or -not (Test-Path -LiteralPath $outputIso)) { throw "xorriso failed with exit code $xorrisoExit." }
    if ((Get-Item -LiteralPath $outputIso).Length -lt 1GB) { throw 'The rebuilt Ubuntu Desktop ISO is unexpectedly small.' }
    [ordered]@{
        SourceSha256 = $Release.Sha256
        ConfigToken = $configToken
        OutputLength = (Get-Item -LiteralPath $outputIso).Length
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Path = $outputIso
    } | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding UTF8
    return $outputIso
}

function New-BlankVhdx {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$SizeGB
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Creating the $SizeGB GB dynamic Ubuntu Desktop VHDX."
        New-VHD -Path $Path -SizeBytes ([int64]$SizeGB * 1GB) -Dynamic | Out-Null
    }
    $disk = Get-VHD -Path $Path -ErrorAction Stop
    $requested = [int64]$SizeGB * 1GB
    if ($disk.Size -lt $requested) { Resize-VHD -Path $Path -SizeBytes $requested }
}

function Remove-ManagedVm {
    param([Parameter(Mandatory = $true)][psobject]$ExistingState)
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
        Remove-VM -Name $VMName -Force
    }
    # The custom ISO is a verified cache artifact shared by the managed VM;
    # preserve it when a VM alone is being recreated.
    foreach ($path in @($ExistingState.OsDisk, $ExistingState.StateRoot)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-SafePath -Path $path -Root $DataRoot }
    }
}

function Set-InstalledVmFirmware {
    param([Parameter(Mandatory = $true)][string]$OsDisk)
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
    $dvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrEmpty([string]$_.Path) } |
        Select-Object -First 1
    if ($dvd) {
        try {
            Remove-VMDvdDrive -VMName $VMName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -ErrorAction Stop
        } catch {
            if ($_.Exception.Message -notmatch 'cannot be found|not found') { throw }
            Write-Log 'The installer had already removed the DVD device; continuing with the installed OS disk.' 'WARN'
        }
    }
    $osDrive = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $OsDisk } | Select-Object -First 1
    if (-not $osDrive) { throw 'The installed Ubuntu OS disk is not attached to the VM.' }
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' -BootOrder @($osDrive)
}

function Ensure-VMConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$OsDisk,
        [Parameter(Mandatory = $true)][string]$InstallIso,
        [Parameter(Mandatory = $true)][string]$SwitchName,
        [Parameter(Mandatory = $true)][int64]$MemoryBytes,
        [Parameter(Mandatory = $true)][int]$Processors,
        [Parameter(Mandatory = $true)][string]$VMRoot,
        [Parameter(Mandatory = $true)][bool]$Installing
    )
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "Creating Generation 2 Hyper-V VM '$VMName'."
        $vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $MemoryBytes -VHDPath $OsDisk -SwitchName $SwitchName -Path $VMRoot
    }
    $needsRestart = $false
    if ($vm.ProcessorCount -ne $Processors) { $needsRestart = $true }
    if ($vm.MemoryStartup -ne $MemoryBytes -or $vm.DynamicMemoryEnabled) { $needsRestart = $true }
    if ($vm.State -ne 'Off' -and $needsRestart) { Stop-VM -Name $VMName -TurnOff -Force }
    if ($needsRestart -or (Get-VM -Name $VMName).State -eq 'Off') {
        Set-VMProcessor -VMName $VMName -Count $Processors
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes
    }
    if ((Get-VM -Name $VMName).State -eq 'Off') {
        Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false -ErrorAction SilentlyContinue
        Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    }
    $adapter = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
    if (-not $adapter) { Add-VMNetworkAdapter -VMName $VMName -SwitchName $SwitchName | Out-Null }
    else { Connect-VMNetworkAdapter -VMName $VMName -SwitchName $SwitchName }
    $osDrive = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $OsDisk } | Select-Object -First 1
    if (-not $osDrive) { Add-VMHardDiskDrive -VMName $VMName -Path $OsDisk }

    $dvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Installing) {
        if (-not $dvd) { $dvd = Add-VMDvdDrive -VMName $VMName -Path $InstallIso -Passthru }
        else { Set-VMDvdDrive -VMName $VMName -Path $InstallIso }
        $osDrive = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $OsDisk } | Select-Object -First 1
        $dvd = Get-VMDvdDrive -VMName $VMName | Select-Object -First 1
        Set-VMFirmware -VMName $VMName -BootOrder @($dvd, $osDrive)
    } else {
        Set-InstalledVmFirmware -OsDisk $OsDisk
    }
    Get-VMIntegrationService -VMName $VMName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Guest Service Interface' } | Enable-VMIntegrationService -ErrorAction SilentlyContinue
    $vm = Get-VM -Name $VMName
    if ($Installing -and $vm.State -ne 'Running') { Write-Log "Starting the unattended Ubuntu Desktop installation."; Start-VM -Name $VMName | Out-Null }
    if (-not $Installing -and $vm.State -ne 'Running') { Write-Log "Starting Ubuntu Desktop VM '$VMName'."; Start-VM -Name $VMName | Out-Null }
}

function Wait-ForInstallerPowerOff {
    param([Parameter(Mandatory = $true)][int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $sawRunning = $false
    $started = Get-Date
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ($vm.State -eq 'Running') { $sawRunning = $true }
        if ($sawRunning -and $vm.State -eq 'Off') {
            Write-Log 'Ubuntu autoinstall powered off the VM after installation.'
            return
        }
        if (-not $sawRunning -and $vm.State -eq 'Off' -and ((Get-Date) - $started).TotalSeconds -gt 120) {
            Write-Log 'The installer VM is already powered off; continuing with the installed-disk verification.' 'WARN'
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "Ubuntu Desktop autoinstall did not power off within $TimeoutMinutes minutes."
}

function Get-GuestIpAddress {
    return @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty IPAddresses -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.' })
}

function Invoke-SshGuest {
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [Parameter(Mandatory = $true)][string]$PrivateKey,
        [Parameter(Mandatory = $true)][string]$Command
    )
    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
    $sshArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-i', $PrivateKey, "$GuestUsername@$Ip", $Command)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ssh
    $quoted = @($sshArgs | ForEach-Object {
        $argument = [string]$_
        if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
    })
    $startInfo.Arguments = $quoted -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Wait-ForGuestSsh {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateKey,
        [psobject]$Network
    )
    $deadline = (Get-Date).AddMinutes($ReadyTimeoutMinutes)
    $lastIp = $null
    while ((Get-Date) -lt $deadline) {
        $ips = @()
        if ($Network -and $Network.Mode -eq 'StaticNat') { $ips += $Network.GuestIp }
        $ips += Get-GuestIpAddress
        foreach ($ip in ($ips | Select-Object -Unique)) {
            if ($ip -ne $lastIp) { Write-Log "Guest network address detected: $ip"; $lastIp = $ip }
            $probe = Invoke-SshGuest -Ip $ip -PrivateKey $PrivateKey -Command 'cloud-init status --wait; s=$?; if [ "$s" -ne 0 ] && [ "$s" -ne 2 ]; then exit "$s"; fi; systemctl is-active --quiet ssh && test -f /var/lib/ubuntu-hyperv-desktop-provisioner.ready && echo UBUNTU_DESKTOP_READY'
            if ($probe.ExitCode -eq 0 -and $probe.Stdout -match 'UBUNTU_DESKTOP_READY') { return $ip }
        }
        Start-Sleep -Seconds 5
    }
    throw "Ubuntu Desktop did not report SSH/readiness within $ReadyTimeoutMinutes minutes."
}

function Verify-GuestDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [Parameter(Mandatory = $true)][string]$PrivateKey
    )
    $command = 'set -eu; test "$(. /etc/os-release; printf %s "$PRETTY_NAME")" != ""; systemctl is-active --quiet ssh; systemctl is-active --quiet gdm3; test "$(systemctl get-default)" = graphical.target; grep -q "AutomaticLoginEnable=true" /etc/gdm3/custom.conf; grep -q "AutomaticLogin=ubuntu" /etc/gdm3/custom.conf; test -f /home/ubuntu/.config/gnome-initial-setup-done; if ps -eo comm= | awk ''$1 == "gnome-initial-s" { found=1 } END { exit(found ? 0 : 1) }''; then exit 1; fi; loginctl list-users --no-legend | awk ''$2 == "ubuntu" { found=1 } END { exit(found ? 0 : 1) }''; sessions=$(loginctl list-sessions --no-legend | awk ''$3 == "ubuntu" { print $1 }''); test -n "$sessions"; graphical=0; for session in $sessions; do session_type=$(loginctl show-session "$session" -p Type --value); session_state=$(loginctl show-session "$session" -p State --value); if { [ "$session_type" = "wayland" ] || [ "$session_type" = "x11" ]; } && { [ "$session_state" = "active" ] || [ "$session_state" = "online" ]; }; then graphical=1; fi; done; test "$graphical" -eq 1; echo UBUNTU_DESKTOP_VERIFIED'
    $probe = Invoke-SshGuest -Ip $Ip -PrivateKey $PrivateKey -Command $command
    if ($probe.ExitCode -ne 0 -or $probe.Stdout -notmatch 'UBUNTU_DESKTOP_VERIFIED') {
        throw "Guest verification failed. $($probe.Stderr.Trim()) $($probe.Stdout.Trim())"
    }
    return $probe.Stdout.Trim()
}

function Wait-ForGuestDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [Parameter(Mandatory = $true)][string]$PrivateKey
    )
    $deadline = (Get-Date).AddMinutes($ReadyTimeoutMinutes)
    $lastError = 'no verification attempt completed'
    while ((Get-Date) -lt $deadline) {
        try {
            return (Verify-GuestDesktop -Ip $Ip -PrivateKey $PrivateKey)
        } catch {
            $lastError = $_.Exception.Message
            Write-Log 'Ubuntu Desktop services are reachable but the graphical login is still starting; retrying.' 'WARN'
            Start-Sleep -Seconds 5
        }
    }
    throw "Ubuntu Desktop graphical readiness was not verified within $ReadyTimeoutMinutes minutes. $lastError"
}

function Open-VMConnectWindow {
    $vmconnect = Get-Command vmconnect.exe -ErrorAction SilentlyContinue
    if (-not $vmconnect) { throw 'vmconnect.exe is not available; Hyper-V management tools are incomplete.' }
    Start-Process -FilePath $vmconnect.Source -ArgumentList @('localhost', $VMName) -WindowStyle Normal | Out-Null
}

try {
    Assert-WindowsPowerShell5
    Assert-Administrator
    Ensure-Directory -Path $DataRoot
    Restore-ResumeConfiguration
    Ensure-HyperVHost
    if ($MemoryGB -lt 4) { throw 'MemoryGB must be at least 4 for Ubuntu Desktop.' }
    if ($CpuCount -lt 2) { throw 'CpuCount must be at least 2 for Ubuntu Desktop.' }
    if ($DiskGB -lt 30) { throw 'DiskGB must be at least 30 for Ubuntu Desktop.' }
    if ([string]::IsNullOrEmpty($VMName) -or $VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$') { throw 'VMName must be 1-63 characters using letters, numbers, dots, and hyphens.' }

    $cacheRoot = Join-Path $DataRoot 'cache'
    $keyRoot = Join-Path $DataRoot 'keys'
    $vmRoot = Join-Path (Join-Path $DataRoot 'VMs') $VMName
    Ensure-Directory -Path $cacheRoot
    Ensure-Directory -Path $keyRoot
    Ensure-Directory -Path $vmRoot

    $switchName = Ensure-VirtualSwitch
    $guestNetwork = Get-GuestNetworkConfig -SwitchName $switchName
    if ($guestNetwork) { Write-Log "Using static guest address $($guestNetwork.GuestIp)/$($guestNetwork.PrefixLength) through gateway $($guestNetwork.Gateway)." }
    $release = Resolve-UbuntuDesktopRelease -Requested $UbuntuRelease
    Write-Log "Selected Ubuntu Desktop $($release.Version); SHA256 $($release.Sha256)."
    $sourceIso = Ensure-VerifiedDownload -Release $release -CacheRoot $cacheRoot
    $keyPair = Ensure-GuestKeyPair -KeyRoot $keyRoot
    $installIsoCandidates = @(Ensure-AutoinstallIso -SourceIso $sourceIso -Release $release -CacheRoot $cacheRoot -VMNameForGuest $VMName -PublicKey $keyPair.PublicKey -Network $guestNetwork)
    $installIso = $installIsoCandidates |
        Where-Object { $_ -is [string] -and (Test-Path -LiteralPath ([string]$_)) } |
        Select-Object -Last 1
    if ([string]::IsNullOrEmpty([string]$installIso)) { throw 'The autoinstall ISO builder did not return a valid ISO path.' }

    $statePath = Join-Path $vmRoot 'state.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath) { try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $state = $null } }
    $existingVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $networkToken = if ($guestNetwork) { "$($guestNetwork.GuestIp)/$($guestNetwork.PrefixLength)|$($guestNetwork.Gateway)|$($guestNetwork.DnsServers -join ',')" } else { 'dhcp' }
    $inputMaterial = $release.Sha256 + $GuestUsername + $GuestPassword + $keyPair.PublicKey + $switchName + $networkToken
    $inputsHash = Get-TextSha256 -Text $inputMaterial
    $legacyInputsHash = if ($state -and $state.ScriptVersion) {
        Get-TextSha256 -Text ([string]$state.ScriptVersion + $inputMaterial)
    } else { $null }
    $orphanedManagedVm = $false
    if ($existingVm -and -not $state) {
        $expectedVmPath = [System.IO.Path]::GetFullPath((Join-Path $vmRoot $VMName)).TrimEnd([char]'\')
        $actualVmPath = [System.IO.Path]::GetFullPath([string]$existingVm.Path).TrimEnd([char]'\')
        $existingOsDrive = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1)
        $existingAdapter = @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1)
        $existingDvd = @(Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1)
        $existingOsPath = if ($existingOsDrive.Count -gt 0) { [System.IO.Path]::GetFullPath([string]$existingOsDrive[0].Path) } else { '' }
        $existingDvdPath = if ($existingDvd.Count -gt 0) { [string]$existingDvd[0].Path } else { '' }
        $shapeMatches =
            $existingVm.Generation -eq 2 -and
            $actualVmPath -eq $expectedVmPath -and
            $existingOsPath -eq [System.IO.Path]::GetFullPath($osDisk) -and
            $existingAdapter.Count -gt 0 -and
            [string]$existingAdapter[0].SwitchName -eq $switchName
        if ($shapeMatches) {
            $orphanedManagedVm = $true
            $orphanedInstallationComplete = $existingVm.State -eq 'Off' -and [string]::IsNullOrEmpty($existingDvdPath)
            $state = [pscustomobject]@{
                ManagedBy = 'UbuntuHyperVDesktopProvisioner'
                InputsHash = $inputsHash
                Release = $release.Version
                InstallationComplete = $orphanedInstallationComplete
            }
            Write-Log "Recovering the interrupted managed VM '$VMName' without restarting its installation." 'WARN'
        }
    }
    $isManaged = ($state -and $state.ManagedBy -eq 'UbuntuHyperVDesktopProvisioner') -or $orphanedManagedVm
    $isCurrent = $isManaged -and
        ($state.InputsHash -eq $inputsHash -or $state.InputsHash -eq $legacyInputsHash) -and
        $state.Release -eq $release.Version

    if ($existingVm -and -not $isManaged) {
        if (-not $ForceRecreate) { throw "VM '$VMName' already exists but is not managed by this script. Choose another -VMName or use -ForceRecreate." }
        Write-Log "Removing explicitly authorized unmanaged VM '$VMName'." 'WARN'
        if ($existingVm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
        Remove-VM -Name $VMName -Force
        $existingVm = $null
    } elseif ($existingVm -and -not $isCurrent) {
        Write-Log "Managed VM inputs are stale; recreating '$VMName'." 'WARN'
        Remove-ManagedVm -ExistingState $state
        $existingVm = $null
        $state = $null
    } elseif (-not $existingVm -and $state -and -not $isCurrent) {
        Write-Log 'Removing stale managed Desktop artifacts from an incomplete previous run.' 'WARN'
        Remove-ManagedVm -ExistingState $state
        $state = $null
    }

    Ensure-Directory -Path $vmRoot
    $osDisk = Join-Path $vmRoot "$VMName-os.vhdx"
    $installing = $true
    if ($state -and $state.InstallationComplete -and (Test-Path -LiteralPath $osDisk)) { $installing = $false }
    if ($state -and -not $state.InstallationComplete -and $existingVm -and $existingVm.State -eq 'Off') {
        $remainingDvd = @(Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrEmpty([string]$_.Path) })
        if ($remainingDvd.Count -eq 0 -and (Test-Path -LiteralPath $osDisk)) {
            Write-Log 'The completed installer auto-ejected its DVD; recovering the installed disk without reinstalling.' 'WARN'
            $state.InstallationComplete = $true
            $installing = $false
        }
    }
    if (-not $state -and (Test-Path -LiteralPath $osDisk)) { Remove-SafePath -Path $osDisk -Root $DataRoot }
    New-BlankVhdx -Path $osDisk -SizeGB $DiskGB

    Ensure-VMConfiguration -OsDisk $osDisk -InstallIso $installIso -SwitchName $switchName -MemoryBytes ([int64]$MemoryGB * 1GB) -Processors $CpuCount -VMRoot $vmRoot -Installing $installing
    $newState = [ordered]@{
        SchemaVersion = 1
        ManagedBy = 'UbuntuHyperVDesktopProvisioner'
        ScriptVersion = $ScriptVersion
        VMName = $VMName
        Release = $release.Version
        Family = $release.Family
        IsoName = $release.IsoName
        IsoUrl = $release.Url
        IsoSha256 = $release.Sha256
        InputsHash = $inputsHash
        SwitchName = $switchName
        GuestUsername = $GuestUsername
        GuestPassword = $GuestPassword
        PrivateKey = $keyPair.PrivateKey
        OsDisk = $osDisk
        InstallIso = $installIso
        StateRoot = $vmRoot
        InstallationComplete = (-not $installing)
        Ready = $false
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $newState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

    if ($installing) {
        Write-Log "Waiting for unattended Ubuntu Desktop installation to finish (up to $ReadyTimeoutMinutes minutes)."
        Wait-ForInstallerPowerOff -TimeoutMinutes $ReadyTimeoutMinutes
        Set-InstalledVmFirmware -OsDisk $osDisk
        $newState.InstallationComplete = $true
        $newState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
        Start-VM -Name $VMName | Out-Null
    }

    Write-Log 'Waiting for Ubuntu Desktop SSH, cloud-init, and graphical readiness.'
    $guestIp = Wait-ForGuestSsh -PrivateKey $keyPair.PrivateKey -Network $guestNetwork
    $verification = Wait-ForGuestDesktop -Ip $guestIp -PrivateKey $keyPair.PrivateKey
    $newState.Ready = $true
    $newState.GuestIp = $guestIp
    $newState.ReadyUtc = (Get-Date).ToUniversalTime().ToString('o')
    $newState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Open-VMConnectWindow
    Write-Log "Ubuntu Desktop $($release.Version) is ready at $guestIp."
    Write-Log "VMConnect opened for '$VMName'."
    Write-Host ''
    Write-Host "Guest username: $GuestUsername" -ForegroundColor Green
    Write-Host "Guest password: $GuestPassword" -ForegroundColor Green
    Write-Host "SSH key: $($keyPair.PrivateKey)" -ForegroundColor Green
    Write-Host "State: $statePath" -ForegroundColor Green
    Write-Host "Verification: $($verification -replace '[\r\n]+', ' ')" -ForegroundColor Green
} catch {
    $failureLocation = $_.InvocationInfo.PositionMessage
    Write-Log ("{0} at {1}" -f $_.Exception.Message, $failureLocation) 'ERROR'
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { Write-Log "The managed VM '$VMName' was left available for the next idempotent retry." 'WARN' }
    exit 1
}
