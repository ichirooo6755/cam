#!/usr/bin/env python3
"""
PiCamera API Mock Server - シミュレーション用
Raspberry PiのAPIを模倣してiOSアプリの検証を行う
"""

import http.server
import socketserver
import json
import os
import time
from datetime import datetime, timezone

PORT = 8001
PHOTOS_DIR = "/tmp/picamera_photos"

# モック設定
MOCK_SETTINGS = {
    "camera_mode": "standard",
    "brightness_threshold": 30,
    "detection_threshold": 30,
    "detection_interval": 0.25,
    "check_interval": 0.25,
    "capture_cooldown": 0.25,
    "iso": "auto",
    "shutter_speed": "auto",
    "white_balance": "auto",
    "width": 1920,
    "height": 1080,
    "contrast": 0,
    "saturation": 0,
    "enable_multiple_exposure": False,
    "enable_2in1_composition": False,
    "enable_timestamp": False,
    "monitoring_enabled": True,
    "quality": 90,
}

MOCK_SESSION_OVERRIDES = {}

MOCK_PHOTOS = [
    "photo_20260216_120000_000000.jpg",
    "photo_20260216_115500_000000.jpg",
    "photo_20260216_115000_000000.jpg",
]

MOCK_SENSOR = {
    "service": "camera-service",
    "camera_mode": "standard",
    "monitoring_enabled": True,
    "threshold_percent": 30,
    "detection_interval": 0.25,
    "check_interval": 0.25,
    "capture_cooldown": 0.25,
    "brightness": 12.5,
    "lux": 12.5,
    "ae_gain": 2.0,
    "ae_exposure_us": 33333.0,
    "last_change_percent": 5.2,
    "last_change_amount": 3.1,
    "last_capture_at": None,
    "last_detected_at": None,
    "last_detect_to_capture_ms": None,
    "width": 1920,
    "height": 1080,
    "state": "monitoring",
    "updated_at": None,
}


def _effective_settings():
    merged = dict(MOCK_SETTINGS)
    merged.update(MOCK_SESSION_OVERRIDES)
    return merged


class MockCameraHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")

    def _read_json_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            body = self.rfile.read(content_length).decode()
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return {}
        return {}

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _send_text(self, text, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(text.encode())

    def do_GET(self):
        path = self.path.split('?')[0]

        if path == '/api/settings':
            settings = _effective_settings()
            self._send_json(settings)

        elif path == '/api/status':
            self._send_json({
                "photo_count": len(MOCK_PHOTOS),
                "brightness_threshold": _effective_settings().get("brightness_threshold", 30),
                "service_running": True,
                "server_time_unix": time.time(),
            })

        elif path == '/api/wifi/status':
            self._send_json({
                "mode": "ap",
                "ip": "192.168.4.1",
                "ip_address": "192.168.4.1",
                "ssid": "PiCamera",
                "ap_ssid": "PiCamera",
            })

        elif path == '/api/photos':
            self._send_json(MOCK_PHOTOS)

        elif path == '/api/sensor/status':
            MOCK_SENSOR["updated_at"] = datetime.now().isoformat()
            settings = _effective_settings()
            self._send_json({
                "success": True,
                "sensor": MOCK_SENSOR,
                "settings": {
                    "camera_mode": settings.get("camera_mode", "standard"),
                    "monitoring_enabled": settings.get("monitoring_enabled", True),
                    "iso": settings.get("iso", "auto"),
                    "shutter_speed": settings.get("shutter_speed", "auto"),
                    "white_balance": settings.get("white_balance", "auto"),
                    "quality": settings.get("quality", 90),
                },
            })

        elif path == '/':
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
<li><a href="/api/photos">Photos</a></li>
<li><a href="/api/sensor/status">Sensor Status</a></li>
</ul>
</body>
</html>"""
            self._send_text(html)

        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        data = self._read_json_body()

        if self.path == '/api/settings':
            is_temporary = data.pop('temporary', False)
            reset_temporary = data.pop('reset_temporary', False)

            if reset_temporary:
                MOCK_SESSION_OVERRIDES.clear()
                self._send_json({"success": True})
                return

            if is_temporary:
                data.pop('camera_mode', None)
                MOCK_SESSION_OVERRIDES.update(data)
            else:
                MOCK_SETTINGS.update(data)
            self._send_json({"success": True})

        elif self.path == '/api/system/time':
            self._send_json({"success": True})

        elif self.path == '/api/capture':
            timestamp = f"{time.time():.6f}"
            manual_mode = data.get('manual_mode', 'current')
            meta = data.get('meta')
            filename = f"manual_{timestamp}.jpg"
            MOCK_PHOTOS.insert(0, filename)

            settings = _effective_settings()
            metadata = {
                "timestamp": timestamp,
                "captured_at": datetime.now(timezone.utc).isoformat(),
                "manual_mode": manual_mode,
                "applied_mode": manual_mode if manual_mode != 'current' else settings.get("camera_mode", "standard"),
                "meta": meta,
                "iso": settings.get("iso"),
                "shutter_speed": settings.get("shutter_speed"),
                "white_balance": settings.get("white_balance"),
                "quality": settings.get("quality"),
                "width": settings.get("width", 1920),
                "height": settings.get("height", 1080),
            }

            location = data.get('location')
            if isinstance(location, dict):
                lat = location.get('latitude')
                lon = location.get('longitude')
                if lat is not None and lon is not None:
                    metadata['latitude'] = lat
                    metadata['longitude'] = lon
                label = location.get('label')
                if label:
                    metadata['location_label'] = label

            self._send_json({
                "success": True,
                "filename": filename,
                "metadata": metadata,
            })

        elif self.path == '/api/photo':
            filename = data.get('filename', '')
            # 1x1 赤い JPEG ピクセル (mock画像)
            mock_jpeg = bytes([
                0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
                0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
                0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
                0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
                0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
                0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
                0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
                0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
                0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
                0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
                0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
                0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
                0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
                0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
                0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
                0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
                0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
                0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
                0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
                0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
                0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
                0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
                0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
                0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
                0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
                0x00, 0x00, 0x3F, 0x00, 0x7B, 0x94, 0x11, 0x00, 0x00, 0x00, 0x00, 0xFF,
                0xD9,
            ])
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', str(len(mock_jpeg)))
            self.end_headers()
            self.wfile.write(mock_jpeg)

        elif self.path == '/api/photo/meta':
            filename = data.get('filename', '')
            self._send_json({
                "success": True,
                "metadata": {
                    "timestamp": str(time.time()),
                    "captured_at": datetime.now(timezone.utc).isoformat(),
                    "manual_mode": "current",
                    "applied_mode": "standard",
                    "iso": "auto",
                    "shutter_speed": "auto",
                    "white_balance": "auto",
                    "quality": 90,
                    "width": 1920,
                    "height": 1080,
                },
            })

        elif self.path == '/api/photos/delete':
            filenames = data.get('filenames', [])
            deleted = []
            for f in filenames:
                if f in MOCK_PHOTOS:
                    MOCK_PHOTOS.remove(f)
                    deleted.append(f)
            self._send_json({
                "success": True,
                "deleted": deleted,
                "not_found": [f for f in filenames if f not in deleted],
                "invalid": [],
                "errors": [],
            })

        elif self.path == '/api/wifi/switch':
            mode = data.get('mode', 'ap')
            self._send_json({
                "success": True,
                "message": f"{mode}モード切替を開始しました。",
                "ip": "192.168.4.1",
                "ip_address": "192.168.4.1",
            })

        elif self.path == '/api/wifi/write_wpa':
            ssid = data.get('ssid', '')
            self._send_json({
                "success": True,
                "message": f"WPA設定を書き込みました: {ssid}",
            })

        elif self.path == '/api/metering':
            settings = _effective_settings()
            self._send_json({
                "success": True,
                "recommendation": {
                    "recommended_iso": 200,
                    "recommended_shutter_us": 16666,
                    "recommended_shutter_label": "1/60",
                    "base_iso": 200,
                    "base_shutter_us": 16666,
                    "base_shutter_label": "1/60",
                    "source": "mock",
                    "camera_mode": settings.get("camera_mode", "standard"),
                    "lux": MOCK_SENSOR.get("lux"),
                    "brightness": MOCK_SENSOR.get("brightness"),
                },
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
        print(f"PiCamera Mock Server running at http://0.0.0.0:{PORT}")
        print(f"Photos dir: {PHOTOS_DIR}")
        print("Press Ctrl+C to stop")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped")
