#!/usr/bin/env python3
import os
import re
import subprocess
from flask import Flask, render_template, request, jsonify, send_from_directory
from pathlib import Path

app = Flask(__name__, static_folder='static')

SCRIPT_DIR = Path(__file__).parent.absolute()
PROJECT_ROOT = SCRIPT_DIR.parent
CONFIG_FILE = PROJECT_ROOT / 'config' / 'stream.conf'
DEFAULTS_FILE = PROJECT_ROOT / 'config' / 'defaults.conf'
VERSION_FILE = PROJECT_ROOT / 'VERSION'

@app.route('/static/<path:filename>')
def static_files(filename):
    """Serve static files."""
    return send_from_directory('static', filename)

def get_version():
    """Get application version from VERSION file."""
    try:
        if VERSION_FILE.exists():
            return VERSION_FILE.read_text().strip()
    except:
        pass
    return "unknown"


def is_config_ready(config):
    """Check if configuration is ready for streaming."""
    rtmp = (config.get('RTMP_URL') or '').strip()
    if not rtmp:
        return False
    return True

def parse_defaults():
    """Parse default values from defaults.conf file."""
    defaults = {}
    
    if not DEFAULTS_FILE.exists():
        return defaults
    
    with open(DEFAULTS_FILE, 'r') as f:
        for line in f:
            line_stripped = line.strip()
            if line_stripped and not line_stripped.startswith('#') and '=' in line_stripped:
                key, value = line_stripped.split('=', 1)
                key = key.strip()
                value = value.strip()
                
                # Remove quotes if present
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                
                defaults[key] = value
    
    return defaults

def parse_config():
    """Parse configuration file with comments support."""
    config = {}
    comments = {}
    
    if not CONFIG_FILE.exists():
        return {}, {}
    
    with open(CONFIG_FILE, 'r') as f:
        content = f.read()
    
    # Parse config content with comments
    current_comment = []
    for line in content.split('\n'):
        line = line.strip()
        if line.startswith('#'):
            current_comment.append(line[1:].strip())
        elif line and '=' in line:
            key, value = line.split('=', 1)
            config[key.strip()] = value.strip()
            if current_comment:
                comments[key.strip()] = '\n'.join(current_comment)
                current_comment = []
        elif line:
            current_comment.append(line)
    
    # Apply default values for missing configuration parameters
    defaults = parse_defaults()
    for key, default_value in defaults.items():
        if key not in config:
            config[key] = default_value
    
    return config, comments

def save_config(config_data):
    """Save configuration to file."""
    # Create config file with defaults if it doesn't exist
    if not CONFIG_FILE.exists():
        defaults = parse_defaults()
        with open(CONFIG_FILE, 'w') as f:
            for key, value in defaults.items():
                f.write(f"{key}={value}\n")
        # Set ownership to original user (not root)
        try:
            import pwd
            sudo_user = os.environ.get('SUDO_USER')
            if sudo_user:
                uid = pwd.getpwnam(sudo_user).pw_uid
                gid = pwd.getpwnam(sudo_user).pw_gid
                os.chown(CONFIG_FILE, uid, gid)
        except:
            pass
    
        
    with open(CONFIG_FILE, 'r') as f:
        lines = f.readlines()
    
    # Track which keys were updated
    updated_keys = set()
    new_lines = []
    
    for line in lines:
        line_stripped = line.strip()
        if '=' in line_stripped and not line_stripped.startswith('#'):
            key = line_stripped.split('=', 1)[0].strip()
            if key in config_data:
                value = config_data[key]
                if ' ' in value or not value:
                    value = f'"{value}"'
                new_lines.append(f'{key}={value}\n')
                updated_keys.add(key)
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
    
    # Add missing parameters from config_data (new parameters not in file)
    for key, value in config_data.items():
        if key not in updated_keys:
            if ' ' in value or not value:
                value = f'"{value}"'
            new_lines.append(f'{key}={value}\n')
    
    try:
        with open(CONFIG_FILE, 'w') as f:
            f.writelines(new_lines)
        return True, "Configuration saved successfully"
    except Exception as e:
        return False, str(e)


@app.route('/')
def index():
    """Main page with configuration editor."""
    config, comments = parse_config()
    config_exists = CONFIG_FILE.exists()
    version = get_version()
    if (not config_exists) or (not is_config_ready(config)):
        return render_template('installer.html', config=config, version=version, 
                             header_title="Конфігурація відеопотоку", show_cpu_mode=True)
    return render_template('index.html', config=config, comments=comments, version=version,
                         header_title="Конфігурація відеопотоку", show_cpu_mode=True)


