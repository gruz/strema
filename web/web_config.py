#!/usr/bin/env python3
import os
import re
import subprocess
from flask import Flask, render_template, request, jsonify
from pathlib import Path

app = Flask(__name__)

SCRIPT_DIR = Path(__file__).parent.absolute()
PROJECT_ROOT = SCRIPT_DIR.parent
CONFIG_FILE = PROJECT_ROOT / 'config' / 'stream.conf'
CONFIG_TEMPLATE = PROJECT_ROOT / 'config' / 'stream.conf.template'
VERSION_FILE = PROJECT_ROOT / 'VERSION'

def get_version():
    """Get application version from VERSION file."""
    try:
        if VERSION_FILE.exists():
            return VERSION_FILE.read_text().strip()
    except:
        pass
    return "unknown"


def is_config_ready(config: dict) -> bool:
    rtmp = (config.get('RTMP_URL') or '').strip()
    if not rtmp:
        return False
    if '__RTMP_URL__' in rtmp:
        return False
    return True

def parse_config():
    """Parse configuration file into a dictionary."""
    config = {}
    comments = {}
    
    if not CONFIG_FILE.exists():
        if CONFIG_TEMPLATE.exists():
            with open(CONFIG_TEMPLATE, 'r') as f:
                content = f.read()
        else:
            return {}, {}
    else:
        with open(CONFIG_FILE, 'r') as f:
            content = f.read()
    
    current_comment = []
    for line in content.split('\n'):
        line_stripped = line.strip()
        
        if line_stripped.startswith('#'):
            current_comment.append(line_stripped[1:].strip())
        elif '=' in line_stripped and not line_stripped.startswith('#'):
            key, value = line_stripped.split('=', 1)
            key = key.strip()
            value = value.strip()
            
            # Remove inline comments
            if '#' in value:
                value = value.split('#')[0].strip()
            
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            
            config[key] = value
            if current_comment:
                comments[key] = ' '.join(current_comment)
                current_comment = []
        elif not line_stripped:
            current_comment = []
    
    return config, comments

def save_config(config_data):
    """Save configuration to file."""
    if not CONFIG_FILE.exists() and CONFIG_TEMPLATE.exists():
        with open(CONFIG_TEMPLATE, 'r') as f:
            template_content = f.read()
        with open(CONFIG_FILE, 'w') as f:
            f.write(template_content)
        # Set ownership to original user (not root)
        try:
            import pwd
            sudo_user = os.environ.get('SUDO_USER')
            if sudo_user:
                pw_record = pwd.getpwnam(sudo_user)
                os.chown(CONFIG_FILE, pw_record.pw_uid, pw_record.pw_gid)
        except:
            pass
    
    if not CONFIG_FILE.exists():
        return False, "Configuration file not found"
    
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
        return render_template('installer.html', config=config, version=version)
    return render_template('index.html', config=config, comments=comments, version=version)


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
            return jsonify({'success': True, 'message': message})
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

