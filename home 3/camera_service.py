#!/usr/bin/env python3
"""
省電力カメラサービス（Pi Zero 2W 最適化版）
光検知時のみ撮影。画像処理はすべてiPhone側で実行。

Camera: Raspberry Pi Camera Module HQ (12.3MP)
Sensor: Sony IMX477 (7.9mm diagonal, 1.55μm pixel)

モード別パフォーマンスプロファイル:
  reaction  : 検知→撮影レイテンシ最小。100ms ポーリング、0.5s クールダウン、denoise OFF
  standard  : 汎用高速。200ms ポーリング、1.5s クールダウン
  manual    : standard と同等
  quality   : 最高画質。500ms ポーリング、3s クールダウン、cdn_hq
  night     : 暗所・夜間高画質。500ms ポーリング、3s クールダウン、cdn_hq
  raw       : DNG保存。大ファイル書込のため 5s クールダウン
  battery   : 省電力。1s ポーリング、5s クールダウン
"""

import os
import time
import json
import logging
from datetime import datetime
from picamera2 import Picamera2
import numpy as np

try:
    import libcamera
except ImportError:
    libcamera = None

LOG_DIR = '/home/pi/logs'
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(os.path.join(LOG_DIR, 'camera_service.log')),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger(__name__)

PHOTOS_DIR = '/home/pi/photos'
SETTINGS_FILE = '/home/pi/camera_settings.json'
SESSION_OVERRIDES_FILE = '/home/pi/camera_session_overrides.json'
SENSOR_STATUS_FILE = '/home/pi/sensor_status.json'

BRIGHTNESS_THRESHOLD = 30
MIN_CHANGE_AMOUNT = 5
SETTINGS_RELOAD_INTERVAL = 2.0
SENSOR_STATUS_WRITE_INTERVAL = 2.0

# --- モード別パフォーマンスプロファイル ---
# check_interval    : 光検知ポーリング間隔（秒）
# min_cooldown      : 撮影後の最短待機（秒）
# max_per_minute    : 1分あたりの撮影上限
# lores_size        : 光検知用の低解像度ストリーム
# quality           : JPEG品質（低い=書込み高速）
# denoise_override  : None=設定に従う / 文字列=強制上書き
MODE_PROFILES = {
    'reaction': {
        'check_interval': 0.1,
        'min_cooldown': 0.5,
        'max_per_minute': 24,
        'lores_size': (128, 96),
        'quality': 70,
        'denoise_override': 'off',
    },
    'standard': {
        'check_interval': 0.2,
        'min_cooldown': 1.5,
        'max_per_minute': 15,
        'lores_size': (160, 120),
        'quality': 90,
        'denoise_override': None,
    },
    'manual': {
        'check_interval': 0.2,
        'min_cooldown': 1.5,
        'max_per_minute': 15,
        'lores_size': (160, 120),
        'quality': 90,
        'denoise_override': None,
    },
    'quality': {
        'check_interval': 0.5,
        'min_cooldown': 3.0,
        'max_per_minute': 10,
        'lores_size': (160, 120),
        'quality': 100,
        'denoise_override': 'cdn_hq',
    },
    'night': {
        'check_interval': 0.5,
        'min_cooldown': 3.0,
        'max_per_minute': 10,
        'lores_size': (160, 120),
        'quality': 95,
        'denoise_override': 'cdn_hq',
    },
    'raw': {
        'check_interval': 0.5,
        'min_cooldown': 5.0,
        'max_per_minute': 6,
        'lores_size': (160, 120),
        'quality': 100,
        'denoise_override': None,
    },
    'battery': {
        'check_interval': 1.0,
        'min_cooldown': 5.0,
        'max_per_minute': 6,
        'lores_size': (128, 96),
        'quality': 80,
        'denoise_override': None,
    },
}
_DEFAULT_PROFILE = MODE_PROFILES['standard']

