# Known Issues and Workarounds

This document tracks known issues, their workarounds, and planned fixes.

## Important Implementation Notes

### Ubuntu Support

**Ubuntu 24.04+ is fully supported and tested.** ✅

**Ubuntu 22.04** has known issues with SSH key deployment via cloud-init in VM creation workflows. The cloud-init `ssh_authorized_keys` mechanism and `write_files + runcmd` approaches both fail to deploy SSH keys correctly, resulting in SSH authentication failures. This appears to be related to how Ubuntu 22.04 cloud images handle cloud-init user-data processing.

**Status:** 
- ✅ Ubuntu 24.04+ - Fully supported and tested
- ⚠️ Ubuntu 22.04 - May require manual SSH configuration in VM workflows

**Recommended:** Use Ubuntu 24.04+ or Fedora 43+ for best compatibility.

---

### SELinux Context Flags (`:z` and `:Z`) - Conditionally Used

**IMPORTANT:** We conditionally use SELinux context flags (`:z`) in Podman volume mounts:
- `:z` flags do NOT work with NFS shares
- Many users (including the maintainer) deploy this service on NFS-mounted NAS shares
- We automatically detect NFS mounts and skip `:z` flags when on NFS

**How we handle SELinux:**
- We detect if directories are on NFS using `stat -f` or `findmnt`
- For local filesystems: We use `:z` flags in volume mounts AND `chcon` for host directories
- For NFS filesystems: We skip `:z` flags and rely on `chcon` only (which works with NFS)
- This ensures compatibility with both local and NFS deployments

**Files affected:**
- `systemd/ztpbootstrap-nginx.container` - Conditionally adds `:z` flag (not on NFS)
- `systemd/ztpbootstrap-webui.container` - Conditionally adds `:z` flag (not on NFS)
- `setup.sh` - Uses `is_nfs_mount()` to detect NFS and conditionally apply `:z` flags
- `setup-interactive.sh` - Same NFS detection logic

---

## Known Issues

Active issues are tracked in [GitHub Issues](https://github.com/coreyhines/ztpbootstrap/issues). See the issues list for current known issues and their status.

---

## Resolved Issues

### ✅ Fixed: Missing Logs Directory in setup.sh

**Issue:** `/opt/containerdata/ztpbootstrap/logs` directory not created by `setup.sh`

**Fix:** Added `mkdir -p "${SCRIPT_DIR}/logs"` with proper permission setup in `setup.sh`

**Status:** ✅ FIXED and verified in fresh setup

---

### ✅ Fixed: Logs Directory Permissions

**Issue:** Nginx container failed with: `open() "/var/log/nginx/error.log" failed (13: Permission denied)`

**Fix:** Added `chown 101:101` and `chmod 777` to logs directory creation in `setup.sh`

**Status:** ✅ FIXED and verified in fresh setup

---

### ✅ Fixed: Interactive Setup Script Piped Input

**Issue:** Yes/no prompts did not handle piped input correctly, preventing automation

**Fix:** Added `--non-interactive` mode to `setup-interactive.sh` for automated deployments and CI/CD

**Status:** ✅ FIXED - Use `./setup-interactive.sh --non-interactive` for automation

---

### ✅ Fixed: SSH Key Setup Not Automated

**Issue:** SSH key setup was not automated in cloud-init, requiring manual step

**Fix:** `vm-create-native.sh` now automatically detects the current user and sets up SSH key authentication

**Status:** ✅ FIXED - SSH keys are automatically configured for the current user

---

## Testing Notes

- **VM Creation:** Works correctly on ARM64 macOS with Fedora 43 Cloud images
- **x86_64 Testing:** Skipped on ARM64 macOS (would require emulation, slow)
- **Fresh Setup:** All fixes verified to work correctly in fresh VM deployment
