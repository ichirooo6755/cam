#!/usr/bin/env python3
"""
省電力カメラサービス（Pi Zero 2W 最適化版）
光検知時のみ撮影。画像処理はすべてiPhone側で実行。

Camera: Raspberry Pi Camera Module HQ (12.3MP)
Sensor: Sony IMX477 (7.9mm diagonal, 1.55μm pixel)
Resolution: 4056x3040 (native)
ISO Range: 100-16000 (推奨: 100-6400)
Shutter: 13μs - 670s (推奨: 100μs - 1s)

Pi Zero 2W 制約:
  CPU: 4-core ARM Cortex-A53 @ 1GHz
  RAM: 512MB
  → 画像合成・エッジ検出・PIL処理はすべて禁止
  → 撮影間隔の下限を2秒に制限（JPEG保存に1-3秒かかるため）
  → 1分あたり最大10枚のハードリミット
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

# --- Pi Zero 2W 安全レート制限 ---
BRIGHTNESS_THRESHOLD = 30
CHECK_INTERVAL = 0.5            # 500ms 間隔で光チェック（CPU負荷半減）
MIN_CAPTURE_COOLDOWN = 2.0      # 最短撮影間隔（Pi Zero 2W ではJPEG保存に1-3秒）
DEFAULT_CAPTURE_COOLDOWN = 3.0  # デフォルト撮影クールダウン
MAX_CAPTURES_PER_MINUTE = 10    # 1分あたりの撮影上限
SETTINGS_RELOAD_INTERVAL = 2.0  # 設定リロード間隔（1秒→2秒に軽量化）
SENSOR_STATUS_WRITE_INTERVAL = 2.0  # ステータス書き込み間隔
MIN_CHANGE_AMOUNT = 5

DEFAULT_SETTINGS = {
    'camera_mode': 'standard',
    'brightness_threshold': 30,
    'detection_interval': CHECK_INTERVAL,
    'check_interval': CHECK_INTERVAL,
    'capture_cooldown': DEFAULT_CAPTURE_COOLDOWN,
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

def _rate_limit_ok() -> bool:
    """1分あたり MAX_CAPTURES_PER_MINUTE 枚を超えていないか"""
    now = time.time()
    cutoff = now - 60.0
    # 古いタイムスタンプを除去
    while _capture_timestamps and _capture_timestamps[0] < cutoff:
        _capture_timestamps.pop(0)
    return len(_capture_timestamps) < MAX_CAPTURES_PER_MINUTE

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
        # Luxが無い場合のみ lores 配列で計算
        array = camera.capture_array("lores")
        if len(array.shape) == 3:
            brightness = float(np.mean(array[:, :, 0]))  # 1チャンネルだけで十分
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


def _apply_camera_controls(camera: Picamera2, settings: dict) -> None:
    """カメラ制御パラメータを設定（軽量操作のみ）"""
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

    # ノイズ除去モード
    denoise_value = settings.get('denoise_mode', 'auto')
    if libcamera is not None and hasattr(libcamera.controls, 'draft'):
        denoise_map = {
            'off': libcamera.controls.draft.NoiseReductionModeEnum.Off,
            'cdn_off': libcamera.controls.draft.NoiseReductionModeEnum.Minimal,
            'cdn_fast': libcamera.controls.draft.NoiseReductionModeEnum.Fast,
            'cdn_hq': libcamera.controls.draft.NoiseReductionModeEnum.HighQuality,
        }
        if denoise_value != 'auto' and denoise_value in denoise_map:
            controls['NoiseReductionMode'] = denoise_map[denoise_value]

    # シャープネス
    sharpness_value = settings.get('sharpness', 1.0)
    try:
        controls['Sharpness'] = max(0.0, min(16.0, float(sharpness_value)))
    except (ValueError, TypeError):
        pass

    if controls:
        camera.set_controls(controls)


def capture_photo(camera, settings: dict, detected_at: float = None) -> dict:
    """
    1枚だけ撮影して保存。画像処理は一切行わない。

    Returns:
        {'success': True/False, 'filepath': str, 'delay_ms': float}
    """
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    raw_mode = settings.get('raw_mode', False)

    if raw_mode:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.dng')
    else:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.jpg')

    try:
        quality = settings.get('quality', 90)
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
            "Photo captured: %s (%.3fs, delay=%s)",
            filepath,
            capture_end - capture_start,
            f"{delay_ms}ms" if delay_ms else "N/A",
        )
        _record_capture()
        return {'success': True, 'filepath': filepath, 'delay_ms': delay_ms}

    except Exception as e:
        logger.error(f"Capture failed: {e}")
        return {'success': False, 'filepath': filepath, 'delay_ms': None}


def main():
    logger.info("Starting light detection camera service (Pi Zero 2W optimized)...")

    try:
        if os.path.exists(SESSION_OVERRIDES_FILE):
            os.remove(SESSION_OVERRIDES_FILE)
    except Exception as e:
        logger.warning(f"Failed to clear session overrides on boot: {e}")

    camera = None
    current_main_size = None
    last_capture_time = 0
    last_settings_load = 0
    threshold = BRIGHTNESS_THRESHOLD
    settings = DEFAULT_SETTINGS.copy()
    last_brightness = None
    detection_interval = CHECK_INTERVAL
    check_interval = CHECK_INTERVAL
    capture_cooldown = DEFAULT_CAPTURE_COOLDOWN
    controls_applied = False

    sensor_state = {
        'service': 'camera-service',
        'camera_mode': 'standard',
        'monitoring_enabled': True,
        'threshold_percent': threshold,
        'detection_interval': detection_interval,
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
                threshold = int(settings.get('brightness_threshold', BRIGHTNESS_THRESHOLD))
                detection_interval = max(0.5, float(settings.get('detection_interval', CHECK_INTERVAL)))

                try:
                    check_interval = max(0.25, float(settings.get('check_interval', CHECK_INTERVAL)))
                except (TypeError, ValueError):
                    check_interval = CHECK_INTERVAL

                # capture_cooldown: Pi Zero 2W の安全下限を強制
                try:
                    raw_cooldown = float(settings.get('capture_cooldown', DEFAULT_CAPTURE_COOLDOWN))
                except (TypeError, ValueError):
                    raw_cooldown = DEFAULT_CAPTURE_COOLDOWN
                capture_cooldown = max(MIN_CAPTURE_COOLDOWN, raw_cooldown)

                monitoring_enabled = bool(settings.get('monitoring_enabled', True))
                try:
                    width = int(settings.get('width', 1920))
                    height = int(settings.get('height', 1080))
                    if width <= 0 or height <= 0:
                        raise ValueError
                except Exception:
                    width, height = 1920, 1080

                desired_size = (width, height)
                sensor_state.update({
                    'camera_mode': settings.get('camera_mode', 'standard'),
                    'monitoring_enabled': monitoring_enabled,
                    'threshold_percent': threshold,
                    'detection_interval': detection_interval,
                    'check_interval': check_interval,
                    'capture_cooldown': capture_cooldown,
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
                        last_brightness = None
                        controls_applied = False
                else:
                    if camera is None or current_main_size != desired_size:
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
                        # lores は光検知用の小さいサイズで十分
                        lores_size = (160, 120)
                        config = cam.create_still_configuration(
                            main={"size": desired_size},
                            lores={"size": lores_size},
                        )
                        cam.configure(config)
                        cam.start()
                        camera = cam
                        current_main_size = desired_size
                        last_brightness = None
                        controls_applied = False
                        logger.info("Camera started: main=%s, lores=%s", desired_size, lores_size)

                    # カメラ制御は設定リロード時に1回だけ適用
                    if camera is not None and not controls_applied:
                        _apply_camera_controls(camera, settings)
                        controls_applied = True

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

                # 暗くなる方向はスキップ（光の「立ち上がり」のみ検知）
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
                        and current_time - last_capture_time >= detection_interval):

                    # レートリミットチェック
                    if not _rate_limit_ok():
                        logger.warning("Rate limit reached (%d/min). Skipping capture.", MAX_CAPTURES_PER_MINUTE)
                        sensor_state['state'] = 'rate_limited'
                        time.sleep(check_interval)
                        continue

                    logger.info(
                        "Light detected: brightness=%.2f, change=%.2f%%, threshold=%d",
                        brightness, change_percent, threshold,
                    )
                    detected_at = time.time()
                    sensor_state['last_detected_at'] = datetime.now().isoformat()

                    result = capture_photo(camera, settings, detected_at=detected_at)
                    if result['success']:
                        last_capture_time = time.time()
                        sensor_state['last_capture_at'] = datetime.now().isoformat()
                        sensor_state['last_detect_to_capture_ms'] = result.get('delay_ms')

            except Exception as e:
                logger.error(f"Detection error: {e}")
                sensor_state['last_error'] = str(e)

            # --- センサーステータス書き込み（省電力）---
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