DEFAULT_SETTINGS = {
    'camera_mode': 'standard',
    'brightness_threshold': 30,
    'detection_interval': 0.5,
    'check_interval': 0.5,
    'capture_cooldown': 3.0,
    'iso': 'auto',
    'shutter_speed': 'auto',
    'white_balance': 'auto',
    'width': 1920,
    'height': 1080,
    'monitoring_enabled': True,
    'quality': 90,
    'raw_mode': False,
    'denoise_mode': 'auto',
    'sharpness': 1.0,
    'stabilization': True,
}

os.makedirs(PHOTOS_DIR, exist_ok=True)

# --- レートリミッター ---
_capture_timestamps = []
_active_max_per_minute = 15

def _rate_limit_ok() -> bool:
    now = time.time()
    cutoff = now - 60.0
    while _capture_timestamps and _capture_timestamps[0] < cutoff:
        _capture_timestamps.pop(0)
    return len(_capture_timestamps) < _active_max_per_minute

def _record_capture():
    _capture_timestamps.append(time.time())


def get_sensor_sample(camera):
    """メタデータから明るさ情報を取得（低負荷）"""
    metadata = camera.capture_metadata()
    lux = metadata.get('Lux')
    ae_gain = metadata.get('AnalogueGain')
    ae_exposure_us = metadata.get('ExposureTime')

    if lux is not None:
        brightness = float(lux)
    else:
        array = camera.capture_array("lores")
        if len(array.shape) == 3:
            brightness = float(np.mean(array[:, :, 0]))
        else:
            brightness = float(np.mean(array))

    return brightness, lux, ae_gain, ae_exposure_us


def load_settings() -> dict:
    settings = DEFAULT_SETTINGS.copy()
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r', encoding='utf-8') as f:
                settings.update(json.load(f))
    except Exception as e:
        logger.warning(f"Failed to load settings: {e}")

    try:
        if os.path.exists(SESSION_OVERRIDES_FILE):
            with open(SESSION_OVERRIDES_FILE, 'r', encoding='utf-8') as f:
                overrides = json.load(f)
            if isinstance(overrides, dict):
                settings.update(overrides)
    except Exception as e:
        logger.warning(f"Failed to load session overrides: {e}")

    return settings


def write_sensor_status(state: dict) -> None:
    try:
        payload = dict(state)
        payload['updated_at'] = datetime.now().isoformat()
        tmp_path = f"{SENSOR_STATUS_FILE}.tmp"
        with open(tmp_path, 'w', encoding='utf-8') as f:
            json.dump(payload, f, indent=2)
        os.replace(tmp_path, SENSOR_STATUS_FILE)
    except Exception as e:
        logger.debug(f"Failed to write sensor status: {e}")


