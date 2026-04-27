# 開発状況ログ（2026-04-27）

## 直近の実施内容

### commit `4eb0d30` — perf: IPC手動撮影 + 輝度スムージング + 長時間露光タイムアウト修正

| ファイル | 変更内容 |
|---|---|
| `camera_service.py` | IPC撮影ハンドラ・輝度スムージング・60fps FPS_PRESET追加 |
| `api_server.py` | IPC優先撮影・rpicam-still fallback・長時間露光タイムアウト修正 |
| `api-server.service` | ExecStartPre で wifi_mode=ap を強制（起動時AP保証） |
| `camera_settings.json` | iso/shutter_speed を auto に変更 |
| `update.sh` | UseDNS no 自動設定（SSH接続遅延対策） |

---

## IPC手動撮影の設計

### 概要

手動撮影（`/api/capture`）の旧来の実装：
```
camera-service 停止（~3s）→ rpicam-still subprocess（~5s）→ camera-service 再起動（~2s）= ~10s
```

新実装（IPC方式）：
```
capture_request.json を書く → camera-service が検知して撮影 → capture_result.json を読む = ~2s
```

### IPCファイル

| パス | 用途 |
|---|---|
| `/run/picamera/capture_request.json` | api_server → camera_service へのリクエスト |
| `/run/picamera/capture_result.json` | camera_service → api_server への結果返却 |

### リクエストスキーマ

```json
{
  "request_id": "uuid(16文字)",
  "created_at": 1745678901.23,
  "width": 1920,
  "height": 1080,
  "quality": 90,
  "shutter_speed": "auto",
  "iso": "auto",
  "raw_mode": false,
  "denoise_mode": "auto",
  "white_balance": "auto"
}
```

### 結果スキーマ

```json
{
  "request_id": "...",
  "success": true,
  "filepath": "/home/pi/photos/photo_xxx.jpg",
  "filename": "photo_xxx.jpg",
  "delay_ms": 45.2,
  "camera_ms": 38.1,
  "written_at": 1745678903.10
}
```

---

## 未解決の問題

### IPC撮影がシーケンシャル実行でタイムアウトする

**状況**:  
quality モード単独: ✅ 成功  
standard/night/reaction 単独: ❌ タイムアウト（curl --max-time 35 で空レスポンス）

**推定原因** (要調査):

1. `_handle_manual_capture_request()` の呼び出し位置が、クールダウンチェックの `continue` 後（設定リロード後）にあるため、クールダウン中はIPC処理がスキップされる可能性がある。  
   - クールダウン値: quality=3.0s / standard=1.5s / night=3.0s / reaction=0.3s  
   - IPCタイムアウト: 28s なので超えないはずだが…

2. quality capture後にカメラが 4056×3040 に再設定され、次のstandard IPC リクエストでも再設定（stop/configure/start）が走り、その間にタイムアウトする可能性。

3. api_server.py 側の `_ipc_capture()` が IPC タイムアウト後に rpicam-still fallback に落ちるが、その際 `service_should_stop=True` でサービス停止を試みる → camera-service が生きているまま rpicam-still が起動しカメラリソース競合。

**次のアクション**:

- [ ] `_handle_manual_capture_request()` の呼び出しをクールダウンチェックの**前**に移動する
- [ ] IPC タイムアウト後の rpicam-still fallback では `service_should_stop=False` にするか、fallbackを無効化してエラーだけ返す
- [ ] Pi の `camera_service.log` でIPCリクエストが受信されているか確認
- [ ] 個別テスト（standard 単独、十分な待機後）で再現確認

---

## カメラ性能改善（実装済み）

### 輝度スムージング
直近3フレームのメジアンで誤検知を抑制。

```python
_brightness_history.append(brightness)
smoothed_brightness = float(np.median(list(_brightness_history)))
```

### 長時間露光タイムアウト自動スケール
rpicam-still の `--timeout` をシャッター速度に合わせて伸ばす。

```python
if shutter_us > 3_000_000:
    rpicam_timeout_ms = shutter_us // 1000 + 3000
else:
    rpicam_timeout_ms = 5000  # 5秒（AEC収束に十分な余裕）

proc_timeout_sec = max(60, (rpicam_timeout_ms + shutter_us) // 1_000_000 + 15)
```

### FPS_PRESETS 拡張（IMX477対応）
```python
FPS_PRESETS = {
    30:  {'main_size': (1920, 1080), 'frame_duration': 33333},
    40:  {'main_size': (2028, 1520), 'frame_duration': 25000},
    60:  {'main_size': (1640, 1232), 'frame_duration': 16666},  # 2x2 binning
    120: {'main_size': (1332,  990), 'frame_duration': 8333},
}
```

---

## 既解決済みの問題（参考）

| 問題 | 原因 | 修正 |
|---|---|---|
| `errno 2 libcamera-still` | Bookworm で rpicam-still に改名 | `_resolve_still_binary()` で自動検出 |
| IMX477 `No cameras available` | `camera_auto_detect=1` と `dtoverlay=imx477` の競合 | `camera_auto_detect=0` に変更 |
| IMX477 認識エラー `-121` | リボンケーブル未着座 | 物理的に再挿入 |
| SSH 接続遅延 30〜60秒 | sshd の逆引きDNS PTRルックアップ | `UseDNS no` を sshd_config に追記 |
| AP watchdog が過剰復旧 | 猶予15s が短すぎた | `AP_UNHEALTHY_GRACE_SEC = 120` に変更 |
| 長時間露光で V4L2 dequeue timeout | `FrameDurationLimits=33333µs` 固定と `ExposureTime=5s` の競合 | ExposureTime > 33333µs 時に FrameDurationLimits を動的拡張 |
| 起動時にAP出ない | `wifi_mode=tethering` がデフォルト | ExecStartPre で強制 `wifi_mode=ap` |

---

## 現在のシステム状態（2026-04-27 11:50 JST）

- Pi: 192.168.4.1（APモード、SSID=PiCamera）
- camera-service: active ✅
- api-server: active ✅
- IMX477: 認識済み ✅
- 全サービス: 再起動時自動起動設定済み ✅
