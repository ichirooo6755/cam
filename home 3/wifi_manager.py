#!/usr/bin/env python3
"""
Wi-Fi Mode Manager for Raspberry Pi
Supports:
1. NetworkManager (nmcli) - Recommended
2. Legacy (wpa_supplicant/dhcpcd) - Fallback for Tethering only
"""

import os
import subprocess
import json
import logging
import time
import shutil
import binascii
import hashlib

logger = logging.getLogger(__name__)

# 設定ファイルパス
SETTINGS_FILE = '/home/pi/camera_settings.json'
WPA_SUPPLICANT_CONF = '/etc/wpa_supplicant/wpa_supplicant.conf'

# APモード時の想定固定IP（Raspberry Pi OSのデフォルト範囲: 192.168.4.1）
AP_IP = '192.168.4.1'

# 環境変数または設定ファイルからデフォルト値を取得（ハードコード回避）
def _get_default_ap_ssid():
    """デフォルトAP SSIDを取得（環境変数 AP_SSID で上書き可能）"""
    return os.environ.get('AP_SSID', 'PiCamera')

def _get_default_ap_password():
    """デフォルトAPパスワードを取得（環境変数 AP_PASSWORD で上書き可能）"""
    return os.environ.get('AP_PASSWORD', 'picamera123')

def _get_primary_ip():
    """Return primary IP address string if available"""
    try:
        result = subprocess.run(
            ['hostname', '-I'],
            capture_output=True, text=True
        )
        ips = result.stdout.strip().split()
        if ips:
            return ips[0]
    except Exception:
        pass
    return None

def has_nmcli():
    """Check if nmcli is available"""
    return shutil.which('nmcli') is not None

def _detect_wifi_interface():
    try:
        res = _run(['iw', 'dev'])
        if res['returncode'] == 0 and res['stdout']:
            for line in res['stdout'].splitlines():
                line = line.strip()
                if line.startswith('Interface '):
                    return line.split('Interface ', 1)[1].strip()
    except Exception:
        pass

    for candidate in ('wlan0', 'wlan1'):
        if os.path.exists(f'/sys/class/net/{candidate}'):
            return candidate
    return 'wlan0'

def _detect_wpa_ctrl_dir():
    for path in ('/run/wpa_supplicant', '/var/run/wpa_supplicant'):
        if os.path.isdir(path):
            return path
    return '/run/wpa_supplicant'

def _ensure_wpa_supplicant_running(iface, ctrl_dir):
    sock_path = os.path.join(ctrl_dir, iface)
    if os.path.exists(sock_path):
        return True

    _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
    _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])
    _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'down'])
    time.sleep(1)
    _run(['sudo', '-n', 'ip', 'link', 'set', iface, 'up'])
    time.sleep(1)

    _run(['sudo', '-n', 'systemctl', 'start', 'wpa_supplicant'])
    time.sleep(2)
    if os.path.exists(sock_path):
        return True

    _run(['sudo', '-n', 'systemctl', 'start', f'wpa_supplicant@{iface}'])
    time.sleep(2)
    if os.path.exists(sock_path):
        return True

    _run([
        'sudo', '-n', 'wpa_supplicant',
        '-B',
        '-i', iface,
        '-c', WPA_SUPPLICANT_CONF,
        '-C', ctrl_dir,
    ])
    time.sleep(2)
    return os.path.exists(sock_path)

def _unsafe_shell_chars_present(value):
    if value is None:
        return False
    return any(ch in value for ch in ('\n', '\r', '\x00'))

def _read_existing_country():
    try:
        res = _run(['sudo', '-n', 'cat', WPA_SUPPLICANT_CONF])
        if res['returncode'] != 0 or not res['stdout']:
            return None
        country = None
        for line in res['stdout'].splitlines():
            line = line.strip()
            if line.startswith('country='):
                country = line.split('=', 1)[1].strip()
        return country
    except Exception:
        pass
    return None

