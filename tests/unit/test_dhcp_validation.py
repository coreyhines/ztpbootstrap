#!/usr/bin/env python3
"""
Unit tests for DHCP validation module
Tests input validation for DHCP configuration
"""

import unittest
import sys
import os

# Add webui directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../webui'))

try:
    from dhcp_validation import (
        validate_ip_address,
        validate_cidr,
        validate_dhcp_range,
        validate_gateway,
        validate_dns_servers,
        validate_domain_name,
        validate_port,
        validate_dhcp_option,
        validate_dhcp_config,
        PROTECTED_DHCP_OPTIONS
    )
except ImportError:
    validate_ip_address = None


@unittest.skipIf(validate_ip_address is None, "DHCP validation not available")
class TestDHCPValidation(unittest.TestCase):
    """Test cases for DHCP validation"""
    
    def test_validate_ip_address_valid_ipv4(self):
        """Test valid IPv4 addresses"""
        is_valid, error = validate_ip_address("192.168.1.1", version=4)
        self.assertTrue(is_valid)
        self.assertIsNone(error)
        
        is_valid, error = validate_ip_address("10.0.0.1", version=4)
        self.assertTrue(is_valid)
    
    def test_validate_ip_address_invalid(self):
        """Test invalid IP addresses"""
        is_valid, error = validate_ip_address("not-an-ip", version=4)
        self.assertFalse(is_valid)
        self.assertIsNotNone(error)
        
        is_valid, error = validate_ip_address("256.256.256.256", version=4)
        self.assertFalse(is_valid)
    
    def test_validate_cidr_valid(self):
        """Test valid CIDR notation"""
        is_valid, error = validate_cidr("192.168.1.0/24", version=4)
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_cidr_invalid(self):
        """Test invalid CIDR notation"""
        is_valid, error = validate_cidr("192.168.1.0/99", version=4)
        self.assertFalse(is_valid)
        
        is_valid, error = validate_cidr("not-a-cidr", version=4)
        self.assertFalse(is_valid)
    
    def test_validate_cidr_too_small(self):
        """Test CIDR with prefix too small"""
        is_valid, error = validate_cidr("10.0.0.0/7", version=4)
        self.assertFalse(is_valid)
        self.assertIn("too small", error)
    
    def test_validate_dhcp_range_valid(self):
        """Test valid DHCP range"""
        is_valid, error = validate_dhcp_range(
            "192.168.1.10",
            "192.168.1.100",
            "192.168.1.0/24"
        )
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_dhcp_range_invalid_order(self):
        """Test DHCP range with start > end"""
        is_valid, error = validate_dhcp_range(
            "192.168.1.100",
            "192.168.1.10",
            "192.168.1.0/24"
        )
        self.assertFalse(is_valid)
        self.assertIn("must be less than", error)
    
    def test_validate_dhcp_range_outside_subnet(self):
        """Test DHCP range outside subnet"""
        is_valid, error = validate_dhcp_range(
            "192.168.2.10",
            "192.168.2.100",
            "192.168.1.0/24"
        )
        self.assertFalse(is_valid)
        self.assertIn("not in subnet", error)
    
    def test_validate_dhcp_range_too_large(self):
        """Test DHCP range that's too large"""
        is_valid, error = validate_dhcp_range(
            "10.0.0.1",
            "10.255.255.254",
            "10.0.0.0/8",
            max_size=1000
        )
        self.assertFalse(is_valid)
        self.assertIn("exceeds maximum", error)
    
    def test_validate_gateway_valid(self):
        """Test valid gateway"""
        is_valid, error = validate_gateway("192.168.1.1", "192.168.1.0/24")
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_gateway_outside_subnet(self):
        """Test gateway outside subnet"""
        is_valid, error = validate_gateway("192.168.2.1", "192.168.1.0/24")
        self.assertFalse(is_valid)
        self.assertIn("not in subnet", error)
    
    def test_validate_dns_servers_valid(self):
        """Test valid DNS servers"""
        is_valid, error = validate_dns_servers(["8.8.8.8", "8.8.4.4"])
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_dns_servers_invalid(self):
        """Test invalid DNS servers"""
        is_valid, error = validate_dns_servers(["not-an-ip", "8.8.8.8"])
        self.assertFalse(is_valid)
        self.assertIn("Invalid DNS server", error)
    
    def test_validate_domain_name_valid(self):
        """Test valid domain names"""
        is_valid, error = validate_domain_name("example.com")
        self.assertTrue(is_valid)
        self.assertIsNone(error)
        
        is_valid, error = validate_domain_name("sub.example.com")
        self.assertTrue(is_valid)
    
    def test_validate_domain_name_invalid(self):
        """Test invalid domain names"""
        is_valid, error = validate_domain_name("invalid..domain")
        self.assertFalse(is_valid)
        
        is_valid, error = validate_domain_name("a" * 64 + ".com")
        self.assertFalse(is_valid)
        self.assertIn("too long", error)
    
    def test_validate_port_valid(self):
        """Test valid port numbers"""
        is_valid, error = validate_port(80)
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_port_invalid(self):
        """Test invalid port numbers"""
        is_valid, error = validate_port(0)
        self.assertFalse(is_valid)
        
        is_valid, error = validate_port(70000)
        self.assertFalse(is_valid)
    
    def test_validate_dhcp_option_protected(self):
        """Test that protected DHCP options are rejected"""
        for code, name in PROTECTED_DHCP_OPTIONS.items():
            is_valid, error = validate_dhcp_option({
                'code': code,
                'name': name,
                'data': 'test'
            })
            self.assertFalse(is_valid)
            self.assertIn("protected", error)
    
    def test_validate_dhcp_option_valid(self):
        """Test valid custom DHCP option"""
        is_valid, error = validate_dhcp_option({
            'code': 150,  # Not a protected option
            'name': 'custom-option',
            'data': 'custom-value'
        })
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_dhcp_option_invalid_code(self):
        """Test DHCP option with invalid code"""
        is_valid, error = validate_dhcp_option({
            'code': 300,  # Out of range
            'name': 'custom',
            'data': 'value'
        })
        self.assertFalse(is_valid)
        self.assertIn("out of valid range", error)
    
    def test_validate_dhcp_config_complete(self):
        """Test complete DHCP configuration"""
        config = {
            'ipv4': {
                'subnet': '192.168.1.0/24',
                'range_start': '192.168.1.10',
                'range_end': '192.168.1.100',
                'gateway': '192.168.1.1',
                'dns': ['8.8.8.8'],
                'domain': 'example.com'
            },
            'lease_time': 3600
        }
        
        is_valid, error = validate_dhcp_config(config)
        self.assertTrue(is_valid)
        self.assertIsNone(error)
    
    def test_validate_dhcp_config_invalid_range(self):
        """Test DHCP config with invalid range"""
        config = {
            'ipv4': {
                'subnet': '192.168.1.0/24',
                'range_start': '192.168.1.100',
                'range_end': '192.168.1.10',  # Invalid: start > end
            }
        }
        
        is_valid, error = validate_dhcp_config(config)
        self.assertFalse(is_valid)
        self.assertIn("must be less than", error)


if __name__ == '__main__':
    unittest.main()
