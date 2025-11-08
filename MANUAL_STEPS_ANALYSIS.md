# Manual Steps Analysis and Automation

This document tracks manual steps that were required during testing and how they've been automated in the setup workflow.

## Manual Steps Identified

### 1. ✅ FIXED - Logs Directory Creation

**Manual Step:**
```bash
sudo mkdir -p /opt/containerdata/ztpbootstrap/logs
sudo chmod 777 /opt/containerdata/ztpbootstrap/logs
sudo chown 101:101 /opt/containerdata/ztpbootstrap/logs
```

**Issue:** Logs directory was only created in `create_self_signed_cert()`, which only runs when certificates are missing. If certificates already exist, the logs directory wasn't created, causing nginx container to fail.

**Fix Applied:**
- Created new `setup_logs_directory()` function in `setup.sh`
- Called `setup_logs_directory()` in `main()` function **before** certificate checks
- Ensures logs directory is always created with correct permissions

**Status:** ✅ FIXED - Now runs automatically in `setup.sh`

---

### 2. ✅ FIXED - SELinux Context for Logs Directory

**Manual Step:**
```bash
sudo chcon -R -t container_file_t /opt/containerdata/ztpbootstrap/logs
```

**Issue:** SELinux context was set for `$SCRIPT_DIR` but not specifically for the logs subdirectory. Nginx container couldn't write to logs due to SELinux restrictions.

**Fix Applied:**
- Added SELinux context setting specifically for logs directory in `setup_logs_directory()`
- Checks if SELinux is enabled before attempting to set context
- Uses `container_file_t` context which works with NFS mounts

**Status:** ✅ FIXED - Now runs automatically in `setup.sh`

---

### 3. ✅ FIXED - Container Startup Order

**Manual Step:**
```bash
sudo systemctl start ztpbootstrap-pod.service
sleep 2
sudo systemctl start ztpbootstrap-nginx.service
sleep 5
sudo systemctl start ztpbootstrap-webui.service
```

**Issue:** `start_service()` only started the pod, not the individual containers. Containers needed to be started manually in the correct order.

**Fix Applied:**
- Updated `start_service()` in `setup.sh` to:
  1. Start the pod
  2. Wait for pod to be ready
  3. Start nginx container
  4. Wait for nginx to be ready
  5. Start webui container (if service exists)
- Added proper error handling and logging for each step

**Status:** ✅ FIXED - All containers now start automatically in correct order

---

### 4. ✅ FIXED - Systemd Daemon Reload Timing

**Manual Step:**
```bash
sudo systemctl daemon-reload
```

**Issue:** After copying container files, systemd needed to be reloaded to recognize new services. Sometimes webui service wasn't recognized immediately.

**Fix Applied:**
- Added `sleep 1` after `systemctl daemon-reload` to give systemd time to process
- Added check for webui service existence before attempting to start it
- Added logging to indicate when services are recognized

**Status:** ✅ FIXED - Proper timing and checks in place

---

### 5. 🔄 IN PROGRESS - SSH Key Setup

**Manual Step:**
```bash
ssh-keygen -R "[127.0.0.1]:2222"
expect << 'EOF'
spawn ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 fedora@127.0.0.1
expect "password:" { send "fedora\r" }
EOF
```

**Issue:** SSH key-based authentication requires manual setup after VM creation. Users have to manually run `ssh-copy-id` or use expect scripts.

**Fix Applied:**
- Added logic to copy host SSH public key to cloud-init ISO
- Added cloud-init runcmd to add SSH key to `authorized_keys` from mounted ISO
- Checks for `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`
- Includes key in cloud-init ISO if found

**Status:** 🔄 IN PROGRESS - Code added, needs testing

**Note:** This is optional - password authentication still works. SSH key setup is a convenience feature.

---

### 6. ⚠️ PARTIALLY ADDRESSED - Config File Creation

**Manual Step:**
```bash
cat > config.yaml << 'EOF'
# ... full config ...
EOF
```

**Issue:** In fresh VM, `config.yaml` doesn't exist. User needs to either:
- Run `setup-interactive.sh` to create it
- Manually create it

**Current State:**
- `setup-interactive.sh` creates `config.yaml` interactively
- Cloud-init can auto-run `setup-interactive.sh` with `--auto-setup` flag
- But if auto-setup is disabled, user must manually create config

**Status:** ⚠️ PARTIALLY ADDRESSED - Works with `--auto-setup`, but manual creation still required if disabled

**Recommendation:** Consider creating a default `config.yaml` template that works out-of-the-box for basic setups.

---

## Summary of Fixes

| Manual Step | Status | Location | Impact |
|------------|--------|----------|--------|
| Logs directory creation | ✅ FIXED | `setup.sh` → `setup_logs_directory()` | Critical - nginx container fails without it |
| SELinux context for logs | ✅ FIXED | `setup.sh` → `setup_logs_directory()` | Critical - nginx can't write logs without it |
| Container startup order | ✅ FIXED | `setup.sh` → `start_service()` | Important - containers don't start automatically |
| Systemd daemon reload | ✅ FIXED | `setup.sh` → `start_service()` | Important - services not recognized |
| SSH key setup | 🔄 IN PROGRESS | `vm-create-native.sh` → cloud-init | Nice-to-have - convenience feature |
| Config file creation | ⚠️ PARTIAL | `setup-interactive.sh` | Works with auto-setup, manual otherwise |

---

## Remaining Manual Steps (Low Priority)

### 1. WebUI Service Recognition

**Issue:** Sometimes webui service isn't immediately recognized by systemd after copying files.

**Current Fix:** Added `sleep 1` after daemon-reload and check for service existence before starting.

**Status:** ✅ ADDRESSED - Should work now, but may need further testing

---

### 2. Container Health Checks

**Issue:** Containers may need a moment to become healthy before they're fully ready.

**Current Fix:** Added `sleep 2` after starting each container.

**Status:** ✅ ADDRESSED - Timing delays added

---

## Testing Recommendations

1. **Fresh VM Test:** Create a fresh VM and verify all containers start automatically without manual intervention
2. **SSH Key Test:** Verify SSH key is automatically added when creating VM
3. **Logs Directory Test:** Verify logs directory is created even when certificates already exist
4. **SELinux Test:** Test on system with SELinux enabled to verify context is set correctly

---

## User Experience Improvements

### Before Fixes:
1. Create VM
2. SSH to VM (password required)
3. Manually create logs directory
4. Manually set SELinux context
5. Run `setup.sh`
6. Manually start pod
7. Manually start nginx container
8. Manually start webui container

### After Fixes:
1. Create VM (SSH key automatically added if available)
2. SSH to VM (key-based or password)
3. Run `setup.sh` (everything happens automatically)
4. ✅ Done - all containers running

**Result:** Reduced from 8 steps to 3 steps, with most steps automated.