@app.route('/api/stream/autostart', methods=['POST'])
def set_autostart():
    """API endpoint to enable/disable autostart on boot."""
    try:
        data = request.json
        enable = data.get('enable', False)
        
        if enable:
            result = os.system('sudo systemctl enable forpost-stream')
            message = 'Autostart enabled'
        else:
            result = os.system('sudo systemctl disable forpost-stream')
            message = 'Autostart disabled'
        
        if result == 0:
            return jsonify({'success': True, 'message': message})
        else:
            return jsonify({'success': False, 'error': 'Failed to change autostart setting'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/autorestart', methods=['GET'])
def get_autorestart():
    """API endpoint to get auto-restart configuration."""
    try:
        config, _ = parse_config()
        enabled = config.get('AUTO_RESTART_ENABLED', 'false') == 'true'
        interval = int(config.get('AUTO_RESTART_INTERVAL', '2'))
        
        # Check timer status
        result = subprocess.run(
            ['systemctl', 'is-active', 'forpost-stream-autorestart.timer'],
            capture_output=True,
            text=True
        )
        timer_active = result.stdout.strip() == 'active'
        
        return jsonify({
            'enabled': enabled,
            'interval': interval,
            'timer_active': timer_active
        })
    except Exception as e:
        return jsonify({'enabled': False, 'interval': 2, 'timer_active': False, 'error': str(e)})

@app.route('/api/autorestart', methods=['POST'])
def set_autorestart():
    """API endpoint to configure auto-restart."""
    try:
        data = request.json
        enabled = data.get('enabled', False)
        interval = data.get('interval', 2)
        
        # Read current config
        config, _ = parse_config()
        
        # Update auto-restart settings
        config['AUTO_RESTART_ENABLED'] = 'true' if enabled else 'false'
        config['AUTO_RESTART_INTERVAL'] = str(interval)
        
        # Save config
        success, message = save_config(config)
        if not success:
            return jsonify({'success': False, 'error': message}), 500
        
        # Apply timer settings
        script_path = PROJECT_ROOT / 'scripts' / 'update_autorestart.sh'
        result = os.system(f'sudo bash {script_path}')
        if result == 0:
            return jsonify({'success': True, 'message': 'Auto-restart settings updated'})
        else:
            return jsonify({'success': False, 'error': 'Failed to update timer'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/status', methods=['GET'])
def get_status():
    """API endpoint to get service status."""
    try:
        # Check if service is active
        result = subprocess.run(
            ['systemctl', 'is-active', 'forpost-stream'],
            capture_output=True,
            text=True
        )
        status = result.stdout.strip()
        active = status == 'active'
        
        # Check if autostart is enabled
        result_enabled = subprocess.run(
            ['systemctl', 'is-enabled', 'forpost-stream'],
            capture_output=True,
            text=True
        )
        enabled = result_enabled.stdout.strip() == 'enabled'
        
        # Check auto-restart timer
        config, _ = parse_config()
        autorestart_enabled = config.get('AUTO_RESTART_ENABLED', 'false') == 'true'
        autorestart_interval = int(config.get('AUTO_RESTART_INTERVAL', '2'))
        
        return jsonify({
            'status': status,
            'active': active,
            'autostart': enabled,
            'autorestart_enabled': autorestart_enabled,
            'autorestart_interval': autorestart_interval
        })
    except Exception as e:
        return jsonify({'status': 'unknown', 'active': False, 'autostart': False, 'autorestart_enabled': False, 'autorestart_interval': 2, 'error': str(e)})

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
                last_freq_file.write_text(current_freq)
                last_freq_file.chmod(0o666)
        except:
            pass
        
        return jsonify({'success': True, 'message': 'Dynamic overlay updated'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/power-settings', methods=['GET'])
def get_power_settings():
    """API endpoint to get current power saving settings."""
    try:
        config, _ = parse_config()
        
        # Get current system state
        wifi_blocked = False
        bluetooth_blocked = False
        hdmi_on = True
        eth_speed = 'auto'
        eth_autoneg = 'on'
        
        try:
            result = subprocess.run(['rfkill', 'list'], capture_output=True, text=True)
            if 'Wireless LAN' in result.stdout:
                wifi_blocked = 'Soft blocked: yes' in result.stdout
            if 'Bluetooth' in result.stdout:
                bluetooth_blocked = 'Soft blocked: yes' in result.stdout
        except:
            pass
        
        hdmi_supported = True
        try:
            result = subprocess.run(['vcgencmd', 'display_power'], capture_output=True, text=True)
            hdmi_on = 'display_power=1' in result.stdout
            # Check if HDMI control actually works by comparing with config
            if config.get('POWER_SAVE_HDMI') == 'true' and hdmi_on:
                hdmi_supported = False
        except:
            hdmi_supported = False
            pass
        
        try:
            result = subprocess.run(['ethtool', 'eth0'], capture_output=True, text=True)
            for line in result.stdout.split('\n'):
                if 'Speed:' in line:
                    if '100Mb/s' in line:
                        eth_speed = '100'
                    elif '1000Mb/s' in line or '1Gb/s' in line:
                        eth_speed = '1000'
                if 'Auto-negotiation:' in line:
                    eth_autoneg = 'on' if 'on' in line else 'off'
        except:
            pass
        
        return jsonify({
            'config': {
                'POWER_SAVE_WIFI': config.get('POWER_SAVE_WIFI', 'false'),
                'POWER_SAVE_BLUETOOTH': config.get('POWER_SAVE_BLUETOOTH', 'false'),
                'POWER_SAVE_HDMI': config.get('POWER_SAVE_HDMI', 'false'),
                'POWER_SAVE_ETH_SPEED': config.get('POWER_SAVE_ETH_SPEED', 'auto'),
                'POWER_SAVE_ETH_AUTONEG': config.get('POWER_SAVE_ETH_AUTONEG', 'on')
            },
            'current': {
                'wifi_blocked': wifi_blocked,
                'bluetooth_blocked': bluetooth_blocked,
                'hdmi_on': hdmi_on,
                'hdmi_supported': hdmi_supported,
                'eth_speed': eth_speed,
                'eth_autoneg': eth_autoneg
            }
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/power-settings', methods=['POST'])
def apply_power_settings():
    """API endpoint to apply power saving settings."""
    try:
        data = request.json
        
        # Read current config
        config, _ = parse_config()
        
        # Update power settings
        config['POWER_SAVE_WIFI'] = data.get('POWER_SAVE_WIFI', 'false')
        config['POWER_SAVE_BLUETOOTH'] = data.get('POWER_SAVE_BLUETOOTH', 'false')
        config['POWER_SAVE_HDMI'] = data.get('POWER_SAVE_HDMI', 'false')
        config['POWER_SAVE_ETH_SPEED'] = data.get('POWER_SAVE_ETH_SPEED', 'auto')
        config['POWER_SAVE_ETH_AUTONEG'] = data.get('POWER_SAVE_ETH_AUTONEG', 'on')
        
        # Save config
        success, message = save_config(config)
        if not success:
            return jsonify({'success': False, 'error': message}), 500
        
        # Apply settings immediately
        script_path = PROJECT_ROOT / 'scripts' / 'apply_power_settings.sh'
        result = os.system(f'sudo bash {script_path}')
        
        if result == 0:
            return jsonify({'success': True, 'message': 'Налаштування енергозбереження застосовано'})
        else:
            return jsonify({'success': False, 'error': 'Не вдалося застосувати налаштування'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081, debug=False)
