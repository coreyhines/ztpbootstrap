#!/usr/bin/env bats

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # shellcheck source=scripts/network-ipv6.sh
    source "${SCRIPT_DIR}/scripts/network-ipv6.sh"
}

@test "remap_ipv6_to_subnet keeps address when already in subnet" {
    run remap_ipv6_to_subnet "2601:441:8483:b501::10" "2601:441:8483:b501::/64"
    [ "$status" -eq 0 ]
    [ "$output" = "2601:441:8483:b501::10" ]
}

@test "remap_ipv6_to_subnet maps host suffix onto new prefix" {
    run remap_ipv6_to_subnet "2601:441:8400:b7e1::10" "2601:441:8483:b501::/64"
    [ "$status" -eq 0 ]
    [ "$output" = "2601:441:8483:b501::10" ]
}

@test "remap_ipv6_to_subnet rejects invalid candidate" {
    run remap_ipv6_to_subnet "not-an-ip" "2601:441:8483:b501::/64"
    [ "$status" -ne 0 ]
}

@test "ip_in_subnet accepts IPv6 in range" {
    run ip_in_subnet "2601:441:8483:b501::10" "2601:441:8483:b501::/64"
    [ "$status" -eq 0 ]
}

@test "ip_in_subnet rejects IPv6 outside range" {
    run ip_in_subnet "2601:441:8400:b7e1::10" "2601:441:8483:b501::/64"
    [ "$status" -ne 0 ]
}
