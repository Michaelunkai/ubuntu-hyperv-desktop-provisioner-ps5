#requires -Version 5.1

<##
.SYNOPSIS
    Removes every resource created by the default Ubuntu Desktop provisioner run.

.DESCRIPTION
    Stops and removes the managed Ubuntu-Desktop-Auto VM, closes only its
    VMConnect window, removes the dedicated Ubuntu-Desktop-Auto-NAT switch and
    NAT, removes the complete C:\ProgramData\Ubuntu-HyperV-Desktop-Provisioner
    tree, removes the known temporary seed-test tree, and removes only the WSL
    packages recorded by the GUI provisioner's xorriso installation command.

    The script refuses a DataRoot outside the exact default project root and
    never unregisters or deletes a WSL distribution.
#>

[CmdletBinding()]
param(
    [string]$VMName = 'Ubuntu-Desktop-Auto',
    [string]$VirtualSwitchName = 'Ubuntu-Desktop-Auto-NAT',
    [string]$DataRoot = "$env:ProgramData\Ubuntu-HyperV-Desktop-Provisioner",
    [string]$SeedTestRoot = 'C:\Temp\ubuntu-desktop-seed-test',
    [string]$WslDistro = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$NatName = "$VirtualSwitchName-NAT"
$ExpectedDataRoot = Join-Path $env:ProgramData 'Ubuntu-HyperV-Desktop-Provisioner'

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

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this cleanup script from an elevated Windows PowerShell 5.1 window.'
    }
}

function Assert-WindowsPowerShell5 {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'This cleanup script must run in Windows PowerShell 5.1 (powershell.exe), not pwsh.'
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

function Get-TreeSummary {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Count = 0; Bytes = [int64]0 }
    }
    $files = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue)
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    return [pscustomobject]@{ Exists = $true; Count = $files.Count; Bytes = [int64]$sum }
}

function Get-WslDistroName {
    if (-not [string]::IsNullOrEmpty($WslDistro)) { return $WslDistro }
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { return $null }
    $names = @(& $wsl.Source --list --quiet 2>$null |
        ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() } |
        Where-Object { $_ })
    if ($names.Count -eq 0) { return $null }
    return [string]$names[0]
}

function Get-WslCleanupPackages {
    param([Parameter(Mandatory = $true)][string]$Distro)
    $wsl = Get-Command wsl.exe -ErrorAction Stop
    $ledgerPath = Join-Path $DataRoot 'wsl-installed-packages.json'
    if (Test-Path -LiteralPath $ledgerPath) {
        try {
            $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
            if ($ledger.Distro -eq $Distro -and $ledger.Packages) {
                return @($ledger.Packages | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
            }
        } catch {
            Write-Log "The WSL package ledger could not be read; checking apt history." 'WARN'
        }
    }

    # Backward-compatible recovery for runs made before the ledger existed.
    # The GUI provisioner uses this exact apt command, so only that transaction
    # is accepted as evidence for removing packages.
    # Keep this command free of nested quotes: wsl.exe passes the complete
    # bash command through Windows argument parsing before bash receives it.
    $historyCommand = 'grep -h -A1 xorriso /var/log/apt/history.log* 2>/dev/null | grep ^Install: | tail -n 1'
    $historyLines = @(& $wsl.Source -d $Distro --user root -- bash -lc $historyCommand 2>$null |
        ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() } |
        Where-Object { $_ })
    $installLine = $historyLines | Select-Object -Last 1
    $packages = @()
    if ($installLine) {
        $matches = [regex]::Matches([string]$installLine, '(?:Install:\s*|,\s*)([A-Za-z0-9][A-Za-z0-9+_.-]*)(?::[A-Za-z0-9+_.-]+)?\s+\(')
        foreach ($match in $matches) { $packages += $match.Groups[1].Value }
    }
    return @($packages | Where-Object { $_ } | Select-Object -Unique)
}

function Remove-WslPackages {
    $distro = Get-WslDistroName
    if ([string]::IsNullOrEmpty($distro)) {
        Write-Log 'WSL is not installed or has no registered distribution; skipping WSL package cleanup.' 'WARN'
        return
    }
    $wsl = Get-Command wsl.exe -ErrorAction Stop
    $packages = @(Get-WslCleanupPackages -Distro $distro)
    if ($packages.Count -eq 0) {
        Write-Log "No package transaction owned by this GUI provisioner was found in WSL '$distro'."
        return
    }
    Write-Log "Removing GUI-provisioner WSL packages from '$distro': $($packages -join ', ')."
    $packageList = $packages -join ' '
    $command = "DEBIAN_FRONTEND=noninteractive apt-get remove -y -- $packageList"
    $output = @(& $wsl.Source -d $distro --user root -- bash -lc $command 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "WSL package cleanup failed with exit code $exitCode. $($output -join ' ')"
    }
}

