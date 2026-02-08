#!/usr/bin/env python3
"""
軽量APIサーバー（ライブビュー無し）
写真一覧取得とシステム状態管理のみ
"""

import os
import json
import logging
import subprocess
import time

import wifi_manager
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PHOTOS_DIR = '/home/pi/photos'
SETTINGS_FILE = '/home/pi/camera_settings.json'
DEFAULT_SETTINGS = {
    'brightness_threshold': 30,
    'detection_threshold': 30,
    'detection_interval': 0.25,
    'iso': 'auto',
    'shutter_speed': 'auto',
    'white_balance': 'auto',
    'width': 1920,
    'height': 1080,
    'contrast': 0,
    'saturation': 0,
    'enable_multiple_exposure': False,
    'enable_2in1_composition': False,
    'enable_timestamp': False,
    'monitoring_enabled': True,
    'quality': 90,
}

class APIHandler(BaseHTTPRequestHandler):
    
    def do_GET(self):
        parsed = urlparse(self.path)
        
        if parsed.path == '/':
            self.serve_root()
        elif parsed.path == '/api/photos':
            self.serve_photo_list()
        elif parsed.path == '/api/status':
            self.serve_status()
        elif parsed.path == '/api/settings':
            self.serve_settings()
        elif parsed.path == '/api/wifi/status':
            self.serve_wifi_status()
        elif parsed.path.startswith('/photos/'):
            self.serve_photo_file(parsed.path)
        else:
            self.send_error(404)
    
    def do_POST(self):
        parsed = urlparse(self.path)
        
        if parsed.path == '/api/settings':
            self.update_settings()
        elif parsed.path == '/api/photo':
            self.serve_photo_request()
        elif parsed.path == '/api/capture':
            self.capture_photo()
        elif parsed.path == '/api/wifi/write_wpa':
            self.write_wpa_settings()
        elif parsed.path == '/api/wifi/switch':
            self.switch_wifi_mode()
        else:
            self.send_error(404)
    
    def serve_photo_list(self):
        """写真一覧を返す"""
        try:
            files = []
            if os.path.exists(PHOTOS_DIR):
                files = [f for f in os.listdir(PHOTOS_DIR) if f.endswith('.jpg')]
                files.sort(reverse=True)  # 新しい順
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(files).encode())
        except Exception as e:
            logger.error(f"Error listing photos: {e}")
            self.send_error(500)

    def serve_wifi_status(self):
        """Wi-Fiステータス配信"""
        status = wifi_manager.get_wifi_status()
        ap_settings = wifi_manager.get_saved_ap_settings()
        status['ap_ssid'] = ap_settings['ssid']
        status['ap_password'] = ap_settings['password']

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(status).encode())

    def serve_root(self):
        """簡易ステータスページ"""
        html = """<!DOCTYPE html>
<html lang=\"ja\">
<head><meta charset=\"utf-8\"><title>PiCamera API</title></head>
<body>
<h1>PiCamera API Server</h1>
<ul>
  <li><a href=\"/api/status\">/api/status</a></li>
  <li><a href=\"/api/photos\">/api/photos</a></li>
  <li><a href=\"/api/settings\">/api/settings</a></li>
</ul>
</body>
</html>"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(html.encode())
    
    def serve_photo_file(self, path):
        """写真ファイルを配信"""
        try:
            filename = os.path.basename(path)
            filepath = os.path.join(PHOTOS_DIR, filename)
            
            if not os.path.exists(filepath):
                self.send_error(404)
                return
            
            with open(filepath, 'rb') as f:
                content = f.read()
            
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', len(content))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            logger.error(f"Error serving photo: {e}")
            self.send_error(500)

    def serve_photo_request(self):
        """POSTで写真ファイルを配信"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode()
            data = json.loads(body) if body else {}

            filename = data.get('filename', '')
            safe_name = os.path.basename(filename)
            if safe_name != filename:
                self.send_error(400)
                return
            if not safe_name.lower().endswith(('.jpg', '.jpeg', '.png')):
                self.send_error(400)
                return

            filepath = os.path.join(PHOTOS_DIR, safe_name)
            if not os.path.exists(filepath):
                self.send_error(404)
                return

            with open(filepath, 'rb') as f:
                content = f.read()

            content_type = 'image/png' if safe_name.lower().endswith('.png') else 'image/jpeg'
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(content))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            logger.error(f"Error serving photo (POST): {e}")
            self.send_error(500)
    
    def serve_status(self):
        """システム状態を返す"""
        try:
            photo_count = 0
            if os.path.exists(PHOTOS_DIR):
                photo_count = len([f for f in os.listdir(PHOTOS_DIR) if f.endswith('.jpg')])
            
            settings = DEFAULT_SETTINGS.copy()
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

            if 'detection_threshold' in settings and 'brightness_threshold' not in settings:
                settings['brightness_threshold'] = settings['detection_threshold']
            
            status = {
                'photo_count': photo_count,
                'brightness_threshold': settings.get('brightness_threshold', 30),
                'service_running': True
            }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(status).encode())
        except Exception as e:
            logger.error(f"Error getting status: {e}")
            self.send_error(500)
    
    def serve_settings(self):
        """設定情報を返す"""
        try:
            settings = DEFAULT_SETTINGS.copy()
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

            if 'detection_threshold' in settings and 'brightness_threshold' not in settings:
                settings['brightness_threshold'] = settings['detection_threshold']
            if 'brightness_threshold' in settings and 'detection_threshold' not in settings:
                settings['detection_threshold'] = settings['brightness_threshold']

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(settings).encode())
        except Exception as e:
            logger.error(f"Error getting settings: {e}")
            self.send_error(500)

    def update_settings(self):
        """設定を更新"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode()
            new_settings = json.loads(body)
            
            settings = DEFAULT_SETTINGS.copy()
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

            if 'detection_threshold' in new_settings and 'brightness_threshold' not in new_settings:
                new_settings['brightness_threshold'] = new_settings['detection_threshold']
            
            settings.update(new_settings)
            
            with open(SETTINGS_FILE, 'w') as f:
                json.dump(settings, f, indent=2)
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': True}).encode())
        except Exception as e:
            logger.error(f"Error updating settings: {e}")
            self.send_error(500)

    def write_wpa_settings(self):
        """家Wi-Fi設定を書き込み"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode()
            data = json.loads(body) if body else {}

            ssid = data.get('ssid')
            psk = data.get('psk')
            result = wifi_manager.configure_wpa_supplicant(ssid, psk)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        except json.JSONDecodeError:
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'message': 'Invalid JSON'}).encode())
        except Exception as e:
            logger.error(f"write_wpa_settings error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'message': str(e)}).encode())

    def switch_wifi_mode(self):
        """Wi-Fiモード切り替え"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode()
            data = json.loads(body) if body else {}

            mode = data.get('mode')

            if mode == 'ap':
                ssid = data.get('ssid')
                password = data.get('password')
                result = wifi_manager.switch_to_ap_mode(ssid, password)
            elif mode == 'tethering':
                result = wifi_manager.switch_to_tethering_mode()
            else:
                result = {'success': False, 'message': 'Unknown mode'}

            self.send_response(200 if result.get('success') else 500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        except Exception as e:
            logger.error(f"Wi-Fi switch error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())

    def capture_photo(self):
        """手動撮影"""
        service_stopped = False
        try:
            settings = DEFAULT_SETTINGS.copy()
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

            stop_result = subprocess.run(
                ['sudo', '-n', 'systemctl', 'stop', 'camera-service'],
                capture_output=True,
                text=True,
                check=False,
            )
            if stop_result.returncode != 0:
                response = {
                    'success': False,
                    'error': 'failed to stop camera-service (sudo required)'
                }
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(response).encode())
                return

            service_stopped = True
            for _ in range(10):
                status = subprocess.run(
                    ['systemctl', 'is-active', 'camera-service'],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if status.stdout.strip() in ('inactive', 'failed', 'deactivating'):
                    break
                time.sleep(0.3)

            timestamp = f"{time.time():.6f}"
            filename = f"manual_{timestamp}.jpg"
            photo_path = os.path.join(PHOTOS_DIR, filename)

            cmd = [
                'libcamera-still',
                '-o', photo_path,
                '--width', '1920',
                '--height', '1080',
                '--quality', str(settings.get('quality', 90)),
                '--timeout', '1000',
                '--nopreview'
            ]

            shutter_speed = settings.get('shutter_speed', 'auto')
            if shutter_speed != 'auto':
                try:
                    cmd.extend(['--shutter', str(int(shutter_speed))])
                except ValueError:
                    logger.warning(f"Invalid shutter speed value: {shutter_speed}")

            wb_value = settings.get('white_balance', 'auto')
            awb_supported = ('auto', 'daylight', 'cloudy', 'tungsten', 'fluorescent')
            awb_val = wb_value if wb_value in awb_supported else 'auto'
            cmd.extend(['--awb', awb_val])

            iso_value = settings.get('iso', 'auto')
            if iso_value != 'auto':
                try:
                    cmd.extend(['--gain', str(int(iso_value) / 100)])
                except ValueError:
                    logger.warning(f"Invalid ISO value: {iso_value}")

            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0:
                response = {'success': True, 'filename': filename}
                self.send_response(200)
            else:
                response = {'success': False, 'error': result.stderr}
                self.send_response(500)

            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        except Exception as e:
            logger.error(f"Capture error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())
        finally:
            if service_stopped:
                subprocess.run(['sudo', '-n', 'systemctl', 'start', 'camera-service'], check=False)
    
    def log_message(self, format, *args):
        """アクセスログ"""
        logger.info("%s - %s", self.client_address[0], format % args)

def restore_wifi_mode_on_boot():
    """起動時に前回のWi-Fiモードを復元"""
    try:
        if not os.path.exists(SETTINGS_FILE):
            return
        with open(SETTINGS_FILE, 'r') as f:
            settings = json.load(f)
        saved_mode = settings.get('wifi_mode')
        if not saved_mode:
            return

        current_mode = wifi_manager.get_current_mode()
        logger.info(f"Boot: saved_mode={saved_mode}, current_mode={current_mode}")

        if saved_mode == 'ap' and current_mode != 'ap':
            ap_ssid = settings.get('ap_ssid')
            ap_password = settings.get('ap_password')
            logger.info(f"Restoring AP mode: SSID={ap_ssid}")
            result = wifi_manager.switch_to_ap_mode(ap_ssid, ap_password)
            logger.info(f"AP restore result: {result}")
        elif saved_mode == 'tethering' and current_mode == 'ap':
            logger.info("Restoring tethering mode")
            result = wifi_manager.switch_to_tethering_mode()
            logger.info(f"Tethering restore result: {result}")
        else:
            logger.info(f"Wi-Fi mode already correct: {current_mode}")
    except Exception as e:
        logger.error(f"Failed to restore Wi-Fi mode: {e}")

def main():
    os.makedirs(PHOTOS_DIR, exist_ok=True)

    restore_wifi_mode_on_boot()
    
    server_address = ('0.0.0.0', 8001)
    HTTPServer.allow_reuse_address = True
    httpd = HTTPServer(server_address, APIHandler)
    logger.info("API Server running on port 8001")
    httpd.serve_forever()

if __name__ == '__main__':
    main()