def _run_with_input(cmd, input_text, timeout=20):
    result = subprocess.run(
        cmd,
        input=input_text,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return {
        'returncode': result.returncode,
        'stdout': (result.stdout or '').strip(),
        'stderr': (result.stderr or '').strip(),
    }

def _validate_wifi_credentials(ssid, psk):
    if not ssid or not psk:
        return False, 'ssid と psk は必須です'
    if _unsafe_shell_chars_present(ssid) or _unsafe_shell_chars_present(psk):
        return False, 'ssid/psk に未対応の文字が含まれています（改行・NULLなど）。'

    ssid_bytes = ssid.encode('utf-8')
    if len(ssid_bytes) == 0 or len(ssid_bytes) > 32:
        return False, 'ssid は 1〜32 byte の範囲で指定してください'

    if len(psk) < 8 or len(psk) > 63:
        return False, 'psk は 8〜63 文字で指定してください'

    return True, None

def _ssid_to_hex(ssid):
    return binascii.hexlify(ssid.encode('utf-8')).decode('ascii')

def _derive_psk_hex(ssid, psk):
    derived = hashlib.pbkdf2_hmac(
        'sha1',
        psk.encode('utf-8'),
        ssid.encode('utf-8'),
        4096,
        32,
    )
    return binascii.hexlify(derived).decode('ascii')

def _write_wpa_supplicant_conf(ssid, psk):
    valid, message = _validate_wifi_credentials(ssid, psk)
    if not valid:
        return {
            'success': False,
            'message': message,
        }

    country = _read_existing_country()

    ssid_hex = _ssid_to_hex(ssid)
    psk_hex = _derive_psk_hex(ssid, psk)
    network_block = [
        'network={',
        f'    ssid={ssid_hex}',
        f'    psk={psk_hex}',
        '    key_mgmt=WPA-PSK',
        '}',
    ]

    conf_lines = []
    conf_lines.append('ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev')
    conf_lines.append('update_config=1')
    if country:
        conf_lines.append(f'country={country}')
    conf_lines.extend(network_block)
    conf_text = '\n'.join(conf_lines) + '\n'

    tmp_path = '/tmp/wpa_supplicant.conf.picamera'
    write_res = _run_with_input(['sudo', '-n', 'tee', tmp_path], conf_text)
    if write_res['returncode'] != 0:
        return {
            'success': False,
            'message': f"write wpa_supplicant.conf failed: {write_res['stderr'] or write_res['stdout']}",
        }

    _run(['sudo', '-n', 'mv', tmp_path, WPA_SUPPLICANT_CONF])
    _run(['sudo', '-n', 'chmod', '600', WPA_SUPPLICANT_CONF])

    iface = _detect_wifi_interface()
    _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
    _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])
    _run(['sudo', '-n', 'systemctl', 'restart', f'wpa_supplicant@{iface}'])
    _run(['sudo', '-n', 'systemctl', 'restart', 'wpa_supplicant'])
    time.sleep(2)
    _run(['sudo', '-n', 'dhcpcd', '-n', iface])

    return {
        'success': True,
        'message': 'wpa_supplicant.conf を更新しました（ファイル書き換えフォールバック）',
        'iface': iface,
        'country': country,
        'psk_derived': True,
    }

def _run(cmd, timeout=20):
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return {
        'returncode': result.returncode,
        'stdout': (result.stdout or '').strip(),
        'stderr': (result.stderr or '').strip(),
    }

def _run_wpa_cli(args, iface=None, timeout=20):
    iface = iface or _detect_wifi_interface()
    ctrl_dir = _detect_wpa_ctrl_dir()
    _ensure_wpa_supplicant_running(iface, ctrl_dir)

    base_cmd = ['wpa_cli', '-p', ctrl_dir, '-i', iface] + list(args)
    res = _run(base_cmd, timeout=timeout)
    if res['returncode'] == 0 and res['stdout'] and 'FAIL' not in res['stdout']:
        return res

    sudo_cmd = ['sudo', '-n'] + base_cmd
    sudo_res = _run(sudo_cmd, timeout=timeout)
    return sudo_res

def configure_wpa_supplicant(ssid, psk):
    valid, message = _validate_wifi_credentials(ssid, psk)
    if not valid:
        return {'success': False, 'message': message}

    try:
        return _write_wpa_supplicant_conf(ssid, psk)
    except subprocess.TimeoutExpired:
        return {'success': False, 'message': 'wpa_supplicant update timed out'}
    except Exception as e:
        logger.error(f"Failed to configure wpa_supplicant: {e}")
        return {'success': False, 'message': str(e)}

