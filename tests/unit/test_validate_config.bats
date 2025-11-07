#!/usr/bin/env bats
# Unit tests for validate-config.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    # Create temporary directory for test configs
    TEST_DIR=$(mktemp -d)
    TEST_CONFIG="${TEST_DIR}/test-config.yaml"
    
    # Create a minimal valid config for testing
    cat > "$TEST_CONFIG" << 'EOF'
paths:
  script_dir: "/tmp/test/ztpbootstrap"
  cert_dir: "/tmp/test/certs"
  env_file: "/tmp/test/ztpbootstrap.env"
  bootstrap_script: "/tmp/test/bootstrap.py"
  nginx_conf: "/tmp/test/nginx.conf"
  quadlet_file: "/tmp/test/ztpbootstrap.container"

network:
  domain: "test.example.com"
  ipv4: "10.0.0.10"
  ipv6: "2001:db8::10"
  https_port: 443
  http_port: 80
  http_only: false

cvaas:
  address: "www.arista.io"
  enrollment_token: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test.token.here"
  proxy: ""
  eos_url: ""
  ntp_server: "time.nist.gov"

ssl:
  cert_file: "fullchain.pem"
  key_file: "privkey.pem"
  use_letsencrypt: false
  letsencrypt_email: "admin@example.com"
  create_self_signed: false

container:
  name: "ztpbootstrap"
  image: "docker.io/nginx:alpine"
  timezone: "UTC"
  host_network: true
  dns:
    - "8.8.8.8"
    - "8.8.4.4"

service:
  health_interval: "30s"
  health_timeout: "10s"
  health_retries: 3
  health_start_period: "60s"
  restart_policy: "on-failure"
EOF
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "validate-config.sh validates valid config" {
    skip "Requires yq to be installed"
    run bash validate-config.sh "$TEST_CONFIG"
    assert_success
    assert_output --partial "All validations passed"
}

@test "validate-config.sh detects invalid IPv4" {
    skip "Requires yq to be installed"
    # Create config with invalid IPv4
    yq eval '.network.ipv4 = "999.999.999.999"' -i "$TEST_CONFIG"
    
    run bash validate-config.sh "$TEST_CONFIG"
    assert_failure
    assert_output --partial "Invalid IPv4"
}

@test "validate-config.sh detects invalid port" {
    skip "Requires yq to be installed"
    # Create config with invalid port
    yq eval '.network.https_port = 99999' -i "$TEST_CONFIG"
    
    run bash validate-config.sh "$TEST_CONFIG"
    assert_failure
    assert_output --partial "Port must be between 1 and 65535"
}

@test "validate-config.sh detects missing enrollment token" {
    skip "Requires yq to be installed"
    # Create config without enrollment token
    yq eval '.cvaas.enrollment_token = ""' -i "$TEST_CONFIG"
    
    run bash validate-config.sh "$TEST_CONFIG"
    assert_failure
    assert_output --partial "enrollment_token is required"
}

@test "validate-config.sh detects invalid domain" {
    skip "Requires yq to be installed"
    # Create config with invalid domain
    yq eval '.network.domain = "invalid..domain"' -i "$TEST_CONFIG"
    
    run bash validate-config.sh "$TEST_CONFIG"
    assert_failure
    assert_output --partial "Invalid domain format"
}

@test "validate-config.sh detects invalid email" {
    skip "Requires yq to be installed"
    # Create config with invalid email
    yq eval '.ssl.use_letsencrypt = true' -i "$TEST_CONFIG"
    yq eval '.ssl.letsencrypt_email = "invalid-email"' -i "$TEST_CONFIG"
    
    run bash validate-config.sh "$TEST_CONFIG"
    assert_failure
    assert_output --partial "Invalid email format"
}
