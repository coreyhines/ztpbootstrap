# CI/CD Testing Strategy and Test Matrix

This document outlines the CI/CD testing strategy for the ZTP Bootstrap Service.

## Testing Philosophy

1. **Fast Feedback:** Quick syntax and validation checks
2. **Comprehensive Coverage:** Full integration tests when possible
3. **Portability:** Test across architectures and OS versions
4. **Practical Constraints:** Balance thoroughness with CI resource limits

## Test Matrix

### Architecture Testing

| Architecture | Host | Status | Notes |
|-------------|------|--------|-------|
| ARM64 (aarch64) | macOS (Apple Silicon) | ✅ Tested | Native performance |
| ARM64 (aarch64) | Linux | ⚠️ Not tested | Should work identically |
| x86_64 (amd64) | Linux | ⚠️ Not tested | Requires x86_64 host |
| x86_64 (amd64) | macOS (Apple Silicon) | ❌ Not recommended | Slow emulation |

### Operating System Testing

| OS | Version | Architecture | Status | Notes |
|----|---------|-------------|--------|-------|
| Fedora | 43 | ARM64 | ✅ Tested | Latest, fully working |
| Fedora | 42 | ARM64 | ⚠️ Not tested | Should work |
| Fedora | 41 | ARM64 | ⚠️ Not tested | Should work |
| Fedora | 40 | ARM64 | ⚠️ Not tested | May work |
| Fedora | <40 | ARM64 | ❌ Not recommended | May lack quadlet support |

### Configuration Testing

| Configuration | Status | Notes |
|--------------|--------|-------|
| Host Networking | ✅ Tested | Works correctly |
| Macvlan Networking | ⚠️ Not tested | Should work, requires network setup |
| HTTP-only Mode | ✅ Tested | Works correctly |
| HTTPS Mode | ⚠️ Not tested | Requires SSL certificates |
| IPv4 Only | ✅ Tested | Works correctly |
| IPv6 Only | ⚠️ Not tested | Should work |
| Dual Stack (IPv4+IPv6) | ⚠️ Not tested | Should work |

## CI Pipeline Strategy

### Level 1: Fast Validation (Always Run)

**Purpose:** Catch syntax errors and basic issues immediately

**Tests:**
- ✅ Script syntax validation (`bash -n`)
- ✅ Python syntax validation
- ✅ YAML syntax validation
- ✅ File permissions checks
- ✅ Required files existence

**Tools:**
- `ci-test.sh` (existing)
- ShellCheck (if available)
- yamllint (if available)

**Runtime:** < 30 seconds
**Resources:** Minimal (no containers, no VMs)

**Status:** ✅ Implemented

---

### Level 2: Integration Testing (On PR/Merge)

**Purpose:** Verify service works end-to-end

**Tests:**
- ✅ Container startup
- ✅ Health endpoint
- ✅ Bootstrap script endpoint
- ✅ Response headers
- ✅ WebUI endpoints
- ✅ API endpoints

**Tools:**
- `integration-test.sh` (existing)
- Podman
- curl

**Runtime:** 2-5 minutes
**Resources:** Requires Podman, can run in containers

**Status:** ✅ Implemented (HTTP-only mode)

**Limitations:**
- Requires Podman installed
- May require root/sudo for some operations
- Best run on Linux runners

---

### Level 3: VM-Based Testing (Manual/Periodic)

**Purpose:** Full fresh setup verification

**Tests:**
- ✅ VM creation
- ✅ Cloud-init completion
- ✅ Full setup workflow
- ✅ All functionality verification

**Tools:**
- `vm-create-native.sh`
- QEMU
- Full VM environment

**Runtime:** 10-30 minutes
**Resources:** Requires QEMU, significant resources

**Status:** ⚠️ Manual testing only

**Challenges:**
- Requires nested virtualization or bare metal
- Slow execution
- Resource intensive
- Difficult to automate in standard CI

**Recommendation:**
- Run manually before releases
- Use self-hosted runners with VM support
- Or use cloud VMs (AWS, GCP, etc.) for testing

---

## CI Platform Recommendations

### GitHub Actions

**Pros:**
- Widely used
- Good integration
- Free for public repos

**Cons:**
- Limited nested virtualization
- macOS runners expensive
- Linux runners may not support QEMU

