# CLAUDE.md

## 基本方針
日本語応対。調査はサブエージェント活用。

## ハードウェア
**Camera**: Raspberry Pi Camera Module HQ (12.3MP)
**Sensor**: Sony IMX477 (7.9mm diagonal, 1.55μm pixel)
**Resolution**: 4056x3040 native
**ISO**: 100-16000 (推奨100-6400)
**Shutter**: 13μs-670s

## アーキテクチャ
iOS(SwiftUI)→HTTP:8001→Pi(Python)。Pi側: `api_server.py`(HTTP), `camera_service.py`(PiCamera2), `wifi_manager.py`(AP/tethering)。IPC: JSON files。

## コマンド
```bash
bash PiCameraControl/build_ios_simulator.sh
python -m py_compile "home 3/api_server.py"
cd "home 3" && bash ./update.sh raspberrypi.local  # or 192.168.4.1
python mock_server.py
cd "home 3" && bash ./wifi_cycle_test.sh
```

## 重要制約
- 開発機は有線接続。Wi-Fi切替OK
- Wi-Fi切替: `_WIFI_SWITCH_LOCK`排他、409拒否、12秒CD、自動fallback
- API追加: `api_server.py`→`Models.swift`→`CameraAPI.swift`→deploy
- `contact.md`で進捗確認
- APやテザリング関係でなければ変更はpiにデプロイし、APテザリングに関係なく、gitにはpushして。