function Stop-ManagedVmConnect {
    $pattern = [regex]::Escape($VMName)
    $processes = @(Get-Process -Name vmconnect -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match $pattern })
    foreach ($process in $processes) {
        Write-Log "Closing VMConnect window for '$VMName'."
        if ($process.CloseMainWindow()) { [void]$process.WaitForExit(5000) }
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
}

function Dismount-ManagedImages {
    if (-not (Get-Command Get-DiskImage -ErrorAction SilentlyContinue)) { return }
    $rootPrefix = (Get-FullPath $DataRoot).TrimEnd('\') + '\'
    $isoFiles = @(Get-ChildItem -LiteralPath $DataRoot -Filter '*.iso' -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) })
    foreach ($isoFile in $isoFiles) {
        $image = Get-DiskImage -ImagePath $isoFile.FullName -ErrorAction SilentlyContinue
        if ($image -and $image.Attached) {
            Write-Log "Dismounting managed image '$($isoFile.FullName)'."
            Dismount-DiskImage -ImagePath $isoFile.FullName -ErrorAction Stop
        }
    }
}

function Remove-ManagedVm {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$VMName' is already absent."
        return
    }
    $vmPath = Get-FullPath ([string]$vm.Path)
    if (-not (Test-PathUnderRoot -Path $vmPath -Root $DataRoot)) {
        throw "Refusing to remove VM '$VMName' because its Hyper-V path is outside the managed root: $vmPath"
    }
    if ($vm.State -ne 'Off') {
        Write-Log "Stopping VM '$VMName'."
        Stop-VM -Name $VMName -TurnOff -Force
    }
    Write-Log "Removing VM '$VMName'."
    Remove-VM -Name $VMName -Force
}

function Remove-ManagedNetwork {
    $nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($nat) {
        Write-Log "Removing NAT '$NatName'."
        Remove-NetNat -Name $NatName -Confirm:$false
    } else {
        Write-Log "NAT '$NatName' is already absent."
    }
    $switch = Get-VMSwitch -Name $VirtualSwitchName -ErrorAction SilentlyContinue
    if ($switch) {
        Write-Log "Removing dedicated switch '$VirtualSwitchName'."
        Remove-VMSwitch -Name $VirtualSwitchName -Force
    } else {
        Write-Log "Switch '$VirtualSwitchName' is already absent."
    }
}

function Remove-ExactTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Already absent: $Path"
        return
    }
    Write-Log "Deleting: $Path"
    [IO.Directory]::Delete((Get-FullPath $Path), $true)
    if (Test-Path -LiteralPath $Path) { throw "The exact cleanup path still exists: $Path" }
}

try {
    Assert-WindowsPowerShell5
    Assert-Administrator

    $actualRoot = (Get-FullPath $DataRoot).TrimEnd('\')
    $expectedRoot = (Get-FullPath $ExpectedDataRoot).TrimEnd('\')
    if ($actualRoot -ne $expectedRoot) {
        throw "Refusing to clean a non-default DataRoot. Expected '$expectedRoot', got '$actualRoot'."
    }

    $before = Get-TreeSummary -Path $DataRoot
    Write-Log ("Managed C: tree before cleanup: {0} files, {1:N0} bytes." -f $before.Count, $before.Bytes)
    Remove-WslPackages
    Dismount-ManagedImages
    Stop-ManagedVmConnect
    Remove-ManagedVm
    Remove-ManagedNetwork

    $resumeTaskName = 'UbuntuHyperVDesktopProvisioner-Resume'
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $resumeTaskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false
            Write-Log "Removed resume task '$resumeTaskName'."
        }
    }
    $runOnce = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $runOnceValues = Get-ItemProperty -Path $runOnce -ErrorAction SilentlyContinue
    if ($runOnceValues -and $runOnceValues.PSObject.Properties.Name -contains $resumeTaskName) {
        Remove-ItemProperty -Path $runOnce -Name $resumeTaskName -ErrorAction SilentlyContinue
        Write-Log "Removed resume RunOnce entry '$resumeTaskName'."
    }

    Remove-ExactTree -Path $DataRoot
    Remove-ExactTree -Path $SeedTestRoot

    $remainingVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $remainingSwitch = Get-VMSwitch -Name $VirtualSwitchName -ErrorAction SilentlyContinue
    $remainingNat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($remainingVm -or $remainingSwitch -or $remainingNat -or (Test-Path -LiteralPath $DataRoot)) {
        throw 'Cleanup verification failed: a managed VM, network resource, or C: tree remains.'
    }
    Write-Log 'Ubuntu Desktop provisioner cleanup completed with no managed resources remaining.'
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
