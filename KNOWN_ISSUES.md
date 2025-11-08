# Known Issues and Workarounds

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

