import os
import time
import json
import logging
from PIL import Image, ImageStat
import numpy as np
import subprocess

# Picamera2のインポート (Raspberry Pi環境のみ)
try:
    from picamzero import Picamera2
except ImportError:
    try:
        from picamera2 import Picamera2
    except ImportError:
        Picamera2 = None

logger = logging.getLogger(__name__)

# 設定ファイルのパス
SETTINGS_FILE = '/home/pi/camera_settings.json'

class LightDetector:
    '''
    光量変化を検知し、自動撮影をトリガーするロジックを管理
    Picamera2を使用して常時接続・ストリーミングを行うことで、
    起動オーバーヘッドを排除し、高速な検知を実現する。
    '''
    
    def __init__(self):
        self.monitoring_enabled = True
        self.detection_threshold = 30 # 輝度変化の閾値 (%)
        self.detection_interval = 0.1 # 検知間隔 (秒) - ストリーミングなので高速化
        self.last_brightness = None
        self.last_capture_time = 0
        self.picam2 = None
        self.camera_config = None
        
        self.load_settings()
        
        # Picamera2の初期化
        if Picamera2:
            self._initialize_picamera()
        else:
            logger.warning("Picamera2 library not found. Falling back to libcamera-still (slow).")

    def _initialize_picamera(self):
        '''Picamera2を初期化してストリームを開始する'''
        try:
            if self.picam2 is not None:
                self.release_camera()
                
            self.picam2 = Picamera2()
            # 撮影兼用の解像度（1280x720）でストリームを開始
            # モード切替なしで即座に保存可能
            self.camera_config = self.picam2.create_preview_configuration(
                main={"size": (1280, 720), "format": "RGB888"}
            )
            self.picam2.configure(self.camera_config)
            self.picam2.start()
            logger.info("Picamera2 initialized and started.")
            # 露出安定化のための待機
            time.sleep(2.0)
            return True
        except Exception as e:
            logger.error(f"Failed to initialize Picamera2: {e}")
            import traceback
            logger.error(traceback.format_exc())
            self.picam2 = None
            return False

    def __del__(self):
        self.release_camera()

    def load_settings(self):
        '''設定ファイルから最新の設定を読み込む'''
        try:
            if os.path.exists(SETTINGS_FILE):
                with open(SETTINGS_FILE, 'r') as f:
                    settings = json.load(f)
                
                # 設定の更新
                self.detection_threshold = settings.get('detection_threshold', 30)
                self.detection_interval = settings.get('detection_interval', 0.1) # デフォルトを高速化
                self.monitoring_enabled = settings.get('monitoring_enabled', True)
                
        except Exception as e:
            logger.error(f"Failed to load detector settings: {e}")

    def open_camera(self):
        '''カメラリソースを確保してストリームを開始する'''
        # Picamera2オブジェクトがない、または停止している場合は再初期化
        if Picamera2:
            if self.picam2 is None:
                return self._initialize_picamera()
            else:
                try:
                    self.picam2.start()
                    logger.info("Picamera2 stream started.")
                    time.sleep(1.0)
                    return True
                except Exception as e:
                    # 既に動作中などの場合
                    logger.debug(f"Picamera2 start info: {e}")
                    return True
        return False

    def release_camera(self):
        '''カメラリソースを完全に解放する（高画質撮影の前など）'''
        if self.picam2:
            try:
                self.picam2.stop()
                self.picam2.close() # デバイスを閉じる
                logger.info("Picamera2 stream stopped and closed.")
            except Exception as e:
                logger.error(f"Failed to stop/close Picamera2: {e}")
            finally:
                self.picam2 = None # オブジェクトを破棄して確実に解放

    def capture_frame(self):
        '''
        カメラからフレームを取得する
        Picamera2がある場合はメモリアレイとして取得 (超高速)
        ない場合は従来のlibcamera-still (低速)
        '''
        if self.picam2:
            try:
                # NumPy配列として画像を取得 (XRGB8888 -> RGB変換が必要かもだが、輝度計算だけならそのまま使える)
                # capture_arrayはデフォルトでメインストリームから取得
                frame = self.picam2.capture_array()
                
                # PIL Imageに変換 (計算ロジックの互換性維持のため)
                # XRGB配列は (H, W, 4) なので、RGB (H, W, 3) に変換するか、そのまま扱う
                # PIL.Image.fromarray は numpy array を受け取れる
                # XRGBの場合、アルファチャンネル(またはパディング)が含まれるため、RGBに変換
                if frame.shape[2] == 4:
                    frame = frame[:, :, :3] # 最初の3チャンネル(RGB)を取り出す（BGRの可能性もあるが輝度変化検知なら許容範囲）
                    # Picamera2のXRGBは通常BGR順のことが多いが、輝度変化を見るだけなら色は問わない
                
                image = Image.fromarray(frame)
                return image
            except Exception as e:
                logger.error(f"Picamera2 capture failed: {e}")
                return None
        
        # --- 以下、Picamera2がない場合のフォールバック (従来のlibcamera-still) ---
        temp_file = '/tmp/detection.jpg'
        
        try:
            cmd = [
                'libcamera-still',
                '-o', temp_file,
                '--width', '320',
                '--height', '240',
                '--timeout', '1000',  # タイムアウトを少し延ばす (200msだと失敗する可能性)
                '--nopreview',
                '--awb', 'auto'
            ]
            
            if os.path.exists(temp_file):
                os.remove(temp_file)
                
            subprocess.run(cmd, capture_output=True, check=True)
            
            if not os.path.exists(temp_file):
                return None
                
            try:
                frame = Image.open(temp_file)
                frame.load()
                return frame
            except Exception:
                return None
            
        except Exception:
            return None

    def calculate_brightness(self, frame):
        '''
        フレームの平均輝度を計算する
        '''
        # グレースケールに変換
        gray = frame.convert('L')
        # 平均輝度を計算
        stat = ImageStat.Stat(gray)
        brightness = stat.mean[0]
        return brightness

    def detect_light_change(self, current_brightness):
        '''
        前回の輝度と比較し、設定された閾値を超えたか検知する
        ノイズフィルター：変化率に加えて絶対的な変化量もチェック
        フィルムカメラ対応：明るくなる変化のみ検知（暗くなる変化は無視）
        '''
        if self.last_brightness is None:
            self.last_brightness = current_brightness
            return False

        # 変化量（正の値：明るくなった、負の値：暗くなった）
        change_amount = current_brightness - self.last_brightness
        
        # 暗くなる変化は無視（フィルムカメラのシャッターが閉じるとき）
        if change_amount < 0:
            self.last_brightness = current_brightness
            return False
        
        # 輝度変化率を計算（明るくなる方向のみ）
        if self.last_brightness > 0:
            change_percent = change_amount / self.last_brightness * 100
        else:
            change_percent = change_amount * 100 

        logger.debug(f"Brightness: {current_brightness:.2f}, Last: {self.last_brightness:.2f}, Change: +{change_percent:.2f}% (+{change_amount:.2f}), Threshold: {self.detection_threshold}%")

        # 変化率が閾値以上 かつ 変化量が5以上の場合のみ検知
        # 変化量5：暗闇でのノイズ（±1以下）と実際のシャッター開放（5以上）を区別
        if change_percent >= self.detection_threshold and change_amount >= 5:
            self.last_brightness = current_brightness
            return True
        
        self.last_brightness = current_brightness
        return False

    def should_capture(self):
        '''
        次の撮影まで十分な時間が経過したかチェックする
        '''
        return (time.time() - self.last_capture_time) >= self.detection_interval

    def update_capture_time(self):
        '''
        最後に撮影を試みた時間を更新する
        '''
        self.last_capture_time = time.time()

    def get_status(self):
        '''
        現在の検知器の状態を返す
        '''
        return {
            'monitoring_enabled': self.monitoring_enabled,
            'detection_threshold': self.detection_threshold,
            'detection_interval': self.detection_interval,
            'last_brightness': self.last_brightness,
            'last_capture_time': self.last_capture_time
        }