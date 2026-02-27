# PiCamera 操作マニュアル

## 白飛び修正（最優先）

原因: `camera_session_overrides.json` に古いISO/シャッター値が残っており、
`camera_settings.json` を修正しても上書きされている。
サービス再起動もされていないためクリアされていない。

### 修正手順（PiCamera WiFi に接続して実行）

```bash
# 1. 接続確認
ping -c 2 192.168.4.1

# 2. session_overrides の中身を確認（これが白飛びの真の原因）
ssh pi@192.168.4.1 "cat /home/pi/camera_session_overrides.json 2>/dev/null || echo 'ファイルなし'"

# 3. session_overrides を削除
ssh pi@192.168.4.1 "rm -f /home/pi/camera_session_overrides.json"

# 4. camera_settings.json の iso/shutter_speed を確認
ssh pi@192.168.4.1 "cat /home/pi/camera_settings.json | python3 -m json.tool"

# 5. もし iso/shutter_speed がまだ数値なら修正（reset_temporary で overrides も消す）
curl -X POST http://192.168.4.1:8001/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"iso": "auto", "shutter_speed": "auto", "reset_temporary": true}'

# 6. サービス再起動（新コードを反映）
ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"

# 7. 再起動確認
ssh pi@192.168.4.1 "systemctl is-active camera-service api-server"

# 8. 設定が正しく反映されたか確認（iso/shutter_speed が "auto" であること）
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool

# 9. テスト撮影
curl -s -X POST http://192.168.4.1:8001/api/capture \
  -H "Content-Type: application/json" -d '{}'
```

---

## デプロイ

```bash
# 1. Pi到達確認
ping -c 2 192.168.4.1

# 2. デプロイ実行
bash "home 3/update.sh" 192.168.4.1

# 3. もし update.sh がタイムアウトしたら手動で：
cd "home 3"
scp wifi_manager.py camera_service.py api_server.py pi@192.168.4.1:/home/pi/
ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"

# 4. 確認
ssh pi@192.168.4.1 "systemctl is-active camera-service api-server"
```

---

## ログ確認

```bash
# camera-service（光検知・撮影）
ssh pi@192.168.4.1 "journalctl -u camera-service --no-pager -n 30"

# api-server（API・WiFi watchdog）
ssh pi@192.168.4.1 "journalctl -u api-server --no-pager -n 30"

# エラーだけ抽出
ssh pi@192.168.4.1 "journalctl -p err --since '24 hours ago' --no-pager -n 50"

# リソース状況（メモリ・温度・ディスク）
ssh pi@192.168.4.1 "free -h; df -h /; vcgencmd measure_temp; uptime"

# サービス再起動時刻の確認
ssh pi@192.168.4.1 "systemctl show camera-service -p ActiveEnterTimestamp"
ssh pi@192.168.4.1 "systemctl show api-server -p ActiveEnterTimestamp"
```

---

## 白飛び診断（問題が再発した場合）

```bash
# 1. 有効な設定を確認（session_overrides込みの最終値）
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool

# 2. session_overrides が残っていないか確認
ssh pi@192.168.4.1 "cat /home/pi/camera_session_overrides.json 2>/dev/null || echo 'なし'"

# 3. camera_settings.json の生の値を確認
ssh pi@192.168.4.1 "python3 -c \"import json; d=json.load(open('/home/pi/camera_settings.json')); print('iso:', d.get('iso'), 'ss:', d.get('shutter_speed'))\""

# 4. センサー状態（AEが動作中か確認）
curl -s http://192.168.4.1:8001/api/sensor/status | python3 -m json.tool

# 5. camera-service のログで露出警告を探す
ssh pi@192.168.4.1 "journalctl -u camera-service --no-pager -n 100 | grep -i 'exposure\|Long manual'"
```

---

## 通常操作

```bash
# 設定取得
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool

# 手動撮影
curl -s -X POST http://192.168.4.1:8001/api/capture \
  -H "Content-Type: application/json" -d '{"manual_mode": "current"}'

# センサー状態
curl -s http://192.168.4.1:8001/api/sensor/status | python3 -m json.tool
```