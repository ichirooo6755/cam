#!/usr/bin/env python3
"""
省電力カメラサービス
光検知時のみカメラを起動して撮影

Camera: Raspberry Pi Camera Module HQ (12.3MP)
Sensor: Sony IMX477 (7.9mm diagonal, 1.55μm pixel)
Resolution: 4056x3040 (native), supports up to 4056x3040
ISO Range: 100-16000 (推奨: 100-6400)
Shutter: 13μs - 670s (推奨: 100μs - 1s)
"""

import os
import time
import json
import logging
from typing import Optional
from datetime import datetime
from picamera2 import Picamera2
import numpy as np

try:
    import libcamera
except ImportError:
    libcamera = None

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None
    ImageDraw = None
    ImageFont = None

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
CHECK_INTERVAL = 0.25  # 250ms間隔でチェック（旧版の挙動に合わせる）
CAPTURE_COOLDOWN = 0.25  # 最短撮影間隔
SETTINGS_RELOAD_INTERVAL = 1.0
SENSOR_STATUS_WRITE_INTERVAL = 1.0
MIN_CHANGE_AMOUNT = 5

# カメラモード別のJPEG品質プリセット
QUALITY_PRESETS = {
    'reaction': 70,    # 高速撮影優先
    'quality': 100,    # 最高画質
    'twilight': 95,    # 高画質（夜景・暗所）
    'night': 95,       # 高画質（夜間）
    'standard': 90,    # 標準
    'manual': 90,      # 標準（マニュアル）
    'raw': 100,        # RAWモード時はJPEGも最高画質
    'battery': 80,     # 省電力（品質を抑えてファイルサイズ削減）
}

DEFAULT_SETTINGS = {
    'camera_mode': 'standard',
    'brightness_threshold': 30,
    'detection_interval': CHECK_INTERVAL,
    'check_interval': CHECK_INTERVAL,
    'capture_cooldown': CAPTURE_COOLDOWN,
    'iso': 'auto',
    'shutter_speed': 'auto',
    'white_balance': 'auto',
    'width': 1920,
    'height': 1080,
    'enable_multiple_exposure': False,
    'multiple_exposure_mode': 'blend',  # blend/additive (星の軌跡など長時間露光効果)
    'multiple_exposure_count': 2,  # 多重露光の枚数（2-10）
    'enable_2in1_composition': False,
    'enable_timestamp': False,
    'monitoring_enabled': True,
    'quality': 90,
    'raw_mode': False,  # RAW（DNG）撮影モード
    'denoise_mode': 'auto',  # off/auto/cdn_off/cdn_fast/cdn_hq
    'sharpness': 1.0,  # 0.0-16.0
    'stabilization': True,  # 手ぶれ補正（電子式）
}

os.makedirs(PHOTOS_DIR, exist_ok=True)

def get_brightness_fast(camera):
    """
    低解像度センサーデータから明るさを高速取得
    """
    metadata = camera.capture_metadata()
    if 'Lux' in metadata:
        return metadata['Lux']
    
    # Luxが無い場合は低解像度キャプチャで計算
    array = camera.capture_array("lores")
    if len(array.shape) == 3:
        gray = np.mean(array, axis=2)
    else:
        gray = array
    return np.mean(gray)

def get_sensor_sample(camera):
    metadata = camera.capture_metadata()
    lux = metadata.get('Lux')
    ae_gain = metadata.get('AnalogueGain')
    ae_exposure_us = metadata.get('ExposureTime')

    if lux is not None:
        brightness = float(lux)
    else:
        array = camera.capture_array("lores")
        if len(array.shape) == 3:
            gray = np.mean(array, axis=2)
        else:
            gray = array
        brightness = float(np.mean(gray))

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

    # カメラモードに応じたJPEG品質の自動設定
    camera_mode = settings.get('camera_mode', 'standard')
    if camera_mode in QUALITY_PRESETS:
        # ユーザーが明示的にqualityを設定していない場合のみ自動設定
        # （session_overridesで個別設定されている場合は尊重）
        if 'quality' not in settings or settings['quality'] == DEFAULT_SETTINGS['quality']:
            auto_quality = QUALITY_PRESETS[camera_mode]
            settings['quality'] = auto_quality

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

# 省電力化: タイムスタンプ追加はiPhone側に移行（_add_timestamp は削除済み）

