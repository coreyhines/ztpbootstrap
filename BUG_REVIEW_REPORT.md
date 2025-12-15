# Bug Review Report for ztpbootstrap

**Date:** 2025-11-29

## 1. Executive Summary

This report details the findings of a code review for the `ztpbootstrap` project. The analysis reveals a solid architectural foundation for a Zero Touch Provisioning (ZTP) system. However, several critical and high-priority issues were identified, primarily concerning security, configuration management, and code complexity.

The most significant risks include a hardcoded default security token, potential privilege escalation through the use of `sudo` in the web application, and a lack of input validation that could lead to a Denial of Service (DoS) attack against the DHCP server.

The findings from the initial automated analysis were interrupted, and as such, this review does not cover an in-depth analysis of shell scripts, `systemd` unit files, or the full testing suite. A follow-up review focusing on these areas is highly recommended.

## 2. High-Priority Findings

### 2.1. Hardcoded Default Enrollment Token (Critical)

- **File:** `bootstrap.py`
- **Symbol:** `enrollmentToken`
- **Description:** The `bootstrap.py` script, which is served to newly provisioned devices, contains a hardcoded default enrollment token. If an administrator does not change this default, any device on the provisioning network could potentially use this token to enroll, leading to a significant security breach.
- **Recommendation:**
    1. Remove the hardcoded token from the `bootstrap.py` script.
    2. The token should be dynamically generated during the initial setup process and injected into the `bootstrap.py` script when it is served.
    3. The Web UI should require the administrator to set a new token and provide a strong warning if a weak or default token is used.

### 2.2. Privilege Escalation via `sudo` in Web UI (Critical)

- **File:** `webui/app.py`
- **Symbol:** `get_logs`
- **Description:** The `get_logs` function in the Flask web application attempts to read service logs using `podman` and `journalctl`. As a fallback, it executes these commands with `sudo`, which presents a critical security risk. If this endpoint can be manipulated, it could lead to privilege escalation on the host system.
- **Recommendation:**
    1. The web application should never run with `sudo` privileges, nor should it call `sudo`.
    2. The application should be granted specific, limited permissions to read the necessary log files (e.g., through group permissions or ACLs).
    3. Alternatively, logs should be redirected to a file or service that the `webui` process has explicit permissions to access without needing elevated rights.

### 2.3. Potential for DHCP Server Crash via Unvalidated Input (High)

- **File:** `webui/dhcp_config.py`
- **Symbol:** `generate_custom_options`
- **Description:** The function responsible for generating DHCP configuration from user input does not appear to validate custom DHCP options. A malicious or malformed entry from a user could generate an invalid Kea configuration file, causing the DHCP server to fail to start or crash on reload. This would constitute a Denial of Service (DoS) for the entire provisioning network.
- **Recommendation:**
    1. Implement strict input validation for all user-configurable fields, especially the "custom DHCP options."
    2. The validation logic should check for correct data types, formatting, and adherence to the Kea DHCP server's configuration schema.
    3. The application should provide clear error messages to the user for invalid input.

## 3. Medium-Priority Findings

### 3.1. Non-Atomic Configuration Updates (Medium)

- **File:** `webui/app.py`
- **Symbol:** `add_dhcp_reservation`, `update_dhcp_config`
- **Description:** When adding a new DHCP reservation, the application first makes an API call to the running Kea server and then separately writes the change to the `config.yaml` file. This two-step process is not atomic. If the file write fails after the API call succeeds, the running configuration will be out of sync with the persisted configuration, leading to inconsistencies on the next service restart.
- **Recommendation:**
    1. Implement a transactional approach. A temporary configuration file could be written first.
    2. If the new configuration is successfully validated and applied to Kea, the temporary file can be moved to become the new `config.yaml`.
    3. If any step fails, the entire transaction should be rolled back.

### 3.2. Inconsistent Lease Data Retrieval (Medium)

- **File:** `webui/kea_client.py`
- **Symbol:** `get_leases`
- **Description:** The system uses two different methods for interacting with DHCP lease data. For individual lease operations, it uses the Kea API. However, to retrieve all leases, it resorts to manually parsing the `memfile` lease database. This approach is fragile and will break if the Kea backend is ever changed to a different storage mechanism (e.g., PostgreSQL).
- **Recommendation:**
    1. Refactor `get_leases` to use the Kea API to fetch all leases.
    2. Remove all direct file parsing from the `kea_client.py` module to ensure that all interactions are consistently handled through the official API.

### 3.3. Weak Content Security Policy (Medium)

- **File:** `nginx.conf`
- **Description:** The Content-Security-Policy (CSP) for the `/ui/` location includes `'unsafe-eval'`. While sometimes necessary for certain legacy JavaScript libraries, this directive significantly weakens the site's defense against Cross-Site Scripting (XSS) attacks.
- **Recommendation:**
    1. Investigate the feasibility of removing `'unsafe-eval'`. This may require refactoring or replacing the JavaScript libraries that depend on it.
    2. If it cannot be removed, ensure that all user-supplied data is rigorously sanitized before being rendered in the UI to mitigate the risk of XSS.

## 4. Low-Priority Findings & Code Smells

### 4.1. Dual Password Hashing Implementations

- **File:** `webui/app.py`
- **Symbols:** `auth_login`, `auth_change_password`
- **Description:** The application contains two separate password hashing schemes: the standard one provided by `werkzeug.security` and a custom one using `hashlib.pbkdf2_hmac`. This adds unnecessary complexity and increases the maintenance burden.
- **Recommendation:**
    - Standardize on a single, well-vetted password hashing library. The `werkzeug.security` implementation is sufficient for this use case. Refactor the code to use it exclusively.

### 4.2. Code Duplication in Nginx Configuration

- **File:** `nginx.conf`
- **Description:** The `server` block and the `default_server` block share a significant amount of duplicated configuration, particularly regarding security headers.
- **Recommendation:**
    - Move the common security headers and other shared settings into a separate file and `include` it in both server blocks to reduce duplication and simplify maintenance.

### 4.3. Potential for Command Injection

- **File:** `bootstrap.py`
- **Symbol:** `CliManager.runCommands`
- **Description:** The script uses `subprocess.run(..., shell=True)`. While there is no immediate vulnerability as the command strings are internally defined, using `shell=True` is a risky practice that can lead to command injection if any part of the command is ever constructed from external input.
- **Recommendation:**
    - Avoid `shell=True` wherever possible. Refactor the commands to be lists of arguments passed directly to `subprocess.run`.