@app.route('/api/installer', methods=['POST'])
def installer_save():
    """API endpoint for first-run installer (minimal required settings)."""
    try:
        data = request.json or {}
        rtmp_url = (data.get('RTMP_URL') or '').strip()
        overlay_text = (data.get('OVERLAY_TEXT') or '')

        if not rtmp_url:
            return jsonify({'success': False, 'error': 'RTMP URL is required'}), 400

        success, message = save_config({
            'RTMP_URL': rtmp_url,
            'OVERLAY_TEXT': overlay_text,
        })

        if success:
            return jsonify({'success': True, 'message': message})
        return jsonify({'success': False, 'error': message}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/config', methods=['GET'])
def get_config():
    """API endpoint to get current configuration."""
    config, comments = parse_config()
    return jsonify({'config': config, 'comments': comments})

@app.route('/api/config', methods=['POST'])
def update_config():
    """API endpoint to update configuration."""
    try:
        config_data = request.json
        success, message = save_config(config_data)
        
        if success:
            # Check if stream will be restarted
            stream_restart_required = False
            try:
                # Check if stream is currently active
                result = subprocess.run(
                    ['systemctl', 'is-active', 'forpost-stream'],
                    capture_output=True,
                    text=True
                )
                stream_active = result.stdout.strip() == 'active'
                
                if stream_active:
                    # Check if critical parameters changed by examining the log
                    log_file = PROJECT_ROOT / 'logs' / 'config_handler.log'
                    if log_file.exists():
                        recent_log = subprocess.run(
                            ['tail', '-20', str(log_file)],
                            capture_output=True,
                            text=True
                        ).stdout
                        
                        if 'Stream-critical parameter changed' in recent_log:
                            stream_restart_required = True
            except:
                pass
            
            return jsonify({
                'success': True, 
                'message': message,
                'stream_restart_required': stream_restart_required
            })
        else:
            return jsonify({'success': False, 'error': message}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/stream/start', methods=['POST'])
def start_service():
    """API endpoint to start the streaming service."""
    try:
        config, _ = parse_config()
        if not is_config_ready(config):
            return jsonify({'success': False, 'error': 'Спочатку заповніть RTMP URL у налаштуваннях і збережіть конфігурацію'}), 400

        # Start UDP proxy if enabled
        if config.get('USE_UDP_PROXY', 'true') == 'true':
            os.system('sudo systemctl start forpost-udp-proxy')
        
        result = os.system('sudo systemctl start forpost-stream')
        if result == 0:
            # Start auto-restart timer if enabled
            if config.get('AUTO_RESTART_ENABLED', 'false') == 'true':
                os.system('sudo systemctl start forpost-stream-autorestart.timer')
            return jsonify({'success': True, 'message': 'Stream started successfully'})
        else:
            return jsonify({'success': False, 'error': 'Failed to start stream'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/stream/stop', methods=['POST'])
def stop_service():
    """API endpoint to stop the streaming service."""
    try:
        # Stop auto-restart timer first
        os.system('sudo systemctl stop forpost-stream-autorestart.timer 2>/dev/null')
        result = os.system('sudo systemctl stop forpost-stream')
        # Stop UDP proxy as well
        os.system('sudo systemctl stop forpost-udp-proxy 2>/dev/null')
        if result == 0:
            return jsonify({'success': True, 'message': 'Stream stopped successfully'})
        else:
            return jsonify({'success': False, 'error': 'Failed to stop stream'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/stream/restart', methods=['POST'])
def restart_service():
    """API endpoint to restart the streaming service."""
    try:
        config, _ = parse_config()
        if not is_config_ready(config):
            return jsonify({'success': False, 'error': 'Спочатку заповніть RTMP URL у налаштуваннях і збережіть конфігурацію'}), 400

        # Restart UDP proxy if enabled
        if config.get('USE_UDP_PROXY', 'true') == 'true':
            os.system('sudo systemctl restart forpost-udp-proxy')
        
        result = os.system('sudo systemctl restart forpost-stream')
        if result == 0:
            return jsonify({'success': True, 'message': 'Stream restarted successfully'})
        else:
            return jsonify({'success': False, 'error': 'Failed to restart stream'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/status', methods=['GET'])
def get_status():
    """API endpoint to get service status and power state."""
    try:
        # Check if service is active
        result = subprocess.run(
            ['systemctl', 'is-active', 'forpost-stream'],
            capture_output=True,
            text=True
        )
        status = result.stdout.strip()
        active = status == 'active'
        
        # Get current power state
        wifi_state = 'Увімкнено'
        bluetooth_state = 'Увімкнено'
        eth_state = 'Auto'
        
        try:
            result = subprocess.run(['rfkill', 'list'], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            
            for i, line in enumerate(lines):
                if 'Wireless LAN' in line:
                    # Check next line for soft blocked status
                    if i + 1 < len(lines) and 'Soft blocked: yes' in lines[i + 1]:
                        wifi_state = 'Вимкнено'
                    # else: remains 'Увімкнено' (default)
                elif 'Bluetooth' in line:
                    # Check next line for soft blocked status
                    if i + 1 < len(lines) and 'Soft blocked: yes' in lines[i + 1]:
                        bluetooth_state = 'Вимкнено'
                    # else: remains 'Увімкнено' (default)
        except:
            pass
        
        try:
            result = subprocess.run(['ethtool', 'eth0'], capture_output=True, text=True)
            speed = 'auto'
            autoneg = 'on'
            for line in result.stdout.split('\n'):
                if 'Speed:' in line:
                    if '100Mb/s' in line:
                        speed = '100'
                    elif '1000Mb/s' in line or '1Gb/s' in line:
                        speed = '1000'
                if 'Auto-negotiation:' in line:
                    autoneg = 'on' if 'on' in line.lower() else 'off'
            
            if speed == '1000' and autoneg == 'on':
                eth_state = '1000Mbps (auto)'
            elif speed == '1000' and autoneg == 'off':
                eth_state = '1000Mbps (fixed)'
            elif speed == '100' and autoneg == 'off':
                eth_state = '100Mbps (fixed)'
            else:
                eth_state = f'{speed}Mbps'
        except:
            pass
        
        return jsonify({
            'status': status,
            'active': active,
            'power': {
                'wifi': wifi_state,
                'bluetooth': bluetooth_state,
                'ethernet': eth_state
            }
        })
    except Exception as e:
        return jsonify({'status': 'unknown', 'active': False, 'error': str(e)})

@app.route('/api/updates/check', methods=['GET'])
def check_updates():
    """Check for available updates from GitHub."""
    try:
        channel = request.args.get('channel', 'stable')
        script_path = PROJECT_ROOT / 'scripts' / 'check_updates.sh'
        
        result = subprocess.run(
            ['bash', str(script_path), channel],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            import json
            update_info = json.loads(result.stdout)
            return jsonify(update_info)
        else:
            return jsonify({'error': 'Failed to check updates', 'details': result.stderr}), 500
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Update check timed out'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/updates/install', methods=['POST'])
def install_update():
    """Install a specific version."""
    try:
        data = request.json
        version = data.get('version')
        
        if not version:
            return jsonify({'error': 'Version is required'}), 400
        
        # Use systemd-run to run update in isolated context
        subprocess.run(
            ['sudo', 'systemd-run', '--unit=forpost-stream-update', '--no-block',
             '/bin/bash', str(PROJECT_ROOT / 'scripts' / 'update.sh'), version],
            check=True
        )
        
        return jsonify({
            'success': True,
            'message': f'Update to {version} started. Please wait...'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/dynamic-overlay', methods=['GET'])
def get_dynamic_overlay():
    """API endpoint to get current dynamic overlay text and scanning state."""
    try:
        dynamic_file = Path('/tmp/dzyga_dynamic_overlay.txt')
        scanning_state_file = Path('/tmp/dzyga_scanning_state.txt')
        
        text = ''
        if dynamic_file.exists():
            text = dynamic_file.read_text().strip()
        
        scanning = 'stable'
        if scanning_state_file.exists():
            scanning = scanning_state_file.read_text().strip()
        
        return jsonify({'text': text, 'scanning': scanning})
    except Exception as e:
        return jsonify({'text': '', 'scanning': 'stable', 'error': str(e)})

@app.route('/api/dynamic-overlay', methods=['POST'])
def set_dynamic_overlay():
    """API endpoint to update dynamic overlay text without restarting stream."""
    try:
        data = request.json
        text = data.get('text', '')
        
        # Write to dynamic overlay file
        dynamic_file = Path('/tmp/dzyga_dynamic_overlay.txt')
        dynamic_file.write_text(text)
        dynamic_file.chmod(0o666)
        
        # Update last frequency file to current frequency to prevent immediate clearing
        freq_script = PROJECT_ROOT / 'scripts' / 'get_frequency.sh'
        last_freq_file = Path('/tmp/dzyga_last_freq_dynamic.txt')
        
        try:
            result = subprocess.run(
                ['sudo', 'bash', str(freq_script)],
                capture_output=True,
                text=True,
                timeout=3
            )
            if result.returncode == 0:
                current_freq = result.stdout.strip()
                # Write via sudo to avoid permission conflicts with update_dynamic_overlay.sh
                subprocess.run(
                    ['sudo', 'tee', str(last_freq_file)],
                    input=current_freq.encode(),
                    capture_output=True
                )
                subprocess.run(['sudo', 'chmod', '666', str(last_freq_file)], capture_output=True)
        except:
            pass
        
        return jsonify({'success': True, 'message': 'Dynamic overlay updated'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/config/raw', methods=['GET'])
def get_raw_config():
    """API endpoint to get raw configuration file content."""
    try:
        if not CONFIG_FILE.exists():
            # Return defaults.conf as initial content
            if DEFAULTS_FILE.exists():
                with open(DEFAULTS_FILE, 'r') as f:
                    content = f.read()
            else:
                return jsonify({'error': 'Configuration file not found'}), 404
        else:
            with open(CONFIG_FILE, 'r') as f:
                content = f.read()
        
        return jsonify({'content': content})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/config/raw', methods=['POST'])
def save_raw_config():
    """API endpoint to save raw configuration file content with 3-backup rotation."""
    try:
        data = request.json
        content = data.get('content', '')
        
        if not content.strip():
            return jsonify({'success': False, 'error': 'Configuration content cannot be empty'}), 400
        
        # Rotate backups: backup.2 -> backup.3, backup.1 -> backup.2, current -> backup.1
        backup_3 = CONFIG_FILE.with_suffix('.conf.backup.3')
        backup_2 = CONFIG_FILE.with_suffix('.conf.backup.2')
        backup_1 = CONFIG_FILE.with_suffix('.conf.backup.1')
        
        # Remove oldest backup if exists
        if backup_3.exists():
            backup_3.unlink()
        
        # Rotate backups
        if backup_2.exists():
            backup_2.rename(backup_3)
        if backup_1.exists():
            backup_1.rename(backup_2)
        
        # Create backup of current config
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, 'r') as f:
                backup_content = f.read()
            with open(backup_1, 'w') as f:
                f.write(backup_content)
        
        # Save new content
        with open(CONFIG_FILE, 'w') as f:
            f.write(content)
        
        # Set ownership to original user (not root)
        try:
            import pwd
            sudo_user = os.environ.get('SUDO_USER')
            if sudo_user:
                pw_record = pwd.getpwnam(sudo_user)
                os.chown(CONFIG_FILE, pw_record.pw_uid, pw_record.pw_gid)
        except:
            pass
        
        return jsonify({'success': True, 'message': 'Configuration saved successfully'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/config/backups', methods=['GET'])
def get_backups():
    """API endpoint to get list of available backups."""
    try:
        backups = []
        
        for i in range(1, 4):
            backup_file = CONFIG_FILE.with_suffix(f'.conf.backup.{i}')
            if backup_file.exists():
                import datetime
                mtime = backup_file.stat().st_mtime
                mod_time = datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')
                backups.append({
                    'number': i,
                    'filename': backup_file.name,
                    'modified': mod_time
                })
        
        return jsonify({'backups': backups})
    except Exception as e:
        return jsonify({'backups': [], 'error': str(e)}), 500

@app.route('/api/config/backup/<int:backup_num>', methods=['GET'])
def get_backup_content(backup_num):
    """API endpoint to get backup content."""
    try:
        if backup_num < 1 or backup_num > 3:
            return jsonify({'error': 'Invalid backup number'}), 400
        
        backup_file = CONFIG_FILE.with_suffix(f'.conf.backup.{backup_num}')
        
        if not backup_file.exists():
            return jsonify({'error': f'Backup {backup_num} not found'}), 404
        
        with open(backup_file, 'r') as f:
            content = f.read()
        
        import datetime
        mtime = backup_file.stat().st_mtime
        mod_time = datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')
        
        return jsonify({
            'content': content,
            'filename': backup_file.name,
            'modified': mod_time,
            'number': backup_num
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/config/restore/<int:backup_num>', methods=['POST'])
def restore_from_backup(backup_num):
    """API endpoint to restore configuration from backup."""
    try:
        if backup_num < 1 or backup_num > 3:
            return jsonify({'success': False, 'error': 'Invalid backup number'}), 400
        
        backup_file = CONFIG_FILE.with_suffix(f'.conf.backup.{backup_num}')
        
        if not backup_file.exists():
            return jsonify({'success': False, 'error': f'Backup {backup_num} not found'}), 404
        
        # Read backup content
        with open(backup_file, 'r') as f:
            backup_content = f.read()
        
        # Save backup content as current config
        with open(CONFIG_FILE, 'w') as f:
            f.write(backup_content)
        
        # Set ownership to original user (not root)
        try:
            import pwd
            sudo_user = os.environ.get('SUDO_USER')
            if sudo_user:
                pw_record = pwd.getpwnam(sudo_user)
                os.chown(CONFIG_FILE, pw_record.pw_uid, pw_record.pw_gid)
        except:
            pass
        
        return jsonify({'success': True, 'message': f'Configuration restored from backup {backup_num}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081, debug=False)
