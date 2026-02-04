#!/usr/bin/env python3
"""
Raspberry Pi Camera Control Web Interface
カメラ設定をWebブラウザから制御するためのHTTPサーバー
"""

import json
import os
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import subprocess
import logging
import wifi_manager

# ログ設定
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/home/pi/camera_control.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# 設定ファイルのパス
SETTINGS_FILE = '/home/pi/camera_settings.json'
PHOTOS_DIR = '/home/pi/photos'

# デフォルト設定
DEFAULT_SETTINGS = {
    'iso': 'auto',
    'shutter_speed': 'auto',  # 'auto' またはマイクロ秒単位の数値
    'white_balance': 'auto',
    'contrast': 0,
    'saturation': 0,
    'awb_mode': 'auto',
    'image_effect': 'none',
    'rotation': 0,
    'hflip': False,
    'vflip': False,
    'quality': 95,
    'width': 4056,
    'height': 3040,
    'monitoring_enabled': True,
    'detection_threshold': 30,
    'detection_interval': 1.0,
    'enable_multiple_exposure': False,
    'enable_2in1_composition': False,
    'enable_timestamp': False
}

class CameraControlHandler(BaseHTTPRequestHandler):
    """カメラ制御用HTTPリクエストハンドラー"""
    
    def do_GET(self):
        """GETリクエストの処理"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/':
            self.serve_main_page()
        elif parsed_path.path == '/style.css':
            self.serve_css()
        elif parsed_path.path == '/api/settings':
            self.serve_settings()
        elif parsed_path.path == '/api/status':
            self.serve_status()
        elif parsed_path.path == '/api/photos':
            self.serve_photo_list()
        elif parsed_path.path.startswith('/photos/'):
            self.serve_photo(parsed_path.path[8:])  # /photos/ を除去
        elif parsed_path.path == '/api/wifi/status':
            self.serve_wifi_status()
        elif parsed_path.path == '/api/wifi/diag':
            self.serve_wifi_diag()
        else:
            self.send_error(404)
    
    def do_POST(self):
        """POSTリクエストの処理"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/api/settings':
            self.update_settings()
        elif parsed_path.path == '/api/capture':
            self.capture_photo()
        elif parsed_path.path == '/api/restart_monitoring':
            self.restart_monitoring()
        elif parsed_path.path == '/api/stop_monitoring':
            self.stop_monitoring()
        elif parsed_path.path == '/api/wifi/write_wpa':
            self.write_wpa_settings()
        elif parsed_path.path == '/api/wifi/switch':
            self.switch_wifi_mode()
        else:
            self.send_error(404)
    
    def serve_main_page(self):
        """メインページのHTML配信"""
        try:
            with open('index.html', 'rb') as f:
                content = f.read()
            
            self.send_response(200)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(404, "index.html not found")
            
    def serve_css(self):
        """CSS配信"""
        try:
            with open('style.css', 'rb') as f:
                content = f.read()
            
            self.send_response(200)
            self.send_header('Content-type', 'text/css; charset=utf-8')
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(404, "style.css not found")
    
    def serve_settings(self):
        """設定情報をJSON形式で配信"""
        settings = load_settings()
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(settings).encode('utf-8'))
    
    def serve_status(self):
        """システム状態をJSON形式で配信"""
        try:
            # 設定から監視状態を確認
            settings = load_settings()
            monitoring_active = settings.get('monitoring_enabled', True)
            
            status = {
                'monitoring_active': monitoring_active,
                'timestamp': time.time(),
                'photos_count': len(get_photo_list())
            }
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(status).encode('utf-8'))
            
        except Exception as e:
            logger.error(f"Status check error: {e}")
            self.send_error(500)

    # ... (省略) ...
    
    def serve_photo_list(self):
        """写真一覧をJSON形式で配信"""
        photos = get_photo_list()
        
        response = {'photos': photos}
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))
    
    def serve_photo(self, filename):
        """写真ファイルを配信（Path Traversal対策付き）"""
        # Path Traversal対策: ファイル名の検証
        # 1. パス区切り文字を除去・正規化
        safe_filename = os.path.basename(filename)
        safe_filename = os.path.normpath(safe_filename)
        
        # 2. 空文字や親ディレクトリ参照の拒否
        if not safe_filename or safe_filename.startswith('..') or '/' in safe_filename or '\\' in safe_filename:
            self.send_error(403, "Invalid filename")
            return
        
        # 3. 正規化されたパスがPHOTOS_DIR内にあることを確認
        photo_path = os.path.join(PHOTOS_DIR, safe_filename)
        real_photos_dir = os.path.realpath(PHOTOS_DIR)
        real_photo_path = os.path.realpath(photo_path)
        
        if not real_photo_path.startswith(real_photos_dir + os.sep) and real_photo_path != real_photos_dir:
            self.send_error(403, "Access denied")
            return
        
        if not os.path.exists(photo_path):
            self.send_error(404)
            return
        
        try:
            with open(photo_path, 'rb') as f:
                content = f.read()
            
            self.send_response(200)
            self.send_header('Content-type', 'image/jpeg')
            self.send_header('Content-length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            
        except Exception as e:
            logger.error(f"Photo serve error: {e}")
            self.send_error(500)
    
    def update_settings(self):
        """設定更新処理"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            new_settings = json.loads(post_data.decode('utf-8'))
            
            # 設定を保存
            save_settings(new_settings)
            
            response = {'success': True}
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))
            
        except Exception as e:
            logger.error(f"Settings update error: {e}")
            response = {'success': False, 'error': str(e)}
            
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))
    
    def capture_photo(self):
        """写真を撮影"""
        try:
            settings = load_settings()
            timestamp = time.time()
            filename = f"manual_{timestamp:.6f}.jpg"
            photo_path = os.path.join(PHOTOS_DIR, filename)
            
            # libcameraコマンドで撮影
            cmd = [
                'libcamera-still',
                '-o', photo_path,
                '--width', str(settings['width']),
                '--height', str(settings['height']),
                '--quality', str(settings['quality']),
                '--timeout', '1000',
                '--nopreview'
            ]
            
            # シャッタースピード設定
            if settings['shutter_speed'] != 'auto':
                try:
                    if int(settings['shutter_speed']) > 0:
                        cmd.extend(['--shutter', str(settings['shutter_speed'])])
                except ValueError:
                    logger.warning(f"Invalid shutter speed value: {settings['shutter_speed']}")
            
            # 露出モードは常にnormal（offは非対応）
            cmd.extend(['--exposure', 'normal'])
                
            # ホワイトバランス設定
            if 'white_balance' in settings and settings['white_balance'] != 'auto':
                cmd.extend(['--awb', settings['white_balance']])
            else:
                cmd.extend(['--awb', 'auto'])

            # ISO設定 (手動撮影用に追加)
            if settings.get('iso', 'auto') != 'auto':
                try:
                    if int(settings['iso']) > 0:
                        cmd.extend(['--gain', str(int(settings['iso']) / 100)])
                except ValueError:
                    logger.warning(f"Invalid ISO value: {settings['iso']}")
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode == 0:
                response = {'success': True, 'filename': filename}
            else:
                response = {'success': False, 'error': result.stderr}
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))
            
        except Exception as e:
            logger.error(f"Capture error: {e}")
            response = {'success': False, 'error': str(e)}
            
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))

    def restart_monitoring(self):
        """監視プロセス再開"""
        try:
            settings = load_settings()
            settings['monitoring_enabled'] = True
            save_settings(settings)

            result = subprocess.run(
                ['sudo', '-n', 'systemctl', 'restart', 'shutter-trigger'],
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                response = {'success': True}
            else:
                response = {'success': False, 'error': result.stderr or result.stdout}

            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))

        except Exception as e:
            logger.error(f"Restart monitoring error: {e}")
            response = {'success': False, 'error': str(e)}

            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))

    def stop_monitoring(self):
        """監視プロセス停止"""
        try:
            settings = load_settings()
            settings['monitoring_enabled'] = False
            save_settings(settings)

            result = subprocess.run(
                ['sudo', '-n', 'systemctl', 'stop', 'shutter-trigger'],
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                response = {'success': True}
            else:
                response = {'success': False, 'error': result.stderr or result.stdout}

            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))

        except Exception as e:
            logger.error(f"Stop monitoring error: {e}")
            response = {'success': False, 'error': str(e)}

            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))

    def serve_wifi_status(self):
        """Wi-Fiステータス配信"""
        status = wifi_manager.get_wifi_status()
        # 保存されているAP設定も返す（フロントエンド表示用）
        ap_settings = wifi_manager.get_saved_ap_settings()
        status['ap_ssid'] = ap_settings['ssid']
        status['ap_password'] = ap_settings['password']
        
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(status).encode('utf-8'))

    def serve_wifi_diag(self):
        try:
            def run_cmd(cmd):
                try:
                    r = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
                    return {
                        'returncode': r.returncode,
                        'stdout': (r.stdout or '').strip(),
                        'stderr': (r.stderr or '').strip(),
                    }
                except Exception as e:
                    return {'returncode': -1, 'stdout': '', 'stderr': str(e)}

            diag = {
                'wifi_status': wifi_manager.get_wifi_status(),
                'ip_link': run_cmd(['ip', '-o', 'link', 'show']),
                'iw_dev': run_cmd(['iw', 'dev']),
                'run_wpa_supplicant_ls': run_cmd(['ls', '-la', '/run/wpa_supplicant']),
                'var_run_wpa_supplicant_ls': run_cmd(['ls', '-la', '/var/run/wpa_supplicant']),
                'ps_wpa': run_cmd(['sh', '-c', "ps -ef | egrep 'wpa_supplicant|hostapd|dnsmasq' | egrep -v egrep || true"]),
                'wpa_cli_status': run_cmd(['wpa_cli', 'status']),
            }

            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(diag).encode('utf-8'))

        except Exception as e:
            logger.error(f"serve_wifi_diag error: {e}")
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'message': str(e)}).encode('utf-8'))

    def write_wpa_settings(self):
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))

            ssid = data.get('ssid')
            psk = data.get('psk')
            result = wifi_manager.configure_wpa_supplicant(ssid, psk)

            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode('utf-8'))

        except json.JSONDecodeError:
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'message': 'Invalid JSON'}).encode('utf-8'))
        except Exception as e:
            logger.error(f"write_wpa_settings error: {e}")
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'message': str(e)}).encode('utf-8'))

    def switch_wifi_mode(self):
        """Wi-Fiモード切り替え処理"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            mode = data.get('mode')
            
            if mode == 'ap':
                ssid = data.get('ssid')
                password = data.get('password')
                result = wifi_manager.switch_to_ap_mode(ssid, password)
            elif mode == 'tethering':
                result = wifi_manager.switch_to_tethering_mode()
            else:
                result = {'success': False, 'message': 'Unknown mode'}
            
            if result['success']:
                self.send_response(200)
            else:
                self.send_response(500)
                
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode('utf-8'))
            
            # モード切り替え成功時にネットワーク再起動が走るため、
            # レスポンス送信後に少し待ってからプロセス終了等の処理が必要かも？
            # 今回は wifi_manager 側で処理完結させる
            
        except Exception as e:
            logger.error(f"Wi-Fi switch error: {e}")
            response = {'success': False, 'error': str(e)}
            
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode('utf-8'))

