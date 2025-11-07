#!/usr/bin/env bats
# Integration tests for full deployment

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    # Create test directories
    TEST_DIR=$(mktemp -d)
    TEST_SCRIPT_DIR="${TEST_DIR}/ztpbootstrap"
    TEST_CERT_DIR="${TEST_DIR}/certs/wild"
    
    mkdir -p "$TEST_SCRIPT_DIR"
    mkdir -p "$TEST_CERT_DIR"
    
    # Copy test files
    cp bootstrap.py "${TEST_SCRIPT_DIR}/"
    cp nginx.conf "${TEST_SCRIPT_DIR}/"
    cp setup.sh "${TEST_SCRIPT_DIR}/"
    
    # Create test config
    cat > "${TEST_SCRIPT_DIR}/config.yaml" << EOF
paths:
  script_dir: "$TEST_SCRIPT_DIR"
  cert_dir: "$TEST_CERT_DIR"
  env_file: "${TEST_SCRIPT_DIR}/ztpbootstrap.env"
  bootstrap_script: "${TEST_SCRIPT_DIR}/bootstrap.py"
  nginx_conf: "${TEST_SCRIPT_DIR}/nginx.conf"

network:
  domain: "test.example.com"
  ipv4: "127.0.0.1"
  ipv6: ""
  https_port: 8443
  http_port: 8080
  http_only: true

cvaas:
  address: "www.arista.io"
  enrollment_token: "test_token_here"
  proxy: ""
  eos_url: ""
  ntp_server: "time.nist.gov"

ssl:
  cert_file: "fullchain.pem"
  key_file: "privkey.pem"
  use_letsencrypt: false
  letsencrypt_email: ""
  create_self_signed: false

container:
  name: "ztpbootstrap-test"
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
    # Cleanup test container if it exists
    podman stop ztpbootstrap-test 2>/dev/null || true
    podman rm ztpbootstrap-test 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

@test "update-config.sh updates bootstrap.py correctly" {
    skip "Requires yq and full setup"
    # This would test that update-config.sh properly updates bootstrap.py
    # with values from config.yaml
}

@test "update-config.sh updates nginx.conf correctly" {
    skip "Requires yq and full setup"
    # This would test that update-config.sh properly updates nginx.conf
}

@test "update-config.sh creates environment file" {
    skip "Requires yq and full setup"
    # This would test that update-config.sh creates ztpbootstrap.env
}

@test "full deployment creates all required files" {
    skip "Requires full deployment setup"
    # This would test that a full deployment creates all necessary files
    # in the correct locations
}
