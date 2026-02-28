# PiCamera 操作マニュアル

## 現在の仕組み

フィルムカメラ内部にPiカメラセンサーを設置。
フィルムシャッターが開くと光が入り、それを検知して同一フレームを保存する。

- AeEnable=False（自動露出OFF）
- ExposureTime=1秒（shutter_speed設定値）
- AnalogueGain=1.0（iso=auto時の初期値、適応型gainで調整）
- 同一フレームキャプチャ（検知フレーム＝保存フレーム、遅延ゼロ）

## 白飛び問題（既知の制限）

ISO100（gain=1.0）でも白飛びする場合がある。
これはセンサーの物理的なgain下限（1.0）の制限。

**対策:**
- フィルムカメラ側の**レンズ絞りを上げる**（f/8〜f/11推奨）
- または**NDフィルター**を使用
- 適応型gainが撮影結果から自動調整するが、gain=1.0が下限

## デプロイ

```bash
ping -c 2 192.168.4.1
cd "home 3"
scp camera_service.py api_server.py metering_calibrate.py pi@192.168.4.1:/home/pi/
ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"
ssh pi@192.168.4.1 "systemctl is-active camera-service api-server"
```

## ログ確認

```bash
ssh pi@192.168.4.1 "journalctl -u camera-service --no-pager -n 30"
ssh pi@192.168.4.1 "journalctl -u api-server --no-pager -n 30"
ssh pi@192.168.4.1 "free -h; df -h /; vcgencmd measure_temp; uptime"
```

## 設定確認・変更

```bash
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool
curl -s http://192.168.4.1:8001/api/sensor/status | python3 -m json.tool

# フィルムカメラ用デフォルトに戻す
curl -X POST http://192.168.4.1:8001/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"iso": "auto", "shutter_speed": 1000000, "camera_mode": "standard", "raw_mode": false}'

# 手動撮影
curl -s -X POST http://192.168.4.1:8001/api/capture \
  -H "Content-Type: application/json" -d '{}'
```

## トラブルシューティング

アプリの「トラブルシューティング」セクションから以下が実行可能:
- **フィルムカメラ用に復元** — ISO auto / SS 1秒 / STANDARD
- **ISO/SS を AUTO に変更** — 一時設定もクリア
- **カメラモード再適用** — 設定をサーバーに再送信