def _apply_camera_controls(camera: Picamera2, settings: dict, profile: dict) -> None:
    """カメラ制御パラメータを設定"""
    controls = {}
    iso_value = settings.get('iso', 'auto')
    shutter_value = settings.get('shutter_speed', 'auto')
    wb_value = settings.get('white_balance', 'auto')

    manual_exposure = iso_value != 'auto' or shutter_value != 'auto'
    controls['AeEnable'] = not manual_exposure

    if iso_value != 'auto':
        try:
            gain = int(iso_value) / 100.0
            controls['AnalogueGain'] = max(1.0, min(160.0, gain))
        except ValueError:
            logger.warning(f"Invalid ISO value: {iso_value}")

    if shutter_value != 'auto':
        try:
            if isinstance(shutter_value, str) and '/' in shutter_value:
                numerator, denominator = shutter_value.split('/', 1)
                exposure_seconds = float(numerator) / float(denominator)
                exposure_time = int(exposure_seconds * 1_000_000)
            else:
                exposure_time = int(shutter_value)
            controls['ExposureTime'] = exposure_time
        except ValueError:
            logger.warning(f"Invalid shutter value: {shutter_value}")

    if libcamera is not None:
        if wb_value == 'auto':
            controls['AwbMode'] = libcamera.controls.AwbModeEnum.Auto
        else:
            wb_map = {
                'daylight': libcamera.controls.AwbModeEnum.Daylight,
                'cloudy': libcamera.controls.AwbModeEnum.Cloudy,
                'tungsten': libcamera.controls.AwbModeEnum.Tungsten,
                'fluorescent': libcamera.controls.AwbModeEnum.Fluorescent,
                'shade': libcamera.controls.AwbModeEnum.Auto,
            }
            controls['AwbMode'] = wb_map.get(wb_value, libcamera.controls.AwbModeEnum.Auto)

    # ノイズ除去: プロファイルの強制上書きが優先
    denoise_value = profile.get('denoise_override') or settings.get('denoise_mode', 'auto')
    if libcamera is not None and hasattr(libcamera.controls, 'draft'):
        denoise_map = {
            'off': libcamera.controls.draft.NoiseReductionModeEnum.Off,
            'cdn_off': libcamera.controls.draft.NoiseReductionModeEnum.Minimal,
            'cdn_fast': libcamera.controls.draft.NoiseReductionModeEnum.Fast,
            'cdn_hq': libcamera.controls.draft.NoiseReductionModeEnum.HighQuality,
        }
        if denoise_value in denoise_map:
            controls['NoiseReductionMode'] = denoise_map[denoise_value]

    # シャープネス
    sharpness_value = settings.get('sharpness', 1.0)
    try:
        controls['Sharpness'] = max(0.0, min(16.0, float(sharpness_value)))
    except (ValueError, TypeError):
        pass

    if controls:
        camera.set_controls(controls)


def capture_photo(camera, settings: dict, profile: dict, detected_at: float = None) -> dict:
    """1枚だけ撮影して保存。画像処理は一切行わない。"""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    raw_mode = settings.get('raw_mode', False)

    if raw_mode:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.dng')
    else:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.jpg')

    try:
        # プロファイルの品質を適用（ユーザー設定より速度優先モードが上書き）
        quality = profile.get('quality', settings.get('quality', 90))
        camera.options["quality"] = quality
        capture_start = time.time()

        if raw_mode:
            try:
                camera.capture_file(filepath, format='dng')
            except Exception:
                camera.switch_mode_and_capture_file(
                    camera.still_configuration, filepath, format='dng')
        else:
            try:
                camera.capture_file(filepath)
            except Exception:
                camera.switch_mode_and_capture_file(
                    camera.still_configuration, filepath)

        capture_end = time.time()
        delay_ms = None
        if detected_at is not None:
            delay_ms = round((capture_end - detected_at) * 1000.0, 1)

        logger.info(
            "Captured: %s (%.3fs, delay=%s, q=%d)",
            os.path.basename(filepath),
            capture_end - capture_start,
            f"{delay_ms}ms" if delay_ms else "N/A",
            quality,
        )
        _record_capture()
        return {'success': True, 'filepath': filepath, 'delay_ms': delay_ms}

    except Exception as e:
        logger.error(f"Capture failed: {e}")
        return {'success': False, 'filepath': filepath, 'delay_ms': None}


