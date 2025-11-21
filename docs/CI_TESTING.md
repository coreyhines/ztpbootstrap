# CI Testing and Pre-Commit Checks

This document describes what tests run during CI and which ones you can run locally before committing.

**TL;DR for Pre-Commit**: Run `make check` - it's fast (~30 seconds) and doesn't require a running service. It includes linting, syntax checks, and security validation.

## CI Tests (Run on Every PR)

### 1. Security Checks
- **Gitleaks** - Secret detection in git history
- **TruffleHog** - Secret detection in PR diff
- **Cannot run locally** - Requires GitHub Actions secrets

### 2. Dependency Scanning
- **OWASP Dependency-Check** - Scans for known vulnerabilities
- **Can run locally** - Requires Docker/Java setup (complex)
- **Recommendation**: Run `make test-ci` instead (faster validation)

### 3. SBOM Generation
- **Syft** - Generates Software Bill of Materials
- **Can run locally** - `syft . -o cyclonedx-json > sbom.cyclonedx.json`
- **Not critical for pre-commit** - Mainly for compliance

### 4. Lint Job
Runs the following checks:

#### Container Security Checks
- **Container log access security** - Validates podman socket and systemd journal mounts follow security best practices
- **Run locally**: `make security-check` or `./dev/scripts/security-check-container-access.sh`
- **Pre-commit**: Included in `make check`

#### Shell Script Linting
- **shellcheck** on all `*.sh` files (root and `dev/scripts/`, `dev/tests/`)
- **Run locally**: `make lint` or `shellcheck -S error *.sh dev/scripts/*.sh dev/tests/*.sh`
- **Pre-commit**: Already configured (auto-runs on commit)

#### YAML Linting
- **yamllint** on all `*.yaml`, `*.yml`, and `config.yaml.template`
- **Run locally**: `make lint` or `yamllint *.yaml *.yml config.yaml.template dev/tests/*.yaml`
- **Pre-commit**: Already configured (auto-runs on commit)

#### Python Formatting
- **black --check** on `bootstrap.py`
- **Run locally**: `black --check bootstrap.py` or `make format` (auto-formats)
- **Pre-commit**: Already configured (auto-formats on commit)

#### Python Import Sorting
- **isort --check-only** on `bootstrap.py`
- **Run locally**: `isort --check-only bootstrap.py` or `isort bootstrap.py` (auto-fixes)
- **Pre-commit**: Already configured (auto-fixes on commit)

### 5. Test Job
Runs the following tests:

#### CI Validation Tests (`dev/tests/ci-test.sh`)
Checks:
- Required files exist
- Scripts are executable
- Nginx configuration syntax
- Python syntax (`bootstrap.py`)
- Shell script syntax
- Documentation files exist
- Systemd files exist

**Run locally**: `make test-ci` or `./dev/tests/ci-test.sh`

#### Integration Tests (`dev/tests/integration-test.sh`)
- Creates test container
- Tests health endpoint
- Tests bootstrap.py endpoint
- Validates file content
- Tests EOS device simulation

**Run locally**: `make test-integration-dev` or `./dev/tests/integration-test.sh --http-only`
**Note**: Requires Podman and root/sudo access

## Recommended Pre-Commit Checks

Run these before committing to avoid CI failures:

### Quick Check (Fast - ~10 seconds) ⭐ **Recommended for Pre-Commit**
```bash
make check         # lint + test-quick + test-ci (no running services required)
# OR individually:
make lint          # shellcheck + yamllint
make format        # black + isort (auto-fixes)
make test-ci       # File existence, syntax checks
make test-quick    # BATS unit tests (no running services)
```

**Note**: `make check` now only runs quick tests that don't require a running service. Perfect for pre-commit!

### Full Check (Slower - ~1-2 minutes, requires running service)
```bash
make lint          # shellcheck + yamllint
make format        # black + isort (auto-fixes)
make test-ci       # CI validation tests
make test-quick    # BATS unit tests
make test-integration  # BATS integration tests (requires running service)
```

### Complete Check (Slowest - ~5-10 minutes, requires Podman + running service)
```bash
make lint          # shellcheck + yamllint
make format        # black + isort (auto-fixes)
make test-ci       # CI validation tests
make test-all      # All BATS tests (unit + integration)
make test-integration-dev  # Container-based integration test (creates containers)
```

