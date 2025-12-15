# Security Considerations for ZTP Bootstrap Service

This document addresses security considerations identified in the comprehensive security audit (COMPREHENSIVE_AUDIT_REPORT.md).

## Container Privilege Requirements (Issue #6)

### Current Implementation

The Web UI container requires elevated privileges for certain operations:

1. **DHCP Container Management**: Creating and managing DHCP containers via systemd
2. **Configuration File Management**: Writing to `/etc/containers/systemd/`
3. **Service Control**: Running `systemctl daemon-reload` and service start/stop

### Security Implications

- **Risk**: The Web UI container has `sudo` access, which could be exploited if the container is compromised
- **Attack Vector**: An attacker gaining access to the Web UI container could potentially:
  - Write arbitrary files to `/etc/containers/systemd/`
  - Create malicious container definitions
  - Start/stop system services
  - Potentially escape the container environment

### Recommended Mitigations

#### Short-term Mitigations (Implemented)

1. **Restrict sudo Access**: Limit sudo permissions to specific commands only
   ```bash
   # In /etc/sudoers.d/ztpbootstrap
   webui ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /etc/containers/systemd
   webui ALL=(ALL) NOPASSWD: /usr/bin/cp /tmp/ztpbootstrap-dhcp.container /etc/containers/systemd/ztpbootstrap-dhcp.container
   webui ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
   webui ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ztpbootstrap-dhcp
   webui ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ztpbootstrap-dhcp
   ```

2. **Input Validation**: All container configurations are validated before being written
3. **Security Logging**: All privileged operations are logged to security audit log
4. **Rate Limiting**: API endpoints that trigger privileged operations are rate-limited

#### Long-term Recommendations (Future Work)

1. **Separate Privileged Service**: Create a host-side privileged service that the Web UI can request operations from via API
   ```
   Web UI (Unprivileged Container)
       ↓ API Request (Unix Socket)
   Container Manager Service (Host, Privileged)
       ↓ Validates & Executes
   Systemd Operations
   ```

2. **Use D-Bus or systemd Socket Activation**: Leverage systemd's built-in mechanisms for controlled service management

3. **Implement Request/Approval Flow**: For critical operations, require explicit approval

4. **SELinux/AppArmor Policies**: Add mandatory access control policies to restrict what the Web UI can do even with sudo

### Deployment Best Practices

1. **Network Isolation**: Run the Web UI container on an isolated network segment
2. **Access Control**: Implement strong authentication and restrict access to trusted networks
3. **Regular Updates**: Keep all container images and the host system updated
4. **Monitoring**: Monitor security logs for suspicious privileged operations
5. **Least Privilege**: Only grant the minimum necessary permissions

## Kea Control Agent Security (Issue #14)

### Current Implementation

The Kea Control Agent API runs on `localhost:8000` without authentication.

### Security Analysis

#### Current Protections

1. **Localhost Only**: The API only listens on `localhost`, not exposed to external networks
2. **Pod Network Isolation**: In Podman pod deployment, the API is only accessible within the pod network
3. **Container Isolation**: An attacker needs to gain access to the container or pod network first

#### Risk Assessment

- **Risk Level**: MEDIUM
- **Attack Scenario**: If an attacker gains access to:
  - The Web UI container
  - The DHCP container
  - The pod network
  
  They could:
  - Send commands to Kea API directly
  - Modify DHCP leases
  - Add malicious reservations
  - Exfiltrate lease data (MAC addresses, IPs, hostnames)

### Recommended Mitigations

#### Short-term (Documentation)

1. **Network Segmentation**: Ensure containers run on isolated networks
2. **Container Hardening**: Follow container security best practices
3. **Monitoring**: Monitor Kea API calls through Web UI audit logs
4. **Access Control**: Restrict access to the Web UI to authorized users only

#### Long-term (Future Implementation)

1. **Authentication**: Configure Kea with basic auth or TLS client certificates
   ```json
   {
     "Control-agent": {
       "http-host": "127.0.0.1",
       "http-port": 8000,
       "authentication": {
         "type": "basic",
         "realm": "kea-control-agent",
         "clients": [
           {
             "user": "webui",
             "password": "<generated-strong-password>"
           }
         ]
       }
     }
   }
   ```

2. **Unix Socket**: Use Unix domain socket instead of TCP for better isolation
   ```json
   {
     "Control-agent": {
       "socket-type": "unix",
       "socket-name": "/var/run/kea/control.sock"
     }
   }
   ```

3. **Authentication Wrapper**: Implement an authentication wrapper around Kea API in Web UI

4. **Audit Logging**: Add detailed audit logging for all Kea API calls

### Deployment Best Practices

1. **Container Security**:
   - Run containers as non-root users
   - Use read-only root filesystems where possible
   - Drop unnecessary capabilities
   - Use security profiles (SELinux, AppArmor)