def _apply_camera_controls(camera: Picamera2, settings: dict) -> None:
    controls = {}
    iso_value = settings.get('iso', 'auto')
    shutter_value = settings.get('shutter_speed', 'auto')
    wb_value = settings.get('white_balance', 'auto')

    manual_exposure = iso_value != 'auto' or shutter_value != 'auto'
    controls['AeEnable'] = not manual_exposure

    if iso_value != 'auto':
        try:
            # PiCamera HQ: ISO 100-16000対応（AnalogueGain 1.0-160.0）
            # 推奨範囲: ISO 100-6400 (Gain 1.0-64.0)
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
            if wb_value == 'shade' and wb_map['shade'] == libcamera.controls.AwbModeEnum.Auto:
                logger.warning("AwbModeEnum.Shade not available. Falling back to Auto.")
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

    # シャープネス（0.0-16.0）
    sharpness_value = settings.get('sharpness', 1.0)
    try:
        sharpness_float = float(sharpness_value)
        controls['Sharpness'] = max(0.0, min(16.0, sharpness_float))
    except (ValueError, TypeError):
        pass

    # 手ぶれ補正（VideoStabilisationMode）
    stabilization_enabled = settings.get('stabilization', True)
    if libcamera is not None:
        try:
            if stabilization_enabled:
                controls['VideoStabilisationMode'] = libcamera.controls.draft.VideoStabilisationModeEnum.On
            else:
                controls['VideoStabilisationMode'] = libcamera.controls.draft.VideoStabilisationModeEnum.Off
        except (AttributeError, KeyError):
            # VideoStabilisationModeが利用できない場合はスキップ
            logger.debug("VideoStabilisationMode not available on this platform")

    if controls:
        camera.set_controls(controls)

# 省電力化: 画像合成はiPhone側に移行（Pi側では使用しない）
def _compose_images(first: Image.Image, second: Image.Image, settings: dict) -> Optional[Image.Image]:
    if settings.get('enable_2in1_composition', False):
        w1, h1 = first.size
        w2, h2 = second.size
        target_h = min(h1, h2)
        first_resized = first.resize((int(w1 * target_h / h1), target_h))
        second_resized = second.resize((int(w2 * target_h / h2), target_h))
        composite = Image.new('RGB', (first_resized.width + second_resized.width, target_h))
        composite.paste(first_resized, (0, 0))
        composite.paste(second_resized, (first_resized.width, 0))
        return composite

    if settings.get('enable_multiple_exposure', False):
        second_resized = second.resize(first.size)
        mode = settings.get('multiple_exposure_mode', 'blend')

        if mode == 'additive':
            # 加算合成: 星の軌跡や車のライトトレイル撮影用
            # PILでは直接加算できないのでnumpyで処理
            arr1 = np.array(first, dtype=np.float32)
            arr2 = np.array(second_resized, dtype=np.float32)
            # 加算してクリップ（0-255範囲）
            result_arr = np.clip(arr1 + arr2, 0, 255).astype(np.uint8)
            return Image.fromarray(result_arr)
        else:
            # blend: 通常のブレンド（50:50）
            return Image.blend(first, second_resized, 0.5)

    return None