**Important**: Integration tests (`test-integration`, `test-integration-dev`) require:
- A running service (or will create containers)
- Podman installed and running
- Root/sudo access
- Full environment setup

These are **NOT suitable for pre-commit** and should only run in CI or when manually testing.

## Pre-Commit Hook Setup (Optional)

The repository includes a `.pre-commit-config.yaml` file for optional git hooks. However, **`make check` is the recommended way to validate code before committing** as it's more reliable and doesn't require complex Python environments.

### If You Want to Use Pre-Commit Hooks

```bash
# Install pre-commit
pip3 install pre-commit
# OR if you prefer user install (adds to ~/.local/bin):
pip3 install --user pre-commit

# Install git hooks (use python3 -m if binary not in PATH)
python3 -m pre_commit install
# OR if binary is in PATH:
pre-commit install

# Test hooks manually
python3 -m pre_commit run --all-files
# OR if binary is in PATH:
pre-commit run --all-files
```

**Note**: 
- If `pre-commit` command is not found after installation, use `python3 -m pre_commit` instead.
- If you encounter Python/pip environment errors with pre-commit, **just use `make check` instead** - it's faster and more reliable.
- Pre-commit hooks are optional - CI will catch any issues if hooks fail or aren't installed.

### What Pre-Commit Hooks Run

The following hooks run automatically on `git commit`:

1. **shellcheck** - Shell script linting (fails on errors)
2. **yamllint** - YAML linting
3. **black** - Python formatting (auto-fixes)
4. **isort** - Python import sorting (auto-fixes)
5. **trailing-whitespace** - Removes trailing whitespace
6. **end-of-file-fixer** - Ensures files end with newline
7. **check-yaml** - Validates YAML syntax
8. **check-added-large-files** - Warns on files >1MB
9. **check-merge-conflict** - Detects merge conflict markers
10. **check-executables-have-shebangs** - Ensures scripts have shebangs

## Makefile Targets Summary

| Target | What It Does | Time | Requires Service? | Can Fail CI? |
|--------|--------------|------|-------------------|--------------|
| `make lint` | shellcheck + yamllint | ~5s | ❌ No | ✅ Yes |
| `make format` | black + isort (auto-fix) | ~2s | ❌ No | ✅ Yes |
| `make test-quick` | BATS unit tests only | ~10s | ❌ No | ⚠️ Maybe* |
| `make test-ci` | CI validation tests | ~10s | ❌ No | ✅ Yes |
| `make check` | lint + test-quick + test-ci + security-check | ~30s | ❌ No | ✅ Yes |
| `make security-check` | Container access security validation | ~2s | ❌ No | ✅ Yes |
| `make test-integration` | BATS integration tests | ~30s | ✅ Yes | ⚠️ Maybe* |
| `make test-all` | All BATS tests | ~40s | ✅ Yes | ⚠️ Maybe* |
| `make test-integration-dev` | Container integration test | ~2min | ✅ Yes (creates) | ✅ Yes |

**Pre-Commit Recommendation**: Use `make check` - it runs all quick checks without requiring a running service.

*BATS tests may not run in CI if bats is not installed, but they should pass if they run.

## CI vs Local Differences

### What CI Does That's Hard to Replicate Locally
- Secret detection (Gitleaks, TruffleHog) - requires GitHub token
- Dependency scanning - requires Java/Docker setup
- SBOM generation - not critical for code quality

### What You Should Always Run Locally
- ✅ `make lint` - Catches syntax and style issues
- ✅ `make format` - Ensures code is formatted
- ✅ `make test-ci` - Validates file structure and syntax
- ⚠️ `make test-integration-dev` - If you changed container/webui code

## Troubleshooting

### Pre-commit hooks not running?
```bash
pre-commit install
pre-commit run --all-files
```

### CI fails but local tests pass?
1. Check if you're running from repo root
2. Ensure all scripts are executable: `chmod +x *.sh dev/scripts/*.sh dev/tests/*.sh`
3. Run `make test-ci` from repo root
4. Check for differences in shellcheck/yamllint versions

### Want to skip pre-commit hooks?
```bash
git commit --no-verify  # Not recommended!
```
