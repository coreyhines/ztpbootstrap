#!/usr/bin/env python3
"""
Unit tests for ConfigManager class
Tests thread-safe configuration file management
"""

import tempfile
import unittest
from pathlib import Path
import sys
import os

# Add webui directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../webui'))

try:
    from config_manager import ConfigManager
except ImportError:
    ConfigManager = None


@unittest.skipIf(ConfigManager is None, "ConfigManager not available")
class TestConfigManager(unittest.TestCase):
    """Test cases for ConfigManager"""
    
    def setUp(self):
        """Create a temporary config file for testing"""
        self.temp_dir = tempfile.mkdtemp()
        self.config_path = Path(self.temp_dir) / "test_config.yaml"
        
        # Create initial config
        with open(self.config_path, 'w') as f:
            f.write("test_key: test_value\n")
        
        self.config_manager = ConfigManager(self.config_path)
    
    def tearDown(self):
        """Clean up temporary files"""
        import shutil
        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)
    
    def test_read_config(self):
        """Test reading configuration"""
        config = self.config_manager.read_config()
        self.assertIsInstance(config, dict)
        self.assertEqual(config.get('test_key'), 'test_value')
    
    def test_write_config(self):
        """Test writing configuration"""
        new_config = {'new_key': 'new_value'}
        self.config_manager.write_config(new_config)
        
        # Read back and verify
        config = self.config_manager.read_config()
        self.assertEqual(config.get('new_key'), 'new_value')
    
    def test_update_section(self):
        """Test updating a single section"""
        success, error = self.config_manager.update_section('dhcp', {'enabled': True})
        self.assertTrue(success)
        self.assertIsNone(error)
        
        # Verify update
        config = self.config_manager.read_config()
        self.assertEqual(config.get('dhcp'), {'enabled': True})
    
    def test_update_section_with_validation(self):
        """Test updating section with validation"""
        def validator(config):
            if 'dhcp' in config and config['dhcp'].get('enabled'):
                return True, None
            return False, "DHCP must be enabled"
        
        # Should succeed
        success, error = self.config_manager.update_section(
            'dhcp', 
            {'enabled': True},
            validate=validator
        )
        self.assertTrue(success)
        
        # Should fail
        success, error = self.config_manager.update_section(
            'dhcp',
            {'enabled': False},
            validate=validator
        )
        self.assertFalse(success)
        self.assertIn("DHCP must be enabled", error)
    
    def test_backup_creation(self):
        """Test that backups are created"""
        initial_config = {'key1': 'value1'}
        self.config_manager.write_config(initial_config)
        
        # Update config (should create backup)
        new_config = {'key2': 'value2'}
        self.config_manager.write_config(new_config)
        
        # Check that backup exists
        backup_files = list(Path(self.temp_dir).glob('test_config.backup.*'))
        self.assertGreater(len(backup_files), 0, "Backup file should be created")
    
    def test_backup_cleanup(self):
        """Test that old backups are cleaned up"""
        # Create more backups than max_backups
        config_manager = ConfigManager(self.config_path, max_backups=3)
        
        for i in range(5):
            config = {f'key{i}': f'value{i}'}
            config_manager.write_config(config)
        
        # Check that only max_backups are kept
        backup_files = list(Path(self.temp_dir).glob('test_config.backup.*'))
        self.assertLessEqual(len(backup_files), 3, "Should keep at most 3 backups")


if __name__ == '__main__':
    unittest.main()
