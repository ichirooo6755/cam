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

import wifi_manager
try:
    from PIL import Image
except ImportError:
    Image = None
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PHOTOS_DIR = '/home/pi/photos'
THUMBNAIL_DIR = os.path.join(PHOTOS_DIR, '_thumbs')
THUMBNAIL_MAX_DIM_DEFAULT = 300
THUMBNAIL_QUALITY = 75
SETTINGS_FILE = '/home/pi/camera_settings.json'
SESSION_OVERRIDES_FILE = '/home/pi/camera_session_overrides.json'
SENSOR_STATUS_FILE = '/home/pi/sensor_status.json'
BOOT_NETWORK_APPLIED_MARKERS = (
    '/run/picamera_boot_network_applied',
    '/tmp/picamera_boot_network_applied',
)
SAFE_FILENAME_PATTERN = re.compile(r'^[A-Za-z0-9._-]+$')
ALLOWED_PHOTO_EXTENSIONS = ('.jpg', '.jpeg', '.png')
MAX_JSON_BODY_BYTES = 64 * 1024
WIFI_SWITCH_COOLDOWN_SEC = 12
WIFI_RECOVERY_CHECK_INTERVAL_SEC = 10
WIFI_RECOVERY_OFFLINE_GRACE_SEC = 45
WIFI_RECOVERY_ATTEMPT_COOLDOWN_SEC = 120
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
    'last_result': None,
    'last_error': None,
}

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
        settings = {}
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings = json.load(f)

        settings['wifi_mode'] = mode
        if ap_ssid:
            settings['ap_ssid'] = ap_ssid
        if ap_password:
            settings['ap_password'] = ap_password

        with open(SETTINGS_FILE, 'w') as f:
            json.dump(settings, f, indent=2)
        logger.info(f"Wi-Fi mode saved: {mode}")
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
            return wifi_manager.check_tethering_connection(timeout=25)
        except Exception as e:
            logger.warning(f"Failed to check tethering operational status: {e}")
            return False

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
    AP_UNHEALTHY_GRACE_SEC = 15  # AP不健全→復旧までの猶予（撮影中の一時的な不安定を許容）

    while True:
        time.sleep(WIFI_RECOVERY_CHECK_INTERVAL_SEC)

        try:
            with _WIFI_SWITCH_LOCK:
                if _WIFI_SWITCH_STATE.get('in_progress'):
                    continue

            mode = wifi_manager.get_current_mode()

            # --- APモード時: AP健全性を監視し、壊れたら復旧 ---
            if mode == 'ap':
                if wifi_manager._is_ap_healthy():
                    ap_unhealthy_since = None
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
    },
    'standard': {
        'quality': 90,
        'width': 1920,
        'height': 1080,
        'check_interval': 0.2,
        'capture_cooldown': 1.5,
        'monitoring_enabled': True,
    },
    'quality': {
        'quality': 100,
        'width': 4056,
        'height': 3040,
        'check_interval': 0.5,
        'capture_cooldown': 3.0,
        'monitoring_enabled': True,
        'denoise_mode': 'cdn_hq',
    },
    'night': {
        'quality': 95,
        'width': 1920,
        'height': 1080,
        'check_interval': 0.5,
        'capture_cooldown': 3.0,
        'monitoring_enabled': True,
        'denoise_mode': 'cdn_hq',
    },
    'battery': {
        'quality': 80,
        'width': 1920,
        'height': 1080,
        'check_interval': 1.0,
        'capture_cooldown': 5.0,
        'monitoring_enabled': True,
    },
    'manual': {
        'monitoring_enabled': False,
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

def _load_effective_settings():
    settings = DEFAULT_SETTINGS.copy()
    if os.path.exists(SETTINGS_FILE):
        with open(SETTINGS_FILE, 'r') as f:
            settings.update(json.load(f))

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
        with Image.open(filepath) as img:
            img.thumbnail((max_dim, max_dim), resample=resample)
            if img.mode in ('RGBA', 'P'):
                img = img.convert('RGB')
            img.save(thumb_path, format='JPEG', quality=THUMBNAIL_QUALITY, optimize=True)
        return thumb_path
    except Exception as e:
        logger.warning(f"Thumbnail generation failed: {e}")
        return None

class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True

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
        else:
            self.send_error(404)

    def serve_sensor_status(self):
        try:
            sensor = {}
            if os.path.exists(SENSOR_STATUS_FILE):
                with open(SENSOR_STATUS_FILE, 'r', encoding='utf-8') as f:
                    loaded = json.load(f)
                    if isinstance(loaded, dict):
                        sensor = loaded

            settings = _load_effective_settings()
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

            sensor = {}
            if os.path.exists(SENSOR_STATUS_FILE):
                with open(SENSOR_STATUS_FILE, 'r', encoding='utf-8') as f:
                    loaded = json.load(f)
                    if isinstance(loaded, dict):
                        sensor = loaded

            settings = _load_effective_settings()

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
    
    def serve_photo_list(self):
        """写真一覧を返す"""
        try:
            files = []
            if os.path.exists(PHOTOS_DIR):
                files = [
                    f for f in os.listdir(PHOTOS_DIR)
                    if f.lower().endswith(ALLOWED_PHOTO_EXTENSIONS) and SAFE_FILENAME_PATTERN.match(f)
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

            content_type = 'image/png' if filename.lower().endswith('.png') else 'image/jpeg'
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', os.path.getsize(filepath))
            self.end_headers()
            with open(filepath, 'rb') as f:
                shutil.copyfileobj(f, self.wfile)
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
            content_type = 'image/png' if safe_name.lower().endswith('.png') else 'image/jpeg'
            if thumbnail:
                thumb_path = _ensure_thumbnail(filepath, max_dim)
                if thumb_path:
                    content_path = thumb_path
                    content_type = 'image/jpeg'

            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', os.path.getsize(content_path))
            self.end_headers()
            with open(content_path, 'rb') as f:
                shutil.copyfileobj(f, self.wfile)
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
                'service_running': True
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
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

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
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

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

                with open(SESSION_OVERRIDES_FILE, 'w') as f:
                    json.dump(overrides, f, indent=2)

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
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings.update(json.load(f))

            if os.path.exists(SESSION_OVERRIDES_FILE):
                try:
                    with open(SESSION_OVERRIDES_FILE, 'r') as f:
                        overrides = json.load(f)
                    if isinstance(overrides, dict):
                        settings.update(overrides)
                except Exception as e:
                    logger.warning(f"Failed to load session overrides (capture): {e}")

            service_should_stop = bool(settings.get('monitoring_enabled', True))

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

            if service_should_stop:
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
            filename = f"{filename}.jpg"
            photo_path = os.path.join(PHOTOS_DIR, filename)

            cmd = [
                'libcamera-still',
                '-o', photo_path,
                '--width', str(width),
                '--height', str(height),
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

                response = {'success': True, 'filename': filename, 'metadata': metadata}
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
        if not os.path.exists(SETTINGS_FILE):
            return
        with open(SETTINGS_FILE, 'r') as f:
            settings = json.load(f)
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
    httpd = ReusableHTTPServer(server_address, APIHandler)
    logger.info("API Server running on port 8001")
    httpd.serve_forever()

if __name__ == '__main__':
    main()