def capture_photo(camera, settings: dict, composition_state: dict, detected_at: Optional[float] = None) -> bool:
    """
    写真を撮影して保存（画像処理なし・省電力版）

    画像合成・タイムスタンプ追加などはiPhone側で実行。
    Pi側はカメラ制御と撮影のみに特化し、消費電力を最小化。
    """
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    raw_mode = settings.get('raw_mode', False)

    if raw_mode:
        # RAWモード: DNGファイルを保存
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.dng')
    else:
        filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.jpg')

    try:
        # JPEG品質はユーザー設定を尊重（最高画質モード対応）
        quality = settings.get('quality', 90)
        camera.options["quality"] = quality
        capture_start = time.time()
        _apply_camera_controls(camera, settings)

        if raw_mode:
            # RAW撮影: capture_file with format='dng'
            try:
                camera.capture_file(filepath, format='dng')
            except Exception as capture_error:
                logger.warning(f"RAW capture failed, fallback to switch_mode: {capture_error}")
                camera.switch_mode_and_capture_file(camera.still_configuration, filepath, format='dng')
        else:
            # 通常のJPEG撮影
            try:
                camera.capture_file(filepath)
            except Exception as capture_error:
                logger.warning(f"capture_file failed, fallback to switch_mode: {capture_error}")
                camera.switch_mode_and_capture_file(camera.still_configuration, filepath)

        capture_end = time.time()
        if detected_at is not None:
            detect_delay = capture_end - detected_at
            composition_state['last_detect_to_capture_ms'] = round(detect_delay * 1000.0, 1)
            logger.info("Detect->Capture delay: %.3fs", detect_delay)
        logger.info("Photo captured: %s (capture=%.3fs)", filepath, capture_end - capture_start)

        # 多重露光・コンポジション対応: 複数枚撮影して個別保存
        # 合成はiPhone側で実行
        composition_enabled = settings.get('enable_multiple_exposure', False) or settings.get('enable_2in1_composition', False)
        if composition_enabled:
            if composition_state['last_frame_path'] is None:
                composition_state['last_frame_path'] = filepath
                composition_state['frame_count'] = 1
                logger.info("Multi-exposure: First frame saved. Waiting for second frame...")
                return False  # まだ完了していない
            else:
                composition_state['frame_count'] = composition_state.get('frame_count', 1) + 1
                max_frames = settings.get('multiple_exposure_count', 2)

                if composition_state['frame_count'] >= max_frames:
                    logger.info(f"Multi-exposure: All {max_frames} frames captured. Ready for iPhone-side composition.")
                    composition_state['last_frame_path'] = None
                    composition_state['frame_count'] = 0
                    return True
                else:
                    logger.info(f"Multi-exposure: Frame {composition_state['frame_count']}/{max_frames} saved.")
                    return False

        return True
    except Exception as e:
        logger.error(f"Capture failed: {e}")
        return False

