#!/usr/bin/env python3
"""
省電力カメラサービス
光検知時のみカメラを起動して撮影
"""

import os
import time
import logging
from datetime import datetime
from picamera2 import Picamera2
import numpy as np

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

PHOTOS_DIR = '/home/pi/photos'
BRIGHTNESS_THRESHOLD = 30
CHECK_INTERVAL = 0.1  # 100ms間隔でチェック
CAPTURE_COOLDOWN = 2.0  # 撮影後2秒はクールダウン

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

def capture_photo(camera):
    """
    写真を撮影して保存
    """
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    filepath = os.path.join(PHOTOS_DIR, f'photo_{timestamp}.jpg')
    
    try:
        camera.switch_mode_and_capture_file(camera.still_configuration, filepath)
        logger.info(f"Photo captured: {filepath}")
        return True
    except Exception as e:
        logger.error(f"Capture failed: {e}")
        return False

def main():
    logger.info("Starting light detection camera service...")
    
    # カメラ初期化（低解像度センサーモード）
    camera = Picamera2()
    
    # 設定：メイン撮影用 + 低解像度センサー用
    config = camera.create_still_configuration(
        main={"size": (1920, 1080)},
        lores={"size": (320, 240)},  # 明るさ検知用
    )
    camera.configure(config)
    camera.start()
    
    logger.info("Camera initialized in low-power mode")
    
    last_capture_time = 0
    
    try:
        while True:
            current_time = time.time()
            
            # クールダウン中はスキップ
            if current_time - last_capture_time < CAPTURE_COOLDOWN:
                time.sleep(CHECK_INTERVAL)
                continue
            
            # 明るさチェック
            try:
                brightness = get_brightness_fast(camera)
                
                if brightness > BRIGHTNESS_THRESHOLD:
                    logger.info(f"Light detected! Brightness: {brightness:.2f}")
                    if capture_photo(camera):
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
