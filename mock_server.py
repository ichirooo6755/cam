#!/usr/bin/env python3
"""
PiCamera API Mock Server - シミュレーション用
Raspberry PiのAPIを模倣してiOSアプリの検証を行う
"""

import http.server
import socketserver
import json
import os
from datetime import datetime

PORT = 8001
PHOTOS_DIR = "/tmp/picamera_photos"

# モック設定
MOCK_SETTINGS = {
    "iso": "auto",
    "shutter_speed": "auto",
    "white_balance": "auto",
    "detection_threshold": 50,
    "enable_multiple_exposure": False,
    "enable_2in1_composition": False,
    "enable_timestamp": True
}

class MockCameraHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _send_text(self, text, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(text.encode())

    def do_GET(self):
        parsed_path = self.path
        
        if parsed_path == '/api/settings':
            self._send_json(MOCK_SETTINGS)
        
        elif parsed_path == '/api/status':
            self._send_json({
                "camera_status": "active",
                "last_capture": None,
                "photos_count": 0,
                "storage_available": "1.2GB"
            })
        
        elif parsed_path == '/api/wifi/status':
            self._send_json({
                "mode": "ap",
                "ip": "192.168.4.1",
                "ip_address": "192.168.4.1",
                "ssid": "PiCamera"
            })
        
        elif parsed_path == '/':
            html = """<!DOCTYPE html>
<html>
<head><title>PiCamera Mock</title></head>
<body>
<h1>PiCamera Mock Server Running</h1>
<p>Status: Active (Simulation Mode)</p>
<ul>
<li><a href="/api/settings">Settings</a></li>
<li><a href="/api/status">Status</a></li>
<li><a href="/api/wifi/status">WiFi Status</a></li>
</ul>
</body>
</html>"""
            self._send_text(html)
        
        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else b'{}'
        
        try:
            data = json.loads(body.decode())
        except Exception:
            data = {}

        if self.path == '/api/settings':
            MOCK_SETTINGS.update(data)
            self._send_json({"success": True, "settings": MOCK_SETTINGS})
        
        elif self.path == '/api/capture':
            filename = f"mock_photo_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jpg"
            self._send_json({
                "success": True,
                "filename": filename,
                "message": "Mock capture successful"
            })
        
        elif self.path == '/api/wifi/switch':
            mode = data.get('mode', 'ap')
            self._send_json({
                "success": True,
                "message": f"Switched to {mode} mode (mock)",
                "ip": "192.168.4.1",
                "ip_address": "192.168.4.1"
            })
        
        elif self.path == '/api/restart_monitoring':
            self._send_json({"success": True})
        
        elif self.path == '/api/stop_monitoring':
            self._send_json({"success": True})
        
        else:
            self._send_json({"error": "Not found"}, 404)

if __name__ == '__main__':
    os.makedirs(PHOTOS_DIR, exist_ok=True)
    
    with socketserver.TCPServer(("", PORT), MockCameraHandler) as httpd:
        print(f"🚀 PiCamera Mock Server running at http://0.0.0.0:{PORT}")
        print(f"📁 Photos dir: {PHOTOS_DIR}")
        print("Press Ctrl+C to stop")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n👋 Server stopped")