def main():
    logger.info("Starting light detection camera service...")

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
    capture_cooldown = CAPTURE_COOLDOWN
    composition_state = {
        'last_frame_path': None,
        'frame_count': 0,
        'last_detect_to_capture_ms': None,
    }
    sensor_state = {
        'service': 'camera-service',
        'camera_mode': settings.get('camera_mode', 'standard'),
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
            
            if current_time - last_settings_load > SETTINGS_RELOAD_INTERVAL:
                settings = load_settings()
                threshold = int(settings.get('brightness_threshold', BRIGHTNESS_THRESHOLD))
                detection_interval = float(settings.get('detection_interval', CHECK_INTERVAL))
                try:
                    check_interval = float(settings.get('check_interval', CHECK_INTERVAL))
                except (TypeError, ValueError):
                    check_interval = CHECK_INTERVAL
                if check_interval <= 0:
                    check_interval = CHECK_INTERVAL

                try:
                    capture_cooldown = float(settings.get('capture_cooldown', CAPTURE_COOLDOWN))
                except (TypeError, ValueError):
                    capture_cooldown = CAPTURE_COOLDOWN
                if capture_cooldown < 0:
                    capture_cooldown = 0

                monitoring_enabled = bool(settings.get('monitoring_enabled', True))
                try:
                    width = int(settings.get('width', 1920))
                    height = int(settings.get('height', 1080))
                    if width <= 0 or height <= 0:
                        raise ValueError('invalid size')
                except Exception:
                    width = 1920
                    height = 1080

                desired_size = (width, height)
                sensor_state['camera_mode'] = settings.get('camera_mode', 'standard')
                sensor_state['monitoring_enabled'] = monitoring_enabled
                sensor_state['threshold_percent'] = threshold
                sensor_state['detection_interval'] = detection_interval
                sensor_state['check_interval'] = check_interval
                sensor_state['capture_cooldown'] = capture_cooldown
                sensor_state['width'] = width
                sensor_state['height'] = height

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
                        composition_state = {
                            'last_frame': None,
                            'last_frame_path': None,
                            'last_detect_to_capture_ms': None,
                        }
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
                        camera_mode = str(settings.get('camera_mode', 'standard') or 'standard').strip().lower()
                        # PiCamera HQ: loresサイズを大きめに（HQセンサーの特性）
                        lores_size = (128, 96) if camera_mode == 'reaction' else (320, 240)
                        config = cam.create_still_configuration(
                            main={"size": desired_size},
                            lores={"size": lores_size},
                        )
                        cam.configure(config)
                        cam.start()
                        camera = cam
                        current_main_size = desired_size
                        last_brightness = None
                        composition_state = {
                            'last_frame': None,
                            'last_frame_path': None,
                            'last_detect_to_capture_ms': None,
                        }

                last_settings_load = current_time

            if not settings.get('monitoring_enabled', True):
                sensor_state['state'] = 'monitoring_disabled'
                time.sleep(check_interval)
                if current_time - last_sensor_status_write >= SENSOR_STATUS_WRITE_INTERVAL:
                    write_sensor_status(sensor_state)
                    last_sensor_status_write = current_time
                continue

            if camera is None:
                sensor_state['state'] = 'camera_unavailable'
                time.sleep(check_interval)
                if current_time - last_sensor_status_write >= SENSOR_STATUS_WRITE_INTERVAL:
                    write_sensor_status(sensor_state)
                    last_sensor_status_write = current_time
                continue

            # 明るさチェック
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

                if change_percent >= threshold and change_amount >= MIN_CHANGE_AMOUNT:
                    if current_time - last_capture_time >= detection_interval:
                        logger.info(
                            "Light change detected: %.2f (threshold=%d, change=%.2f%%)",
                            brightness,
                            threshold,
                            change_percent,
                        )
                        detected_at = time.time()
                        sensor_state['last_detected_at'] = datetime.now().isoformat()
                        if capture_photo(camera, settings, composition_state, detected_at=detected_at):
                            last_capture_time = time.time()
                            sensor_state['last_capture_at'] = datetime.now().isoformat()
                            sensor_state['last_detect_to_capture_ms'] = composition_state.get('last_detect_to_capture_ms')

            except Exception as e:
                logger.error(f"Detection error: {e}")
                sensor_state['last_error'] = str(e)

            # 省電力: センサーステータスは変更時のみ書き込み
            if current_time - last_sensor_status_write >= SENSOR_STATUS_WRITE_INTERVAL:
                # 前回と異なる場合のみ書き込み
                if sensor_state != getattr(write_sensor_status, '_last_state', None):
                    write_sensor_status(sensor_state)
                    write_sensor_status._last_state = sensor_state.copy()
                last_sensor_status_write = current_time

            time.sleep(check_interval)
            
    except KeyboardInterrupt:
        logger.info("Service stopped by user")
    finally:
        sensor_state['state'] = 'stopped'
        sensor_state['monitoring_enabled'] = False
        write_sensor_status(sensor_state)
        if camera is not None:
            camera.stop()
            camera.close()

def apply_focus_peaking(camera, color: str = 'red', threshold: int = 30) -> bytes:
    """
    フォーカスピーキング: エッジ検出して色オーバーレイ

    Args:
        camera: Picamera2インスタンス
        color: ピーキング色 ('red', 'green', 'blue', 'yellow')
        threshold: エッジ検出閾値（0-255、デフォルト30）

    Returns:
        JPEG画像データ（bytes）
    """
    try:
        # 低解像度でキャプチャ（プレビュー用）
        array = camera.capture_array("main")

        if array is None or len(array.shape) < 2:
            logger.warning("Failed to capture array for focus peaking")
            return b''

        # グレースケール化
        if len(array.shape) == 3:
            gray = np.mean(array, axis=2).astype(np.uint8)
        else:
            gray = array.astype(np.uint8)

        # Sobelエッジ検出
        from scipy import ndimage
        sobel_x = ndimage.sobel(gray, axis=1)
        sobel_y = ndimage.sobel(gray, axis=0)
        edges = np.hypot(sobel_x, sobel_y)

        # 正規化とthreshold適用
        edges = (edges / edges.max() * 255).astype(np.uint8)
        edge_mask = edges > threshold

        # 元画像をRGBに変換
        if len(array.shape) == 2:
            rgb_image = np.stack([array, array, array], axis=-1)
        else:
            rgb_image = array.copy()

        # 色オーバーレイ
        color_map = {
            'red': (255, 0, 0),
            'green': (0, 255, 0),
            'blue': (0, 0, 255),
            'yellow': (255, 255, 0)
        }
        overlay_color = color_map.get(color, (255, 0, 0))

        # エッジ部分に色を適用
        for i in range(3):
            rgb_image[:, :, i] = np.where(edge_mask, overlay_color[i], rgb_image[:, :, i])

        # JPEGエンコード
        if Image is not None:
            img = Image.fromarray(rgb_image.astype(np.uint8))
            import io
            buffer = io.BytesIO()
            img.save(buffer, format='JPEG', quality=85)
            return buffer.getvalue()
        else:
            logger.warning("PIL not available, cannot encode focus peaking image")
            return b''

    except Exception as e:
        logger.error(f"Focus peaking error: {e}")
        return b''

if __name__ == '__main__':
    main()
