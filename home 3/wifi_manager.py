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
            subprocess.run(['sudo', 'wpa_cli', '-i', 'wlan0', 'reconfigure'], capture_output=True)
            time.sleep(3)
            
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

