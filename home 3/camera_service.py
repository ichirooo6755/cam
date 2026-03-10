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
import threading
from collections import deque
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
SENSOR_STATUS_FILE = '/run/picamera/sensor_status.json'
_SENSOR_STATUS_DIR = '/run/picamera'

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
        'wifi_sleep': 0.0,
    },
    'standard': {
        'check_interval': 0.2,
        'min_cooldown': 1.5,
        'max_per_minute': 15,
        'lores_size': (160, 120),
        'quality': 90,
        'denoise_override': None,
        'wifi_sleep': 0.08,
    },
    'manual': {
        'check_interval': 0.2,
        'min_cooldown': 1.5,
        'max_per_minute': 15,
        'lores_size': (160, 120),
        'quality': 90,
        'denoise_override': None,
        'wifi_sleep': 0.08,
    },
    'quality': {
        'check_interval': 0.5,
        'min_cooldown': 3.0,
        'max_per_minute': 10,
        'lores_size': (160, 120),
        'quality': 100,
        'denoise_override': 'cdn_hq',
        'wifi_sleep': 0.10,
    },
    'night': {
        'check_interval': 0.5,
        'min_cooldown': 3.0,
        'max_per_minute': 10,
        'lores_size': (160, 120),
        'quality': 95,
        'denoise_override': 'cdn_hq',
        'wifi_sleep': 0.10,
    },
    'raw': {
        'check_interval': 0.5,
        'min_cooldown': 5.0,
        'max_per_minute': 6,
        'lores_size': (160, 120),
        'quality': 100,
        'denoise_override': None,
        'wifi_sleep': 0.10,
    },
    'battery': {
        'check_interval': 1.0,
        'min_cooldown': 5.0,
        'max_per_minute': 6,
        'lores_size': (128, 96),
        'quality': 80,
        'denoise_override': None,
        'wifi_sleep': 0.15,
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
os.makedirs(_SENSOR_STATUS_DIR, exist_ok=True)

# --- レートリミッター ---
_capture_timestamps: deque = deque()
_active_max_per_minute = 15

def _rate_limit_ok() -> bool:
    now = time.time()
    cutoff = now - 60.0
    while _capture_timestamps and _capture_timestamps[0] < cutoff:
        _capture_timestamps.popleft()
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


def get_sensor_sample_from_request(request):
    """キャプチャリクエストから明るさ情報を取得"""
    metadata = request.get_metadata()
    lux = metadata.get('Lux')
    ae_gain = metadata.get('AnalogueGain')
    ae_exposure_us = metadata.get('ExposureTime')

    if lux is not None:
        brightness = float(lux)
    else:
        array = request.make_array("lores")
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

    # フィルムカメラ内蔵用途: カメラ内部は真っ暗だがシャッターが開くと明るい光が一瞬入る。
    #   - AeEnable=Trueだと暗所にgain=8まで適応し、AnalogueGain指定を上書きする
    #   - AeEnable=Falseでも DigitalGain=1.0（実測確認済み）なので白飛びしない
    #   - ET=33msだとISPのブラックレベル補正でmainストリームが黒に潰れる（実測確認済み）
    #   - ExposureTime=33ms（30fps）で同一フレームキャプチャと組み合わせる
    #   - どんな環境でもカメラ内部は暗いのでこの設定で普遍的に動作する
    manual_exposure = iso_value != 'auto' or shutter_value != 'auto'
    controls['AeEnable'] = not manual_exposure

    # ユーザーが明示的にISO値を設定した場合はそれを最優先で使用
    if iso_value != 'auto':
        try:
            gain = int(iso_value) / 100.0
            controls['AnalogueGain'] = max(1.0, min(160.0, gain))
        except ValueError:
            logger.warning(f"Invalid ISO value: {iso_value}")
    elif _adaptive_gain is not None:
        # auto時のみ適応型gainを使用（撮影結果から自動調整）
        controls['AnalogueGain'] = max(_ADAPTIVE_GAIN_MIN, min(_ADAPTIVE_GAIN_MAX, _adaptive_gain))
        logger.info("Using adaptive gain: %.2f (ISO %d)", _adaptive_gain, int(_adaptive_gain * 100))
    else:
        # 初回起動時: ISO 100（gain=1.0）を安全なデフォルトとして設定
        # AEが暗所に適応してgain=8にする前に上書きする
        controls['AnalogueGain'] = 1.0

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

    logger.info("Controls: AE=%s AG=%s ET=%s", controls.get('AeEnable'), controls.get('AnalogueGain'), controls.get('ExposureTime'))

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


# --- 適応型露出フィードバック ---
# フィルムカメラ内蔵用途: 撮影後に写真の平均輝度を分析し、
# 次の撮影のAnalogueGain（ISO相当）を自動調整する。
# フィルムカメラ側のSSが変わっても自動で追従する。
_adaptive_gain = None  # None=未初期化（設定のISO値を使用）
_ADAPTIVE_TARGET_BRIGHTNESS = 115  # 目標平均輝度（0-255）
_ADAPTIVE_TOLERANCE = 30           # この範囲内なら調整しない
_ADAPTIVE_GAIN_MIN = 1.0           # ISO 100
_ADAPTIVE_GAIN_MAX = 16.0          # ISO 1600


def _analyze_brightness(filepath: str) -> float:
    """撮影した写真の平均輝度を返す（0-255）"""
    try:
        from PIL import Image
        with Image.open(filepath) as img:
            small = img.resize((160, 120))
            if small.mode != 'L':
                small = small.convert('L')
            pixels = list(small.getdata())
            return sum(pixels) / len(pixels) if pixels else 128.0
    except Exception:
        pass
    try:
        arr = np.fromfile(filepath, dtype=np.uint8)
        if len(arr) > 1000:
            sample = arr[len(arr)//4 : len(arr)*3//4]
            return float(np.mean(sample))
    except Exception:
        pass
    return -1.0


def _adapt_exposure(camera: 'Picamera2', filepath: str, settings: dict) -> None:
    """撮影結果に基づいてAnalogueGainを自動調整する"""
    global _adaptive_gain

    brightness = _analyze_brightness(filepath)
    if brightness < 0:
        return

    iso_value = settings.get('iso', 'auto')

    # 手動ISO設定時は適応型gainをリセット（古い値が残らないようにする）
    if iso_value != 'auto':
        _adaptive_gain = None
        return

    if _adaptive_gain is None:
        _adaptive_gain = 1.0  # ISO 100相当（安全な開始点、白飛び防止）

    target = _ADAPTIVE_TARGET_BRIGHTNESS
    tolerance = _ADAPTIVE_TOLERANCE

    if abs(brightness - target) <= tolerance:
        logger.info("Adaptive exposure: brightness=%.1f (OK, gain=%.2f)", brightness, _adaptive_gain)
        return

    if brightness < 5:
        ratio = 4.0
    elif brightness > 250:
        ratio = 0.25
    else:
        ratio = target / max(brightness, 1.0)
        ratio = max(0.5, min(2.0, ratio))

    new_gain = _adaptive_gain * ratio
    new_gain = max(_ADAPTIVE_GAIN_MIN, min(_ADAPTIVE_GAIN_MAX, new_gain))

    logger.info(
        "Adaptive exposure: brightness=%.1f → gain %.2f→%.2f (ISO %d→%d)",
        brightness, _adaptive_gain, new_gain,
        int(_adaptive_gain * 100), int(new_gain * 100),
    )

    _adaptive_gain = new_gain
    try:
        camera.set_controls({'AnalogueGain': new_gain})
    except Exception as e:
        logger.warning("Failed to apply adaptive gain: %s", e)


def _adapt_exposure_background(camera, filepath, settings):
    """適応型露出をバックグラウンドスレッドで実行"""
    try:
        _adapt_exposure(camera, filepath, settings)
    except Exception as e:
        logger.debug("Adaptive exposure background error: %s", e)


def save_request_to_file(request, filepath, settings, profile):
    """キャプチャリクエストをファイルに保存。リクエストのreleaseは呼び出し元が行う。"""
    raw_mode = settings.get('raw_mode', False)
    if raw_mode:
        try:
            request.save_dng(filepath)
        except Exception as dng_err:
            logger.warning("DNG save failed (%s), falling back to JPEG", dng_err)
            filepath = filepath.replace('.dng', '.jpg')
            request.save("main", filepath)
    else:
        request.save("main", filepath)
    return filepath


def capture_photo(camera, settings: dict, profile: dict, detected_at: float = None, request=None) -> dict:
    """撮影して保存。requestが渡された場合はそのフレームを保存（光検知と同一フレーム）。"""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    raw_mode = settings.get('raw_mode', False)

    if raw_mode:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.dng')
    else:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.jpg')

    try:
        quality = profile.get('quality', settings.get('quality', 90))
        camera.options["quality"] = quality
        capture_start = time.time()

        if request is not None:
            # 光検知と同一フレームを保存（遅延ゼロ）
            filepath = save_request_to_file(request, filepath, settings, profile)
        else:
            # 旧コード方式: capture_file → switch_mode_and_capture_fileフォールバック
            if raw_mode:
                try:
                    camera.capture_file(filepath, format='dng')
                except Exception as dng_err:
                    try:
                        camera.switch_mode_and_capture_file(
                            camera.still_configuration, filepath, format='dng')
                    except Exception as dng_err2:
                        logger.warning("DNG capture failed (%s / %s), falling back to JPEG", dng_err, dng_err2)
                        filepath = filepath.replace('.dng', '.jpg')
                        camera.options["quality"] = quality
                        camera.capture_file(filepath)
            else:
                try:
                    camera.capture_file(filepath)
                except Exception:
                    camera.switch_mode_and_capture_file(
                        camera.still_configuration, filepath)

        camera_done = time.time()
        camera_ms = round((camera_done - capture_start) * 1000.0, 1)

        # WiFi AP安定化（モード別: reactionは0ms、batteryは150ms）
        wifi_sleep_s = profile.get('wifi_sleep', 0.15)
        if wifi_sleep_s > 0:
            time.sleep(wifi_sleep_s)

        capture_end = time.time()
        delay_ms = None
        if detected_at is not None:
            delay_ms = round((capture_end - detected_at) * 1000.0, 1)

        logger.info(
            "Captured: %s (cam=%.0fms wifi=%.0fms total=%sms q=%d)",
            os.path.basename(filepath),
            camera_ms,
            wifi_sleep_s * 1000,
            f"{delay_ms}" if delay_ms else "N/A",
            quality,
        )
        _record_capture()

        # 適応型露出: バックグラウンドで実行（撮影パスをブロックしない）
        threading.Thread(
            target=_adapt_exposure_background,
            args=(camera, filepath, settings),
            daemon=True,
        ).start()

        return {
            'success': True,
            'filepath': filepath,
            'delay_ms': delay_ms,
            'camera_ms': camera_ms,
            'wifi_sleep_ms': round(wifi_sleep_s * 1000.0, 1),
        }

    except Exception as e:
        logger.error(f"Capture failed: {e}")
        return {'success': False, 'filepath': filepath, 'delay_ms': None}


def main():
    # WiFi AP安定化: camera_serviceのCPU優先度を下げる
    # 撮影時のCPUスパイクでWiFiビーコンフレームが送出できなくなりiOSが切断される問題の対策
    try:
        os.nice(10)
        logger.info("Process priority lowered (nice=10) for WiFi stability")
    except OSError as e:
        logger.warning(f"Failed to set nice level: {e}")

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
    _camera_retry_delay = 10.0  # カメラ未検出時のリトライ間隔（指数バックオフ、最大120秒）

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
        'last_camera_ms': None,
        'last_wifi_sleep_ms': None,
        'max_per_minute': _active_max_per_minute,
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

                        try:
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
                            _camera_retry_delay = 10.0  # リセット
                            logger.info(
                                "Camera started: mode=%s, main=%s, lores=%s, cooldown=%.1fs",
                                camera_mode, desired_size, desired_lores, capture_cooldown,
                            )
                        except RuntimeError as cam_err:
                            # カメラ未検出: クラッシュせず指数バックオフでリトライ
                            logger.warning(
                                "Camera not available (%s). Retrying in %.0fs...",
                                cam_err, _camera_retry_delay,
                            )
                            sensor_state['state'] = 'camera_unavailable'
                            sensor_state['last_error'] = str(cam_err)
                            write_sensor_status(sensor_state)
                            last_sensor_status_write = current_time
                            time.sleep(_camera_retry_delay)
                            _camera_retry_delay = min(_camera_retry_delay * 2, 120.0)
                            last_settings_load = 0  # 次ループで即リトライ
                            continue

                    # カメラ制御は設定リロードごとに再適用（設定変更を確実に反映）
                    if camera is not None:
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

            # --- 光検知ループ（同一フレーム撮影方式） ---
            # capture_request() で取得したフレームで明るさを判定し、
            # トリガ時はそのフレームをそのまま保存。
            # 「検知→新フレーム待ち」の遅延を完全に除去する。
            request = None
            try:
                request = camera.capture_request()
                brightness, lux, ae_gain, ae_exposure_us = get_sensor_sample_from_request(request)

                if last_brightness is None:
                    last_brightness = brightness
                    request.release()
                    request = None
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
                    request.release()
                    request = None
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
                        request.release()
                        request = None
                        time.sleep(check_interval)
                        continue

                    logger.info(
                        "Light detected: lux=%.2f, change=%.1f%%, thr=%d",
                        brightness, change_percent, threshold,
                    )
                    detected_at = time.time()
                    sensor_state['last_detected_at'] = datetime.now().isoformat()

                    # 同一フレームを保存（検知フレーム = 撮影フレーム）
                    result = capture_photo(
                        camera, settings, active_profile,
                        detected_at=detected_at, request=request)
                    request.release()
                    request = None
                    if result['success']:
                        last_capture_time = time.time()
                        sensor_state['last_capture_at'] = datetime.now().isoformat()
                        sensor_state['last_detect_to_capture_ms'] = result.get('delay_ms')
                        sensor_state['last_camera_ms'] = result.get('camera_ms')
                        sensor_state['last_wifi_sleep_ms'] = result.get('wifi_sleep_ms')

            except Exception as e:
                logger.error(f"Detection error: {e}")
                sensor_state['last_error'] = str(e)
            finally:
                if request is not None:
                    try:
                        request.release()
                    except Exception:
                        pass

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
