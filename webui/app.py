#!/usr/bin/env python3
"""
Simple Web UI for ZTP Bootstrap Service
Lightweight Flask application for configuration and monitoring
"""

import json
import os
import subprocess
from pathlib import Path
from flask import Flask, render_template, request, jsonify, send_from_directory

app = Flask(__name__)

# Configuration paths
CONFIG_DIR = Path(os.environ.get('ZTP_CONFIG_DIR', '/opt/containerdata/ztpbootstrap'))
CONFIG_FILE = CONFIG_DIR / 'config.yaml'
BOOTSTRAP_SCRIPT = CONFIG_DIR / 'bootstrap.py'
NGINX_CONF = CONFIG_DIR / 'nginx.conf'

@app.route('/')
def index():
    """Main dashboard page"""
    return render_template('index.html')

@app.route('/api/config')
def get_config():
    """Get current configuration"""
    try:
        if CONFIG_FILE.exists():
            # Try to read YAML if yq is available
            try:
                result = subprocess.run(
                    ['yq', 'eval', '-o=json', str(CONFIG_FILE)],
                    capture_output=True,
                    text=True,
                    check=True
                )
                return jsonify({'parsed': json.loads(result.stdout), 'raw': CONFIG_FILE.read_text()})
            except (subprocess.CalledProcessError, FileNotFoundError):
                # Fallback: read as text
                return jsonify({'raw': CONFIG_FILE.read_text(), 'parsed': None})
        else:
            return jsonify({'error': 'Config file not found'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/bootstrap-scripts')
def list_bootstrap_scripts():
    """List available bootstrap scripts"""
    scripts = []
    script_dir = CONFIG_DIR
    active_script = None
    
    # Check which script is currently active (bootstrap.py is the active one)
    active_path = BOOTSTRAP_SCRIPT
    if active_path.exists():
        if active_path.is_symlink():
            # Resolve symlink to get the actual target file
            try:
                resolved = active_path.resolve()
                active_script = resolved.name
            except:
                active_script = active_path.name
        else:
            # bootstrap.py is a regular file, so it's the active one
            active_script = active_path.name
    
    # Get the resolved path and name of the active script for comparison
    active_resolved_path = None
    active_resolved_name = None
    if active_script:
        try:
            active_file = script_dir / active_script
            if active_file.exists():
                active_resolved_path = active_file.resolve()
                active_resolved_name = active_resolved_path.name
        except:
            pass
    
    for file in script_dir.glob('bootstrap*.py'):
        # Only mark as active if this file's NAME matches the resolved target name
        # This ensures only the actual target file is marked active, not the symlink
        is_active = False
        if active_resolved_name:
            # Compare by name, not by resolved path, to avoid marking symlinks as active
            is_active = file.name == active_resolved_name
        else:
            is_active = file.name == active_script
        
        scripts.append({
            'name': file.name,
            'path': str(file),
            'size': file.stat().st_size,
            'modified': file.stat().st_mtime,
            'active': is_active
        })
    
    return jsonify({'scripts': scripts, 'active': active_script})

@app.route('/api/bootstrap-script/<filename>')
def get_bootstrap_script(filename):
    """Get bootstrap script content"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        # Check if this script is the active one
        active_path = BOOTSTRAP_SCRIPT
        is_active = False
        if active_path.exists():
            try:
                if active_path.is_symlink():
                    is_active = script_path.resolve() == active_path.resolve()
                else:
                    is_active = script_path.name == active_path.name
            except:
                is_active = script_path.name == active_path.name
        
        return jsonify({
            'name': filename,
            'content': script_path.read_text(),
            'path': str(script_path),
            'active': is_active
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/bootstrap-script/<filename>/set-active', methods=['POST'])
def set_active_script(filename):
    """Set a bootstrap script as active"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        # Create symlink or copy to bootstrap.py
        target = BOOTSTRAP_SCRIPT
        if target.exists() and target.is_symlink():
            target.unlink()
        elif target.exists():
            # Backup existing bootstrap.py
            backup = CONFIG_DIR / f'bootstrap_backup_{int(target.stat().st_mtime)}.py'
            target.rename(backup)
        
        # Create symlink to the selected script
        target.symlink_to(script_path.name)
        
        return jsonify({
            'success': True,
            'message': f'{filename} is now the active bootstrap script',
            'active': filename
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/bootstrap-script/upload', methods=['POST'])
def upload_bootstrap_script():
    """Upload a new bootstrap script"""
    try:
        if 'file' not in request.files:
            return jsonify({'error': 'No file provided'}), 400
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({'error': 'No file selected'}), 400
        
        if not file.filename.endswith('.py'):
            return jsonify({'error': 'File must be a Python script (.py)'}), 400
        
        # Save file
        filename = file.filename
        if not filename.startswith('bootstrap'):
            filename = f'bootstrap_{filename}'
        
        file_path = CONFIG_DIR / filename
        
        # Try to save with proper error handling
        try:
            file.save(str(file_path))
            # Set permissions - try with subprocess if direct chmod fails
            try:
                file_path.chmod(0o644)
            except PermissionError:
                # Try using chmod command
                subprocess.run(['chmod', '644', str(file_path)], check=False)
        except PermissionError as e:
            return jsonify({'error': f'Permission denied: {str(e)}. Directory may need write permissions.'}), 500
        except OSError as e:
            return jsonify({'error': f'File system error: {str(e)}'}), 500
        
        return jsonify({
            'success': True,
            'message': f'Script {filename} uploaded successfully',
            'filename': filename,
            'path': str(file_path)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/status')
def get_status():
    """Get service status"""
    try:
        # Check if pod service is running via systemd
        container_running = False
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', '--quiet', 'ztpbootstrap-pod.service'],
                capture_output=True,
                text=True,
                timeout=2
            )
            container_running = result.returncode == 0
        except:
            # Fallback: check if we can reach nginx
            try:
                import urllib.request
                urllib.request.urlopen('http://127.0.0.1/health', timeout=1)
                container_running = True
            except:
                pass
        
        # Check health endpoint
        health_ok = False
        try:
            import urllib.request
            response = urllib.request.urlopen('http://127.0.0.1/health', timeout=2)
            health_ok = response.status == 200 and response.read().decode().strip() == 'healthy'
        except:
            pass
        
        return jsonify({
            'container_running': container_running,
            'health_ok': health_ok,
            'config_exists': CONFIG_FILE.exists(),
            'bootstrap_script_exists': BOOTSTRAP_SCRIPT.exists()
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/logs')
def get_logs():
    """Get recent logs"""
    try:
        # Try to get logs from systemd services
        logs = []
        services = ['ztpbootstrap-pod.service', 'ztpbootstrap-nginx.service', 'ztpbootstrap-webui.service']
        
        for service in services:
            try:
                result = subprocess.run(
                    ['journalctl', '-u', service, '-n', '20', '--no-pager', '--no-hostname'],
                    capture_output=True,
                    text=True,
                    timeout=2
                )
                if result.stdout.strip():
                    logs.append(f"=== {service} ===")
                    logs.append(result.stdout)
            except:
                pass
        
        if not logs:
            logs = ['No logs available. Services may not be running or journalctl is not accessible.']
        
        return jsonify({'logs': '\n'.join(logs)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    # Run on all interfaces (accessible from nginx container in pod)
    app.run(host='0.0.0.0', port=5000, debug=False)
