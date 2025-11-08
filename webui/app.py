#!/usr/bin/env python3
"""
Simple Web UI for ZTP Bootstrap Service
Lightweight Flask application for configuration and monitoring
"""

import json
import os
import re
import subprocess
import time
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from flask import Flask, render_template, request, jsonify, send_from_directory

app = Flask(__name__)

# Configuration paths
CONFIG_DIR = Path(os.environ.get('ZTP_CONFIG_DIR', '/opt/containerdata/ztpbootstrap'))
CONFIG_FILE = CONFIG_DIR / 'config.yaml'
BOOTSTRAP_SCRIPT = CONFIG_DIR / 'bootstrap.py'
NGINX_CONF = CONFIG_DIR / 'nginx.conf'
SCRIPTS_METADATA = CONFIG_DIR / 'scripts_metadata.json'
DEVICE_CONNECTIONS_FILE = CONFIG_DIR / 'device_connections.json'
# Try shared volume first, then container path
NGINX_ACCESS_LOG = Path('/var/log/nginx/ztpbootstrap_access.log')
NGINX_ERROR_LOG = Path('/var/log/nginx/ztpbootstrap_error.log')
# Fallback to config directory if mounted there
if not NGINX_ACCESS_LOG.exists():
    NGINX_ACCESS_LOG = CONFIG_DIR / 'logs' / 'ztpbootstrap_access.log'
if not NGINX_ERROR_LOG.exists():
    NGINX_ERROR_LOG = CONFIG_DIR / 'logs' / 'ztpbootstrap_error.log'

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

def load_scripts_metadata():
    """Load scripts metadata from JSON file"""
    if SCRIPTS_METADATA.exists():
        try:
            with open(SCRIPTS_METADATA, 'r') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_scripts_metadata(metadata):
    """Save scripts metadata to JSON file"""
    try:
        with open(SCRIPTS_METADATA, 'w') as f:
            json.dump(metadata, f, indent=2)
        return True
    except Exception as e:
        print(f"Error saving metadata: {e}")
        return False

def cleanup_old_backups():
    """Keep only the 5 most recent backup files, delete older ones"""
    try:
        script_dir = CONFIG_DIR
        backup_files = []
        
        # Find all backup files
        for file in script_dir.glob('bootstrap_backup_*.py'):
            try:
                backup_files.append((file.stat().st_mtime, file))
            except OSError:
                continue
        
        # Sort by modification time (newest first)
        backup_files.sort(key=lambda x: x[0], reverse=True)
        
        # Keep only the 5 most recent, delete the rest
        if len(backup_files) > 5:
            for mtime, backup_file in backup_files[5:]:
                try:
                    backup_file.unlink()
                    print(f"Deleted old backup: {backup_file.name}")
                except OSError as e:
                    print(f"Error deleting backup {backup_file.name}: {e}")
    except Exception as e:
        print(f"Error cleaning up backups: {e}")

