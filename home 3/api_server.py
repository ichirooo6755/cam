#!/usr/bin/env python3
"""
軽量APIサーバー（ライブビュー無し）
写真一覧取得とシステム状態管理のみ
"""

import os
import json
import logging
import subprocess
import shutil
import glob
import time
import threading
import re
import datetime
import base64

import wifi_manager
try:
    from PIL import Image
except ImportError:
    Image = None
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _resolve_still_binary():
    """libcamera-still / rpicam-still のうち利用可能なものを返す。Bookworm 以降は rpicam-still が標準。"""
    for name in ('rpicam-still', 'libcamera-still'):
        path = shutil.which(name)
        if path:
            return path
    return None


PHOTOS_DIR = '/home/pi/photos'
THUMBNAIL_DIR = os.path.join(PHOTOS_DIR, '_thumbs')
THUMBNAIL_MAX_DIM_DEFAULT = 300
THUMBNAIL_QUALITY = 75
SETTINGS_FILE = '/home/pi/camera_settings.json'
SESSION_OVERRIDES_FILE = '/home/pi/camera_session_overrides.json'
SENSOR_STATUS_FILE = '/run/picamera/sensor_status.json'
CAPTURE_REQUEST_FILE = '/run/picamera/capture_request.json'
CAPTURE_RESULT_FILE  = '/run/picamera/capture_result.json'
LAST_CAPTURE_FILE = '/run/picamera/last_capture_unix'
_CAPTURE_IPC_POLL_INTERVAL = 0.02   # 結果待ち（秒）: 専用IPCスレッドと併用
_CAPTURE_IPC_TIMEOUT_BASE_SEC = 30.0  # camera_service.py と揃える（reconfig+露光の余裕）
_CAPTURE_IPC_LATE_GRACE_SEC = 10.0   # タイムアウト後も result 到着を待つ猶予
_CAPTURE_PREVIEW_MAX_DIM = 640      # 大きすぎるとAP転送中に切断されやすい
AP_CAPTURE_GRACE_SEC = 60.0         # 撮影直後はAPウォッチドッグの再構築を抑止
BOOT_NETWORK_APPLIED_MARKERS = (
    '/run/picamera_boot_network_applied',
    '/tmp/picamera_boot_network_applied',
)
SAFE_FILENAME_PATTERN = re.compile(r'^[A-Za-z0-9._-]+$')
# camera_service の光検知撮影は raw_mode 時に .dng を保存するため一覧・配信対象に含める
ALLOWED_PHOTO_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.dng')
MAX_JSON_BODY_BYTES = 64 * 1024
WIFI_SWITCH_COOLDOWN_SEC = 12
WIFI_RECOVERY_CHECK_INTERVAL_SEC = 15
WIFI_RECOVERY_OFFLINE_GRACE_SEC = 75
WIFI_RECOVERY_ATTEMPT_COOLDOWN_SEC = 150
# テザリング切替直後は一時的に不安定になりやすいため、AP自動復旧を抑止
WIFI_RECOVERY_TETHERING_STABILIZE_SEC = 300
AP_IP_PREFIXES = ('192.168.4.', '10.42.0.')

_WIFI_SWITCH_LOCK = threading.Lock()
_WIFI_SWITCH_STATE = {
    'in_progress': False,
    'started_at': 0.0,
    'last_mode': None,
}

_WIFI_RECOVERY_LOCK = threading.Lock()
_WIFI_RECOVERY_STATE = {
    'offline_since': None,
    'last_attempt_at': 0.0,
    'last_mode': None,
    'last_mode_changed_at': 0.0,
    'last_result': None,
    'last_error': None,
}

# /api/status の photo_count は監視ポーリングで高頻度に呼ばれるため短TTLでキャッシュする。
_PHOTO_COUNT_CACHE = {'value': 0, 'expires_at': 0.0}
_PHOTO_COUNT_CACHE_LOCK = threading.Lock()
_PHOTO_COUNT_CACHE_TTL_SEC = 3.0

ALLOWED_SETTINGS_KEYS = {
    'camera_mode',
    'brightness_threshold',
    'detection_threshold',
    'detection_interval',
    'check_interval',
    'capture_cooldown',
    'iso',
    'shutter_speed',
    'white_balance',
    'contrast',
    'saturation',
    'quality',
    'width',
    'height',
    'enable_multiple_exposure',
    'enable_2in1_composition',
    'enable_timestamp',
    'monitoring_enabled',
    'raw_mode',
    'denoise_mode',
    'sharpness',
    'stabilization',
    'detection_fps',
}