def main():
    logger.info("Starting light detection camera service (Pi Zero 2W)...")

    try:
        if os.path.exists(SESSION_OVERRIDES_FILE):
            os.remove(SESSION_OVERRIDES_FILE)
    except Exception as e:
        logger.warning(f"Failed to clear session overrides on boot: {e}")

    global _active_max_per_minute

    camera = None
    current_main_size = None
    current_lores_size = None
    last_capture_time = 0
    last_settings_load = 0
    threshold = BRIGHTNESS_THRESHOLD
    settings = DEFAULT_SETTINGS.copy()
    last_brightness = None
    check_interval = 0.5
    capture_cooldown = 3.0
    controls_applied = False
    active_profile = _DEFAULT_PROFILE

    sensor_state = {
        'service': 'camera-service',
        'camera_mode': 'standard',
        'monitoring_enabled': True,
        'threshold_percent': threshold,
        'check_interval': check_interval,
        'capture_cooldown': capture_cooldown,
        'brightness': None,
        'last_change_percent': None,
        'last_change_amount': None,
        'last_capture_at': None,
        'last_detected_at': None,
        'last_detect_to_capture_ms': None,
    }
    last_sensor_status_write = 0.0

    try:
        while True:
            current_time = time.time()

            # クールダウン中はスキップ
            if current_time - last_capture_time < capture_cooldown:
                time.sleep(check_interval)
                continue

            # --- 設定リロード ---
            if current_time - last_settings_load > SETTINGS_RELOAD_INTERVAL:
                settings = load_settings()
                camera_mode = str(settings.get('camera_mode', 'standard') or 'standard').strip().lower()
                active_profile = MODE_PROFILES.get(camera_mode, _DEFAULT_PROFILE)

                threshold = int(settings.get('brightness_threshold', BRIGHTNESS_THRESHOLD))

                # プロファイルの値を適用（ユーザー設定で上書き可能だが下限はプロファイルが決定）
                profile_check = active_profile['check_interval']
                profile_cooldown = active_profile['min_cooldown']
                _active_max_per_minute = active_profile['max_per_minute']

                try:
                    user_check = float(settings.get('check_interval', profile_check))
                except (TypeError, ValueError):
                    user_check = profile_check
                # ユーザーがもっと速い値を指定してもプロファイル下限を尊重
                check_interval = max(profile_check, min(user_check, 2.0))

                try:
                    user_cooldown = float(settings.get('capture_cooldown', profile_cooldown))
                except (TypeError, ValueError):
                    user_cooldown = profile_cooldown
                capture_cooldown = max(profile_cooldown, min(user_cooldown, 30.0))

                monitoring_enabled = bool(settings.get('monitoring_enabled', True))
                try:
                    width = int(settings.get('width', 1920))
                    height = int(settings.get('height', 1080))
                    if width <= 0 or height <= 0:
                        raise ValueError
                except Exception:
                    width, height = 1920, 1080

                desired_size = (width, height)
                desired_lores = active_profile['lores_size']

                sensor_state.update({
                    'camera_mode': camera_mode,
                    'monitoring_enabled': monitoring_enabled,
                    'threshold_percent': threshold,
                    'check_interval': check_interval,
                    'capture_cooldown': capture_cooldown,
                    'max_per_minute': _active_max_per_minute,
                    'width': width,
                    'height': height,
                })

                if not monitoring_enabled:
                    if camera is not None:
                        try:
                            camera.stop()
                        except Exception:
                            pass
                        try:
                            camera.close()
                        except Exception:
                            pass
                        camera = None
                        current_main_size = None
                        current_lores_size = None
                        last_brightness = None
                        controls_applied = False
                else:
                    need_reconfig = (
                        camera is None
                        or current_main_size != desired_size
                        or current_lores_size != desired_lores
                    )
                    if need_reconfig:
                        if camera is not None:
                            try:
                                camera.stop()
                            except Exception:
                                pass
                            try:
                                camera.close()
                            except Exception:
                                pass
                            camera = None

                        cam = Picamera2()
                        config = cam.create_still_configuration(
                            main={"size": desired_size},
                            lores={"size": desired_lores},
                        )
                        cam.configure(config)
                        cam.start()
                        camera = cam
                        current_main_size = desired_size
                        current_lores_size = desired_lores
                        last_brightness = None
                        controls_applied = False
                        logger.info(
                            "Camera started: mode=%s, main=%s, lores=%s, cooldown=%.1fs",
                            camera_mode, desired_size, desired_lores, capture_cooldown,
                        )

                    # カメラ制御は設定リロード時に1回だけ適用
                    if camera is not None and not controls_applied:
                        _apply_camera_controls(camera, settings, active_profile)
                        controls_applied = True
                        # JPEG品質もここで設定（毎撮影時に再設定しなくて済む）
                        camera.options["quality"] = active_profile.get(
                            'quality', settings.get('quality', 90))

                last_settings_load = current_time

            # --- モニタリング無効 ---
            if not settings.get('monitoring_enabled', True):
                sensor_state['state'] = 'monitoring_disabled'
                if current_time - last_sensor_status_write >= SENSOR_STATUS_WRITE_INTERVAL:
                    write_sensor_status(sensor_state)
                    last_sensor_status_write = current_time
                time.sleep(check_interval)
                continue

            # --- カメラ未初期化 ---
            if camera is None:
                sensor_state['state'] = 'camera_unavailable'
                if current_time - last_sensor_status_write >= SENSOR_STATUS_WRITE_INTERVAL:
                    write_sensor_status(sensor_state)
                    last_sensor_status_write = current_time
                time.sleep(check_interval)
                continue

            # --- 光検知ループ ---
            try:
                brightness, lux, ae_gain, ae_exposure_us = get_sensor_sample(camera)

                if last_brightness is None:
                    last_brightness = brightness
                    time.sleep(check_interval)
                    continue

                prev_brightness = last_brightness
                change_amount = brightness - prev_brightness
                last_brightness = brightness

                sensor_state['state'] = 'monitoring'
                sensor_state['brightness'] = round(float(brightness), 3)
                sensor_state['lux'] = round(float(lux), 3) if lux is not None else None
                sensor_state['ae_gain'] = round(float(ae_gain), 4) if ae_gain is not None else None
                sensor_state['ae_exposure_us'] = round(float(ae_exposure_us), 1) if ae_exposure_us is not None else None
                sensor_state['last_change_amount'] = round(float(change_amount), 3)

                if change_amount < 0:
                    time.sleep(check_interval)
                    continue

                if prev_brightness > 0:
                    change_percent = change_amount / prev_brightness * 100
                else:
                    change_percent = change_amount * 100
                sensor_state['last_change_percent'] = round(float(change_percent), 3)

                # --- 撮影判定 ---
                if (change_percent >= threshold
                        and change_amount >= MIN_CHANGE_AMOUNT
                        and current_time - last_capture_time >= capture_cooldown):

                    if not _rate_limit_ok():
                        logger.warning(
                            "Rate limit (%d/min). Skipping.", _active_max_per_minute)
                        sensor_state['state'] = 'rate_limited'
                        time.sleep(check_interval)
                        continue

                    logger.info(
                        "Light detected: lux=%.2f, change=%.1f%%, thr=%d",
                        brightness, change_percent, threshold,
                    )
                    detected_at = time.time()
                    sensor_state['last_detected_at'] = datetime.now().isoformat()

                    result = capture_photo(
                        camera, settings, active_profile, detected_at=detected_at)
                    if result['success']:
                        last_capture_time = time.time()
                        sensor_state['last_capture_at'] = datetime.now().isoformat()
                        sensor_state['last_detect_to_capture_ms'] = result.get('delay_ms')

            except Exception as e:
                logger.error(f"Detection error: {e}")
                sensor_state['last_error'] = str(e)

            # --- センサーステータス書き込み ---
            if current_time - last_sensor_status_write >= SENSOR_STATUS_WRITE_INTERVAL:
                write_sensor_status(sensor_state)
                last_sensor_status_write = current_time

            time.sleep(check_interval)

    except KeyboardInterrupt:
        logger.info("Service stopped by user")
    finally:
        sensor_state['state'] = 'stopped'
        sensor_state['monitoring_enabled'] = False
        write_sensor_status(sensor_state)
        if camera is not None:
            try:
                camera.stop()
            except Exception:
                pass
            try:
                camera.close()
            except Exception:
                pass


if __name__ == '__main__':
    main()