@app.route('/api/bootstrap-scripts')
def list_bootstrap_scripts():
    """List available bootstrap scripts"""
    scripts = []
    script_dir = CONFIG_DIR
    active_script = None
    metadata = load_scripts_metadata()
    
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
        # Skip backup files (they shouldn't be shown in the UI)
        if file.name.startswith('bootstrap_backup_'):
            continue
        
        # Skip symlink loops (symlinks pointing to themselves)
        try:
            if file.is_symlink():
                resolved = file.resolve()
                if resolved == file:
                    # Symlink loop detected, skip this file
                    continue
        except (OSError, RuntimeError):
            # Error resolving symlink (loop or broken), skip this file
            continue
        
        # Only mark as active if this file's NAME matches the resolved target name
        # This ensures only the actual target file is marked active, not the symlink
        is_active = False
        if active_resolved_name:
            # Compare by name, not by resolved path, to avoid marking symlinks as active
            is_active = file.name == active_resolved_name
        else:
            is_active = file.name == active_script
        
        try:
            # For bootstrap.py, if it's a symlink, we still want to show it
            # but we'll mark the target as active instead
            file_stat = file.stat()
            script_meta = metadata.get(file.name, {})
            scripts.append({
                'name': file.name,
                'path': str(file),
                'size': file_stat.st_size,
                'modified': file_stat.st_mtime,
                'active': is_active
            })
        except OSError as e:
            # Skip files that can't be stat'd (e.g., symlink loops)
            continue
    
    # Always include bootstrap.py in the list if it exists (even as symlink)
    # This ensures it's visible even when it's a symlink to another file
    bootstrap_py_path = script_dir / 'bootstrap.py'
    if bootstrap_py_path.exists() and not any(s['name'] == 'bootstrap.py' for s in scripts):
        try:
            is_active = False
            if active_resolved_name:
                # If bootstrap.py is a symlink, check if its target matches
                if bootstrap_py_path.is_symlink():
                    try:
                        resolved = bootstrap_py_path.resolve()
                        is_active = resolved.name == active_resolved_name
                    except:
                        pass
                else:
                    is_active = 'bootstrap.py' == active_resolved_name
            else:
                is_active = 'bootstrap.py' == active_script
            
            file_stat = bootstrap_py_path.stat()
            script_meta = metadata.get('bootstrap.py', {})
            scripts.append({
                'name': 'bootstrap.py',
                'path': str(bootstrap_py_path),
                'size': file_stat.st_size,
                'modified': file_stat.st_mtime,
                'active': is_active
            })
        except OSError:
            pass
    
    # Sort scripts: active script first, then by name
    scripts.sort(key=lambda x: (not x['active'], x['name']))
    
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
        
        # Special case: if setting bootstrap.py as active, ensure it's a regular file
        if filename == 'bootstrap.py':
            target = BOOTSTRAP_SCRIPT
            
            # If bootstrap.py doesn't exist, we need to find what it should point to
            # or create it from another file. But if the user is clicking on bootstrap.py,
            # it should exist (either as file or symlink)
            if not script_path.exists():
                return jsonify({'error': 'bootstrap.py not found. Please set another script as active first.'}), 404
            
            # Resolve the source file path before potentially removing the symlink
            source_file = script_path
            if script_path.is_symlink():
                try:
                    # Get the actual target file that the symlink points to
                    source_file = script_path.resolve()
                    if not source_file.exists():
                        return jsonify({'error': f'Symlink target not found: {source_file}'}), 404
                except (OSError, RuntimeError) as e:
                    return jsonify({'error': f'Cannot resolve symlink: {str(e)}'}), 500
            
            # If bootstrap.py is a symlink, remove it first
            if target.exists() and target.is_symlink():
                try:
                    target.unlink()
                except (OSError, RuntimeError):
                    pass
            
            # Copy the source file to bootstrap.py
            import shutil
            try:
                shutil.copy2(source_file, target)
            except (OSError, shutil.Error) as e:
                return jsonify({'error': f'Failed to copy file: {str(e)}'}), 500
            
            return jsonify({
                'success': True,
                'message': 'bootstrap.py is now the active bootstrap script',
                'active': 'bootstrap.py'
            })
        
        # For other scripts, create symlink to bootstrap.py
        target = BOOTSTRAP_SCRIPT
        if target.exists() and target.is_symlink():
            target.unlink()
        elif target.exists():
            # Backup existing bootstrap.py
            backup = CONFIG_DIR / f'bootstrap_backup_{int(target.stat().st_mtime)}.py'
            target.rename(backup)
            # Clean up old backups, keeping only the 5 most recent
            cleanup_old_backups()
        
        # Create symlink to the selected script
        target.symlink_to(script_path.name)
        
        return jsonify({
            'success': True,
            'message': f'{filename} is now the active bootstrap script',
            'active': filename
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/bootstrap-script/<filename>/rename', methods=['POST'])
def rename_bootstrap_script(filename):
    """Rename a bootstrap script"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        data = request.get_json()
        new_name = data.get('new_name', '').strip()
        
        if not new_name:
            return jsonify({'error': 'New name is required'}), 400
        
        # Validate new name
        if not new_name.endswith('.py'):
            return jsonify({'error': 'New name must end with .py'}), 400
        
        # Ensure it starts with bootstrap
        if not new_name.startswith('bootstrap'):
            new_name = f'bootstrap_{new_name}'
        
        # Check if new name already exists
        new_path = CONFIG_DIR / new_name
        if new_path.exists() and new_path != script_path:
            return jsonify({'error': f'A script with the name {new_name} already exists'}), 400
        
        # Prevent renaming the active script (bootstrap.py)
        active_path = BOOTSTRAP_SCRIPT
        if active_path.exists():
            try:
                if active_path.is_symlink():
                    resolved = active_path.resolve()
                    if resolved == script_path.resolve():
                        return jsonify({'error': 'Cannot rename the active script. Set another script as active first.'}), 400
                elif active_path.resolve() == script_path.resolve():
                    return jsonify({'error': 'Cannot rename bootstrap.py when it is the active script. Set another script as active first.'}), 400
            except (OSError, RuntimeError):
                pass
        
        # Rename the file
        try:
            script_path.rename(new_path)
            
            # Update metadata if it exists
            metadata = load_scripts_metadata()
            if filename in metadata:
                metadata[new_name] = metadata.pop(filename)
                save_scripts_metadata(metadata)
            
            return jsonify({
                'success': True,
                'message': f'Script renamed from {filename} to {new_name}',
                'old_name': filename,
                'new_name': new_name
            })
        except OSError as e:
            return jsonify({'error': f'Failed to rename file: {str(e)}'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/bootstrap-script/<filename>', methods=['DELETE'])
def delete_bootstrap_script(filename):
    """Delete a bootstrap script"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        # Prevent deleting bootstrap.py if it's the active script (not a symlink)
        if filename == 'bootstrap.py':
            target = BOOTSTRAP_SCRIPT
            if target.exists() and not target.is_symlink():
                return jsonify({'error': 'Cannot delete bootstrap.py when it is the active script. Set another script as active first.'}), 400
        
        # Check if this script is currently active
        active_path = BOOTSTRAP_SCRIPT
        if active_path.exists():
            try:
                if active_path.is_symlink():
                    resolved = active_path.resolve()
                    if resolved == script_path.resolve():
                        return jsonify({'error': 'Cannot delete the active script. Set another script as active first.'}), 400
                elif active_path.resolve() == script_path.resolve():
                    return jsonify({'error': 'Cannot delete the active script. Set another script as active first.'}), 400
            except (OSError, RuntimeError):
                pass
        
        # Delete the file
        try:
            script_path.unlink()
        except OSError as e:
            return jsonify({'error': f'Failed to delete file: {str(e)}'}), 500
        
        return jsonify({
            'success': True,
            'message': f'Script {filename} deleted successfully'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/bootstrap-scripts/backups')
def list_backup_scripts():
    """List backup bootstrap scripts"""
    backups = []
    script_dir = CONFIG_DIR
    
    for file in script_dir.glob('bootstrap_backup_*.py'):
        try:
            stat = file.stat()
            # Extract timestamp from filename (bootstrap_backup_TIMESTAMP.py)
            timestamp_str = file.stem.replace('bootstrap_backup_', '')
            try:
                timestamp = int(timestamp_str)
                from datetime import datetime
                dt = datetime.fromtimestamp(timestamp)
                human_date = dt.strftime('%Y-%m-%d %H:%M:%S')
            except (ValueError, OSError):
                # Fallback to file modification time
                from datetime import datetime
                dt = datetime.fromtimestamp(stat.st_mtime)
                human_date = dt.strftime('%Y-%m-%d %H:%M:%S')
            
            backups.append({
                'name': file.name,
                'path': str(file),
                'size': stat.st_size,
                'modified': stat.st_mtime,
                'human_date': human_date,
                'timestamp': timestamp if 'timestamp' in locals() else int(stat.st_mtime)
            })
        except OSError:
            continue
    
    # Sort by timestamp (newest first)
    backups.sort(key=lambda x: x['timestamp'], reverse=True)
    
    return jsonify({'backups': backups})

@app.route('/api/bootstrap-script/backup/<filename>/restore', methods=['POST'])
def restore_backup_script(filename):
    """Restore a backup script"""
    try:
        # Validate filename is a backup
        if not filename.startswith('bootstrap_backup_') or not filename.endswith('.py'):
            return jsonify({'error': 'Invalid backup filename'}), 400
        
        backup_path = CONFIG_DIR / filename
        if not backup_path.exists():
            return jsonify({'error': 'Backup not found'}), 404
        
        # Get restore option from request
        data = request.get_json() or {}
        restore_as = data.get('restore_as', 'new')  # 'new' or 'active'
        
        if restore_as == 'active':
            # Restore as bootstrap.py (active)
            target = BOOTSTRAP_SCRIPT
            import shutil
            shutil.copy2(backup_path, target)
            return jsonify({
                'success': True,
                'message': f'Backup {filename} restored as bootstrap.py (active)',
                'restored_as': 'active'
            })
        else:
            # Restore as a new script with a cleaned name
            # Extract original name or create a new one
            from datetime import datetime
            timestamp_str = filename.replace('bootstrap_backup_', '').replace('.py', '')
            try:
                timestamp = int(timestamp_str)
                dt = datetime.fromtimestamp(timestamp)
                new_name = f"bootstrap_restored_{dt.strftime('%Y%m%d_%H%M%S')}.py"
            except:
                new_name = f"bootstrap_restored_{int(time.time())}.py"
            
            new_path = CONFIG_DIR / new_name
            import shutil
            shutil.copy2(backup_path, new_path)
            return jsonify({
                'success': True,
                'message': f'Backup {filename} restored as {new_name}',
                'restored_as': 'new',
                'new_filename': new_name
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

def load_device_connections():
    """Load device connection data from JSON file"""
    if DEVICE_CONNECTIONS_FILE.exists():
        try:
            with open(DEVICE_CONNECTIONS_FILE, 'r') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_device_connections(connections):
    """Save device connection data to JSON file"""
    try:
        with open(DEVICE_CONNECTIONS_FILE, 'w') as f:
            json.dump(connections, f, indent=2)
        return True
    except Exception as e:
        print(f"Error saving device connections: {e}")
        return False

def parse_nginx_access_log():
    """Parse nginx access log to track device connections"""
    connections = load_device_connections()
    current_time = time.time()
    
    # Track which log lines we've already processed
    processed_lines_file = CONFIG_DIR / 'processed_log_lines.txt'
    processed_lines = set()
    if processed_lines_file.exists():
        try:
            with open(processed_lines_file, 'r') as f:
                processed_lines = set(line.strip() for line in f if line.strip())
        except:
            pass
    
    # Nginx log format: IP - - [timestamp] "method path protocol" status size "referer" "user-agent"
    # Example: 10.0.2.15 - - [08/Nov/2025:12:00:00 +0000] "GET /bootstrap.py HTTP/1.1" 200 1234 "-" "Arista-ZTP/1.0"
    
    if not NGINX_ACCESS_LOG.exists():
        return connections
    
    try:
        # Read last 1000 lines to avoid processing too much
        with open(NGINX_ACCESS_LOG, 'r') as f:
            lines = f.readlines()
            recent_lines = lines[-1000:] if len(lines) > 1000 else lines
        
        new_processed_lines = set()
        for line in recent_lines:
            line_stripped = line.strip()
            # Skip if we've already processed this line
            if line_stripped in processed_lines:
                new_processed_lines.add(line_stripped)
                continue
            
            # Parse log line
            # Match: IP - - [timestamp] "method path protocol" status size "referer" "user-agent"
            match = re.match(r'^(\S+) - - \[([^\]]+)\] "(\S+) (\S+) ([^"]+)" (\d+) (\S+) "([^"]*)" "([^"]*)"', line)
            if not match:
                new_processed_lines.add(line_stripped)
                continue
            
            ip = match.group(1)
            timestamp_str = match.group(2)
            method = match.group(3)
            path = match.group(4)
            status = int(match.group(6))
            user_agent = match.group(9)
            
            # Skip health checks, UI requests, and API requests (WebUI's own requests)
            if (path in ['/health', '/ui', '/api'] or 
                path.startswith('/ui/') or 
                path.startswith('/api/') or
                '/api/' in path or
                user_agent and ('Mozilla' in user_agent or 'Gecko' in user_agent or 'Chrome' in user_agent or 'Safari' in user_agent)):
                # Mark as processed but don't count
                new_processed_lines.add(line_stripped)
                continue
            
            # Parse timestamp (format: 08/Nov/2025:12:00:00 +0000)
            try:
                dt = datetime.strptime(timestamp_str.split()[0], '%d/%b/%Y:%H:%M:%S')
                timestamp = dt.timestamp()
            except:
                continue
            
            # Initialize device entry if not exists
            if ip not in connections:
                connections[ip] = {
                    'ip': ip,
                    'first_seen': timestamp,
                    'last_seen': timestamp,
                    'bootstrap_downloaded': False,
                    'bootstrap_download_time': None,
                    'session_start': timestamp,
                    'session_end': timestamp,
                    'total_requests': 0,
                    'user_agent': user_agent,
                    'sessions': []
                }
            
            device = connections[ip]
            device['last_seen'] = timestamp
            device['total_requests'] = device.get('total_requests', 0) + 1
            
            # Track bootstrap.py downloads
            if path == '/bootstrap.py' and status == 200:
                device['bootstrap_downloaded'] = True
                if not device['bootstrap_download_time'] or timestamp > device['bootstrap_download_time']:
                    device['bootstrap_download_time'] = timestamp
            
            # Track sessions (requests within 5 minutes are considered same session)
            if device['sessions']:
                last_session = device['sessions'][-1]
                if timestamp - last_session['end'] < 300:  # 5 minutes
                    last_session['end'] = timestamp
                    last_session['requests'] += 1
                else:
                    # New session
                    device['sessions'].append({
                        'start': timestamp,
                        'end': timestamp,
                        'requests': 1
                    })
            else:
                device['sessions'].append({
                    'start': timestamp,
                    'end': timestamp,
                    'requests': 1
                })
            
            # Keep only last 50 sessions per device
            if len(device['sessions']) > 50:
                device['sessions'] = device['sessions'][-50:]
            
            # Mark this line as processed
            new_processed_lines.add(line_stripped)
        
        # Save processed lines (keep only last 2000 to avoid file growing too large)
        all_processed = processed_lines | new_processed_lines
        if len(all_processed) > 2000:
            # Keep only the most recent 2000
            all_processed = set(list(all_processed)[-2000:])
        
        try:
            with open(processed_lines_file, 'w') as f:
                for line in sorted(all_processed):
                    f.write(line + '\n')
        except Exception as e:
            print(f"Error saving processed lines: {e}")
        
        # Clean up old devices (not seen in 24 hours)
        cutoff_time = current_time - 86400  # 24 hours
        connections = {ip: data for ip, data in connections.items() 
                      if data['last_seen'] > cutoff_time}
        
        save_device_connections(connections)
        return connections
    except Exception as e:
        print(f"Error parsing nginx log: {e}")
        return connections

@app.route('/api/logs')
def get_logs():
    """Get recent logs from specified source"""
    try:
        log_source = request.args.get('source', 'container')
        lines = int(request.args.get('lines', 100))
        
        logs = []
        
        if log_source == 'nginx_access':
            # Try multiple paths - works with both host networking and macvlan
            # The logs are mounted as a volume, so we should be able to read them directly
            log_paths = [
                Path('/var/log/nginx/ztpbootstrap_access.log'),  # Mounted volume path
                CONFIG_DIR / 'logs' / 'ztpbootstrap_access.log',  # Alternative path
            ]
            
            log_found = False
            for log_path in log_paths:
                if log_path.exists():
                    try:
                        with open(log_path, 'r') as f:
                            all_lines = f.readlines()
                            recent_lines = all_lines[-lines:] if len(all_lines) > lines else all_lines
                            # Filter out UI/API requests to reduce noise
                            filtered_lines = []
                            for line in recent_lines:
                                # Skip UI and API requests (they're not interesting for device tracking)
                                if '/ui/' not in line and '/api/' not in line and ' /ui ' not in line and ' /api ' not in line:
                                    filtered_lines.append(line)
                            logs = ''.join(filtered_lines) if filtered_lines else "No device requests found in recent log entries (UI/API requests filtered out)"
                            log_found = True
                            break
                    except Exception as e:
                        logs = f"Error reading nginx access log from {log_path}: {str(e)}"
                        log_found = True
                        break
            
            if not log_found:
                # Fallback: Try to read from nginx container via podman exec
                # This works regardless of networking mode if podman is accessible
                try:
                    result = subprocess.run(
                        ['podman', 'exec', 'ztpbootstrap-nginx', 'tail', '-n', str(lines), '/var/log/nginx/ztpbootstrap_access.log'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    if result.returncode == 0 and result.stdout.strip():
                        # Filter out UI/API requests
                        all_lines = result.stdout.split('\n')
                        filtered_lines = [line for line in all_lines if '/ui/' not in line and '/api/' not in line and ' /ui ' not in line and ' /api ' not in line]
                        logs = '\n'.join(filtered_lines) if filtered_lines else "No device requests found in recent log entries (UI/API requests filtered out)"
                    else:
                        logs = f"Nginx access log not found. Checked paths: {', '.join(str(p) for p in log_paths)}"
                except FileNotFoundError:
                    logs = f"Nginx access log not accessible. Podman not available. Checked paths: {', '.join(str(p) for p in log_paths)}"
                except Exception as e:
                    logs = f"Error accessing nginx access log: {str(e)}"
        
        elif log_source == 'nginx_error':
            # Try multiple paths - works with both host networking and macvlan
            # The logs are mounted as a volume, so we should be able to read them directly
            log_paths = [
                Path('/var/log/nginx/ztpbootstrap_error.log'),  # Mounted volume path
                CONFIG_DIR / 'logs' / 'ztpbootstrap_error.log',  # Alternative path
            ]
            
            log_found = False
            for log_path in log_paths:
                if log_path.exists():
                    try:
                        with open(log_path, 'r') as f:
                            all_lines = f.readlines()
                            recent_lines = all_lines[-lines:] if len(all_lines) > lines else all_lines
                            logs = ''.join(recent_lines)
                            log_found = True
                            break
                    except Exception as e:
                        logs = f"Error reading nginx error log from {log_path}: {str(e)}"
                        log_found = True
                        break
            
            if not log_found:
                # Fallback: Try to read from nginx container via podman exec
                # This works regardless of networking mode if podman is accessible
                try:
                    result = subprocess.run(
                        ['podman', 'exec', 'ztpbootstrap-nginx', 'tail', '-n', str(lines), '/var/log/nginx/ztpbootstrap_error.log'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    logs = result.stdout if result.returncode == 0 and result.stdout.strip() else f"Error: {result.stderr or 'No log content'}"
                except FileNotFoundError:
                    logs = f"Nginx error log not accessible. Podman not available. Checked paths: {', '.join(str(p) for p in log_paths)}"
                except Exception as e:
                    logs = f"Error accessing nginx error log: {str(e)}"
        
        # Handle container logs (default) - only if not nginx_access or nginx_error
        if log_source not in ['nginx_access', 'nginx_error']:
            # Try to get container logs using multiple methods
            # Works with both host networking and macvlan approaches
            log_parts = []
            containers = {
                'ztpbootstrap-pod.service': 'ztpbootstrap-pod-infra',
                'ztpbootstrap-nginx.service': 'ztpbootstrap-nginx',
                'ztpbootstrap-webui.service': 'ztpbootstrap-webui'
            }
            
            for service, container_name in containers.items():
                log_parts.append(f"=== {service} ===")
                container_logs = None
                
                # Method 1: Try podman logs (works if podman socket is accessible)
                try:
                    result = subprocess.run(
                        ['podman', 'logs', '--tail', str(lines // len(containers)), container_name],
                        capture_output=True,
                        text=True,
                        timeout=3
                    )
                    if result.returncode == 0 and result.stdout.strip():
                        container_logs = result.stdout.strip()
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    pass
                except Exception:
                    pass
                
                # Method 2: Try journalctl (works if journal is accessible)
                if not container_logs:
                    try:
                        journal_result = subprocess.run(
                            ['journalctl', '-u', service, '-n', str(lines // len(containers)), '--no-pager', '--no-hostname'],
                            capture_output=True,
                            text=True,
                            timeout=3
                        )
                        if journal_result.returncode == 0 and journal_result.stdout.strip():
                            container_logs = journal_result.stdout.strip()
                    except (FileNotFoundError, subprocess.TimeoutExpired):
                        pass
                    except Exception:
                        pass
                
                if container_logs:
                    log_parts.append(container_logs)
                else:
                    log_parts.append(f"Container: {container_name}")
                    log_parts.append("Logs not available from within container.")
                log_parts.append("")
            
            if log_parts:
                logs = '\n'.join(log_parts)
                # Only show help message if no logs were retrieved
                if "Logs not available from within container" in logs:
                    logs += '\nTo view logs from the host:\n'
                    logs += '  sudo journalctl -u ztpbootstrap-pod.service -n 50\n'
                    logs += '  sudo journalctl -u ztpbootstrap-nginx.service -n 50\n'
                    logs += '  sudo journalctl -u ztpbootstrap-webui.service -n 50\n\n'
                    logs += 'Or use podman logs:\n'
                    logs += '  sudo podman logs ztpbootstrap-nginx --tail 50\n'
                    logs += '  sudo podman logs ztpbootstrap-webui --tail 50\n'
            else:
                logs = 'Container logs are not available from within the container.'
        
        if not logs:
            logs = 'No logs available'
        
        return jsonify({'logs': logs, 'source': log_source})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/logs/mark', methods=['POST'])
def mark_logs():
    """Insert a MARK line into the nginx logs"""
    try:
        from datetime import datetime
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')
        mark_line = f'===== MARK: {timestamp} =====\n'
        
        # Get which log source to mark (default to both)
        log_source = request.args.get('source', 'both')
        errors = []
        
        # Write MARK to nginx access log
        if log_source in ['both', 'nginx_access', 'access']:
            if NGINX_ACCESS_LOG.exists():
                try:
                    with open(NGINX_ACCESS_LOG, 'a') as f:
                        f.write(mark_line)
                except Exception as e:
                    errors.append(f'Failed to write MARK to access log: {str(e)}')
            else:
                # Try to write via podman exec
                try:
                    result = subprocess.run(
                        ['podman', 'exec', 'ztpbootstrap-nginx', 'sh', '-c', f'echo "{mark_line.strip()}" >> /var/log/nginx/ztpbootstrap_access.log'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    if result.returncode != 0:
                        errors.append(f'Failed to write MARK to access log: {result.stderr}')
                except Exception as e:
                    errors.append(f'Failed to write MARK to access log: {str(e)}')
        
        # Write MARK to nginx error log
        if log_source in ['both', 'nginx_error', 'error']:
            if NGINX_ERROR_LOG.exists():
                try:
                    with open(NGINX_ERROR_LOG, 'a') as f:
                        f.write(mark_line)
                except Exception as e:
                    errors.append(f'Failed to write MARK to error log: {str(e)}')
            else:
                # Try to write via podman exec
                try:
                    result = subprocess.run(
                        ['podman', 'exec', 'ztpbootstrap-nginx', 'sh', '-c', f'echo "{mark_line.strip()}" >> /var/log/nginx/ztpbootstrap_error.log'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    if result.returncode != 0:
                        errors.append(f'Failed to write MARK to error log: {result.stderr}')
                except Exception as e:
                    errors.append(f'Failed to write MARK to error log: {str(e)}')
        
        if errors:
            return jsonify({'error': '; '.join(errors)}), 500
        
        return jsonify({
            'success': True,
            'message': f'MARK inserted at {timestamp}',
            'timestamp': timestamp
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/device-connections')
def get_device_connections():
    """Get device connection data"""
    try:
        # Parse nginx logs to update connection data
        connections = parse_nginx_access_log()
        
        # Format for frontend
        devices = []
        for ip, data in connections.items():
            # Calculate session duration
            sessions = data.get('sessions', [])
            total_duration = sum(s['end'] - s['start'] for s in sessions)
            last_session_duration = sessions[-1]['end'] - sessions[-1]['start'] if sessions else 0
            
            devices.append({
                'ip': ip,
                'first_seen': data['first_seen'],
                'last_seen': data['last_seen'],
                'bootstrap_downloaded': data.get('bootstrap_downloaded', False),
                'bootstrap_download_time': data.get('bootstrap_download_time'),
                'total_requests': data.get('total_requests', 0),
                'total_sessions': len(sessions),
                'total_duration': total_duration,
                'last_session_duration': last_session_duration,
                'user_agent': data.get('user_agent', 'Unknown')
            })
        
        # Sort by last seen (most recent first)
        devices.sort(key=lambda x: x['last_seen'], reverse=True)
        
        return jsonify({'devices': devices})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    # Run on all interfaces (accessible from nginx container in pod)
    app.run(host='0.0.0.0', port=5000, debug=False)
