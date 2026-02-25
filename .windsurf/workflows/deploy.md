---
description: PiCameraへのデプロイとログ確認の手順
---

# デプロイ & ログ確認ガイド

## 前提条件

- MacのWiFiが「PiCamera」SSIDに接続されていること（パスワード: `picamera123`）
- PiのIPアドレス: `192.168.4.1`（APモード時）
- SSHユーザー: `pi@192.168.4.1`

---

## 1. デプロイ手順

### 1-1. Pi到達確認
```bash
ping -c 2 192.168.4.1
```
- 応答があればOK
- タイムアウトする場合 → MacのWiFiが「PiCamera」に接続されているか確認

### 1-2. デプロイ実行
```bash
bash "home 3/update.sh" 192.168.4.1
```
このスクリプトが自動で行うこと:
1. `wifi_manager.py`, `camera_service.py`, `api_server.py` をSCPで転送
2. `camera-service.service`, `api-server.service` を転送・インストール
3. `TROUBLESHOOTING.md` を転送
4. 旧サービスの停止・無効化
5. 新サービスの有効化・再起動

### 1-3. デプロイ後の確認
```bash
# サービス状態
ssh pi@192.168.4.1 "systemctl is-active camera-service api-server"
# → 両方 "active" ならOK

# API応答テスト
curl -s http://192.168.4.1:8001/api/status
# → JSON応答が返ればOK
```

---

## 2. ログ確認

### 2-1. camera-service のログ（光検知・撮影）
```bash
# 最新30行
ssh pi@192.168.4.1 "journalctl -u camera-service --no-pager -n 30"

# リアルタイム監視（Ctrl+Cで停止）
ssh pi@192.168.4.1 "journalctl -u camera-service -f"

# エラーだけ抽出
ssh pi@192.168.4.1 "journalctl -u camera-service --no-pager -p err -n 50"

# 今日のログだけ
ssh pi@192.168.4.1 "journalctl -u camera-service --no-pager --since today"
```

### 2-2. api-server のログ（API・WiFi watchdog）
```bash
# 最新30行
ssh pi@192.168.4.1 "journalctl -u api-server --no-pager -n 30"

# エラーだけ抽出
ssh pi@192.168.4.1 "journalctl -u api-server --no-pager -p err -n 50"

# watchdog関連のみ
ssh pi@192.168.4.1 "journalctl -u api-server --no-pager -n 100 | grep -i watchdog"
```

### 2-3. システム全体のエラー
```bash
# 過去24時間のエラー
ssh pi@192.168.4.1 "journalctl -p err --since '24 hours ago' --no-pager -n 50"

# カーネルメッセージ（ハードウェア系）
ssh pi@192.168.4.1 "dmesg --level=err,crit | tail -20"

# 失敗中のサービス一覧
ssh pi@192.168.4.1 "systemctl --failed"
```

### 2-4. リソース状況
```bash
ssh pi@192.168.4.1 "
  echo '=== MEMORY ==='; free -h
  echo '=== DISK ==='; df -h /
  echo '=== TEMP ==='; vcgencmd measure_temp
  echo '=== LOAD ==='; uptime
  echo '=== TOP PROCS ==='; ps aux --sort=-%mem | head -8
  echo '=== RESTART COUNT ==='; systemctl show camera-service -p NRestarts
"
```

---

## 3. よく使う操作

### サービスの手動再起動
```bash
ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"
```

### カメラ検出テスト
```bash
ssh pi@192.168.4.1 "libcamera-hello --list-cameras"
# "Available cameras" の下にカメラ情報が出ればOK
# "No cameras available!" → CSIケーブル接続を確認
```

### 設定の確認・変更
```bash
# 現在の設定取得
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool

# 設定変更（例: SS 1/1000）
curl -s -X POST http://192.168.4.1:8001/api/settings \
  -H "Content-Type: application/json" \
  -d '{"shutter_speed": 1000}'

# autoに戻す
curl -s -X POST http://192.168.4.1:8001/api/settings \
  -H "Content-Type: application/json" \
  -d '{"shutter_speed": "auto", "iso": "auto"}'
```

### 手動撮影テスト
```bash
curl -s -X POST http://192.168.4.1:8001/api/capture \
  -H "Content-Type: application/json" \
  -d '{"manual_mode": "current"}'
```

### WiFi状態確認
```bash
curl -s http://192.168.4.1:8001/api/wifi/status | python3 -m json.tool
```

### センサー状態確認
```bash
curl -s http://192.168.4.1:8001/api/sensor/status | python3 -m json.tool
```

---

## 4. トラブルシューティング

| 症状 | 確認コマンド | 対処 |
|------|-------------|------|
| pingが通らない | MacのWiFi設定確認 | 「PiCamera」に接続 |
| SSHタイムアウト | `ping 192.168.4.1` | Piの電源を抜き差し |
| camera-service inactive | `systemctl status camera-service` | `sudo systemctl restart camera-service` |
| Camera not found | `libcamera-hello --list-cameras` | CSIケーブルを挿し直し→再起動 |
| Swap枯渇 | `free -h` | `sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile && sudo systemctl restart dphys-swapfile` |
| ディスク満杯 | `df -h /` | `ssh pi@192.168.4.1 "ls -lt /home/pi/photos | tail"` で古い写真を確認・削除 |