def load_settings():
    """設定ファイルから設定を読み込み"""
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings = json.load(f)
            
            # 欠落しているキーをデフォルト値で補完
            for key, default_value in DEFAULT_SETTINGS.items():
                if key not in settings:
                    settings[key] = default_value
            
            # boolean型の設定が文字列として保存される問題を修正
            settings['enable_multiple_exposure'] = settings.get('enable_multiple_exposure', False) in (True, 'True', 'true', 'on')
            settings['enable_2in1_composition'] = settings.get('enable_2in1_composition', False) in (True, 'True', 'true', 'on')
            settings['enable_timestamp'] = settings.get('enable_timestamp', False) in (True, 'True', 'true', 'on')
            
            return settings
        else:
            return DEFAULT_SETTINGS.copy()
    except Exception as e:
        logger.error(f"Settings load error: {e}")
        return DEFAULT_SETTINGS.copy()

def save_settings(settings):
    """設定をファイルに保存"""
    try:
        # 既存設定を読み込んで更新
        current_settings = load_settings()
        current_settings.update(settings)
        
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(current_settings, f, indent=2)
        
        logger.info("Settings saved successfully")
        
    except Exception as e:
        logger.error(f"Settings save error: {e}")
        raise

def get_photo_list():
    """写真ディレクトリから写真一覧を取得"""
    try:
        if not os.path.exists(PHOTOS_DIR):
            os.makedirs(PHOTOS_DIR, exist_ok=True)
            return []
        
        photos = []
        for filename in os.listdir(PHOTOS_DIR):
            if filename.lower().endswith(('.jpg', '.jpeg', '.png')):
                photos.append(filename)
        
        # 新しい順にソート
        photos.sort(reverse=True)
        return photos[:50]  # 最新50枚まで
        
    except Exception as e:
        logger.error(f"Photo list error: {e}")
        return []

