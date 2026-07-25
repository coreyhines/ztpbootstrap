#!/usr/bin/env python3
"""Unit tests for DHCP dashboard summary calculations."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../webui"))

from dhcp_summary import (  # noqa: E402
    build_dhcp_summary,
    format_lease_for_api,
    normalize_lease_state,
    pool_address_count,
)


class TestNormalizeLeaseState(unittest.TestCase):
    def test_numeric_states(self):
        self.assertEqual(normalize_lease_state(0), "active")
        self.assertEqual(normalize_lease_state(1), "expired")
        self.assertEqual(normalize_lease_state(2), "reclaimed")

    def test_string_states(self):
        self.assertEqual(normalize_lease_state("0"), "active")
        self.assertEqual(normalize_lease_state("active"), "active")


class TestFormatLeaseForApi(unittest.TestCase):
    def test_formats_numeric_state_and_ipv6_addresses(self):
        lease = format_lease_for_api(
            {
                "hw-address": "00:1c:73:aa:bb:cc",
                "ip-addresses": ["2601:441:8483:b505::50"],
                "state": 0,
                "valid-lft": 86400,
                "hostname": "spine1",
            },
            "ipv6",
        )
        self.assertEqual(lease["state"], "active")
        self.assertEqual(lease["ip"], "2601:441:8483:b505::50")
        self.assertEqual(lease["type"], "ipv6")


class TestPoolAddressCount(unittest.TestCase):
    def test_inclusive_pool_size(self):
        self.assertEqual(pool_address_count("10.0.5.220", "10.0.5.230"), 11)


class TestBuildDhcpSummary(unittest.TestCase):
    def test_counts_leases_reservations_drift_and_pool(self):
        config = {
            "dhcp": {
                "ipv4": {
                    "range_start": "10.0.5.220",
                    "range_end": "10.0.5.230",
                },
                "reservations": [
                    {"hw-address": "fc:bd:67:0e:ac:6e", "ip-address": "10.0.5.2"},
                    {"hw-address": "fc:bd:67:0e:ac:6e", "ip-address": "2601:441:8483:b505::2"},
                    {"hw-address": "e0:fa:5b:72:11:9f", "ip-address": "10.0.5.3"},
                ],
            }
        }
        ipv4_leases = [
            {
                "hw-address": "fc:bd:67:0e:ac:6e",
                "ip-address": "10.0.5.2",
                "state": 0,
                "cltt": 1000,
                "hostname": "720xp-24",
            },
            {
                "hw-address": "e0:fa:5b:72:11:9f",
                "ip-address": "10.0.5.221",
                "state": 0,
                "cltt": 900,
                "hostname": "720xp-48",
            },
            {
                "hw-address": "2c:dd:e9:fd:06:d6",
                "ip-address": "10.0.5.4",
                "state": 0,
                "cltt": 800,
            },
        ]

        summary = build_dhcp_summary(
            config,
            ipv4_leases,
            [],
            {"reachable": True, "lease_cmds_loaded": True, "latency_ms": 42, "error": None},
        )

        self.assertEqual(summary["leases"]["total"], 3)
        self.assertEqual(summary["leases"]["ipv4"], 3)
        self.assertEqual(summary["reservations"]["total"], 3)
        self.assertEqual(summary["reservations"]["unique_hosts"], 2)
        self.assertEqual(summary["reservations"]["active_matches"], 1)
        self.assertEqual(summary["reservations"]["drift_count"], 1)
        self.assertEqual(summary["pool"]["ipv4"]["total"], 11)
        self.assertEqual(summary["pool"]["ipv4"]["used"], 1)
        self.assertEqual(summary["kea"]["latency_ms"], 42)
        self.assertEqual(summary["last_activity"]["hostname"], "720xp-24")


if __name__ == "__main__":
    unittest.main()