ALLOWED_WHITE_BALANCE = {'auto', 'daylight', 'cloudy', 'tungsten', 'fluorescent', 'shade'}
DEFAULT_SETTINGS = {
    'camera_mode': 'standard',
    'brightness_threshold': 30,
    'detection_threshold': 30,
    'detection_interval': 0.5,
    'check_interval': 0.5,
    'capture_cooldown': 3.0,
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


def _load_settings_dict() -> dict:
    """camera_settings.json を読み込む。空ファイル・破損時は {} を返す。"""
    if not os.path.exists(SETTINGS_FILE):
        return {}
    try:
        if os.path.getsize(SETTINGS_FILE) == 0:
            logger.warning("Settings file is empty, using defaults")
            return {}
        with open(SETTINGS_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, OSError, ValueError) as e:
        logger.warning("Failed to load settings file, using defaults: %s", e)
        return {}


def _save_settings_dict(settings: dict) -> None:
    """設定をアトミックに保存（書き込み中の電源断で0バイト化しない）。"""
    tmp_path = f"{SETTINGS_FILE}.tmp"
    with open(tmp_path, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, SETTINGS_FILE)


def _save_session_overrides_dict(overrides: dict) -> None:
    """session_overrides.json をアトミックに保存。"""
    if not overrides:
        try:
            if os.path.exists(SESSION_OVERRIDES_FILE):
                os.remove(SESSION_OVERRIDES_FILE)
        except Exception as e:
            logger.warning("Failed to remove empty session overrides: %s", e)
        return
    tmp_path = f"{SESSION_OVERRIDES_FILE}.tmp"
    with open(tmp_path, 'w', encoding='utf-8') as f:
        json.dump(overrides, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, SESSION_OVERRIDES_FILE)


def _invalidate_photo_count_cache() -> None:
    with _PHOTO_COUNT_CACHE_LOCK:
        _PHOTO_COUNT_CACHE['expires_at'] = 0.0


def _ipc_capture_timeout_sec(settings: dict) -> float:
    """露光時間・reconfig を考慮した IPC 待ち時間（camera_service と整合）。"""
    shutter_us = 0
    shutter_speed = settings.get('shutter_speed', 'auto')
    if shutter_speed not in (None, 'auto', ''):
        try:
            shutter_us = max(0, int(shutter_speed))
        except (ValueError, TypeError):
            shutter_us = 0
    exposure_sec = shutter_us / 1_000_000.0
    return max(_CAPTURE_IPC_TIMEOUT_BASE_SEC, 30.0 + exposure_sec + 8.0)


def _recent_capture_within(grace_sec: float) -> bool:
    """直近の撮影直後か（APウォッチドッグ抑止用）"""
    try:
        if os.path.exists(LAST_CAPTURE_FILE):
            with open(LAST_CAPTURE_FILE, 'r', encoding='utf-8') as f:
                last_unix = float((f.read() or '').strip())
            if time.time() - last_unix < grace_sec:
                return True
    except Exception:
        pass

    try:
        if os.path.exists(SENSOR_STATUS_FILE):
            with open(SENSOR_STATUS_FILE, 'r', encoding='utf-8') as f:
                sensor = json.load(f)
            last_at = sensor.get('last_capture_at')
            if isinstance(last_at, str):
                dt = datetime.datetime.fromisoformat(last_at.replace('Z', '+00:00'))
                if dt.tzinfo is None:
                    age = time.time() - dt.timestamp()
                else:
                    age = time.time() - dt.timestamp()
                if age < grace_sec:
                    return True
    except Exception:
        pass
    return False


def _encode_capture_preview_base64(photo_path: str, max_dim: int = _CAPTURE_PREVIEW_MAX_DIM):
    """撮影レスポンス同梱用のJPEGプレビューを base64 で返す"""
    if not photo_path or not os.path.exists(photo_path):
        return None

    content_path = photo_path
    if photo_path.lower().endswith('.dng'):
        thumb_path = _ensure_thumbnail(photo_path, max_dim)
        if not thumb_path:
            return None
        content_path = thumb_path
    elif Image is not None and max_dim > 0:
        try:
            thumb_path = _ensure_thumbnail(photo_path, max_dim)
            if thumb_path:
                content_path = thumb_path
        except Exception:
            pass

    try:
        with open(content_path, 'rb') as f:
            return base64.b64encode(f.read()).decode('ascii')
    except Exception as e:
        logger.warning("Failed to encode capture preview: %s", e)
        return None


def _is_camera_service_running() -> bool:
    """camera-service が active かどうかを確認"""
    try:
        result = subprocess.run(
            ['systemctl', 'is-active', 'camera-service'],
            capture_output=True, text=True, check=False, timeout=5,
        )
        return result.stdout.strip() == 'active'
    except Exception:
        return False


def _poll_ipc_result_for_request(request_id: str, timeout_sec: float) -> dict | None:
    """capture_result.json を request_id 一致までポーリング。"""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if os.path.exists(CAPTURE_RESULT_FILE):
            try:
                with open(CAPTURE_RESULT_FILE, 'r', encoding='utf-8') as f:
                    result = json.load(f)
            except Exception:
                result = None
            if isinstance(result, dict) and result.get('request_id') == request_id:
                try:
                    os.remove(CAPTURE_RESULT_FILE)
                except Exception:
                    pass
                return result
        time.sleep(_CAPTURE_IPC_POLL_INTERVAL)
    return None


def _finalize_ipc_capture_paths(result: dict, photo_path: str) -> dict:
    """IPC 成功結果の filepath を期待パスへ揃える。"""
    if not result.get('success') or not result.get('filepath'):
        return result
    actual_path = result['filepath']
    if os.path.exists(actual_path) and actual_path != photo_path:
        try:
            os.rename(actual_path, photo_path)
            result['filepath'] = photo_path
            result['filename'] = os.path.basename(photo_path)
        except Exception:
            result['filepath'] = actual_path
            result['filename'] = os.path.basename(actual_path)
    return result


def _run_rpicam_still_capture(
    settings: dict,
    photo_path: str,
    width: int,
    height: int,
    shutter_us: int,
) -> tuple[bool, str]:
    """camera-service 停止中のみ使用する rpicam-still フォールバック。"""
    still_bin = _resolve_still_binary()
    if not still_bin:
        return False, 'rpicam-still / libcamera-still が見つかりません。rpicam-apps をインストールしてください。'

    if shutter_us > 3_000_000:
        rpicam_timeout_ms = shutter_us // 1000 + 3000
    else:
        rpicam_timeout_ms = 5000

    proc_timeout_sec = max(60, (rpicam_timeout_ms + shutter_us) // 1_000_000 + 15)

    cmd = [
        still_bin,
        '-o', photo_path,
        '--width', str(width),
        '--height', str(height),
        '--quality', str(settings.get('quality', 90)),
        '--timeout', str(rpicam_timeout_ms),
        '--nopreview',
    ]

    if shutter_us > 0:
        cmd.extend(['--shutter', str(shutter_us)])

    wb_value = settings.get('white_balance', 'auto')
    awb_supported = ('auto', 'daylight', 'cloudy', 'tungsten', 'fluorescent')
    awb_val = wb_value if wb_value in awb_supported else 'auto'
    cmd.extend(['--awb', awb_val])

    iso_value = settings.get('iso', 'auto')
    if iso_value != 'auto':
        try:
            cmd.extend(['--gain', str(int(iso_value) / 100)])
        except ValueError:
            logger.warning("Invalid ISO value: %s", iso_value)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=proc_timeout_sec)
    except subprocess.TimeoutExpired:
        try:
            os.remove(photo_path)
        except OSError:
            pass
        return False, f'capture timed out ({os.path.basename(still_bin)} {proc_timeout_sec}s exceeded)'
    except FileNotFoundError as e:
        return False, f'capture binary not found: {e}'

    if result.returncode != 0:
        return False, (result.stderr or 'rpicam-still failed').strip()

    try:
        file_size = os.path.getsize(photo_path)
    except OSError:
        file_size = 0
    if file_size == 0:
        try:
            os.remove(photo_path)
        except OSError:
            pass
        return False, 'capture produced empty file (camera may not be available)'

    return True, ''


def _ipc_capture(settings: dict, photo_path: str, mode_label: str) -> dict:
    """
    camera_service.py 経由のIPC撮影。
    camera-service が active な場合に呼び出す。
    成功時: {'success': True, 'filepath': ..., 'filename': ...}
    失敗時: {'success': False, 'error': ...}
    """
    import uuid
    request_id = str(uuid.uuid4())[:16]
    timeout_sec = _ipc_capture_timeout_sec(settings)

    # camera_service.py がリクエスト内の設定を使って撮影するので、解決済みの設定を渡す
    req = {
        'request_id': request_id,
        'created_at': time.time(),
        'width': int(settings.get('width', 1920)),
        'height': int(settings.get('height', 1080)),
        'quality': int(settings.get('quality', 90)),
        'shutter_speed': settings.get('shutter_speed', 'auto'),
        'iso': settings.get('iso', 'auto'),
        'raw_mode': bool(settings.get('raw_mode', False)),
        'denoise_mode': settings.get('denoise_mode', 'auto'),
        'white_balance': settings.get('white_balance', 'auto'),
    }

    # 既存の結果ファイルを削除（古い結果が残っている場合）
    try:
        if os.path.exists(CAPTURE_RESULT_FILE):
            os.remove(CAPTURE_RESULT_FILE)
    except Exception:
        pass

    # リクエストファイルを書き込む
    try:
        tmp_req = f"{CAPTURE_REQUEST_FILE}.tmp"
        with open(tmp_req, 'w', encoding='utf-8') as f:
            json.dump(req, f, indent=2)
        os.replace(tmp_req, CAPTURE_REQUEST_FILE)
    except Exception as e:
        return {'success': False, 'error': f'Failed to write IPC request: {e}', 'request_id': request_id}

    def _write_request(_request_id: str) -> None:
        req['request_id'] = _request_id
        req['created_at'] = time.time()
        tmp_req = f"{CAPTURE_REQUEST_FILE}.tmp"
        with open(tmp_req, 'w', encoding='utf-8') as f:
            json.dump(req, f, indent=2)
        os.replace(tmp_req, CAPTURE_REQUEST_FILE)

    result = _poll_ipc_result_for_request(request_id, timeout_sec)
    if result is None:
        result = _poll_ipc_result_for_request(request_id, _CAPTURE_IPC_LATE_GRACE_SEC)
    if result is None:
        try:
            os.remove(CAPTURE_REQUEST_FILE)
        except Exception:
            pass
        return {'success': False, 'error': 'IPC capture timed out', 'request_id': request_id}

    result = _finalize_ipc_capture_paths(result, photo_path)
    result.setdefault('request_id', request_id)
    return result


def _sanitize_meta_tag(value):
    if not value:
        return None
    safe = re.sub(r'[^A-Za-z0-9._-]+', '_', str(value).strip())
    safe = safe.strip('._-')
    if not safe:
        return None
    return safe[:48]


def _sanitize_location_label(value):
    if not value:
        return None
    safe = re.sub(r'[^A-Za-z0-9._\-\s]+', '', str(value).strip())
    safe = re.sub(r'\s+', ' ', safe).strip()
    if not safe:
        return None
    return safe[:96]


def _unsafe_text_chars_present(value):
    if value is None:
        return False
    text = str(value)
    return any((ord(ch) < 32 and ch not in ('\t',)) for ch in text)


def _parse_bool_value(value, default=False):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {'1', 'true', 'yes', 'on'}:
            return True
        if lowered in {'0', 'false', 'no', 'off', ''}:
            return False
    return default


def _parse_int(value):
    if isinstance(value, bool):
        return None
    try:
        if isinstance(value, str):
            value = value.strip()
        return int(value)
    except Exception:
        return None


def _parse_float(value):
    if isinstance(value, bool):
        return None
    try:
        if isinstance(value, str):
            value = value.strip()
        return float(value)
    except Exception:
        return None


def _read_json_body(handler, max_bytes=MAX_JSON_BODY_BYTES):
    content_length_raw = handler.headers.get('Content-Length', '0')
    try:
        content_length = int(content_length_raw)
    except Exception:
        handler.send_response(400)
        handler.send_header('Content-Type', 'application/json')
        handler.end_headers()
        handler.wfile.write(json.dumps({'success': False, 'message': 'Invalid Content-Length'}).encode())
        return None

    if content_length < 0 or content_length > max_bytes:
        handler.send_response(413)
        handler.send_header('Content-Type', 'application/json')
        handler.end_headers()
        handler.wfile.write(json.dumps({'success': False, 'message': 'Request body too large'}).encode())
        return None

    body = handler.rfile.read(content_length).decode() if content_length > 0 else ''
    if not body:
        return {}

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        handler.send_response(400)
        handler.send_header('Content-Type', 'application/json')
        handler.end_headers()
        handler.wfile.write(json.dumps({'success': False, 'message': 'Invalid JSON'}).encode())
        return None

    if not isinstance(payload, dict):
        handler.send_response(400)
        handler.send_header('Content-Type', 'application/json')
        handler.end_headers()
        handler.wfile.write(json.dumps({'success': False, 'message': 'JSON object required'}).encode())
        return None

    return payload


def _sanitize_settings_patch(patch):
    errors = []
    sanitized = {}

    for key, value in patch.items():
        if key not in ALLOWED_SETTINGS_KEYS:
            errors.append(f'Unsupported setting key: {key}')
            continue

        if key == 'camera_mode':
            mode = str(value).strip().lower()
            if mode not in CAMERA_MODE_PRESETS:
                errors.append('camera_mode must be one of reaction/standard/quality/night/battery/manual/raw')
            else:
                sanitized[key] = mode
            continue

        if key in ('brightness_threshold', 'detection_threshold'):
            ivalue = _parse_int(value)
            if ivalue is None or ivalue < 0 or ivalue > 100:
                errors.append(f'{key} must be an integer in 0..100')
            else:
                sanitized[key] = ivalue
            continue

        if key in ('width', 'height'):
            ivalue = _parse_int(value)
            if ivalue is None or ivalue < 320 or ivalue > 5000:
                errors.append(f'{key} must be an integer in 320..5000')
            else:
                sanitized[key] = ivalue
            continue

        if key in ('quality',):
            ivalue = _parse_int(value)
            if ivalue is None or ivalue < 60 or ivalue > 100:
                errors.append('quality must be an integer in 60..100')
            else:
                sanitized[key] = ivalue
            continue

        if key in ('contrast', 'saturation'):
            ivalue = _parse_int(value)
            if ivalue is None or ivalue < -100 or ivalue > 100:
                errors.append(f'{key} must be an integer in -100..100')
            else:
                sanitized[key] = ivalue
            continue

        if key in ('detection_interval', 'check_interval'):
            fvalue = _parse_float(value)
            if fvalue is None or fvalue < 0.05 or fvalue > 10:
                errors.append(f'{key} must be a number in 0.05..10.0')
            else:
                sanitized[key] = round(fvalue, 3)
            continue

        if key == 'capture_cooldown':
            fvalue = _parse_float(value)
            if fvalue is None or fvalue < 0 or fvalue > 30:
                errors.append('capture_cooldown must be a number in 0..30')
            else:
                sanitized[key] = round(fvalue, 3)
            continue

        if key == 'iso':
            if isinstance(value, str):
                lowered = value.strip().lower()
                if lowered == 'auto':
                    sanitized[key] = 'auto'
                else:
                    ivalue = _parse_int(value)
                    if ivalue not in METERING_ISO_STOPS:
                        errors.append('iso must be auto or one of 100/200/400/800/1600/3200')
                    else:
                        sanitized[key] = ivalue
            else:
                ivalue = _parse_int(value)
                if ivalue not in METERING_ISO_STOPS:
                    errors.append('iso must be auto or one of 100/200/400/800/1600/3200')
                else:
                    sanitized[key] = ivalue
            continue

        if key == 'shutter_speed':
            if isinstance(value, str) and value.strip().lower() == 'auto':
                sanitized[key] = 'auto'
            else:
                ivalue = _parse_int(value)
                if ivalue is None or ivalue < 100 or ivalue > 120_000_000:
                    errors.append('shutter_speed must be auto or microseconds in 100..120000000')
                else:
                    sanitized[key] = ivalue
            continue

        if key == 'white_balance':
            wb = str(value).strip().lower()
            if wb not in ALLOWED_WHITE_BALANCE:
                errors.append('white_balance must be auto/daylight/cloudy/tungsten/fluorescent/shade')
            else:
                sanitized[key] = wb
            continue

        if key in ('enable_multiple_exposure', 'enable_2in1_composition', 'enable_timestamp', 'monitoring_enabled'):
            parsed = _parse_bool_value(value, default=None)
            if parsed is None:
                errors.append(f'{key} must be boolean')
            else:
                sanitized[key] = parsed
            continue

    return sanitized, errors


def _begin_wifi_switch(mode, bypass_cooldown=False):
    now = time.time()
    with _WIFI_SWITCH_LOCK:
        if _WIFI_SWITCH_STATE.get('in_progress'):
            return False, '別のWi-Fi切替処理が進行中です。しばらく待ってから再実行してください。'

        started_at = float(_WIFI_SWITCH_STATE.get('started_at') or 0.0)
        if (not bypass_cooldown) and now - started_at < WIFI_SWITCH_COOLDOWN_SEC:
            return False, f'Wi-Fi切替直後です。{WIFI_SWITCH_COOLDOWN_SEC}秒以上空けて再試行してください。'

        _WIFI_SWITCH_STATE['in_progress'] = True
        _WIFI_SWITCH_STATE['started_at'] = now
        _WIFI_SWITCH_STATE['last_mode'] = mode
        return True, None


def _finish_wifi_switch():
    with _WIFI_SWITCH_LOCK:
        _WIFI_SWITCH_STATE['in_progress'] = False


def _is_wifi_switching():
    with _WIFI_SWITCH_LOCK:
        return bool(_WIFI_SWITCH_STATE.get('in_progress'))


def _persist_wifi_mode(mode, ap_ssid=None, ap_password=None):
    """Wi-Fiモードをcamera_settings.jsonに保存"""
    try:
        settings = _load_settings_dict()

        settings['wifi_mode'] = mode
        if ap_ssid:
            settings['ap_ssid'] = ap_ssid
        if ap_password:
            settings['ap_password'] = ap_password

        _save_settings_dict(settings)
        logger.info(f"Wi-Fi mode saved: {mode}")
        with _WIFI_RECOVERY_LOCK:
            _WIFI_RECOVERY_STATE['last_mode'] = mode
            _WIFI_RECOVERY_STATE['last_mode_changed_at'] = time.time()
            # モード切替直後の古いオフライン状態を引きずらない
            _WIFI_RECOVERY_STATE['offline_since'] = None
    except Exception as e:
        logger.error(f"Failed to save Wi-Fi mode: {e}")


def _is_ap_ip(ip_address):
    ip_text = str(ip_address or '').strip()
    if not ip_text:
        return False
    return any(ip_text.startswith(prefix) for prefix in AP_IP_PREFIXES)


def _is_ap_operational():
    """AP制御が実際に成立しているかを判定する。"""
    try:
        current_mode = wifi_manager.get_current_mode()
        if current_mode != 'ap':
            return False

        iface = wifi_manager._detect_wifi_interface()
        ips = wifi_manager._get_ipv4_addrs_for_interface(iface)
        return any(_is_ap_ip(ip) for ip in ips)
    except Exception as e:
        logger.warning(f"Failed to check AP operational status: {e}")
        return False


def _is_mode_operational(mode):
    mode = str(mode or '').strip().lower()
    if mode == 'ap':
        return _is_ap_operational()

    if mode == 'tethering':
        try:
            if wifi_manager.check_tethering_connection(timeout=14):
                return True
            # インターネット無し・一時的な default route 欠落でもリンクが生きていれば「まだテザリング」とみなし AP 自動復帰を避ける
            return wifi_manager.tethering_has_local_link(timeout=10)
        except Exception as e:
            logger.warning(f"Failed to check tethering operational status: {e}")
            return False

    return False


def _has_ap_clients_connected():
    """
    APにクライアントが接続中かどうかを判定する。
    判定失敗時は False を返す（過剰ブロックを避ける）。
    """
    try:
        count = int(wifi_manager.get_ap_connected_station_count())
        if count > 0:
            logger.info(f"AP has connected stations: {count}")
        return count > 0
    except Exception as e:
        logger.warning(f"Failed to check AP station count: {e}")
        return False


def _run_force_ap_recovery(trigger='watchdog'):
    """通信不能時にAPへ強制復旧する。"""
    saved_ap = wifi_manager.get_saved_ap_settings()
    ssid = saved_ap.get('ssid')
    password = saved_ap.get('password')

    primary = wifi_manager.switch_to_ap_mode(ssid, password)
    if primary.get('success'):
        _persist_wifi_mode('ap', ap_ssid=ssid, ap_password=password)
        return {
            'success': True,
            'message': f'AP force recovery succeeded ({trigger}, switch_to_ap_mode)',
            'result': primary,
        }

    persistence = wifi_manager.ensure_ap_persistence(allow_recursive_ap_recovery=False)
    if persistence.get('success'):
        _persist_wifi_mode('ap', ap_ssid=ssid, ap_password=password)
        return {
            'success': True,
            'message': f'AP force recovery succeeded ({trigger}, ensure_ap_persistence)',
            'switch_result': primary,
            'persistence_result': persistence,
        }

    return {
        'success': False,
        'message': f"AP force recovery failed ({trigger})",
        'switch_result': primary,
        'persistence_result': persistence,
    }


def _wifi_recovery_watchdog_loop():
    """通常経路で到達不能な状態が続いたらAPを自動復旧する。
    APモード時もAP健全性を監視し、撮影等でAPが壊れた場合に自動復旧する。
    """
    logger.info(
        "Wi-Fi recovery watchdog started "
        f"(interval={WIFI_RECOVERY_CHECK_INTERVAL_SEC}s grace={WIFI_RECOVERY_OFFLINE_GRACE_SEC}s cooldown={WIFI_RECOVERY_ATTEMPT_COOLDOWN_SEC}s)"
    )

    ap_unhealthy_since = None
    AP_UNHEALTHY_GRACE_SEC = 180  # AP不健全→復旧までの猶予（撮影中の一時的な不安定を許容）

    while True:
        time.sleep(WIFI_RECOVERY_CHECK_INTERVAL_SEC)

        try:
            with _WIFI_SWITCH_LOCK:
                if _WIFI_SWITCH_STATE.get('in_progress'):
                    continue

            mode = wifi_manager.get_current_mode()

            # --- APモード時: AP健全性を監視し、壊れたら復旧 ---
            if mode == 'ap':
                # 撮影直後の一時的ビーコン欠落でAP再構築しない（iPhone切断の主因）
                if _recent_capture_within(AP_CAPTURE_GRACE_SEC):
                    ap_unhealthy_since = None
                    continue

                if wifi_manager._is_ap_healthy():
                    ap_unhealthy_since = None
                    # 60秒ごとに powersave OFF を再適用（AP ビーコン安定化）
                    if int(time.time()) % 60 < WIFI_RECOVERY_CHECK_INTERVAL_SEC:
                        try:
                            wifi_manager._apply_ap_radio_tuning()
                        except Exception as e:
                            logger.debug("AP radio tuning skipped: %s", e)
                    continue

                now = time.time()
                if ap_unhealthy_since is None:
                    ap_unhealthy_since = now
                    logger.warning("Wi-Fi watchdog: AP appears unhealthy, monitoring...")
                    continue

                unhealthy_for = now - ap_unhealthy_since
                if unhealthy_for < AP_UNHEALTHY_GRACE_SEC:
                    continue

                logger.warning(f"Wi-Fi watchdog: AP unhealthy for {int(unhealthy_for)}s, attempting recovery")
                ap_unhealthy_since = None

                can_switch, guard_error = _begin_wifi_switch('watchdog-ap-repair', bypass_cooldown=True)
                if not can_switch:
                    logger.warning(f"Wi-Fi watchdog AP repair skipped: {guard_error}")
                    continue

                try:
                    result = wifi_manager.ensure_ap_persistence()
                    if result.get('success'):
                        logger.info(f"Wi-Fi watchdog: AP repaired successfully (action={result.get('action')})")
                    else:
                        logger.error(f"Wi-Fi watchdog: AP repair failed: {result}")
                except Exception as e:
                    logger.error(f"Wi-Fi watchdog: AP repair exception: {e}")
                finally:
                    _finish_wifi_switch()
                continue

            # --- テザリングモード時: 既存ロジック ---
            if mode not in ('tethering',):
                # 想定外モード時は自動切替を走らせない
                with _WIFI_RECOVERY_LOCK:
                    _WIFI_RECOVERY_STATE['last_mode'] = mode
                    _WIFI_RECOVERY_STATE['offline_since'] = None
                continue

            operational = _is_mode_operational(mode)
            now = time.time()

            should_attempt_recovery = False
            offline_for_sec = 0

            with _WIFI_RECOVERY_LOCK:
                _WIFI_RECOVERY_STATE['last_mode'] = mode

                if operational:
                    if _WIFI_RECOVERY_STATE.get('offline_since'):
                        logger.info("Wi-Fi recovery watchdog: connectivity restored")
                    _WIFI_RECOVERY_STATE['offline_since'] = None
                    _WIFI_RECOVERY_STATE['last_error'] = None
                    continue

                offline_since = _WIFI_RECOVERY_STATE.get('offline_since')
                if offline_since is None:
                    offline_since = now
                    _WIFI_RECOVERY_STATE['offline_since'] = offline_since
                    logger.warning("Wi-Fi recovery watchdog: control path seems offline")

                # テザリングへ切替直後の一時的不安定ではAPへ戻さない（フラップ防止）
                last_mode_changed_at = float(_WIFI_RECOVERY_STATE.get('last_mode_changed_at') or 0.0)
                if (
                    last_mode_changed_at > 0.0
                    and now - last_mode_changed_at < WIFI_RECOVERY_TETHERING_STABILIZE_SEC
                ):
                    continue

                offline_for_sec = now - offline_since
                last_attempt = float(_WIFI_RECOVERY_STATE.get('last_attempt_at') or 0.0)
                if (
                    offline_for_sec >= WIFI_RECOVERY_OFFLINE_GRACE_SEC
                    and now - last_attempt >= WIFI_RECOVERY_ATTEMPT_COOLDOWN_SEC
                ):
                    _WIFI_RECOVERY_STATE['last_attempt_at'] = now
                    should_attempt_recovery = True

            if not should_attempt_recovery:
                continue

            can_switch, guard_error = _begin_wifi_switch('watchdog-force-ap', bypass_cooldown=True)
            if not can_switch:
                logger.warning(f"Wi-Fi recovery watchdog skipped by switch guard: {guard_error}")
                continue

            try:
                result = _run_force_ap_recovery(trigger='watchdog')
                if result.get('success'):
                    logger.warning(f"Wi-Fi recovery watchdog: AP recovered after offline {int(offline_for_sec)}s")
                else:
                    logger.error(f"Wi-Fi recovery watchdog: AP recovery failed: {result}")

                with _WIFI_RECOVERY_LOCK:
                    _WIFI_RECOVERY_STATE['last_result'] = result
                    _WIFI_RECOVERY_STATE['last_error'] = None if result.get('success') else result.get('message')
            except Exception as e:
                logger.error(f"Wi-Fi recovery watchdog attempt failed: {e}")
                with _WIFI_RECOVERY_LOCK:
                    _WIFI_RECOVERY_STATE['last_error'] = str(e)
            finally:
                _finish_wifi_switch()
        except Exception as e:
            logger.error(f"Wi-Fi recovery watchdog loop error: {e}")

CAMERA_MODE_PRESETS = {
    'reaction': {
        'quality': 70,
        'width': 1920,
        'height': 1080,
        'check_interval': 0.1,
        'capture_cooldown': 0.5,
        'monitoring_enabled': True,
        'denoise_mode': 'off',
        'raw_mode': False,
    },
    'standard': {
        'quality': 90,
        'width': 1920,
        'height': 1080,
        'check_interval': 0.2,
        'capture_cooldown': 1.5,
        'monitoring_enabled': True,
        'raw_mode': False,
    },
    'quality': {
        'quality': 100,
        'width': 4056,
        'height': 3040,
        'check_interval': 0.5,
        'capture_cooldown': 3.0,
        'monitoring_enabled': True,
        'denoise_mode': 'cdn_hq',
        'raw_mode': False,
    },
    'night': {
        'quality': 95,
        'width': 1920,
        'height': 1080,
        'check_interval': 0.5,
        'capture_cooldown': 3.0,
        'monitoring_enabled': True,
        'denoise_mode': 'cdn_hq',
        'raw_mode': False,
    },
    'battery': {
        'quality': 80,
        'width': 1920,
        'height': 1080,
        'check_interval': 1.0,
        'capture_cooldown': 5.0,
        'monitoring_enabled': True,
        'raw_mode': False,
    },
    'manual': {
        'monitoring_enabled': False,
        'raw_mode': False,
    },
    'raw': {
        'raw_mode': True,
        'quality': 100,
        'width': 4056,
        'height': 3040,
        'denoise_mode': 'off',
        'sharpness': 0.0,
        'stabilization': False,
        'monitoring_enabled': True,
        'capture_cooldown': 5.0,
    },
}

METERING_ISO_STOPS = [100, 200, 400, 800, 1600, 3200, 6400]
METERING_SHUTTER_US_STOPS = [
    2500,
    4000,
    8000,
    16666,
    33333,
    66666,
    125000,
    250000,
    500000,
    1_000_000,
    2_000_000,
    3_000_000,
    4_000_000,
    5_000_000,
    6_000_000,
    7_000_000,
    8_000_000,
    9_000_000,
    10_000_000,
    11_000_000,
    12_000_000,
    13_000_000,
    14_000_000,
    15_000_000,
    16_000_000,
    17_000_000,
    18_000_000,
    19_000_000,
    20_000_000,
]

_sensor_status_cache = {'mtime': 0.0, 'data': {}}

def _read_sensor_status_cached() -> dict:
    global _sensor_status_cache
    try:
        if not os.path.exists(SENSOR_STATUS_FILE):
            return {}
        mtime = os.path.getmtime(SENSOR_STATUS_FILE)
        if mtime == _sensor_status_cache['mtime']:
            return _sensor_status_cache['data']
        with open(SENSOR_STATUS_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        if isinstance(data, dict):
            _sensor_status_cache = {'mtime': mtime, 'data': data}
            return data
    except Exception:
        pass
    return _sensor_status_cache.get('data', {})

_settings_cache = {'mtime_main': 0.0, 'mtime_over': 0.0, 'data': None}

def _load_effective_settings_cached():
    global _settings_cache
    try:
        mt_main = os.path.getmtime(SETTINGS_FILE) if os.path.exists(SETTINGS_FILE) else 0.0
        mt_over = os.path.getmtime(SESSION_OVERRIDES_FILE) if os.path.exists(SESSION_OVERRIDES_FILE) else 0.0
        if (mt_main == _settings_cache['mtime_main']
                and mt_over == _settings_cache['mtime_over']
                and _settings_cache['data'] is not None):
            return _settings_cache['data']
        data = _load_effective_settings()
        _settings_cache = {'mtime_main': mt_main, 'mtime_over': mt_over, 'data': data}
        return data
    except Exception:
        if _settings_cache['data'] is not None:
            return _settings_cache['data']
        return _load_effective_settings()

def _load_effective_settings():
    settings = DEFAULT_SETTINGS.copy()
    settings.update(_load_settings_dict())

    if os.path.exists(SESSION_OVERRIDES_FILE):
        try:
            with open(SESSION_OVERRIDES_FILE, 'r') as f:
                overrides = json.load(f)
            if isinstance(overrides, dict):
                settings.update(overrides)
        except Exception as e:
            logger.warning(f"Failed to load session overrides: {e}")

    if 'detection_threshold' in settings and 'brightness_threshold' not in settings:
        settings['brightness_threshold'] = settings['detection_threshold']
    if 'brightness_threshold' in settings and 'detection_threshold' not in settings:
        settings['detection_threshold'] = settings['brightness_threshold']
    return settings

def _nearest_stop(stops, value):
    return min(stops, key=lambda x: abs(x - value))

def _format_shutter_label(microseconds):
    try:
        microseconds = int(microseconds)
    except (TypeError, ValueError):
        return '-'

    if microseconds <= 0:
        return '-'
    if microseconds >= 1_000_000:
        seconds = microseconds / 1_000_000
        if abs(seconds - round(seconds)) < 0.0001:
            return f"{int(round(seconds))}s"
        return f"{seconds:.2f}s"

    fps = round(1_000_000 / microseconds)
    if fps <= 0:
        return '-'
    return f"1/{fps}"

def _default_metering_shutter_us(camera_mode):
    if camera_mode == 'reaction':
        return 8000
    if camera_mode == 'quality':
        return 250000
    if camera_mode == 'battery':
        return 33333
    return 16666

def _calc_metering_recommendation(sensor_status, settings, target_iso=None, target_shutter_us=None):
    base_iso = None
    base_shutter_us = None
    source = 'fallback'

    ae_gain = sensor_status.get('ae_gain')
    ae_exposure_us = sensor_status.get('ae_exposure_us')
    try:
        if ae_gain is not None and ae_exposure_us is not None:
            base_iso = int(round(float(ae_gain) * 100.0))
            base_shutter_us = int(float(ae_exposure_us))
            source = 'ae_metadata'
    except (TypeError, ValueError):
        base_iso = None
        base_shutter_us = None

    if base_iso is None:
        iso_value = settings.get('iso', 'auto')
        if iso_value != 'auto':
            try:
                base_iso = int(iso_value)
                source = 'manual_settings'
            except (TypeError, ValueError):
                base_iso = None

    if base_shutter_us is None:
        shutter_value = settings.get('shutter_speed', 'auto')
        if shutter_value != 'auto':
            try:
                base_shutter_us = int(shutter_value)
                source = 'manual_settings'
            except (TypeError, ValueError):
                base_shutter_us = None

    if base_iso is None:
        base_iso = 200
    if base_shutter_us is None:
        base_shutter_us = 16666

    base_iso = max(100, min(3200, base_iso))
    base_shutter_us = max(2500, min(20_000_000, base_shutter_us))

    if target_iso is not None:
        target_iso = max(100, min(3200, int(target_iso)))
    if target_shutter_us is not None:
        target_shutter_us = max(2500, min(20_000_000, int(target_shutter_us)))

    if target_iso is None and target_shutter_us is None:
        target_shutter_us = _default_metering_shutter_us(settings.get('camera_mode', 'standard'))

    exposure_product = float(base_iso) * float(base_shutter_us)

    if target_iso is None and target_shutter_us is not None:
        target_iso = int(round(exposure_product / float(target_shutter_us)))
    if target_shutter_us is None and target_iso is not None:
        target_shutter_us = int(round(exposure_product / float(target_iso)))

    target_iso = max(100, min(3200, int(target_iso)))
    target_shutter_us = max(2500, min(20_000_000, int(target_shutter_us)))

    recommended_iso = _nearest_stop(METERING_ISO_STOPS, target_iso)
    refined_shutter = int(round(exposure_product / float(recommended_iso)))
    refined_shutter = max(2500, min(20_000_000, refined_shutter))
    recommended_shutter_us = _nearest_stop(METERING_SHUTTER_US_STOPS, refined_shutter)

    # フォーカス距離の推奨（簡易版：被写界深度を考慮した推奨値）
    # ISO値に基づいて推奨距離を計算（低ISO=遠景、高ISO=近景の傾向）
    if recommended_iso <= 200:
        recommended_focus_m = 10.0  # 遠景（風景向け）
    elif recommended_iso <= 800:
        recommended_focus_m = 3.0   # 中距離（一般撮影）
    else:
        recommended_focus_m = 1.5   # 近距離（暗所/近接撮影）

    return {
        'recommended_iso': int(recommended_iso),
        'recommended_shutter_us': int(recommended_shutter_us),
        'recommended_shutter_label': _format_shutter_label(recommended_shutter_us),
        'recommended_focus_m': round(recommended_focus_m, 1),
        'base_iso': int(base_iso),
        'base_shutter_us': int(base_shutter_us),
        'base_shutter_label': _format_shutter_label(base_shutter_us),
        'source': source,
        'camera_mode': settings.get('camera_mode', 'standard'),
        'lux': sensor_status.get('lux'),
        'brightness': sensor_status.get('brightness'),
    }

def _thumbnail_path(filename, max_dim):
    base, _ext = os.path.splitext(filename)
    return os.path.join(THUMBNAIL_DIR, f"{base}_w{max_dim}.jpg")


def _content_type_for_photo(filename: str) -> str:
    lower = filename.lower()
    if lower.endswith('.png'):
        return 'image/png'
    if lower.endswith('.dng'):
        return 'image/dng'
    return 'image/jpeg'


def _ensure_thumbnail(filepath, max_dim):
    if Image is None:
        return None

    try:
        os.makedirs(THUMBNAIL_DIR, exist_ok=True)
        thumb_path = _thumbnail_path(os.path.basename(filepath), max_dim)
        if os.path.exists(thumb_path):
            if os.path.getmtime(thumb_path) >= os.path.getmtime(filepath):
                return thumb_path

        resample = Image.Resampling.LANCZOS if hasattr(Image, 'Resampling') else Image.LANCZOS

        def _write_thumb_from_image(img):
            img.thumbnail((max_dim, max_dim), resample=resample)
            if img.mode in ('RGBA', 'P'):
                img = img.convert('RGB')
            img.save(thumb_path, format='JPEG', quality=THUMBNAIL_QUALITY, optimize=True)

        basename = os.path.basename(filepath)
        try:
            with Image.open(filepath) as img:
                _write_thumb_from_image(img)
        except Exception as pil_err:
            if basename.lower().endswith('.dng'):
                try:
                    import rawpy  # type: ignore
                    with rawpy.imread(filepath) as raw:
                        rgb = raw.postprocess()
                    img = Image.fromarray(rgb)
                    _write_thumb_from_image(img)
                except Exception as raw_err:
                    logger.warning(
                        "Thumbnail generation failed for DNG (PIL: %s, rawpy: %s)",
                        pil_err, raw_err,
                    )
                    return None
            else:
                logger.warning(f"Thumbnail generation failed: {pil_err}")
                return None
        return thumb_path
    except Exception as e:
        logger.warning(f"Thumbnail generation failed: {e}")
        return None


def _apply_client_unix_time(ts):
    """クライアントから受け取った Unix 時刻でシステム時計を合わせる（AP モードで NTP が同期しない対策）。"""
    try:
        ts = float(ts)
    except (TypeError, ValueError):
        return False, 'unix_time must be a number'
    # 2020-01-01 .. 2100-01-01 付近のみ許可
    if ts < 1577836800.0 or ts > 4102444800.0:
        return False, 'unix_time out of allowed range'
    sec = int(ts)
    result = subprocess.run(
        ['sudo', '-n', 'date', '-u', '-s', '@%d' % sec],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        err = (result.stderr or result.stdout or 'date failed').strip()
        return False, err[:300] if err else 'sudo date failed (need NOPASSWD for date?)'
    hw = shutil.which('fake-hwclock')
    if hw:
        def _save_hwclock():
            try:
                subprocess.run(
                    ['sudo', '-n', 'fake-hwclock', 'save'],
                    capture_output=True, text=True, timeout=25,
                )
            except (subprocess.TimeoutExpired, OSError, subprocess.SubprocessError) as e:
                logger.warning('fake-hwclock save skipped after time set: %s', e)

        threading.Thread(target=_save_hwclock, daemon=True).start()
    return True, None


def _verify_photo_on_disk(photo_path: str) -> bool:
    try:
        return os.path.isfile(photo_path) and os.path.getsize(photo_path) > 0
    except OSError:
        return False


def _mark_last_capture_unix_file() -> None:
    try:
        tmp_path = f"{LAST_CAPTURE_FILE}.tmp"
        with open(tmp_path, 'w', encoding='utf-8') as f:
            f.write(f"{time.time():.3f}")
        os.replace(tmp_path, LAST_CAPTURE_FILE)
    except Exception as e:
        logger.debug("Failed to mark last capture: %s", e)


def _get_cached_photo_count():
    now = time.time()
    with _PHOTO_COUNT_CACHE_LOCK:
        if _PHOTO_COUNT_CACHE['expires_at'] > now:
            return _PHOTO_COUNT_CACHE['value']

    count = 0
    if os.path.exists(PHOTOS_DIR):
        try:
            with os.scandir(PHOTOS_DIR) as entries:
                for entry in entries:
                    if not entry.is_file():
                        continue
                    name = entry.name
                    if (name.lower().endswith(ALLOWED_PHOTO_EXTENSIONS)
                            and SAFE_FILENAME_PATTERN.match(name)):
                        count += 1
        except Exception:
            count = 0

    with _PHOTO_COUNT_CACHE_LOCK:
        _PHOTO_COUNT_CACHE['value'] = count
        _PHOTO_COUNT_CACHE['expires_at'] = now + _PHOTO_COUNT_CACHE_TTL_SEC
    return count


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

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
        elif parsed.path == '/api/sensor/status':
            self.serve_sensor_status()
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
        elif parsed.path == '/api/photo/meta':
            self.serve_photo_metadata()
        elif parsed.path == '/api/photos/delete':
            self.delete_photos()
        elif parsed.path == '/api/capture':
            self.capture_photo()
        elif parsed.path == '/api/wifi/write_wpa':
            self.write_wpa_settings()
        elif parsed.path == '/api/wifi/switch':
            self.switch_wifi_mode()
        elif parsed.path == '/api/wifi/scan':
            self.scan_wifi_networks()
        elif parsed.path == '/api/metering':
            self.serve_metering_recommendation()
        elif parsed.path == '/api/metering/calibrate':
            self.metering_calibrate()
        elif parsed.path == '/api/system/time':
            self.update_system_time()
        else:
            self.send_error(404)

    def serve_sensor_status(self):
        try:
            sensor = _read_sensor_status_cached()

            settings = _load_effective_settings_cached()
            payload = {
                'success': True,
                'sensor': sensor,
                'settings': {
                    'camera_mode': settings.get('camera_mode', 'standard'),
                    'monitoring_enabled': settings.get('monitoring_enabled', True),
                    'iso': settings.get('iso', 'auto'),
                    'shutter_speed': settings.get('shutter_speed', 'auto'),
                    'white_balance': settings.get('white_balance', 'auto'),
                    'quality': settings.get('quality', 90),
                },
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
        except Exception as e:
            logger.error(f"Error serving sensor status: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())

    def serve_metering_recommendation(self):
        try:
            data = _read_json_body(self)
            if data is None:
                return

            sensor = _read_sensor_status_cached()

            settings = _load_effective_settings_cached()

            target_iso = data.get('target_iso')
            if target_iso == 'auto':
                target_iso = None
            if target_iso is not None:
                target_iso = int(target_iso)

            target_shutter_us = data.get('target_shutter_us')
            if target_shutter_us == 'auto':
                target_shutter_us = None
            if target_shutter_us is not None:
                target_shutter_us = int(target_shutter_us)

            recommendation = _calc_metering_recommendation(
                sensor_status=sensor,
                settings=settings,
                target_iso=target_iso,
                target_shutter_us=target_shutter_us,
            )

            response = {'success': True, 'recommendation': recommendation}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        except Exception as e:
            logger.error(f"Metering recommendation error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())
    
    def metering_calibrate(self):
        """測光キャリブレーション: AE収束を待ってから複数枚撮影し適正露出を計測"""
        service_stopped = False
        try:
            data = _read_json_body(self)
            if data is None:
                return

            settle = int(data.get('settle_seconds', 3))
            capture = int(data.get('capture_seconds', 3))
            settle = max(1, min(settle, 15))
            capture = max(2, min(capture, 30))

            stop_result = subprocess.run(
                ['sudo', '-n', 'systemctl', 'stop', 'camera-service'],
                capture_output=True, text=True, check=False,
            )
            if stop_result.returncode != 0:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'success': False, 'error': 'Failed to stop camera-service',
                }).encode())
                return

            service_stopped = True
            for _ in range(10):
                status = subprocess.run(
                    ['systemctl', 'is-active', 'camera-service'],
                    capture_output=True, text=True, check=False,
                )
                if status.stdout.strip() in ('inactive', 'failed', 'deactivating'):
                    break
                time.sleep(0.3)

            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'metering_calibrate.py')
            if not os.path.exists(script_path):
                script_path = '/home/pi/metering_calibrate.py'

            # スクリプト内の撮影間隔・I/O を含め余裕を持たせる（短時間キャリブでもタイムアウトしにくく）
            timeout_sec = settle + capture + 25
            result = subprocess.run(
                ['python3', script_path,
                 f'--settle={settle}', f'--capture={capture}'],
                capture_output=True, text=True, timeout=timeout_sec,
            )

            if result.returncode != 0:
                logger.error(f"Metering calibrate failed: {result.stderr}")
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'success': False,
                    'error': f'Calibration script failed: {result.stderr[:500]}',
                }).encode())
                return

            try:
                output = json.loads(result.stdout)
            except json.JSONDecodeError:
                output = {'success': False, 'error': 'Invalid script output', 'raw': result.stdout[:500]}

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(output).encode())

        except subprocess.TimeoutExpired:
            logger.error("Metering calibrate timed out")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'success': False, 'error': 'Calibration timed out',
            }).encode())
        except Exception as e:
            logger.error(f"Metering calibrate error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())
        finally:
            if service_stopped:
                subprocess.run(
                    ['sudo', '-n', 'systemctl', 'start', 'camera-service'],
                    capture_output=True, text=True, check=False,
                )

    def serve_photo_list(self):
        """写真一覧を返す"""
        try:
            files = []
            if os.path.exists(PHOTOS_DIR):
                files = [
                    f for f in os.listdir(PHOTOS_DIR)
                    if f.lower().endswith(ALLOWED_PHOTO_EXTENSIONS)
                    and SAFE_FILENAME_PATTERN.match(f)
                    and os.path.getsize(os.path.join(PHOTOS_DIR, f)) > 0
                ]
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

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        try:
            self.wfile.write(json.dumps(status).encode())
        except (BrokenPipeError, ConnectionResetError):
            return

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
    
    def _sendfile_or_copy(self, filepath):
        """os.sendfileでゼロコピー転送、失敗時はshutilフォールバック"""
        try:
            with open(filepath, 'rb') as f:
                fd_in = f.fileno()
                fd_out = self.wfile.fileno()
                offset = 0
                size = os.fstat(fd_in).st_size
                while offset < size:
                    sent = os.sendfile(fd_out, fd_in, offset, size - offset)
                    if sent == 0:
                        break
                    offset += sent
        except (OSError, AttributeError):
            with open(filepath, 'rb') as f:
                shutil.copyfileobj(f, self.wfile)

    def serve_photo_file(self, path):
        """写真ファイルを配信"""
        try:
            filename = os.path.basename(path)
            if not filename or SAFE_FILENAME_PATTERN.match(filename) is None:
                self.send_error(400)
                return

            if not filename.lower().endswith(ALLOWED_PHOTO_EXTENSIONS):
                self.send_error(400)
                return

            filepath = os.path.join(PHOTOS_DIR, filename)
            
            if not os.path.exists(filepath):
                self.send_error(404)
                return

            content_type = _content_type_for_photo(filename)
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', os.path.getsize(filepath))
            self.end_headers()
            self._sendfile_or_copy(filepath)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            logger.error(f"Error serving photo: {e}")
            self.send_error(500)

    def serve_photo_request(self):
        """POSTで写真ファイルを配信"""
        try:
            data = _read_json_body(self)
            if data is None:
                return

            filename = data.get('filename', '')
            thumbnail = _parse_bool_value(data.get('thumbnail', False), default=False)
            try:
                max_dim = int(data.get('max_dim', THUMBNAIL_MAX_DIM_DEFAULT))
            except (TypeError, ValueError):
                max_dim = THUMBNAIL_MAX_DIM_DEFAULT
            max_dim = max(120, min(max_dim, 1024))
            safe_name = os.path.basename(filename)
            if safe_name != filename:
                self.send_error(400)
                return
            if not safe_name.lower().endswith(ALLOWED_PHOTO_EXTENSIONS):
                self.send_error(400)
                return
            if SAFE_FILENAME_PATTERN.match(safe_name) is None:
                self.send_error(400)
                return

            filepath = os.path.join(PHOTOS_DIR, safe_name)
            if not os.path.exists(filepath):
                self.send_error(404)
                return

            content_path = filepath
            content_type = _content_type_for_photo(safe_name)
            if thumbnail:
                thumb_path = _ensure_thumbnail(filepath, max_dim)
                if thumb_path:
                    content_path = thumb_path
                    content_type = 'image/jpeg'

            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', os.path.getsize(content_path))
            self.end_headers()
            self._sendfile_or_copy(content_path)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            logger.error(f"Error serving photo (POST): {e}")
            self.send_error(500)

    def serve_photo_metadata(self):
        """写真のメタデータ(JSON sidecar)を返す"""
        try:
            data = _read_json_body(self)
            if data is None:
                return

            filename = data.get('filename', '')
            safe_name = os.path.basename(filename)
            if safe_name != filename:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'Invalid filename'}).encode())
                return

            lower = safe_name.lower()
            if not lower.endswith(ALLOWED_PHOTO_EXTENSIONS):
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'Invalid filename'}).encode())
                return

            if SAFE_FILENAME_PATTERN.match(safe_name) is None:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'Invalid filename'}).encode())
                return

            base, _ext = os.path.splitext(safe_name)
            meta_path = os.path.join(PHOTOS_DIR, f"{base}.json")
            if not os.path.exists(meta_path):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'Metadata not found'}).encode())
                return

            with open(meta_path, 'r', encoding='utf-8') as f:
                metadata = json.load(f)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': True, 'metadata': metadata}).encode())
        except Exception as e:
            logger.error(f"Error serving photo metadata: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())
    
    def delete_photos(self):
        try:
            data = _read_json_body(self)
            if data is None:
                return

            filenames = []
            if isinstance(data.get('filenames'), list):
                filenames = data.get('filenames')
            elif isinstance(data.get('filename'), str):
                filenames = [data.get('filename')]

            if not filenames:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': 'filename(s) required'}).encode())
                return

            deleted = []
            not_found = []
            invalid = []
            errors = []

            for name in filenames:
                if not isinstance(name, str):
                    invalid.append(str(name))
                    continue

                safe_name = os.path.basename(name)
                if safe_name != name:
                    invalid.append(name)
                    continue

                lower = safe_name.lower()
                if not lower.endswith(ALLOWED_PHOTO_EXTENSIONS):
                    invalid.append(name)
                    continue

                if SAFE_FILENAME_PATTERN.match(safe_name) is None:
                    invalid.append(name)
                    continue

                filepath = os.path.join(PHOTOS_DIR, safe_name)
                if not os.path.exists(filepath):
                    not_found.append(safe_name)
                    continue

                try:
                    os.remove(filepath)
                    deleted.append(safe_name)
                    base, _ext = os.path.splitext(safe_name)
                    meta_path = os.path.join(PHOTOS_DIR, f"{base}.json")
                    if os.path.exists(meta_path):
                        try:
                            os.remove(meta_path)
                        except Exception as e:
                            logger.warning(f"Failed to remove metadata {meta_path}: {e}")
                    thumb_pattern = os.path.join(THUMBNAIL_DIR, f"{base}_w*.jpg")
                    for thumb in glob.glob(thumb_pattern):
                        try:
                            os.remove(thumb)
                        except Exception as e:
                            logger.warning(f"Failed to remove thumbnail {thumb}: {e}")
                except Exception as e:
                    errors.append({'filename': safe_name, 'error': str(e)})

            success = len(invalid) == 0 and len(errors) == 0

            if deleted:
                _invalidate_photo_count_cache()

            self.send_response(200 if success else 400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(
                json.dumps({
                    'success': success,
                    'deleted': deleted,
                    'not_found': not_found,
                    'invalid': invalid,
                    'errors': errors,
                }).encode())
        except Exception as e:
            logger.error(f"Error deleting photos: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())

    def update_system_time(self):
        """POST /api/system/time — ボディ JSON: {\"unix_time\": <seconds since 1970>}"""
        try:
            data = _read_json_body(self)
            if data is None:
                return
            ok, err = _apply_client_unix_time(data.get('unix_time'))
            payload = {'success': ok}
            if err:
                payload['error'] = err
            self.send_response(200 if ok else 400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())
            if ok:
                logger.info('System time set from client via /api/system/time')
        except Exception as e:
            logger.error(f'update_system_time: {e}')
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())
    
    def serve_status(self):
        """システム状態を返す"""
        try:
            photo_count = _get_cached_photo_count()
            
            settings = DEFAULT_SETTINGS.copy()
            settings.update(_load_settings_dict())

            if os.path.exists(SESSION_OVERRIDES_FILE):
                try:
                    with open(SESSION_OVERRIDES_FILE, 'r') as f:
                        overrides = json.load(f)
                    if isinstance(overrides, dict):
                        settings.update(overrides)
                except Exception as e:
                    logger.warning(f"Failed to load session overrides: {e}")

            if 'detection_threshold' in settings and 'brightness_threshold' not in settings:
                settings['brightness_threshold'] = settings['detection_threshold']
            
            status = {
                'photo_count': photo_count,
                'brightness_threshold': settings.get('brightness_threshold', 30),
                'service_running': True,
                # iOS が AP 直結時に NTP 不能でも時刻合わせできるよう Unix 時刻を載せる
                'server_time_unix': time.time(),
            }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            try:
                self.wfile.write(json.dumps(status).encode())
            except (BrokenPipeError, ConnectionResetError):
                return
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            logger.error(f"Error getting status: {e}")
            self.send_error(500)
    
    def serve_settings(self):
        """設定情報を返す"""
        try:
            settings = DEFAULT_SETTINGS.copy()
            settings.update(_load_settings_dict())

            if os.path.exists(SESSION_OVERRIDES_FILE):
                try:
                    with open(SESSION_OVERRIDES_FILE, 'r') as f:
                        overrides = json.load(f)
                    if isinstance(overrides, dict):
                        settings.update(overrides)
                except Exception as e:
                    logger.warning(f"Failed to load session overrides: {e}")

            if 'detection_threshold' in settings and 'brightness_threshold' not in settings:
                settings['brightness_threshold'] = settings['detection_threshold']
            if 'brightness_threshold' in settings and 'detection_threshold' not in settings:
                settings['detection_threshold'] = settings['brightness_threshold']

            for internal_key in ('ap_password', 'ap_ssid', 'wifi_mode'):
                settings.pop(internal_key, None)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            try:
                self.wfile.write(json.dumps(settings).encode())
            except (BrokenPipeError, ConnectionResetError):
                return
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            logger.error(f"Error getting settings: {e}")
            self.send_error(500)

    def update_settings(self):
        """設定を更新"""
        try:
            new_settings = _read_json_body(self)
            if new_settings is None:
                return

            is_temporary = _parse_bool_value(new_settings.pop('temporary', False), default=False)
            reset_temporary = _parse_bool_value(new_settings.pop('reset_temporary', False), default=False)

            sanitized_patch, validation_errors = _sanitize_settings_patch(new_settings)
            if validation_errors:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'errors': validation_errors}).encode())
                return

            new_settings = sanitized_patch

            if reset_temporary:
                try:
                    if os.path.exists(SESSION_OVERRIDES_FILE):
                        os.remove(SESSION_OVERRIDES_FILE)
                except Exception as e:
                    logger.warning(f"Failed to reset session overrides: {e}")
            
            settings = DEFAULT_SETTINGS.copy()
            settings.update(_load_settings_dict())

            if 'detection_threshold' in new_settings and 'brightness_threshold' not in new_settings:
                new_settings['brightness_threshold'] = new_settings['detection_threshold']
            if 'brightness_threshold' in new_settings and 'detection_threshold' not in new_settings:
                new_settings['detection_threshold'] = new_settings['brightness_threshold']

            if is_temporary:
                new_settings.pop('camera_mode', None)

                overrides = {}
                if os.path.exists(SESSION_OVERRIDES_FILE):
                    try:
                        with open(SESSION_OVERRIDES_FILE, 'r') as f:
                            overrides = json.load(f) or {}
                    except Exception:
                        overrides = {}

                if not isinstance(overrides, dict):
                    overrides = {}

                overrides.update(new_settings)

                _save_session_overrides_dict(overrides)

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': True}).encode())
                return

            camera_mode = new_settings.get('camera_mode')
            if camera_mode is not None:
                preset = CAMERA_MODE_PRESETS.get(camera_mode)
                if preset is None:
                    new_settings.pop('camera_mode', None)
                else:
                    new_settings.update(preset)

                    try:
                        if os.path.exists(SESSION_OVERRIDES_FILE):
                            os.remove(SESSION_OVERRIDES_FILE)
                    except Exception as e:
                        logger.warning(f"Failed to clear session overrides on mode change: {e}")
            
            # iso/shutter_speedが変更された場合、session_overridesからも
            # 該当キーを削除（古いtemporary値が新しい設定を上書きする問題の防止）
            changed_exposure_keys = [k for k in ('iso', 'shutter_speed') if k in new_settings]
            if changed_exposure_keys and os.path.exists(SESSION_OVERRIDES_FILE):
                try:
                    with open(SESSION_OVERRIDES_FILE, 'r') as f:
                        overrides = json.load(f) or {}
                    if isinstance(overrides, dict):
                        changed = False
                        for k in changed_exposure_keys:
                            if k in overrides:
                                del overrides[k]
                                changed = True
                        if changed:
                            if overrides:
                                _save_session_overrides_dict(overrides)
                            else:
                                os.remove(SESSION_OVERRIDES_FILE)
                except Exception as e:
                    logger.warning(f"Failed to clean session overrides for changed keys: {e}")

            settings.update(new_settings)
            
            _save_settings_dict(settings)
            
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
            data = _read_json_body(self)
            if data is None:
                return

            ssid = str(data.get('ssid') or '').strip()
            psk = str(data.get('psk') or '').strip()

            if _unsafe_text_chars_present(ssid) or _unsafe_text_chars_present(psk):
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'message': 'ssid/psk contains invalid characters'}).encode())
                return

            ssid_len = len(ssid.encode('utf-8'))
            if ssid_len < 1 or ssid_len > 32:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'message': 'ssid must be 1..32 bytes'}).encode())
                return

            if len(psk) < 8 or len(psk) > 63:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'message': 'psk must be 8..63 chars'}).encode())
                return

            result = wifi_manager.configure_wpa_supplicant(ssid, psk)

            self.send_response(200 if result.get('success') else 400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        except Exception as e:
            logger.error(f"write_wpa_settings error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'message': str(e)}).encode())

    def scan_wifi_networks(self):
        """周辺Wi-Fiネットワークをスキャン"""
        try:
            # Wi-Fi切替中はスキャンを拒否
            if _is_wifi_switching():
                self.send_response(409)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'success': False,
                    'message': 'Wi-Fi切替中のためスキャンできません'
                }).encode())
                return

            data = _read_json_body(self)
            max_results = 25
            rescan = True
            if data:
                max_results = int(data.get('max_results', 25))
                rescan = bool(data.get('rescan', True))

            result = wifi_manager.scan_wifi_networks(max_results=max_results, rescan=rescan)

            self.send_response(200 if result.get('success') else 500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        except Exception as e:
            logger.error(f"scan_wifi_networks error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'success': False,
                'message': 'Wi-Fiスキャンに失敗しました'
            }).encode())

    def switch_wifi_mode(self):
        """Wi-Fiモード切り替え"""
        try:
            data = _read_json_body(self)
            if data is None:
                return

            mode = str(data.get('mode') or '').strip().lower()
            force_requested = _parse_bool_value(data.get('force'), default=False)
            if mode not in ('ap', 'tethering'):
                result = {'success': False, 'message': 'Unknown mode'}
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())
                self.wfile.flush()
                return

            current_mode = (wifi_manager.get_wifi_status().get('mode') or '').strip().lower()
            if current_mode == mode and not force_requested:
                if _is_mode_operational(mode):
                    result = {'success': True, 'message': f'既に{mode}モードです'}
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(result).encode())
                    self.wfile.flush()
                    return

                force_requested = True
                logger.warning(f"Requested mode={mode} matches current state but control path is unhealthy; forcing recovery")

            can_switch, guard_error = _begin_wifi_switch(mode, bypass_cooldown=force_requested)
            if not can_switch:
                self.send_response(409)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'message': guard_error}).encode())
                self.wfile.flush()
                return

            if mode == 'ap':
                saved = wifi_manager.get_saved_ap_settings()
                ssid = str(data.get('ssid') or saved.get('ssid') or '').strip()
                password = str(data.get('password') or saved.get('password') or '').strip()

                if not ssid or not password:
                    _finish_wifi_switch()
                    result = {'success': False, 'message': 'ssid/password required'}
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(result).encode())
                    self.wfile.flush()
                    return

                if _unsafe_text_chars_present(ssid) or _unsafe_text_chars_present(password):
                    _finish_wifi_switch()
                    result = {'success': False, 'message': 'ssid/password contains invalid characters'}
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(result).encode())
                    self.wfile.flush()
                    return

                if len(ssid.encode('utf-8')) < 1 or len(ssid.encode('utf-8')) > 32:
                    _finish_wifi_switch()
                    result = {'success': False, 'message': 'SSIDは1〜32byteで指定してください'}
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(result).encode())
                    self.wfile.flush()
                    return

                if len(password) < 8 or len(password) > 63:
                    _finish_wifi_switch()
                    result = {'success': False, 'message': 'パスワードは8〜63文字で指定してください'}
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(result).encode())
                    self.wfile.flush()
                    return

                result = {
                    'success': True,
                    'message': (
                        f'APモードの強制復旧を開始しました。スマホで「{ssid}」に接続してください。'
                        if force_requested
                        else f'APモード切替を開始しました。スマホで「{ssid}」に接続してください。'
                    ),
                    'ip': '192.168.4.1',
                    'ip_address': '192.168.4.1',
                }
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())
                self.wfile.flush()

                def worker():
                    try:
                        time.sleep(0.7)
                        sw = wifi_manager.switch_to_ap_mode(ssid, password)
                        if force_requested and not sw.get('success'):
                            logger.warning("Forced AP request: primary AP switch failed, trying ensure_ap_persistence")
                            persistence = wifi_manager.ensure_ap_persistence(allow_recursive_ap_recovery=False)
                            sw = {
                                'success': bool(persistence.get('success')),
                                'message': sw.get('message'),
                                'primary': sw,
                                'persistence': persistence,
                                'ip': persistence.get('ip') or persistence.get('ip_address') or sw.get('ip') or sw.get('ip_address'),
                                'ip_address': persistence.get('ip_address') or persistence.get('ip') or sw.get('ip_address') or sw.get('ip'),
                            }
                        logger.info(f"Wi-Fi switch (ap) result: {sw}")
                        if sw.get('success'):
                            _persist_wifi_mode('ap', ap_ssid=ssid, ap_password=password)
                    except Exception as e:
                        logger.error(f"Wi-Fi switch (ap) background error: {e}")
                    finally:
                        _finish_wifi_switch()

                threading.Thread(target=worker, daemon=True).start()
                return

            if mode == 'tethering':
                if not os.path.exists(wifi_manager.WPA_SUPPLICANT_CONF):
                    _finish_wifi_switch()
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({'success': False, 'message': 'wpa_supplicant.conf が見つかりません'}).encode())
                    self.wfile.flush()
                    return

                result = {
                    'success': True,
                    'message': 'テザリング切替を開始しました。Wi-Fiを切り替えた後、raspberrypi.local で再接続してください。',
                    'host': 'raspberrypi.local',
                }
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())
                self.wfile.flush()

                def worker():
                    try:
                        time.sleep(0.7)
                        sw = wifi_manager.switch_to_tethering_mode()
                        logger.info(f"Wi-Fi switch (tethering) result: {sw}")
                        if sw.get('success'):
                            _persist_wifi_mode('tethering')
                    except Exception as e:
                        logger.error(f"Wi-Fi switch (tethering) background error: {e}")
                    finally:
                        _finish_wifi_switch()

                threading.Thread(target=worker, daemon=True).start()
                return
        except Exception as e:
            _finish_wifi_switch()
            logger.error(f"Wi-Fi switch error: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': str(e)}).encode())

    def capture_photo(self):
        """手動撮影"""
        service_stopped = False
        try:
            request_data = _read_json_body(self)
            if request_data is None:
                return

            latitude = None
            longitude = None
            location_label = None
            location_obj = request_data.get('location')
            if isinstance(location_obj, dict):
                try:
                    lat_raw = location_obj.get('latitude')
                    lon_raw = location_obj.get('longitude')
                    if lat_raw is not None and lon_raw is not None:
                        lat_value = float(lat_raw)
                        lon_value = float(lon_raw)
                        if -90.0 <= lat_value <= 90.0 and -180.0 <= lon_value <= 180.0:
                            latitude = round(lat_value, 7)
                            longitude = round(lon_value, 7)
                except Exception as e:
                    logger.warning(f"Invalid capture location coordinates ignored: {e}")

                try:
                    location_label = _sanitize_location_label(
                        location_obj.get('label') or location_obj.get('name')
                    )
                except Exception:
                    location_label = None

            settings = DEFAULT_SETTINGS.copy()
            settings.update(_load_settings_dict())

            if os.path.exists(SESSION_OVERRIDES_FILE):
                try:
                    with open(SESSION_OVERRIDES_FILE, 'r') as f:
                        overrides = json.load(f)
                    if isinstance(overrides, dict):
                        settings.update(overrides)
                except Exception as e:
                    logger.warning(f"Failed to load session overrides (capture): {e}")

            manual_mode = request_data.get('manual_mode') or request_data.get('mode')
            if manual_mode:
                manual_mode = str(manual_mode).lower()
                if manual_mode != 'current':
                    preset = CAMERA_MODE_PRESETS.get(manual_mode)
                    if preset is None:
                        self.send_response(400)
                        self.send_header('Content-Type', 'application/json')
                        self.end_headers()
                        self.wfile.write(
                            json.dumps({'success': False, 'error': 'Invalid manual_mode'}).encode())
                        return
                    settings.update(preset)

            width = settings.get('width', 1920)
            height = settings.get('height', 1080)
            try:
                width = int(width)
                height = int(height)
                if width <= 0 or height <= 0:
                    raise ValueError('invalid size')
            except Exception:
                width = 1920
                height = 1080

            timestamp = f"{time.time():.6f}"
            meta_value = request_data.get('meta') or request_data.get('tag') or request_data.get('label')
            safe_meta = _sanitize_meta_tag(meta_value)
            tag_parts = []
            if manual_mode and manual_mode != 'current':
                tag_parts.append(manual_mode)
            if safe_meta:
                tag_parts.append(safe_meta)
            tag_suffix = '_'.join(tag_parts)
            filename = f"manual_{timestamp}"
            if tag_suffix:
                filename = f"{filename}_{tag_suffix}"
            photo_ext = '.dng' if settings.get('raw_mode') else '.jpg'
            filename = f"{filename}{photo_ext}"
            photo_path = os.path.join(PHOTOS_DIR, filename)

            # --- 撮影: IPC優先（camera-service 稼働中）。rpicam-still は service 停止時のみ ---
            shutter_speed = settings.get('shutter_speed', 'auto')
            shutter_us = 0
            if shutter_speed != 'auto':
                try:
                    shutter_us = int(shutter_speed)
                except (ValueError, TypeError):
                    shutter_us = 0

            capture_ok = False
            result_error = ''
            ipc_result = None

            if _is_camera_service_running():
                ipc_result = _ipc_capture(settings, photo_path, manual_mode or 'current')
                if ipc_result.get('success'):
                    capture_ok = True
                    if ipc_result.get('filepath'):
                        photo_path = ipc_result['filepath']
                        filename = os.path.basename(photo_path)
                else:
                    result_error = ipc_result.get('error', 'IPC capture failed')
                    logger.warning("IPC capture failed (%s)", result_error)

            if not capture_ok and ipc_result is not None and _is_camera_service_running():
                err_text = (result_error or '').lower()
                timeout_like = ('timed out' in err_text) or ('timeout' in err_text) or ('expired' in err_text)
                if timeout_like:
                    try:
                        restart = subprocess.run(
                            ['sudo', '-n', 'systemctl', 'restart', 'camera-service'],
                            capture_output=True, text=True, check=False, timeout=20,
                        )
                        if restart.returncode == 0:
                            time.sleep(1.0)
                            ipc_retry = _ipc_capture(settings, photo_path, manual_mode or 'current')
                            if ipc_retry.get('success'):
                                capture_ok = True
                                ipc_result = ipc_retry
                                if ipc_retry.get('filepath'):
                                    photo_path = ipc_retry['filepath']
                                    filename = os.path.basename(photo_path)
                            else:
                                result_error = ipc_retry.get('error', result_error)
                        else:
                            logger.warning(
                                "camera-service restart failed: %s",
                                (restart.stderr or restart.stdout or '').strip(),
                            )
                    except Exception as e:
                        logger.warning("camera-service restart exception: %s", e)

            if not capture_ok and ipc_result is not None and _is_camera_service_running():
                if _verify_photo_on_disk(photo_path):
                    capture_ok = True
                    logger.info("IPC reported failure but photo exists on disk: %s", photo_path)
                else:
                    logger.warning(
                        "IPC failed while camera-service active; refusing rpicam-still fallback (%s)",
                        result_error or 'unknown',
                    )

            if not capture_ok and not _is_camera_service_running():
                logger.info("camera-service inactive; using rpicam-still fallback")
                capture_ok, still_err = _run_rpicam_still_capture(
                    settings, photo_path, width, height, shutter_us,
                )
                if still_err:
                    result_error = still_err

            if capture_ok:
                applied_mode = manual_mode if manual_mode and manual_mode != 'current' else settings.get('camera_mode', 'standard')
                metadata = {
                    'timestamp': timestamp,
                    'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'manual_mode': manual_mode or 'current',
                    'applied_mode': applied_mode,
                    'meta': meta_value,
                    'iso': settings.get('iso'),
                    'shutter_speed': settings.get('shutter_speed'),
                    'white_balance': settings.get('white_balance'),
                    'quality': settings.get('quality'),
                    'width': width,
                    'height': height,
                }
                if latitude is not None and longitude is not None:
                    metadata['latitude'] = latitude
                    metadata['longitude'] = longitude
                if location_label:
                    metadata['location_label'] = location_label
                try:
                    meta_path = os.path.splitext(photo_path)[0] + '.json'
                    with open(meta_path, 'w') as f:
                        json.dump(metadata, f, indent=2)
                except Exception as e:
                    logger.warning(f"Failed to write capture metadata: {e}")

                saved_on_device = _verify_photo_on_disk(photo_path)
                if saved_on_device:
                    _mark_last_capture_unix_file()
                    _invalidate_photo_count_cache()

                response = {
                    'success': True,
                    'filename': filename,
                    'metadata': metadata,
                    'saved_on_device': saved_on_device,
                }
                include_preview = _parse_bool_value(
                    request_data.get('include_preview', False), default=False
                )
                if include_preview and saved_on_device:
                    preview_b64 = _encode_capture_preview_base64(photo_path)
                    if preview_b64:
                        response['preview_base64'] = preview_b64
                        response['preview_mime'] = 'image/jpeg'
                self.send_response(200)
            else:
                error_msg = result_error or 'Capture failed'
                saved_on_device = _verify_photo_on_disk(photo_path)
                if saved_on_device:
                    error_msg = (
                        f'{error_msg} (photo saved on Pi SD as {os.path.basename(photo_path)})'
                    )
                response = {
                    'success': False,
                    'error': error_msg,
                    'saved_on_device': saved_on_device,
                }
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
                subprocess.run(['sudo', '-n', 'systemctl', 'start', 'camera-service'], check=False, timeout=15)
    
    def _save_wifi_mode(self, mode, ap_ssid=None, ap_password=None):
        """Wi-Fiモードをcamera_settings.jsonに保存"""
        _persist_wifi_mode(mode, ap_ssid=ap_ssid, ap_password=ap_password)

    def log_message(self, format, *args):
        """アクセスログ"""
        logger.info("%s - %s", self.client_address[0], format % args)

def restore_wifi_mode_on_boot():
    """起動時に前回のWi-Fiモードを復元
    
    APが既に正常動作中の場合は重い切替処理をスキップし、
    SSH/API接続を途切れさせない。
    """
    try:
        settings = _load_settings_dict()
        if not settings:
            return
        saved_mode = settings.get('wifi_mode')
        if not saved_mode:
            return

        current_mode = wifi_manager.get_current_mode()
        logger.info(f"Boot: saved_mode={saved_mode}, current_mode={current_mode}")

        if saved_mode == 'ap':
            # APモードの場合: まずAPが既に正常動作中かチェック
            if wifi_manager._is_ap_healthy():
                logger.info("Boot: AP is already healthy, applying lightweight tuning only (no disruption)")
                iface = wifi_manager._detect_wifi_interface()
                iw_cmd = wifi_manager._resolve_executable('iw')
                wifi_manager._run(['sudo', '-n', iw_cmd, 'dev', iface, 'set', 'power_save', 'off'])
                return

            if current_mode == 'ap':
                # APモードだがHotspotが不健全 → ensure_ap_persistence（内部で健全性チェック済み）
                try:
                    persistence = wifi_manager.ensure_ap_persistence()
                    logger.info(f"AP persistence ensure result: {persistence}")
                except Exception as e:
                    logger.warning(f"AP persistence ensure failed: {e}")
                return

            # テザリングモードからAP復元が必要
            ap_ssid = settings.get('ap_ssid')
            ap_password = settings.get('ap_password')
            logger.info(f"Restoring AP mode: SSID={ap_ssid}")
            result = wifi_manager.switch_to_ap_mode(ap_ssid, ap_password)
            logger.info(f"AP restore result: {result}")
            return

        if saved_mode == 'tethering' and current_mode != 'ap':
            connected = False
            try:
                connected = wifi_manager.check_tethering_connection(timeout=20)
            except Exception as e:
                logger.warning(f"Boot tethering check failed: {e}")

            if not connected:
                logger.warning("Boot: saved tethering but not connected. Try reconnect (fallback to AP if fails).")
                result = wifi_manager.switch_to_tethering_mode()
                logger.info(f"Tethering boot reconnect result: {result}")
                return

        if saved_mode == 'tethering' and current_mode == 'ap':
            # APへ接続中の端末がある場合、強制的にテザリングへ戻さない（フラップ防止）
            if _is_ap_operational() and _has_ap_clients_connected():
                logger.info("Boot restore: AP has connected client(s); keep AP mode and skip tethering restore")
                _persist_wifi_mode('ap', ap_ssid=settings.get('ap_ssid'), ap_password=settings.get('ap_password'))
                return
            logger.info("Restoring tethering mode")
            result = wifi_manager.switch_to_tethering_mode()
            logger.info(f"Tethering restore result: {result}")
            return

        logger.info(f"Wi-Fi mode already correct: {current_mode}")
    except Exception as e:
        logger.error(f"Failed to restore Wi-Fi mode: {e}")


def _consume_boot_network_applied_marker():
    """デプロイ/再起動直後の1回だけWi-Fi自動復元をスキップする。"""
    consumed = False

    for marker in BOOT_NETWORK_APPLIED_MARKERS:
        if not os.path.exists(marker):
            continue

        removed = False
        try:
            os.remove(marker)
            removed = True
        except PermissionError:
            sudo_rm = subprocess.run(
                ['sudo', '-n', 'rm', '-f', marker],
                capture_output=True,
                text=True,
                check=False,
            )
            if sudo_rm.returncode == 0:
                removed = True
            else:
                logger.warning(
                    f"Failed to remove boot marker with sudo: {marker}: "
                    f"{sudo_rm.stderr.strip() or sudo_rm.stdout.strip()}"
                )
        except Exception as e:
            logger.warning(f"Failed to remove boot marker: {marker}: {e}")

        if removed:
            consumed = True

    if consumed:
        logger.info("Skip boot Wi-Fi restore once: deployment marker consumed")
    return consumed

def main():
    os.makedirs(PHOTOS_DIR, exist_ok=True)

    try:
        if os.path.exists(SESSION_OVERRIDES_FILE):
            os.remove(SESSION_OVERRIDES_FILE)
    except Exception as e:
        logger.warning(f"Failed to clear session overrides on boot: {e}")

    if not _consume_boot_network_applied_marker():
        restore_wifi_mode_on_boot()

    threading.Thread(target=_wifi_recovery_watchdog_loop, daemon=True).start()
    
    server_address = ('0.0.0.0', 8001)
    httpd = ThreadedHTTPServer(server_address, APIHandler)
    logger.info("API Server running on port 8001")
    httpd.serve_forever()

if __name__ == '__main__':
    main()
