#!/usr/bin/env python3
"""
省電力カメラサービス
光検知時のみカメラを起動して撮影
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
BRIGHTNESS_THRESHOLD = 30
CHECK_INTERVAL = 0.25  # 250ms間隔でチェック（旧版の挙動に合わせる）
CAPTURE_COOLDOWN = 0.25  # 最短撮影間隔
SETTINGS_RELOAD_INTERVAL = 5.0
MIN_CHANGE_AMOUNT = 5

DEFAULT_SETTINGS = {
    'brightness_threshold': 30,
    'iso': 'auto',
    'shutter_speed': 'auto',
    'white_balance': 'auto',
    'enable_multiple_exposure': False,
    'enable_2in1_composition': False,
    'enable_timestamp': False,
    'monitoring_enabled': True,
    'quality': 90,
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

def load_settings() -> dict:
    settings = DEFAULT_SETTINGS.copy()
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r', encoding='utf-8') as f:
                settings.update(json.load(f))
    except Exception as e:
        logger.warning(f"Failed to load settings: {e}")
    return settings

def _add_timestamp(image: Image.Image, timestamp: str) -> Image.Image:
    if ImageDraw is None:
        return image

    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", 40)
    except Exception:
        font = ImageFont.load_default()

    text_x = 10
    text_y = image.height - 60
    draw.text((text_x + 2, text_y + 2), timestamp, font=font, fill=(0, 0, 0))
    draw.text((text_x, text_y), timestamp, font=font, fill=(255, 255, 255))
    return image

def _apply_camera_controls(camera: Picamera2, settings: dict) -> None:
    controls = {}
    iso_value = settings.get('iso', 'auto')
    shutter_value = settings.get('shutter_speed', 'auto')
    wb_value = settings.get('white_balance', 'auto')

    if iso_value != 'auto':
        try:
            controls['AnalogueGain'] = max(1.0, int(iso_value) / 100.0)
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

    if controls:
        camera.set_controls(controls)

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
        return Image.blend(first, second_resized, 0.5)

    return None

def capture_photo(camera, settings: dict, composition_state: dict, detected_at: Optional[float] = None) -> bool:
    """
    写真を撮影して保存
    """
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.jpg')

    try:
        quality = settings.get('quality', 90)
        capture_start = time.time()
        _apply_camera_controls(camera, settings)
        camera.switch_mode_and_capture_file(camera.still_configuration, filepath, quality=quality)
        capture_end = time.time()
        if detected_at is not None:
            detect_delay = capture_end - detected_at
            logger.info("Detect->Capture delay: %.3fs", detect_delay)
        logger.info("Photo captured: %s (capture=%.3fs)", filepath, capture_end - capture_start)

        if Image is None:
            return True

        composition_enabled = settings.get('enable_multiple_exposure', False) or settings.get('enable_2in1_composition', False)
        if composition_enabled:
            image = Image.open(filepath)
            image.load()

            if composition_state['last_frame'] is None:
                composition_state['last_frame'] = image
                composition_state['last_frame_path'] = filepath
                logger.info("Waiting for second frame for composition")
                return False

            composite = _compose_images(composition_state['last_frame'], image, settings)
            if composite is None:
                return True

            if settings.get('enable_timestamp', False):
                composite = _add_timestamp(composite, timestamp)

            composite_path = os.path.join(PHOTOS_DIR, f'COMPOSITE_{timestamp}.jpg')
            composite.save(composite_path, quality=settings.get('quality', 90))
            logger.info(f"Composite saved: {composite_path}")

            for temp_path in (composition_state['last_frame_path'], filepath):
                if temp_path and os.path.exists(temp_path):
                    os.remove(temp_path)

            composition_state['last_frame'] = None
            composition_state['last_frame_path'] = None
            return True

        if settings.get('enable_timestamp', False) and Image is not None:
            image = Image.open(filepath)
            image.load()
            image = _add_timestamp(image, timestamp)
            image.save(filepath, quality=quality)

        return True
    except Exception as e:
        logger.error(f"Capture failed: {e}")
        return False

def main():
    logger.info("Starting light detection camera service...")
    
    # カメラ初期化（低解像度センサーモード）
    camera = Picamera2()
    
    # 設定：メイン撮影用 + 低解像度センサー用（Zero 2W軽量化）
    config = camera.create_still_configuration(
        main={"size": (1920, 1080)},
        lores={"size": (160, 120)},  # 明るさ検知用（負荷軽減）
    )
    camera.configure(config)
    camera.start()
    
    logger.info("Camera initialized in low-power mode")
    
    last_capture_time = 0
    last_settings_load = 0
    threshold = BRIGHTNESS_THRESHOLD
    settings = DEFAULT_SETTINGS.copy()
    last_brightness = None
    detection_interval = CHECK_INTERVAL
    composition_state = {'last_frame': None, 'last_frame_path': None}
    
    try:
        while True:
            current_time = time.time()
            
            # クールダウン中はスキップ
            if current_time - last_capture_time < CAPTURE_COOLDOWN:
                time.sleep(CHECK_INTERVAL)
                continue
            
            if current_time - last_settings_load > SETTINGS_RELOAD_INTERVAL:
                settings = load_settings()
                threshold = int(settings.get('brightness_threshold', BRIGHTNESS_THRESHOLD))
                detection_interval = float(settings.get('detection_interval', CHECK_INTERVAL))
                last_settings_load = current_time

            if not settings.get('monitoring_enabled', True):
                time.sleep(CHECK_INTERVAL)
                continue

            # 明るさチェック
            try:
                brightness = get_brightness_fast(camera)

                if last_brightness is None:
                    last_brightness = brightness
                    time.sleep(CHECK_INTERVAL)
                    continue

                prev_brightness = last_brightness
                change_amount = brightness - prev_brightness
                last_brightness = brightness

                if change_amount < 0:
                    time.sleep(CHECK_INTERVAL)
                    continue

                if prev_brightness > 0:
                    change_percent = change_amount / prev_brightness * 100
                else:
                    change_percent = change_amount * 100

                if change_percent >= threshold and change_amount >= MIN_CHANGE_AMOUNT:
                    if current_time - last_capture_time >= detection_interval:
                        logger.info(
                            "Light change detected: %.2f (threshold=%d, change=%.2f%%)",
                            brightness,
                            threshold,
                            change_percent,
                        )
                        if capture_photo(camera, settings, composition_state, detected_at=current_time):
                            last_capture_time = current_time
            
            except Exception as e:
                logger.error(f"Detection error: {e}")
            
            time.sleep(CHECK_INTERVAL)
            
    except KeyboardInterrupt:
        logger.info("Service stopped by user")
    finally:
        camera.stop()
        camera.close()

if __name__ == '__main__':
    main()
