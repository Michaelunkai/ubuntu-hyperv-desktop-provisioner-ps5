# Third-party notices

This repository contains orchestration code only. The provisioner downloads
the official Ubuntu Desktop AMD64 ISO from Canonical's release infrastructure
and verifies its published SHA256 checksum before using it.

The provisioner uses these host components when available or installs the
missing package inside the existing WSL Ubuntu distribution:

- Windows Hyper-V and its PowerShell management module, provided by Microsoft.
- Windows OpenSSH client, provided by Microsoft.
- WSL Ubuntu, provided by Microsoft and Canonical.
- `xorriso`, provided by the Debian/Ubuntu package with its own open-source
  license, to rebuild the ISO while preserving its boot images.

Ubuntu and Hyper-V are trademarks of their respective owners. No third-party
binary is committed to this repository.
