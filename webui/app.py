#!/usr/bin/env python3
"""
Simple Web UI for ZTP Bootstrap Service
Lightweight Flask application for configuration and monitoring
"""

import json
import os
import subprocess
import time
from pathlib import Path
from flask import Flask, render_template, request, jsonify, send_from_directory

app = Flask(__name__)

# Configuration paths
CONFIG_DIR = Path(os.environ.get('ZTP_CONFIG_DIR', '/opt/containerdata/ztpbootstrap'))
CONFIG_FILE = CONFIG_DIR / 'config.yaml'
BOOTSTRAP_SCRIPT = CONFIG_DIR / 'bootstrap.py'
NGINX_CONF = CONFIG_DIR / 'nginx.conf'
SCRIPTS_METADATA = CONFIG_DIR / 'scripts_metadata.json'

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

def regenerate_nginx_config():
    """Regenerate nginx config based on script metadata"""
    if not NGINX_CONF.exists():
        print(f"Nginx config not found: {NGINX_CONF}")
        return False
    
    try:
        import re
        
        # Read current nginx config
        with open(NGINX_CONF, 'r') as f:
            config_content = f.read()
        
        # Load metadata
        metadata = load_scripts_metadata()
        
        # Find all scripts that should be served as their filename
        scripts_as_filename = []
        for filename, meta in metadata.items():
            if meta.get('serve_as_filename', False):
                script_path = CONFIG_DIR / filename
                if script_path.exists() and script_path.suffix == '.py':
                    scripts_as_filename.append(filename)
        
        # Remove any existing specific location blocks for scripts (to avoid duplicates)
        # Use a more robust approach: find all location blocks for bootstrap*.py and remove them
        # Match from comment to closing brace, handling nested braces correctly
        lines = config_content.split('\n')
        new_lines = []
        skip_until_brace = False
        brace_count = 0
        i = 0
        while i < len(lines):
            line = lines[i]
            # Check if this is a location block we want to remove
            if re.match(r'\s*# Serve bootstrap.*?\.py as its filename', line):
                # Skip the comment line
                i += 1
                # Skip the location line and count braces
                if i < len(lines) and 'location = /bootstrap' in lines[i] and '{' in lines[i]:
                    brace_count = lines[i].count('{') - lines[i].count('}')
                    i += 1
                    # Skip until we find the matching closing brace
                    while i < len(lines) and brace_count > 0:
                        brace_count += lines[i].count('{') - lines[i].count('}')
                        i += 1
                    # Skip the blank line after if present
                    if i < len(lines) and lines[i].strip() == '':
                        i += 1
                    continue
            
            # Also update the nested location ~* \.py$ block in default server block
            # to exclude scripts that have specific location blocks
            if 'location ~* \\.py$' in line and 'Set proper MIME type for Python scripts' in '\n'.join(lines[max(0, i-3):i]):
                # This is the nested location block in default server block
                # We need to add the if statement to skip scripts with specific location blocks
                # Find the scripts that should be excluded
                scripts_to_exclude = []
                for filename, meta in metadata.items():
                    if meta.get('serve_as_filename', False):
                        scripts_to_exclude.append(filename.replace('.py', '').replace('bootstrap-', 'bootstrap-').replace('bootstrap', 'bootstrap'))
                # We'll handle this after we've processed all lines
                pass
            new_lines.append(line)
            i += 1
        config_content = '\n'.join(new_lines)
        
        # Generate location blocks for scripts that should be served as their filename
        # These need to come BEFORE the location / block (at the same level, not nested)
        location_blocks = []
        for filename in sorted(scripts_as_filename):
            # URL-encode filename for RFC 5987 format
            import urllib.parse
            filename_encoded = urllib.parse.quote(filename, safe='')
            # Also encode for standard format to handle special characters like hyphens
            filename_quoted = urllib.parse.quote(filename, safe='')
            # Proxy to Flask app's download endpoint for reliable filename handling
            # Use a URL that doesn't expose the filename in the path to avoid browser extraction
            # Use /d/ prefix to make it less obvious what the filename is
            location_blocks.append(f'''    # Serve {filename} as its filename via Flask download endpoint
    location = /{filename} {{
        # Use internal redirect to a path that doesn't expose the filename
        # This prevents browsers from extracting filename from URL path
        rewrite ^ /d/{filename}? break;
        proxy_pass http://127.0.0.1:5000/download/{filename};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout 5s;
        proxy_read_timeout 5s;
        # Ensure Flask's headers are passed through
        proxy_pass_header Content-Disposition;
        proxy_pass_header Content-Type;
    }}''')
        
        # Pattern to match the location / block (we need to insert before it)
        # Look for "location / {" that's at the start of a line with proper indentation
        # We need to insert before BOTH server blocks (main and default)
        location_root_pattern = r'(    # Main location block[^\n]*\n    location / \{|    # Main location block - serve content instead of returning 444\n    location / \{)'
        
        # Insert location blocks before the location / block in both server blocks
        if location_blocks:
            replacement = '\n'.join(location_blocks) + '\n\n    ' + r'\1'
            new_config = re.sub(location_root_pattern, replacement, config_content, flags=re.MULTILINE)
        else:
            new_config = config_content
        
        # Write updated config
        with open(NGINX_CONF, 'w') as f:
            f.write(new_config)
        
        # Try to reload/restart nginx to pick up config changes
        # Since we're in a pod, try to reload via podman exec or restart the container
        reloaded = False
        try:
            # First try to reload nginx (less disruptive)
            result = subprocess.run(
                ['podman', 'exec', 'ztpbootstrap-nginx', 'nginx', '-s', 'reload'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                reloaded = True
        except:
            pass
        
        if not reloaded:
            try:
                # If reload fails, restart the container (more disruptive but ensures config is picked up)
                result = subprocess.run(
                    ['podman', 'restart', 'ztpbootstrap-nginx'],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if result.returncode == 0:
                    reloaded = True
            except:
                pass
        
        if not reloaded:
            try:
                # Try systemctl reload as fallback
                result = subprocess.run(
                    ['systemctl', 'reload', 'ztpbootstrap-nginx.service'],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0:
                    reloaded = True
            except:
                pass
        
        if not reloaded:
            print("Warning: Could not reload/restart nginx automatically. Config updated but nginx needs manual restart.")
            # Don't fail - config is updated, just needs manual restart
        
        return True
    except Exception as e:
        print(f"Error regenerating nginx config: {e}")
        import traceback
        traceback.print_exc()
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
                'active': is_active,
                'serve_as_filename': script_meta.get('serve_as_filename', False)
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
                'active': is_active,
                'serve_as_filename': script_meta.get('serve_as_filename', False)
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

@app.route('/download/<filename>')
def download_bootstrap_script(filename):
    """Download bootstrap script with correct filename in Content-Disposition header"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        # Check metadata to see if this should be served as its filename
        metadata = load_scripts_metadata()
        script_meta = metadata.get(filename, {})
        serve_as_filename = script_meta.get('serve_as_filename', False)
        
        # Use Flask's send_file with as_attachment and download_name
        from flask import send_file, Response
        import urllib.parse
        
        download_name = filename if serve_as_filename else 'bootstrap.py'
        
        # Read the file content
        with open(script_path, 'rb') as f:
            content = f.read()
        
        # Create response with explicit Content-Disposition header
        # Use both standard format (with quotes) and RFC 5987 format for maximum compatibility
        # For filenames with hyphens, browsers may extract from URL, so we need to be very explicit
        filename_encoded = urllib.parse.quote(download_name, safe='')
        # Use both formats: standard with quotes, and RFC 5987
        # Some browsers prefer the RFC 5987 format when there are special characters
        content_disposition = f'attachment; filename="{download_name}"; filename*=UTF-8\'\'{filename_encoded}'
        
        response = Response(
            content,
            mimetype='text/plain; charset=utf-8',
            headers={
                'Content-Disposition': content_disposition,
                'X-Content-Type-Options': 'nosniff',
                'Cache-Control': 'no-cache, no-store, must-revalidate',
                'Pragma': 'no-cache',
                'Expires': '0',
                'Content-Length': str(len(content))
            }
        )
        return response
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

@app.route('/api/bootstrap-script/<filename>/serve-as-filename', methods=['POST'])
def set_serve_as_filename(filename):
    """Set whether a script should be served as its filename or as bootstrap.py"""
    try:
        script_path = CONFIG_DIR / filename
        if not script_path.exists() or not script_path.suffix == '.py':
            return jsonify({'error': 'Script not found'}), 404
        
        data = request.get_json()
        serve_as_filename = data.get('serve_as_filename', False)
        
        metadata = load_scripts_metadata()
        if filename not in metadata:
            metadata[filename] = {}
        metadata[filename]['serve_as_filename'] = bool(serve_as_filename)
        
        if save_scripts_metadata(metadata):
            # Regenerate nginx config based on updated metadata
            if regenerate_nginx_config():
                return jsonify({
                    'success': True,
                    'message': f'Script will be served as {"its filename" if serve_as_filename else "bootstrap.py"}',
                    'serve_as_filename': serve_as_filename
                })
            else:
                return jsonify({
                    'success': True,
                    'message': f'Metadata updated, but nginx config update failed. Script will be served as {"its filename" if serve_as_filename else "bootstrap.py"} after manual nginx reload.',
                    'serve_as_filename': serve_as_filename,
                    'warning': 'nginx config update failed'
                })
        else:
            return jsonify({'error': 'Failed to save metadata'}), 500
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
