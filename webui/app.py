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
                return jsonify(json.loads(result.stdout))
            except (subprocess.CalledProcessError, FileNotFoundError):
                # Fallback: read as text
                return jsonify({'raw': CONFIG_FILE.read_text()})
        else:
            return jsonify({'error': 'Config file not found'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/bootstrap-scripts')
def list_bootstrap_scripts():
    """List available bootstrap scripts"""
    scripts = []
    script_dir = CONFIG_DIR
    
    for file in script_dir.glob('bootstrap*.py'):
        scripts.append({
            'name': file.name,
            'path': str(file),
            'size': file.stat().st_size,
            'modified': file.stat().st_mtime
        })
    
    return jsonify({'scripts': scripts})

@app.route('/api/bootstrap-script/<filename>')
def get_bootstrap_script(filename):
    """Get bootstrap script content"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        return jsonify({
            'name': filename,
            'content': script_path.read_text(),
            'path': str(script_path)
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
