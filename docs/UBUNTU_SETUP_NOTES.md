# Ubuntu Setup Notes

This document captures lessons learned from setting up ztpbootstrap on Ubuntu systems.

## Key Differences from Fedora

### 1. Service File Location
- **Fedora/Standard**: Systemd's quadlet generator creates service files in `/run/systemd/generator/` (tmpfs, temporary)
- **Solution**: Create service files in `/etc/systemd/system/` for permanence across reboots
- **Implementation**: Updated `setup-interactive.sh` to create all service files in `/etc/systemd/system/`

### 2. Pod Service Type
- **Issue**: `Type=notify` doesn't work with `Restart=always` for pod services
- **Error**: Service gets stuck in "activating (start)" state and times out
- **Solution**: Use `Type=forking` for pod services (allows `Restart=always`)
- **Note**: Container services can still use `Type=notify` (they send sdnotify properly)

### 3. Systemd Library Paths
- **Fedora**: Systemd libraries are in `/lib64/libsystemd.so.0` and `/usr/lib64/systemd`
- **Ubuntu**: Systemd libraries are in `/lib/aarch64-linux-gnu/libsystemd.so.0` and `/usr/lib/aarch64-linux-gnu/systemd`
- **Issue**: Container file has Fedora-specific paths that don't exist on Ubuntu, causing podman errors
- **Solution**: 
  - Detect distribution in `setup-interactive.sh`
  - Filter out Fedora-specific volume mounts on non-Fedora systems
  - Only include volume mounts if the source path exists

### 4. Volume Mount Filtering
- **Implementation**: When creating service files, check if source paths exist before including them
- **Special paths**: Always include `/run/*` and `/opt/*` paths (they're created at runtime)
- **Other paths**: Verify existence before including in volume mounts

## Implementation Details

### Distribution Detection
```bash
local distro=""
if [[ -f /etc/os-release ]]; then
    distro=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
fi
```

### Volume Mount Filtering
```bash
# Skip Fedora-specific paths on non-Fedora systems
if [[ "$distro" != "fedora" ]] && [[ "$distro" != "rhel" ]] && [[ "$distro" != "centos" ]]; then
    if [[ "$source_path" =~ ^/lib64/libsystemd ]] || [[ "$source_path" == "/usr/lib64/systemd" ]]; then
        continue
    fi
fi

# Only include if path exists (or is special path)
if [[ "$source_path" =~ ^/run ]] || [[ "$source_path" =~ ^/opt ]] || [[ -e "$source_path" ]]; then
    volumes="${volumes} -v ${volume_path}"
fi
```

## Service File Creation

### Pod Service
- **Type**: `forking` (not `notify` or `oneshot`)
- **Location**: `/etc/systemd/system/ztpbootstrap-pod.service`
- **Allows**: `Restart=always`

### Container Services (nginx, webui)
- **Type**: `notify` (works fine for containers)
- **Location**: `/etc/systemd/system/ztpbootstrap-{nginx,webui}.service`
- **Volumes**: Dynamically extracted from container files with filtering

## Testing Checklist

When testing on Ubuntu:
1. ✅ Pod service starts and remains active (not stuck in activating)
2. ✅ Nginx container starts and joins the pod
3. ✅ WebUI container starts and joins the pod
4. ✅ No errors about missing `/lib64/libsystemd.so.0` or `/usr/lib64/systemd`
5. ✅ All service files persist in `/etc/systemd/system/`
6. ✅ Services survive reboot

## Files Modified

- `setup-interactive.sh`:
  - Service file creation now uses `/etc/systemd/system/`
  - Pod service uses `Type=forking`
  - Volume mount extraction filters Fedora-specific paths
  - Distribution detection for conditional volume mounts

## Future Improvements

- Consider making systemd library paths configurable or auto-detected
- Add Ubuntu-specific container file variant if needed
- Document distribution-specific requirements in main README

