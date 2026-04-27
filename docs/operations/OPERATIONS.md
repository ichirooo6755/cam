# PiCamera Control 運用ガイド

## 1. システム概要
Raspberry Pi + カメラで光変化を検知して撮影し、iOS アプリから設定・閲覧・編集を行うシステムです。

主な構成:
- Pi 側: `home 3/api_server.py`, `home 3/camera_service.py`, `home 3/wifi_manager.py`
- iOS 側: `PiCameraControl/`

## 2. 接続情報

### AP モード（デフォルト）
- SSID: `PiCamera`
- PASS: `picamera123`
- API: `http://192.168.4.1:8001`

### テザリング（家 Wi-Fi）
- API: `http://raspberrypi.local:8001`

## 3. 重要運用ルール
- Wi-Fi 切替は排他制御されるため、短時間連打しない
- AP/テザリング関連変更は実機デプロイして確認する
- API 追加時は Pi 側実装と iOS 側モデル/API クライアントを合わせて更新する

## 4. 基本コマンド

```bash
# Python 構文確認
python -m py_compile "home 3/api_server.py"

# Pi へデプロイ（家Wi-Fi）
cd "home 3" && bash ./update.sh raspberrypi.local

# Pi へデプロイ（AP）
cd "home 3" && bash ./update.sh 192.168.4.1

# Wi-Fi 切替試験
cd "home 3" && bash ./wifi_cycle_test.sh
```

## 5. 主要 API
- `GET/POST /api/settings`: 設定の取得/更新
- `GET /api/wifi/status`: Wi-Fi 状態
- `POST /api/wifi/switch`: AP/テザリング切替
- `GET /api/photos`: 写真一覧
- `POST /api/photo`: 写真取得（サムネ対応）
- `POST /api/capture`: 手動撮影
- `GET /api/sensor/status`: センサー状態

## 6. 白飛び・露出トラブル対応

### 症状
- 写真が全体的に白飛びする
- 日中だけ極端に露出オーバーになる

### 主な原因
- `iso` / `shutter_speed` が手動固定で保存され、AE が無効化されている
- センサー側の gain 下限（1.0）により、強い入射光を抑えきれない

### 設定確認

```bash
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool
# iso が "auto"、shutter_speed が "auto" かを確認
```

### 復旧手順

```bash
curl -X POST http://192.168.4.1:8001/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"iso":"auto","shutter_speed":"auto"}'
ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"
```

### 日中運用の実践値
- レンズ絞りは `f/8` 以上を推奨（快晴時は `f/11`〜`f/16`）
- ND フィルターを併用すると白飛びを抑えやすい
- 手動露出値はモード変更後も残る場合があるため注意

## 7. トラブル時の最短確認

```bash
ping 192.168.4.1
ping raspberrypi.local

ssh pi@192.168.4.1 "systemctl status api-server camera-service"
ssh pi@192.168.4.1 "journalctl -u camera-service -n 50 --no-pager"
```

詳細ランブック: `docs/runbook/TROUBLESHOOTING.md`
