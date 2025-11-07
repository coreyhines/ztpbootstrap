# Testing Guide

This document describes the testing infrastructure for the ZTP Bootstrap Service.

## Test Scripts Overview

The repository includes three test scripts, each serving a different purpose:

1. **test-service.sh** - Basic validation of existing service configuration
2. **integration-test.sh** - Comprehensive end-to-end integration testing
3. **ci-test.sh** - Quick validation for CI/CD pipelines

## test-service.sh

**Purpose**: Validates an existing service configuration without modifying anything.

**Usage**:
```bash
sudo /opt/containerdata/ztpbootstrap/test-service.sh
```

**What it tests**:
- Network configuration (IP addresses assigned)
- SSL certificates (if not in HTTP-only mode)
- Container/systemd configuration
- Nginx configuration syntax
- DNS resolution
- Service status and endpoints

**When to use**: After initial setup to verify everything is configured correctly.

## integration-test.sh

**Purpose**: Comprehensive end-to-end testing that creates a test container and validates it works correctly.

**Usage**:
```bash
# Test HTTPS mode (requires SSL certificates)
sudo /opt/containerdata/ztpbootstrap/integration-test.sh

# Test HTTP-only mode
sudo /opt/containerdata/ztpbootstrap/integration-test.sh --http-only

# Keep container running after test (for debugging)
sudo /opt/containerdata/ztpbootstrap/integration-test.sh --no-cleanup
```

**What it tests**:
- ✅ Container starts successfully with podman
- ✅ Health endpoint responds correctly
- ✅ Bootstrap.py endpoint returns 200 OK
- ✅ Response headers are correct (Content-Type, Content-Disposition, Cache-Control)
- ✅ Bootstrap.py content is valid Python
- ✅ Downloaded file matches original file
- ✅ EOS device simulation works
- ✅ Nginx configuration syntax is valid (tested inside container)
- ✅ No errors in container logs

**When to use**: 
- Before deploying to production
- After making changes to nginx.conf or bootstrap.py
- To verify the setup process works end-to-end
- In development to catch issues early

**Features**:
- Automatically detects HTTP-only vs HTTPS mode
- Creates isolated test environment
- Cleans up test resources automatically (unless --no-cleanup is used)
- Provides detailed test results with pass/fail counts

## ci-test.sh

**Purpose**: Quick validation checks suitable for CI/CD pipelines.

**Usage**:
```bash
/opt/containerdata/ztpbootstrap/ci-test.sh
```

**What it tests**:
- ✅ Required files exist
- ✅ File permissions are correct (scripts are executable)
- ✅ Nginx configuration syntax is valid (if nginx available)
- ✅ Bootstrap.py Python syntax is valid
- ✅ Shell script syntax is valid
- ✅ Setup script help works
- ✅ Documentation files exist and are not empty

**When to use**: 
- In CI/CD pipelines before merging PRs
- Quick validation before committing changes
- Automated testing in development workflows

**Features**:
- Fast execution (no container startup)
- Returns exit code 0 on success, non-zero on failure
- Works without root privileges (except for some checks)
- Minimal dependencies

## Test Results

All test scripts provide colored output:
- 🟢 **Green [PASS]**: Test passed
- 🟡 **Yellow [WARN]**: Warning (non-critical issue)
- 🔴 **Red [FAIL/ERROR]**: Test failed (critical issue)

The integration test provides a summary at the end:
```
=========================================
Test Summary
=========================================
Tests Passed: 12
Tests Failed: 0
=========================================
```

## Running Tests in CI/CD

### GitHub Actions Example

```yaml
name: Test ZTP Bootstrap Service

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y podman python3 curl nginx
      
      - name: Run CI tests
        run: |
          chmod +x ci-test.sh
          ./ci-test.sh
      
      - name: Run integration tests (HTTP-only)
        run: |
          chmod +x integration-test.sh
          sudo ./integration-test.sh --http-only
```

### GitLab CI Example

```yaml
test:
  image: fedora:latest
  before_script:
    - dnf install -y podman python3 curl nginx
  script:
    - chmod +x ci-test.sh integration-test.sh
    - ./ci-test.sh
    - sudo ./integration-test.sh --http-only
```

## Manual Testing

You can also manually test the service endpoints:

```bash
# Test health endpoint
curl -k https://ztpboot.example.com/health
# Expected: healthy

# Test bootstrap script endpoint
curl -k https://ztpboot.example.com/bootstrap.py
# Expected: bootstrap.py file content

# Test with EOS-like User-Agent
curl -k -A "Arista-EOS/4.28.0F" https://ztpboot.example.com/bootstrap.py

# Validate Python syntax
curl -k https://ztpboot.example.com/bootstrap.py | python3 -m py_compile -

# Check response headers
curl -k -I https://ztpboot.example.com/bootstrap.py
# Should show: Content-Type: text/plain, Content-Disposition, Cache-Control: no-cache
```

## Troubleshooting Tests

### Integration test fails to start container

- Check podman is installed and working: `podman --version`
- Check nginx image is available: `podman images | grep nginx`
- Check ports 8080/8443 are not in use: `sudo ss -tlnp | grep -E '8080|8443'`

### CI test fails on file permissions

- Make scripts executable: `chmod +x *.sh`

### Integration test fails on SSL certificates

- Use `--http-only` flag if you don't have certificates
- Or ensure certificates exist at `/opt/containerdata/certs/wild/`

### Test shows warnings but passes

- Warnings are non-critical and won't cause test failure
- Review warnings to improve configuration, but service should still work

## Best Practices

1. **Run CI tests before committing**: Quick validation catches syntax errors early
2. **Run integration tests before deploying**: Ensures everything works end-to-end
3. **Run tests after configuration changes**: Validates changes don't break functionality
4. **Use --no-cleanup for debugging**: Keeps test container running to investigate issues
5. **Test both HTTP and HTTPS modes**: Ensures both configurations work

## Adding New Tests

To add new tests:

1. **For integration-test.sh**: Add a new test function and call it in `main()`
2. **For ci-test.sh**: Add a new test function and call it in `main()`
3. **Follow naming convention**: `test_*` for test functions
4. **Use logging functions**: `log()`, `success()`, `error()`, `warn()`
5. **Update counters**: Use `((TESTS_PASSED++))` or `((TESTS_FAILED++))` for integration tests

Example:
```bash
test_new_feature() {
    log "Testing new feature..."
    
    if some_check; then
        success "New feature works correctly"
    else
        error "New feature test failed"
    fi
}
```
