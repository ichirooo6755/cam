#!/usr/bin/env python3
"""
軽量APIサーバー（ライブビュー無し）
写真一覧取得とシステム状態管理のみ
"""

import os
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PHOTOS_DIR = '/home/pi/photos'
SETTINGS_FILE = '/home/pi/camera_settings.json'

class APIHandler(BaseHTTPRequestHandler):
    
    def do_GET(self):
        parsed = urlparse(self.path)
        
        if parsed.path == '/api/photos':
            self.serve_photo_list()
        elif parsed.path == '/api/status':
            self.serve_status()
        elif parsed.path.startswith('/photos/'):
            self.serve_photo_file(parsed.path)
        else:
            self.send_error(404)
    
    def do_POST(self):
        parsed = urlparse(self.path)
        
        if parsed.path == '/api/settings':
            self.update_settings()
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
    
    def serve_status(self):
        """システム状態を返す"""
        try:
            photo_count = 0
            if os.path.exists(PHOTOS_DIR):
                photo_count = len([f for f in os.listdir(PHOTOS_DIR) if f.endswith('.jpg')])
            
            settings = {}
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings = json.load(f)
            
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
    
    def update_settings(self):
        """設定を更新"""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode()
            new_settings = json.loads(body)
            
            settings = {}
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings = json.load(f)
            
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
    
    def log_message(self, format, *args):
        """ログを抑制"""
        pass

def main():
    os.makedirs(PHOTOS_DIR, exist_ok=True)
    
    server_address = ('0.0.0.0', 8001)
    httpd = HTTPServer(server_address, APIHandler)
    logger.info("API Server running on port 8001")
    httpd.serve_forever()

if __name__ == '__main__':
    main()