def check_tethering_connection(timeout=15):
    """
    テザリングモードで実際に接続できているか確認
    Returns: True if connected, False otherwise
    """
    import time
    start_time = time.time()
    
    while time.time() - start_time < timeout:
        try:
            # SSIDが取得できるか確認
            result = subprocess.run(
                ['iwgetid', '-r'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                ssid = result.stdout.strip()
                logger.info(f"Connected to SSID: {ssid}")
                
                # IPアドレスが取得できているか確認（APの192.168.4.x以外）
                ip = _get_primary_ip()
                if ip and not ip.startswith('192.168.4.') and not ip.startswith('10.42.0.'):
                    logger.info(f"Tethering connection confirmed: IP={ip}")
                    return True
        except Exception as e:
            logger.debug(f"Connection check error: {e}")
        
        time.sleep(2)
    
    logger.warning("Tethering connection check failed")
    return False

def get_current_mode():
    """
    現在のWi-Fiモードを取得する
    Returns: 'ap' or 'tethering'
    """
    if has_nmcli():
        try:
            result = subprocess.run(
                ['nmcli', '-t', '-f', 'NAME,TYPE', 'connection', 'show', '--active'],
                capture_output=True, text=True
            )
            if 'Hotspot' in result.stdout or 'hotspot' in result.stdout.lower():
                return 'ap'
        except Exception:
            pass
    
    # Legacy fallback: use IP帯域でAP判定
    ip = _get_primary_ip()
    if ip and (ip.startswith('192.168.4.') or ip.startswith('10.42.0.')):
        return 'ap'
    return 'tethering'

def get_wifi_status():
    """
    Wi-Fiの詳細ステータスを取得
    """
    mode = get_current_mode()
    
    status = {
        'mode': mode,
        'ip_address': None,
        'ip': None,
        'ssid': None
    }
    
    try:
        # IPアドレスを取得
        result = subprocess.run(
            ['hostname', '-I'],
            capture_output=True, text=True
        )
        ips = result.stdout.strip().split()
        if ips:
            status['ip_address'] = ips[0]
            status['ip'] = ips[0]
        
        # 接続中のSSIDを取得
        result = subprocess.run(
            ['iwgetid', '-r'],
            capture_output=True, text=True
        )
        if result.returncode == 0 and result.stdout.strip():
            status['ssid'] = result.stdout.strip()
        elif mode == 'ap':
            # APモードの場合は保存されているSSIDを返す
            ap_settings = get_saved_ap_settings()
            status['ssid'] = ap_settings.get('ssid', 'PiCamera')
            # APモード時は固定IPが取れないケースに備えて既定値を返す
            status['ip'] = status['ip'] or AP_IP
            status['ip_address'] = status['ip_address'] or AP_IP
                
    except Exception as e:
        logger.error(f"Failed to get Wi-Fi status: {e}")
    
    return status

def switch_to_ap_mode(ssid='PiCamera', password='picamera123'):
    """
    APモードに切り替える
    """
    if not has_nmcli():
        return {
            'success': False, 
            'message': 'APモードへの切り替えには nmcli (NetworkManager) が必要です。現在はサポートされていません。'
        }

    try:
        ssid = ssid or _get_default_ap_ssid()
        password = password or _get_default_ap_password()

        # 引数が空なら保存済み設定を優先
        saved = get_saved_ap_settings()
        ssid = ssid or saved.get('ssid', _get_default_ap_ssid())
        password = password or saved.get('password', _get_default_ap_password())

        logger.info(f"Switching to AP mode with nmcli: SSID={ssid}")
        
        if len(password) < 8:
            return {'success': False, 'message': 'パスワードは8文字以上必要です'}
        
        # Safe teardown with delays
        subprocess.run(['sudo', 'nmcli', 'connection', 'down', 'Hotspot'], capture_output=True)
        time.sleep(2)
        subprocess.run(['sudo', 'nmcli', 'connection', 'delete', 'Hotspot'], capture_output=True)
        time.sleep(2)
        
        result = subprocess.run(
            ['sudo', 'nmcli', 'device', 'wifi', 'hotspot', 
             'ssid', ssid, 
             'password', password],
            capture_output=True, text=True
        )
        
        if result.returncode != 0:
            return {'success': False, 'message': f'Hotspot起動に失敗: {result.stderr}'}
        
        # 設定を保存
        _save_wifi_settings('ap', ssid, password)

        # 現在のIPを取得（失敗時は既定値）
        ip_result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        current_ip = ip_result.stdout.strip().split()[0] if ip_result.stdout.strip() else AP_IP
        
        logger.info("Successfully switched to AP mode")
        return {
            'success': True, 
            'message': f'APモードに切り替えました。スマホで「{ssid}」に接続してください。',
            'ip': current_ip,
            'ip_address': current_ip
        }
        
    except Exception as e:
        logger.error(f"AP mode switch failed: {e}")
        return {'success': False, 'message': str(e)}

def switch_to_tethering_mode():
    """
    テザリングモード（通常のWi-Fiクライアントモード）に切り替える
    """
    # 保存された設定からSSIDを取得（もしあれば）
    # ここでは実装簡略化のため、既存のwpa_supplicant.confを優先するか、Webから渡された値を使うべき
    # 引数がないので、UI側で入力させるのが理想だが、今のAPIは引数なし。
    # 実際は update_wifi_settings API経由で wpa_supplicant を書き換えるフローが必要。
    
    if has_nmcli():
        try:
            logger.info("Switching to tethering mode (nmcli)")
            subprocess.run(['sudo', 'nmcli', 'connection', 'down', 'Hotspot'], capture_output=True)
            time.sleep(2)
            subprocess.run(['sudo', 'nmcli', 'connection', 'delete', 'Hotspot'], capture_output=True)
            time.sleep(2)
            subprocess.run(['sudo', 'nmcli', 'device', 'wifi', 'rescan'], capture_output=True)
            time.sleep(2)
            # 自動接続
            subprocess.run(['sudo', 'nmcli', 'device', 'connect', 'wlan0'], capture_output=True)
            
            _save_wifi_settings('tethering', None, None)
            return {'success': True, 'message': 'テザリングモードに切り替えました。'}
        except Exception as e:
            return {'success': False, 'message': str(e)}
    
    else:
        # Legacy: wpa_supplicant mode
        # すでにwpa_supplicant.confが適切なら、単にインターフェース再起動
        try:
            logger.info("Switching to tethering mode (legacy)")
            iface = _detect_wifi_interface()
            _run(['sudo', '-n', 'systemctl', 'stop', 'hostapd'])
            _run(['sudo', '-n', 'systemctl', 'stop', 'dnsmasq'])

            reconfigure = _run_wpa_cli(['reconfigure'], iface=iface)
            if reconfigure['returncode'] != 0 or 'FAIL' in reconfigure['stdout']:
                _run(['sudo', '-n', 'systemctl', 'restart', f'wpa_supplicant@{iface}'])
                time.sleep(2)
                reconfigure = _run_wpa_cli(['reconfigure'], iface=iface)

            if reconfigure['returncode'] != 0 or 'FAIL' in reconfigure['stdout']:
                return {
                    'success': False,
                    'message': f"wpa_cli reconfigure failed: {reconfigure['stderr'] or reconfigure['stdout']}",
                }

            time.sleep(3)

            reconnect = _run_wpa_cli(['reconnect'], iface=iface)
            if reconnect['returncode'] != 0 or 'FAIL' in reconnect['stdout']:
                return {
                    'success': False,
                    'message': f"wpa_cli reconnect failed: {reconnect['stderr'] or reconnect['stdout']}",
                }
            time.sleep(2)
            
            _save_wifi_settings('tethering', None, None)
            return {'success': True, 'message': '設定を再読み込みしました (Legacy mode)'}
        except Exception as e:
            return {'success': False, 'message': str(e)}

def _save_wifi_settings(mode, ssid, password):
    """Wi-Fi設定を保存"""
    try:
        settings = {}
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings = json.load(f)
        
        settings['wifi_mode'] = mode
        if ssid:
            settings['ap_ssid'] = ssid
        if password:
            settings['ap_password'] = password
        
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(settings, f, indent=2)
            
    except Exception as e:
        logger.error(f"Failed to save Wi-Fi settings: {e}")

def get_saved_ap_settings():
    """保存されているAP設定を取得"""
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings = json.load(f)
            return {
                'ssid': settings.get('ap_ssid', _get_default_ap_ssid()),
                'password': settings.get('ap_password', _get_default_ap_password())
            }
    except Exception:
        pass
    return {'ssid': _get_default_ap_ssid(), 'password': _get_default_ap_password()}

if __name__ == '__main__':
    import sys
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) < 2:
        print(f"Current mode: {get_current_mode()}")
        print(f"Status: {get_wifi_status()}")

