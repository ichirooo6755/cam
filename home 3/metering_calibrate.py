#!/usr/bin/env python3
"""測光キャリブレーション: AE収束を待ってから複数枚撮影し、適正露出を計測する。
api_server.py から subprocess で呼び出される。
"""
import json
import time
import sys
import os

PHOTOS_DIR = '/home/pi/photos'

def main():
    from picamera2 import Picamera2

    settle_sec = 3
    capture_sec = 3
    width = 1920
    height = 1080

    # コマンドライン引数でパラメータ上書き
    for arg in sys.argv[1:]:
        if arg.startswith('--settle='):
            settle_sec = int(arg.split('=', 1)[1])
        elif arg.startswith('--capture='):
            capture_sec = int(arg.split('=', 1)[1])
        elif arg.startswith('--width='):
            width = int(arg.split('=', 1)[1])
        elif arg.startswith('--height='):
            height = int(arg.split('=', 1)[1])

    os.makedirs(PHOTOS_DIR, exist_ok=True)

    cam = Picamera2()
    config = cam.create_still_configuration(
        main={"size": (width, height)},
    )
    cam.configure(config)
    cam.start()

    # AE収束待機
    time.sleep(settle_sec)

    # AE収束後のメタデータ取得
    pre_meta = cam.capture_metadata()

    results = []
    # capture_sec 内に複数サンプル（短い計測でも最低2枚程度を狙う）
    capture_interval = min(2.5, max(0.7, capture_sec / 3.0))
    num_captures = max(1, int(capture_sec / capture_interval))
    for i in range(num_captures):
        meta = cam.capture_metadata()
        filename = f"metering_{time.time():.6f}.jpg"
        filepath = os.path.join(PHOTOS_DIR, filename)

        cam.options["quality"] = 90
        cam.capture_file(filepath)

        file_size = os.path.getsize(filepath) if os.path.exists(filepath) else 0
        results.append({
            'filename': filename,
            'index': i,
            'ae_gain': meta.get('AnalogueGain'),
            'ae_exposure_us': meta.get('ExposureTime'),
            'lux': meta.get('Lux'),
            'colour_temperature': meta.get('ColourTemperature'),
            'file_size': file_size,
        })

        if i < num_captures - 1:
            time.sleep(capture_interval)

    cam.stop()
    cam.close()

    # 最後の数枚から平均を計算（AEが最も収束している）
    stable_results = results[-3:] if len(results) >= 3 else results
    gains = [r['ae_gain'] for r in stable_results if r['ae_gain'] is not None]
    exposures = [r['ae_exposure_us'] for r in stable_results if r['ae_exposure_us'] is not None]
    lux_values = [r['lux'] for r in stable_results if r['lux'] is not None]

    avg_gain = sum(gains) / len(gains) if gains else None
    avg_exposure = sum(exposures) / len(exposures) if exposures else None
    avg_lux = sum(lux_values) / len(lux_values) if lux_values else None

    # ISO停留所に丸める
    ISO_STOPS = [100, 200, 400, 800, 1600, 3200]
    recommended_iso = None
    if avg_gain is not None:
        raw_iso = int(round(avg_gain * 100))
        recommended_iso = min(ISO_STOPS, key=lambda s: abs(s - raw_iso))

    output = {
        'success': True,
        'settle_seconds': settle_sec,
        'capture_seconds': capture_sec,
        'photos': results,
        'pre_settle_meta': {
            'ae_gain': pre_meta.get('AnalogueGain'),
            'ae_exposure_us': pre_meta.get('ExposureTime'),
            'lux': pre_meta.get('Lux'),
        },
        'recommendation': {
            'avg_gain': round(avg_gain, 3) if avg_gain else None,
            'avg_exposure_us': int(round(avg_exposure)) if avg_exposure else None,
            'avg_lux': round(avg_lux, 2) if avg_lux else None,
            'recommended_iso': recommended_iso,
            'recommended_shutter_us': int(round(avg_exposure)) if avg_exposure else None,
        },
    }
    print(json.dumps(output))


if __name__ == '__main__':
    main()