def _get_uptime_seconds():
    try:
        with open('/proc/uptime', 'r') as f:
            first = f.read().strip().split()[0]
        return float(first)
    except Exception:
        return None

def _boot_network_already_applied():
    return os.path.exists('/run/picamera_boot_network_applied')

def _mark_boot_network_applied():
    try:
        with open('/run/picamera_boot_network_applied', 'w') as f:
            f.write('1')
    except Exception:
        pass

def main():
    """メイン関数"""
    try:
        # 必要なディレクトリを作成
        os.makedirs(PHOTOS_DIR, exist_ok=True)
        
        # --- 起動時のネットワーク設定適用 ---
        try:
            uptime = _get_uptime_seconds()
            if uptime is not None and uptime < 120 and not _boot_network_already_applied():
                settings = load_settings()
                current_mode = wifi_manager.get_current_mode()
                target_mode = settings.get('wifi_mode', 'tethering')

                logger.info(f"Boot check: current_mode={current_mode}, target_mode={target_mode}")

                if target_mode == 'ap' and current_mode != 'ap':
                    if not wifi_manager.has_nmcli():
                        logger.warning("Skip switching to AP mode on boot: nmcli is not available")
                    else:
                        logger.info("Switching to AP mode on boot...")
                        saved_ap = wifi_manager.get_saved_ap_settings()
                        ssid = settings.get('ap_ssid') or saved_ap.get('ssid')
                        password = settings.get('ap_password') or saved_ap.get('password')
                        wifi_manager.switch_to_ap_mode(ssid, password)

                elif target_mode == 'tethering':
                    if current_mode != 'tethering':
                        logger.info("Switching to Tethering mode on boot...")
                    else:
                        logger.info("Reasserting Tethering mode on boot...")
                    
                    wifi_manager.switch_to_tethering_mode()
                    
                    # テザリング接続確認
                    logger.info("Verifying tethering connection...")
                    if wifi_manager.check_tethering_connection(timeout=20):
                        logger.info("Tethering connection successful")
                    else:
                        logger.warning("Tethering connection failed, falling back to AP mode")
                        saved_ap = wifi_manager.get_saved_ap_settings()
                        ssid = settings.get('ap_ssid') or saved_ap.get('ssid')
                        password = settings.get('ap_password') or saved_ap.get('password')
                        logger.info(f"Starting AP mode: SSID={ssid}")
                        wifi_manager.switch_to_ap_mode(ssid, password)

                _mark_boot_network_applied()
            else:
                logger.info(f"Skip boot network apply (not system boot): uptime={uptime}")

        except Exception as e:
            logger.error(f"Failed to apply boot network settings: {e}")
        # ------------------------------------
        
        # HTTPサーバーを起動
        server_address = ('0.0.0.0', 8001)
        httpd = HTTPServer(server_address, CameraControlHandler)
        
        logger.info("Camera control server starting on port 8001")
        logger.info("Access via: http://localhost:8001")
        
        httpd.serve_forever()
        
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
