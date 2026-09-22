# Ubuntu Hyper-V Desktop Provisioner for PowerShell 5.1

An idempotent, fully unattended Ubuntu Desktop installer for Windows
PowerShell 5.1 and Hyper-V.

The entry point is
[Install-UbuntuHyperVDesktop.ps1](./Install-UbuntuHyperVDesktop.ps1). The
project is intentionally separate from the Ubuntu Server cloud-image
provisioner: it downloads the official Ubuntu Desktop ISO and installs the
desktop source (`ubuntu-desktop`) rather than a Server image.

## Result

One elevated Windows PowerShell 5.1 command produces a usable Generation 2
Hyper-V guest:

- the newest numbered Ubuntu Desktop AMD64 ISO from Canonical;
- SHA256 verification against Canonical's `SHA256SUMS` file;
- a rebuilt bootable ISO with a local NoCloud autoinstall seed;
- no installer keyboard or mouse interaction;
- Ubuntu Desktop with GNOME and GDM3;
- the exact requested credentials `ubuntu` / `ubuntu`;
- graphical automatic login as `ubuntu` after every boot;
- GNOME first-run and release-upgrade onboarding completed automatically;
- SSH, Git, build tools, and common utilities;
- Secure Boot enabled and a dynamically expanding VHDX;
- an existing Hyper-V switch reused, or an internal NAT switch created;
- VMConnect opened only after SSH, cloud-init, GDM3, graphical.target, the
automatic-login configuration, the active graphical session, the GNOME
completion markers, and the absence of the first-run onboarding process have
been verified.

The autoinstall deliberately powers the VM off after the OS installation. The
host then removes the installer ISO from the boot path, boots the installed
VHDX, verifies the real guest, and opens VMConnect. This prevents a reboot from
accidentally starting the installer a second time.

## Run it

Open Windows PowerShell 5.1 as Administrator and run:

    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "F:\study\Operating_Systems\Windows\Administration\Virtualization\Hyper-V\Ubuntu\Provisioning\PowerShell5\UbuntuHyperVDesktopProvisioner\Install-UbuntuHyperVDesktop.ps1"

Useful optional examples:

    # Pin the current Ubuntu 26.04 release family.
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Install-UbuntuHyperVDesktop.ps1" -UbuntuRelease 26.04

    # Choose a different managed VM name and size.
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Install-UbuntuHyperVDesktop.ps1" -VMName Ubuntu-Desktop-Lab -MemoryGB 12 -CpuCount 6 -DiskGB 120

The first run downloads roughly 6 GB and needs free space for the ISO, the
rebuilt ISO, the dynamic VHDX, and temporary WSL package data. If `xorriso` is
not already installed in the first WSL distribution, the script installs it
automatically. If Windows needs to reboot while enabling Hyper-V or OpenSSH,
the script registers a one-time resume task and continues at the next logon.

## Credentials and automatic login

The project intentionally fixes the guest credentials at:

    username: ubuntu
    password: ubuntu

The generated autoinstall data creates the account, enables password SSH, and
configures `/etc/gdm3/custom.conf` with `AutomaticLoginEnable=true` and
`AutomaticLogin=ubuntu`. The guest readiness check reads those settings from
the running VM and confirms the `ubuntu` user has an active login session.

This is a convenience lab image, not a secure production template. Do not
attach it to an untrusted network without changing the credentials and
removing automatic login.

## Repeatability and safety

State, the verified ISO cache, the generated SSH key, the custom ISO, and the
managed VM live under:

    C:\ProgramData\Ubuntu-HyperV-Desktop-Provisioner

Later runs reuse a checksum-matching ISO, a matching autoinstall ISO, the
existing switch, and a ready managed VM. A managed VM is rebuilt only when its
release or provisioning inputs change. An unrelated VM with the same name is
never removed unless `-ForceRecreate` is supplied.

The default switch selection is conservative: an existing named switch is
reused first, then Hyper-V's Default Switch, then an external switch, and only
then a new internal NAT switch is created. Internal NAT uses a deterministic
static guest address because Windows NetNat does not provide DHCP.

## Remove the managed deployment

To stop and remove the GUI VM and reclaim the deployment's C: storage, run the
companion cleanup script from elevated Windows PowerShell 5.1:

    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "F:\study\Operating_Systems\Windows\Administration\Virtualization\Hyper-V\Ubuntu\Provisioning\PowerShell5\UbuntuHyperVDesktopProvisioner\Remove-UbuntuHyperVDesktop.ps1"

The cleanup is deliberately scoped to this project's exact managed VM,
VHDX/ISO/state root, seed-test directory, NAT switch, NAT object, resume task,
and the `xorriso` WSL transaction installed by the provisioner. It verifies
that those resources are gone and leaves the WSL distribution itself intact.

## Validation

The parser/static test does not enable features, download an ISO, create a VM,
or modify Hyper-V:

    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-PowerShell5.ps1"

The end-to-end run itself is the final integration test. It verifies the
Ubuntu release, cloud-init completion, SSH, network, GDM3, graphical target,
automatic-login configuration, and an active `ubuntu` session. The script
opens VMConnect only after those checks succeed.

## Official sources

- [Ubuntu releases](https://releases.ubuntu.com/)
- [Ubuntu 26.04 release files](https://releases.ubuntu.com/26.04/)
- [Canonical autoinstall introduction](https://canonical-subiquity.readthedocs-hosted.com/en/latest/intro-to-autoinstall.html)
- [Canonical autoinstall quick start](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html)

## License

MIT. See [LICENSE](./LICENSE).
