#!/usr/bin/env python3
"""
Shutter Trigger System for Pi Camera
光量変化検知による自動撮影システム
"""

import os
import sys
import time
import json
import logging
import signal
import subprocess
from datetime import datetime
from light_detection_algorithm import LightDetector
from PIL import Image, ImageDraw, ImageFont, ImageChops
import numpy as np

# ログ設定
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/home/pi/shutter_trigger.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# 環境変数に基づいてモックを使用するかどうかを決定
USE_CAMERA_MOCK = os.getenv('USE_CAMERA_MOCK') == '1'

class ShutterTriggerSystem:
    '''シャッター検知・撮影システム'''
    
    def __init__(self):
        self.detector = LightDetector()
        self.photos_dir = '/home/pi/photos'
        self.settings_file = '/home/pi/camera_settings.json'
        self.running = True
        self.last_frame = None # 合成用フレーム (多重露光/2in1共通) - PIL Image object
        self.last_frame_path = None # 1枚目の画像パス
        
        os.makedirs(self.photos_dir, exist_ok=True)
        
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
        logger.info("Shutter trigger system initialized")
    
    def signal_handler(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
    
    def load_camera_settings(self) -> dict:
        try:
            if os.path.exists(self.settings_file):
                with open(self.settings_file, 'r') as f:
                    return json.load(f)
            else:
                return {
                    'iso': 100,
                    'shutter_speed': 1000000,
                    'width': 1920, # モック用に解像度を調整
                    'height': 1080,
                    'quality': 90,
                    'exposure_mode': 'auto',
                    'enable_multiple_exposure': False,
                    'enable_2in1_composition': False,
                    'enable_timestamp': False
                }
        except Exception as e:
            logger.error(f"Failed to load camera settings: {e}")
            return {}
    
    def _add_timestamp(self, img_pil, timestamp):
        dt_object = datetime.fromtimestamp(timestamp)
        date_text = dt_object.strftime("%Y/%m/%d %H:%M:%S")
        
        draw = ImageDraw.Draw(img_pil)
        
        # フォント設定 (Raspberry Pi環境に存在する可能性が高いフォントを使用)
        try:
            font = ImageFont.truetype("DejaVuSans-Bold.ttf", 50)
        except IOError:
            font = ImageFont.load_default()
        
        # テキストの描画
        text_x = 10
        text_y = img_pil.height - 70
        
        # 影付きの文字を描画 (見やすくするため)
        draw.text((text_x + 2, text_y + 2), date_text, font=font, fill=(0, 0, 0)) # 影
        draw.text((text_x, text_y), date_text, font=font, fill=(255, 255, 255)) # 本体
        
        logger.info("Timestamp added to photo.")
        return img_pil

    def capture_high_quality_photo(self) -> str:
        try:
            settings = self.load_camera_settings()
            
            timestamp = time.time()
            random_id = os.urandom(4).hex().upper()
            
            # 合成モードの場合、一時ファイル名を使用
            is_composition_mode = settings.get('enable_multiple_exposure', False) or settings.get('enable_2in1_composition', False)
            
            if is_composition_mode and self.last_frame is None:
                # 1枚目の画像として保存
                filename = f"Camera_{timestamp}_{random_id}_1st.jpg"
            elif is_composition_mode and self.last_frame is not None:
                # 2枚目の画像として保存
                filename = f"Camera_{timestamp}_{random_id}_2nd.jpg"
            else:
                # 通常撮影
                filename = f"Camera_{timestamp}_{random_id}.jpg"
                
            filepath = os.path.join(self.photos_dir, filename)
            
            # --- 超高速撮影: ストリームからそのまま保存 ---
            picam2 = self.detector.picam2
            
            if picam2 is not None:
                # 現在のストリームからそのまま保存（モード切替なし = 爆速）
                try:
                    # capture_file で現在のフレームを直接JPEGとして保存
                    picam2.capture_file(filepath)
                    logger.info(f"Instant capture completed: {filepath}")
                    
                except Exception as e:
                    logger.error(f"Picamera2 fast capture failed: {e}")
                    return None
            else:
                # フォールバック: libcamera-still（遅い）
                logger.warning("Picamera2 not available, using slow libcamera-still")
                cmd = [
                    'libcamera-still',
                    '-o', filepath,
                    '--width', str(settings.get('width', 1640)),
                    '--height', str(settings.get('height', 1232)),
                    '--quality', str(settings.get('quality', 85)),
                    '--timeout', '500',  # 高速化: タイムアウト短縮
                    '--nopreview',
                    '--immediate'  # 即座に撮影
                ]
                
                # AWB設定
                cmd.extend(['--awb', settings.get('white_balance', 'auto')])
                
                self.detector.release_camera()
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True)
                finally:
                    self.detector.open_camera()
                
                if result.returncode != 0:
                    logger.error(f"libcamera-still failed: {result.stderr}")
                    return None
            
            # 撮影した画像を読み込み (PIL)
            try:
                frame = Image.open(filepath)
                frame.load() # メモリに読み込む
            except Exception as e:
                logger.error(f"Failed to read captured image with PIL: {e}")
                return None
            
            if frame is None:
                logger.error("Captured image is empty.")
                return None
            
            # --- 画像処理と保存 ---
            
            if is_composition_mode:
                if self.last_frame is None:
                    # 1枚目の画像
                    # 合成モード時は中間ファイルにタイムスタンプを入れない
                    # ファイルは既にlibcamera-stillで保存されている
                    
                    self.last_frame = frame
                    self.last_frame_path = filepath
                    logger.info(f"First frame for composition saved: {filepath}")
                    return None
                
                else:
                    # 2枚目の画像
                    # 合成処理
                    try:
                        img1 = self.last_frame
                        img2 = frame
                        
                        composite_img = None
                        
                        if settings.get('enable_2in1_composition', False):
                            # 2in1: 横に並べる
                            # 高さ合わせ
                            w1, h1 = img1.size
                            w2, h2 = img2.size
                            target_h = min(h1, h2)
                            
                            img1_resized = img1.resize((int(w1 * target_h / h1), target_h))
                            img2_resized = img2.resize((int(w2 * target_h / h2), target_h))
                            
                            composite_img = Image.new('RGB', (img1_resized.width + img2_resized.width, target_h))
                            composite_img.paste(img1_resized, (0, 0))
                            composite_img.paste(img2_resized, (img1_resized.width, 0))
                            
                        elif settings.get('enable_multiple_exposure', False):
                            # 多重露光: ブレンド
                            # 2枚目を1枚目のサイズに合わせる
                            img2_resized = img2.resize(img1.size)
                            composite_img = Image.blend(img1, img2_resized, 0.5)
                        
                        if composite_img is not None:
                            # タイムスタンプ付与 (合成後の画像に)
                            if settings.get('enable_timestamp', False):
                                composite_img = self._add_timestamp(composite_img, timestamp)
                            
                            # 保存
                            base_name = os.path.basename(self.last_frame_path).replace('_1st.jpg', '')
                            result_filename = f"COMPOSITE_{base_name}.jpg"
                            result_path = os.path.join(self.photos_dir, result_filename)
                            
                            composite_img.save(result_path, quality=settings.get('quality', 95))
                            logger.info(f"Composite photo saved: {result_filename}")
                            
                            # 中間ファイルの削除
                            try:
                                if os.path.exists(self.last_frame_path):
                                    os.remove(self.last_frame_path)
                                # 2枚目のファイルも削除 (filepath)
                                if os.path.exists(filepath):
                                    os.remove(filepath)
                            except Exception as e:
                                logger.warning(f"Failed to remove temp file: {e}")
                            
                            # 状態リセット
                            self.last_frame = None
                            self.last_frame_path = None
                            
                            return result_filename
                            
                    except Exception as e:
                        logger.error(f"Composition error: {e}")
                        self.last_frame = None
                        self.last_frame_path = None
                        return None
            
            else:
                # 通常撮影
                self.last_frame = None
                self.last_frame_path = None
                
                # タイムスタンプ付与
                if settings.get('enable_timestamp', False):
                    frame = self._add_timestamp(frame, timestamp)
                    # 上書き保存
                    frame.save(filepath, quality=settings.get('quality', 95))
                    
                if USE_CAMERA_MOCK or os.path.exists(filepath):
                    file_size = os.path.getsize(filepath) if not USE_CAMERA_MOCK else 0
                    logger.info(f"Photo captured successfully: {filename} ({file_size} bytes)")
                    return filename
                else:
                    logger.error("Photo file not created.")
                    return None
                
        except Exception as e:
            logger.error(f"Photo capture error: {e}")
            self.last_frame = None # エラー時はリセット
            return None
    
    def cleanup_old_photos(self, max_photos: int = 1000):
        try:
            if not os.path.exists(self.photos_dir):
                return
            
            photos = []
            for filename in os.listdir(self.photos_dir):
                if filename.lower().endswith(('.jpg', '.jpeg', '.png', '.txt')):
                    filepath = os.path.join(self.photos_dir, filename)
                    mtime = os.path.getmtime(filepath)
                    photos.append((mtime, filepath, filename))
            
            photos.sort()
            
            if len(photos) > max_photos:
                to_delete = photos[:-max_photos]
                for mtime, filepath, filename in to_delete:
                    try:
                        os.remove(filepath)
                        logger.info(f"Deleted old photo: {filename}")
                    except Exception as e:
                        logger.error(f"Failed to delete {filename}: {e}")
                        
        except Exception as e:
            logger.error(f"Photo cleanup error: {e}")
    
    def get_system_stats(self) -> dict:
        try:
            photo_count = 0
            total_size = 0
            if os.path.exists(self.photos_dir):
                for filename in os.listdir(self.photos_dir):
                    if filename.lower().endswith(('.jpg', '.jpeg', '.png', '.txt')):
                        filepath = os.path.join(self.photos_dir, filename)
                        if os.path.exists(filepath):
                            photo_count += 1
                            total_size += os.path.getsize(filepath)
            
            disk_usage = subprocess.run(['df', '-h', '/home/pi'], 
                                      capture_output=True, text=True)
            
            return {
                'photo_count': photo_count,
                'total_size_mb': total_size / (1024 * 1024),
                'detector_status': self.detector.get_status(),
                'disk_info': disk_usage.stdout if disk_usage.returncode == 0 else 'N/A'
            }
            
        except Exception as e:
            logger.error(f"Stats collection error: {e}")
            return {}
    
    def run(self):
        logger.info("Starting shutter trigger system...")
        
        startup_delay = 0.5
        logger.info(f"Waiting {startup_delay} seconds for system stabilization...")
        time.sleep(startup_delay)
        
        last_cleanup_time = time.time()
        cleanup_interval = 3600
        
        last_stats_time = time.time()
        stats_interval = 300
        
        try:
            while self.running:
                self.detector.load_settings()
                
                if not self.detector.monitoring_enabled:
                    logger.debug("Monitoring disabled, sleeping...")
                    time.sleep(1.0)
                    continue
                
                if not self.detector.should_capture():
                    time.sleep(0.1)
                    continue
                
                frame = self.detector.capture_frame()
                if frame is None:
                    logger.warning("Failed to capture detection frame")
                    time.sleep(1)
                    continue
                
                brightness = self.detector.calculate_brightness(frame)
                light_changed = self.detector.detect_light_change(brightness)
                
                self.detector.update_capture_time()
                
                if light_changed:
                    logger.info("Light change detected, capturing high-quality photo...")
                    filename = self.capture_high_quality_photo()
                    
                    if filename:
                        logger.info(f"Photo saved: {filename}")
                    else:
                        logger.error("Failed to capture photo")
                
                current_time = time.time()
                if current_time - last_cleanup_time > cleanup_interval:
                    self.cleanup_old_photos()
                    last_cleanup_time = current_time
                
                if current_time - last_stats_time > stats_interval:
                    stats = self.get_system_stats()
                    logger.info(f"System stats: {stats['photo_count']} photos, {stats['total_size_mb']:.2f}MB total")
                    last_stats_time = current_time
                
                time.sleep(self.detector.detection_interval)
                
        except Exception as e:
            logger.error(f"Main loop error: {e}")
        finally:
            logger.info("Shutter trigger system stopped")

def main():
    try:
        system = ShutterTriggerSystem()
        system.run()
    except KeyboardInterrupt:
        logger.info("System stopped by user")
    except Exception as e:
        logger.error(f"System error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
