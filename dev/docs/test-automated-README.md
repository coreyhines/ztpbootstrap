# Automated Testing Iteration System

This automated testing system runs comprehensive tests across multiple scenarios, iterating on failures until all tests pass or max iterations are reached.

## Overview

The system consists of:
- **`test-automated-iteration.sh`** - Main test runner script
- **`dev/tests/test-matrix.yaml`** - Test case definitions

## Features

- **Automatic VM Management**: Creates, resets, and manages test VMs
- **Distro-Agnostic**: Works with Fedora, Ubuntu, Rocky Linux, AlmaLinux, CentOS Stream, and openSUSE Leap
- **Multiple Test Scenarios**: Tests fresh installs, upgrades, different network configs, etc.
- **Iterative Improvement**: Automatically wipes and recreates VMs on failure
- **Comprehensive Reporting**: Saves test results, logs, and outputs for analysis

## Usage

### Basic Usage

```bash
# Run tests with default settings (Fedora 43)
./dev/tests/test-automated-iteration.sh

# Test a specific distribution
./dev/tests/test-automated-iteration.sh ubuntu 24.04
./dev/tests/test-automated-iteration.sh rocky 9
```

### Advanced Options

```bash
# Use custom test matrix
./dev/tests/test-automated-iteration.sh --test-matrix my-tests.yaml fedora 43

# Keep VM on failure for debugging
./dev/tests/test-automated-iteration.sh --keep-on-failure ubuntu 24.04

# Limit iterations
./dev/tests/test-automated-iteration.sh --max-iterations 5 rocky 9

# Custom report directory
./dev/tests/test-automated-iteration.sh --report-dir ./my-reports fedora 43
```

## Test Matrix Format

The test matrix (`dev/tests/test-matrix.yaml`) defines test cases:

```yaml
tests:
  - name: "test_name"
    description: "Test description"
    scenario: "fresh"  # or "upgrade"
    setup_interactive_args: ["--non-interactive"]
    expected_exit_code: 0
    requires_existing_install: false
    environment:
      VAR_NAME: "value"
    interactive_responses:
      - "y"
      - "n"
    verify:
      - service_running: "ztpbootstrap"
      - file_exists: "/path/to/file"
```

### Test Fields

- **name**: Unique test identifier
- **description**: Human-readable description
- **scenario**: `fresh` (new install) or `upgrade` (upgrade existing)
- **setup_interactive_args**: Arguments to pass to `setup-interactive.sh`
- **expected_exit_code**: Expected exit code (0 for success, non-zero for expected failures)
- **requires_existing_install**: If `true`, sets up an existing installation first
- **environment**: Environment variables to set
- **interactive_responses**: Canned responses for interactive prompts
- **verify**: List of verification checks to run after test

### Verification Checks

- `service_running: "service-name"` - Checks if systemd service is active
- `file_exists: "/path/to/file"` - Checks if file exists
- `backup_exists: true` - Checks if backup was created
- `config_preserved: true` - Checks if config was preserved (upgrade tests)
- `network_type: "macvlan"` or `"host"` - Checks network configuration
- `password_reset: true` - Checks if password was reset

## How It Works

1. **VM Creation**: Creates a fresh VM for each iteration
2. **SSH Detection**: Automatically detects the correct SSH user based on distribution
3. **Directory Discovery**: Finds ztpbootstrap directory in common locations
4. **Test Execution**: Runs each test from the matrix
5. **Verification**: Runs verification checks after each test
6. **Iteration**: On failure, wipes VM and starts new iteration
7. **Reporting**: Saves all results, logs, and outputs to report directory

## Report Structure

```
tests/test-reports/
├── vm-create-YYYYMMDD_HHMMSS.log
├── test-<test-name>-iter<iteration>-<timestamp>/
│   ├── result.txt
│   ├── output.log
│   ├── setup-existing.log (if applicable)
│   └── responses.txt (if interactive)
└── ...
```

## Examples

### Test Fresh Installation

```yaml
- name: "fresh_install_non_interactive"
  scenario: "fresh"
  setup_interactive_args: ["--non-interactive"]
  expected_exit_code: 0
  verify:
    - service_running: "ztpbootstrap"
    - service_running: "ztpbootstrap-nginx"
```

### Test Upgrade

```yaml
- name: "upgrade_existing"
  scenario: "upgrade"
  requires_existing_install: true
  setup_interactive_args: ["--upgrade"]
  expected_exit_code: 0
  verify:
    - service_running: "ztpbootstrap"
    - config_preserved: true
```

### Test Interactive Mode

```yaml
- name: "interactive_with_responses"
  scenario: "fresh"
  setup_interactive_args: []
  interactive_responses:
    - "y"  # Create backup
    - ""   # Use defaults
  expected_exit_code: 0
```

## Troubleshooting

### VM Not Ready

If VM doesn't become ready, check:
- VM creation logs in report directory
- QEMU process is running: `ps aux | grep qemu`
- SSH port is available: `lsof -i :2222`

### Tests Failing

- Check test output logs in report directory
- Use `--keep-on-failure` to keep VM for debugging
- SSH into VM: `ssh -p 2222 <user>@localhost`

### Can't Find ztpbootstrap Directory

The script searches common locations. If it fails:
- Check cloud-init logs in VM
- Verify repository was cloned during VM creation
- Check `/home/*/ztpbootstrap` manually

## Requirements

- `yq` - YAML processor (install with `brew install yq`)
- `qemu` - VM creation
- `ssh` - VM access
- `scp` - File transfer to VM