**Strategy:**
- Level 1: ✅ Run on all platforms
- Level 2: ✅ Run on Linux runners (Podman available)
- Level 3: ⚠️ Manual or self-hosted runners

**Example Workflow:**
```yaml
name: Test ZTP Bootstrap

on: [push, pull_request]

jobs:
  fast-validation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run CI tests
        run: ./ci-test.sh

  integration-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Podman
        run: |
          sudo apt-get update
          sudo apt-get install -y podman
      - name: Run integration tests
        run: sudo ./integration-test.sh --http-only
```

---

### GitLab CI

**Pros:**
- Good Docker/Podman support
- Self-hosted runners easy
- Can use Docker-in-Docker

**Cons:**
- Requires GitLab instance
- Self-hosted runners need setup

**Strategy:**
- Level 1: ✅ Run on shared runners
- Level 2: ✅ Run on shared runners (Podman available)
- Level 3: ⚠️ Self-hosted runners with VM support

**Example Pipeline:**
```yaml
test:
  image: fedora:latest
  before_script:
    - dnf install -y podman python3 curl
  script:
    - ./ci-test.sh
    - sudo ./integration-test.sh --http-only
```

---

### Self-Hosted Runners

**Pros:**
- Full control
- Can enable nested virtualization
- Can test VM creation
- Can test multiple architectures

**Cons:**
- Requires infrastructure
- Maintenance overhead
- Security considerations

**Strategy:**
- All levels: ✅ Can run everything
- Best for Level 3 (VM-based testing)

**Recommendation:**
- Use for comprehensive testing
- Run before releases
- Test multiple architectures

---

## Test Execution Strategy

### Pre-Commit (Local)

**Run:**
- Level 1: Fast validation
- Optional: Level 2 integration tests

**Tools:**
- Pre-commit hooks (if configured)
- Manual `./ci-test.sh`

---

### Pull Request

**Run:**
- Level 1: Fast validation (required)
- Level 2: Integration tests (required)

**Tools:**
- CI pipeline
- `ci-test.sh` and `integration-test.sh`

---

### Merge to Main

**Run:**
- Level 1: Fast validation
- Level 2: Integration tests
- Optional: Level 3 VM testing (if resources available)

**Tools:**
- CI pipeline
- Manual VM testing if needed

---

### Release

**Run:**
- Level 1: Fast validation
- Level 2: Integration tests
- Level 3: Full VM-based testing (recommended)

**Tools:**
- All test scripts
- Manual verification
- Fresh VM setup testing

---

## Current Implementation Status

### ✅ Implemented

- `ci-test.sh` - Fast validation tests
- `integration-test.sh` - Integration tests
- `test-service.sh` - Service validation
- Manual VM testing procedures

### ⚠️ Partially Implemented

- Automated CI pipeline (basic structure exists, needs enhancement)
- VM-based automated testing (manual only)

### ❌ Not Implemented

- Automated cross-architecture testing
- Automated multi-version testing
- Automated configuration matrix testing

---

## Recommendations

1. **Immediate:**
   - ✅ Use existing `ci-test.sh` in CI pipelines
   - ✅ Use existing `integration-test.sh` in CI pipelines
   - ✅ Run Level 1 and Level 2 tests on every PR

2. **Short-term:**
   - Enhance CI pipelines with better error reporting
   - Add more validation checks to `ci-test.sh`
   - Document CI setup procedures

3. **Long-term:**
   - Set up self-hosted runners for VM testing
   - Automate cross-architecture testing
   - Create test matrix automation
   - Add performance benchmarking

---

## Test Coverage Goals

### Current Coverage

- ✅ Script syntax and structure
- ✅ Basic service functionality
- ✅ HTTP-only mode
- ✅ Host networking
- ✅ ARM64 architecture
- ✅ Fedora 43

### Target Coverage

- ⚠️ HTTPS mode
- ⚠️ Macvlan networking
- ⚠️ x86_64 architecture
- ⚠️ Multiple Fedora versions
- ⚠️ IPv6 configurations
- ⚠️ Error scenarios

---

## Notes

- **VM Testing:** Best done manually or on self-hosted runners
- **Container Testing:** Can be automated in standard CI
- **Architecture Testing:** Requires appropriate host or emulation
- **Performance Testing:** Requires consistent environment