2. **Network Security**:
   - Use private networks for container communication
   - Implement network policies to restrict container-to-container traffic
   - Use TLS for all external communications

3. **Monitoring**:
   - Monitor container logs for suspicious activity
   - Alert on unexpected Kea API calls
   - Track DHCP lease patterns for anomalies

4. **Access Control**:
   - Implement strong Web UI authentication
   - Use MFA where possible
   - Regularly rotate credentials
   - Implement session timeouts

## PostgreSQL Credentials (Issue #13)

### Current Implementation

When using PostgreSQL backend for Kea, credentials are stored in plain text in `config.yaml`:

```yaml
dhcp:
  backend:
    type: postgresql
    postgresql:
      host: ""
      port: 5432
      database: ""
      user: ""
      password: ""  # Plain text!
```

### Security Implications

- **Risk**: Database credentials exposed if config file is compromised
- **Impact**: Attacker could access DHCP lease database, modify leases, or cause denial of service

### Recommended Mitigations

#### Implemented Solutions

1. **Environment Variable References**: Support `${VAR_NAME}` syntax in config.yaml
   ```yaml
   dhcp:
     backend:
       postgresql:
         password: "${POSTGRES_PASSWORD}"
   ```

2. **File Permissions**: Ensure config.yaml is readable only by the Web UI container user (0600)

#### Future Improvements

1. **Secrets Management Integration**:
   - HashiCorp Vault
   - Kubernetes Secrets
   - Docker Secrets
   - Cloud provider secret managers (AWS Secrets Manager, Azure Key Vault, etc.)

2. **Certificate-based Authentication**: Use PostgreSQL SSL client certificates instead of passwords

3. **Config Encryption**: Encrypt sensitive sections of config.yaml at rest

### Deployment Best Practices

1. **Use Environment Variables**: Store sensitive credentials in environment variables, not in config files
2. **Restrict File Permissions**: Ensure config files have minimal permissions (0600)
3. **Use Secrets Management**: Integrate with a secrets management system in production
4. **Regular Rotation**: Rotate database credentials regularly
5. **Audit Access**: Monitor and audit database access logs

## Additional Security Measures Implemented

### 1. Rate Limiting (Issue #9)

All API endpoints now have rate limiting to prevent abuse:
- Login endpoint: 5 attempts per 15 minutes per IP
- DHCP operations: 5 calls per minute per IP
- Configuration updates: 10 calls per minute per IP

### 2. Input Validation (Issues #5, #7)

Comprehensive validation for all user inputs:
- DHCP configuration parameters (IP addresses, CIDR, ranges)
- DHCP options (protected options cannot be overridden)
- File paths (path traversal prevention)
- Filenames (sanitization and validation)

### 3. Security Event Logging (Issue #10)

Enhanced logging for security-relevant events:
- All authentication attempts (success and failure)
- Configuration changes
- DHCP container operations
- Privileged command executions
- Rate limiting triggers

### 4. Thread-Safe Configuration Management (Issue #1)

ConfigManager class provides:
- File locking to prevent race conditions
- Atomic read-modify-write operations
- Automatic backups before changes
- Transaction-like semantics

## Security Testing Recommendations

1. **Penetration Testing**: Conduct regular penetration tests of the Web UI and DHCP service
2. **Vulnerability Scanning**: Use tools like:
   - CodeQL for static code analysis
   - Trivy for container image scanning
   - OWASP ZAP for web application security testing
3. **Dependency Scanning**: Regularly scan for vulnerable dependencies
4. **Security Audits**: Conduct periodic security audits of the codebase
5. **Fuzz Testing**: Implement fuzz testing for API endpoints and configuration parsing

## Incident Response

### If a Security Breach is Suspected

1. **Immediate Actions**:
   - Stop all containers: `systemctl stop ztpbootstrap-*`
   - Isolate the affected systems from the network
   - Preserve logs for forensic analysis

2. **Investigation**:
   - Review security logs: `/opt/containerdata/ztpbootstrap/logs/security.log`
   - Check system logs for unauthorized access
   - Review DHCP lease logs for anomalies
   - Examine configuration file changes

3. **Remediation**:
   - Change all credentials
   - Update all container images
   - Apply security patches
   - Review and update security policies

4. **Recovery**:
   - Restore from backup if necessary
   - Verify system integrity before bringing services back online
   - Monitor closely for any signs of continued compromise

## References

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [CWE Top 25 Most Dangerous Software Weaknesses](https://cwe.mitre.org/top25/)
- [Docker Security Best Practices](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Kea DHCP Security](https://kea.readthedocs.io/en/latest/arm/security.html)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)

## Changelog

- 2025-12-15: Initial security considerations document
  - Documented container privilege requirements (Issue #6)
  - Documented Kea Control Agent security (Issue #14)
  - Documented PostgreSQL credentials handling (Issue #13)
  - Added deployment best practices
  - Added incident response procedures
