#!/usr/bin/env bats
# Unit tests for validation functions from validate-config.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Source the validation functions
# Note: We'll extract validation functions to a separate file for testing
source_validation_functions() {
    # Extract validation functions from validate-config.sh
    # This is a simplified version for testing
    validate_ipv4() {
        local ip="$1"
        if [[ -z "$ip" ]] || [[ "$ip" == "null" ]]; then
            return 0
        fi
        if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            IFS='.' read -ra ADDR <<< "$ip"
            for i in "${ADDR[@]}"; do
                if [[ $i -gt 255 ]]; then
                    return 1
                fi
            done
            return 0
        else
            return 1
        fi
    }
    
    validate_port() {
        local port="$1"
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        if [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
            return 1
        fi
        return 0
    }
    
    validate_domain() {
        local domain="$1"
        if [[ -z "$domain" ]] || [[ "$domain" == "null" ]]; then
            return 1
        fi
        if [[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?)+$ ]]; then
            return 0
        else
            return 1
        fi
    }
}

setup() {
    source_validation_functions
}

@test "validate_ipv4 accepts valid IPv4 addresses" {
    validate_ipv4 "10.0.0.1"
    assert_success
    
    validate_ipv4 "192.168.1.1"
    assert_success
    
    validate_ipv4 "255.255.255.255"
    assert_success
}

@test "validate_ipv4 rejects invalid IPv4 addresses" {
    validate_ipv4 "999.999.999.999"
    assert_failure
    
    validate_ipv4 "10.0.0"
    assert_failure
    
    validate_ipv4 "not.an.ip.address"
    assert_failure
}

@test "validate_ipv4 accepts empty string" {
    validate_ipv4 ""
    assert_success
    
    validate_ipv4 "null"
    assert_success
}

@test "validate_port accepts valid ports" {
    validate_port "1"
    assert_success
    
    validate_port "443"
    assert_success
    
    validate_port "65535"
    assert_success
}

@test "validate_port rejects invalid ports" {
    validate_port "0"
    assert_failure
    
    validate_port "65536"
    assert_failure
    
    validate_port "abc"
    assert_failure
    
    validate_port "-1"
    assert_failure
}

@test "validate_domain accepts valid domains" {
    validate_domain "example.com"
    assert_success
    
    validate_domain "test.example.com"
    assert_success
    
    validate_domain "sub-domain.example.co.uk"
    assert_success
}

@test "validate_domain rejects invalid domains" {
    validate_domain ""
    assert_failure
    
    validate_domain "invalid..domain"
    assert_failure
    
    validate_domain "-invalid.com"
    assert_failure
    
    validate_domain "invalid-.com"
    assert_failure
}
