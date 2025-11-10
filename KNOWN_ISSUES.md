# Known Issues and Workarounds

## Ubuntu Support

**Ubuntu 22.04 (and potentially other Ubuntu versions) has known issues with SSH key deployment via cloud-init in this environment.** 

The cloud-init `ssh_authorized_keys` mechanism and `write_files + runcmd` approaches both fail to deploy SSH keys correctly, resulting in SSH authentication failures. This appears to be related to how Ubuntu cloud images handle cloud-init user-data processing.

**Status:** Ubuntu is not fully supported. If you need to use Ubuntu, you may need to manually configure SSH access or work around cloud-init limitations.

**Recommended:** Use Fedora 43 or later, which has been fully tested and works correctly.

---

## SELinux Context Flags (`:z` and `:Z`) - NOT USED

**IMPORTANT:** We do NOT use SELinux context flags (`:z` or `:Z`) in Podman volume mounts because:
- These flags do NOT work with NFS shares
- Many users (including the maintainer) deploy this service on NFS-mounted NAS shares
- SELinux contexts are set via `chcon` on the host directories instead

**How we handle SELinux:**
- We use `chcon -R -t container_file_t` to set SELinux contexts on host directories
- This works with both local filesystems and NFS shares
- Volume mounts in quadlet files use only `:ro` (read-only) or `:rw` (read-write) flags

**Files affected:**
- `systemd/ztpbootstrap-nginx.container` - No `:z` or `:Z` flags
- `systemd/ztpbootstrap-webui.container` - No `:z` or `:Z` flags
- `setup.sh` - Uses `chcon` instead of volume mount flags

This document tracks known issues, their workarounds, and planned fixes.

## Minor Issues

### 1. Cloud-init Deprecation Warnings

**Issue:** Cloud-init reports deprecated configuration keys in `vm-create-native.sh`:
- `chpasswd.list` deprecated in 22.2 (use `users` instead)
- `system_info` deprecated in 24.2
- Config key 'lists' deprecated in 22.3

**Impact:** Non-critical - cloud-init completes successfully but shows warnings

**Workaround:** None required - service works correctly

**Planned Fix:** Update `vm-create-native.sh` cloud-init configuration to use modern syntax

**Status:** Documented for future improvement

---

### 2. README_VM_SETUP.txt Missing

**Issue:** Expected file `/home/fedora/README_VM_SETUP.txt` not created by cloud-init

**Impact:** Low - documentation file, not required for functionality

**Workaround:** None required

**Planned Fix:** Verify if this file should be created by cloud-init and add if needed

**Status:** Documented for investigation

---

### 3. Cloud-init Status Shows "Degraded"

**Issue:** Cloud-init extended status shows `degraded done` instead of just `done`

**Impact:** Non-critical - cloud-init completed successfully, likely due to deprecation warnings

**Workaround:** None required - service works correctly

**Planned Fix:** Resolve deprecation warnings (see Issue #1)

**Status:** Documented for future improvement

---

### 4. Interactive Setup Script Piped Input

**Issue:** Yes/no prompts (`prompt_yes_no` function) do not handle piped input correctly. Script gets stuck in loop asking "Please answer yes or no." even when valid input is provided.

**Impact:** Cannot fully automate testing of interactive script with piped input

**Workaround:** 
- Test manually by running `./setup-interactive.sh` interactively
- Use `expect` script for automation if needed
- Use `config.yaml` directly and skip interactive setup for automated deployments

**Planned Fix:** 
- Consider creating a non-interactive mode for CI/CD
- Or use `expect` script for automated testing

**Status:** Documented - limitation of interactive script design

---

### 5. SSH Key Setup Not Automated

**Issue:** SSH key setup (ssh-copy-id) is not automated in cloud-init, requiring manual step

**Impact:** Low - manual step required after VM creation

**Workaround:** Manually run `ssh-copy-id` after VM is created

**Planned Fix:** Add SSH key setup to cloud-init configuration in `vm-create-native.sh`

**Status:** Enhancement for future improvement

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

## Testing Notes

- **VM Creation:** Works correctly on ARM64 macOS with Fedora 43 Cloud images
- **x86_64 Testing:** Skipped on ARM64 macOS (would require emulation, slow)
- **Fresh Setup:** All fixes verified to work correctly in fresh VM deployment
