# 2026-06-07 実用化・ログ・Zero2W チューニング

本番（フィルムカメラ内蔵センサー＋光検知）に向けた調査・修正・フィールドテストの記録。

関連: [TROUBLESHOOTING.md](../runbook/TROUBLESHOOTING.md)（症状別）、[OPERATIONS.md](../operations/OPERATIONS.md)（運用・用語）

---

## 背景と目的

- **本番経路**: フィルムシャッターで幕が開く → `camera_service.py` が明るさの**立ち上がり**を検知 → 同一フレームを SD 保存。
- **補助経路**: iPhone の撮影ボタン → `POST /api/capture`（コード上「手動撮影」、本ドキュメントでは **API撮影** と表記）。
- 課題: 撮影失敗が多い印象、ログで「スマホ何回 vs Pi 何回」を突き合わせできない、Pi Zero 2 W（512MB）での安定性。

---

## 実施した変更（概要）

### Pi — ログ・観測性

| 項目 | 内容 |
|------|------|
| HTTP アクセスログ | `/home/pi/logs/api_access.log`（TSV、Rotating 10MB×5） |
| API 詳細ログ | `/home/pi/logs/api_server.log`（Rotating） |
| journald | `Storage=persistent`（`journald-persistent.conf`） |
| 相関 ID | iOS → `X-Client-Request-Id`、Pi → `client=` / `ipc=` で3ログ横断 |

**アクセスログ形式**（タブ区切り）:

```
UTC時刻  IP  METHOD  PATH  STATUS  ms  client_id  detail
```

`POST /api/capture` の detail 例: `event=capture ipc_request_id=... saved_on_device=1 success=1`

**突き合わせコマンド**:

```bash
# 光検知（本番）
grep -a "$(date +%Y-%m-%d)" /home/pi/logs/camera_service.log | grep -a 'Light detected' | wc -l
grep -a "$(date +%Y-%m-%d)" /home/pi/logs/camera_service.log | grep -a 'Captured: photo_' | wc -l

# API撮影（テスト用）
grep -a "$(date +%Y-%m-%d)" /home/pi/logs/api_access.log | grep -a $'\tPOST\t/api/capture\t' | wc -l
```

### Pi — 設定・IPC

| 項目 | 内容 |
|------|------|
| 閾値キー統一 | `detection_threshold` ↔ `brightness_threshold` を `_normalize_threshold_keys()` で相互補完 |
| IPC 競合対策 | request_id 専用結果ファイル `/run/picamera/capture_results/{id}.json` + `_CAPTURE_IPC_LOCK` |
| 二重撮影防止 | 撮影後 `lux ≤ 8`（`REARM_BRIGHTNESS_MAX`）まで再武装しない |
| rpicam fallback | camera-service 稼働中は禁止（競合防止） |
| IPC タイムアウト | api_server / camera_service を 30s / 45s で整合 |

### Pi — Zero 2 W システムチューニング（2026-06-07 後半）

| ファイル | 役割 |
|----------|------|
| `setup_zero2w_system.sh` | zram・swap・sysctl・時刻・systemd ユニット一括適用 |
| `sysctl-picamera-zero2w.conf` | swappiness=10、dirty_ratio 等 |
| `timesync-picamera.conf` | systemd-timesyncd（テザリング時 NTP） |
| `picamera-time-sync.service` | 起動時 fake-hwclock 復元 + NTP 有効化 |
| `picamera-system-tune.service` | 起動時 zram/swap/sysctl |
| `tune_performance_zero2w.sh` | 上記 `--full` へのラッパー（**カメラ設定は上書きしない**） |

**メモリ方針（512MB）**:

- zram: RAM の **50%**、lz4、優先度 100
- dphys-swapfile: **128MB** のみ（旧 tune の 512MB から縮小）
- camera-service: MemoryMax 300M、CPUWeight 200、Nice -2、撮影中 swappiness=0
- api-server: MemoryMax 96M、CPUWeight 80、Nice 5

**時計同期（3段）**:

1. 再起動: `fake-hwclock load`
2. テザリング: `systemd-timesyncd` + NTP
3. AP のみ: iPhone が `/api/system/time` で同期（ずれ 12 秒超）

### iOS

| 項目 | 内容 |
|------|------|
| `savedOnDevice` | SD 保存済みならプレビュー失敗でも成功扱い |
| `X-Client-Request-Id` | 撮影ごと 8 文字 UUID |
| `ConnectionMonitor` | `/api/status` JSON 検証、時刻ずれがあれば**毎回**同期試行 |
| `UnifiedGalleryView` | 空一覧でローカル全削除しない、編集版保持 |
| `Models.swift` | 閾値フォールバック decode + `encode(to:)` |

### デプロイ (`update.sh`)

- 転送前 `py_compile`
- `.conf` も SSH パイプ転送
- zram `.deb` バイナリパイプ転送
- journald / `setup_zero2w_system.sh --full` 自動実行

---

## 変更ファイル一覧

### Pi (`home 3/`)

- `api_server.py` — ログ、アクセスログ、IPC、閾値正規化、capture 応答
- `camera_service.py` — 閾値、IPC 結果パス、再武装、Rotating ログ
- `update.sh` — py_compile、パイプ拡張、system tune、journald
- `journald-persistent.conf`
- `setup_zero2w_system.sh`（新規）
- `sysctl-picamera-zero2w.conf`（新規）
- `timesync-picamera.conf`（新規）
- `picamera-time-sync.service`（新規）
- `picamera-system-tune.service`（新規）
- `tune_performance_zero2w.sh` — ラッパー化（設定上書き削除）
- `camera-service.service` — メモリ/CPU 制限、After tune units
- `api-server.service` — メモリ/CPU 制限

### iOS (`PiCameraControl/`)

- `CameraAPI.swift`
- `Models.swift`
- `ContentView.swift`
- `ConnectionMonitor.swift`
- `UnifiedGalleryView.swift`

### ドキュメント

- `docs/runbook/TROUBLESHOOTING.md` — ログ突き合わせ、用語
- 本ファイル

---

## フィールドテスト結果

### Pi 時刻と Mac/iPhone のずれ

- Pi の `date` が実際より **約 7 時間遅れ**のことがあった。
- ユーザーが「23:42 にテスト」と言っても、Pi ログ上は `16:55` 等として記録される。
- **対策**: `setup_zero2w_system.sh` + iPhone 自動時刻同期。デプロイ後 `timedatectl status` で確認。

### テスト 1（Pi 16:55 頃 ≒ ユーザー 23:42 頃）

| 項目 | 結果 |
|------|------|
| 試行 | 20 回（ユーザー申告） |
| `Light detected` | 5 |
| SD 保存 | 5 |
| 検知→保存 | 100% |
| 全体 | **25%**（検知漏れ 15） |

### テスト 2（Pi 17:00:19〜17:01:05、reaction モード）

| 項目 | 結果 |
|------|------|
| `Light detected` | 22 |
| SD 保存 | 22 |
| 検知→保存 | **100%** |
| レイテンシ | **75〜125ms**（平均 ~81ms） |
| 注意 | 1 秒以内の連続検知 **6 組** → 1 シャッター 2 枚の可能性 |

→ **再武装ロジック**（`REARM_BRIGHTNESS_MAX`）を後から追加。

### 失敗パターン整理

| パターン | 意味 |
|----------|------|
| スマホ試行 >> Pi `Light detected` | 本番経路未到達ではなく、**検知漏れ**（幕が短い・既に明るい・閾値） |
| スマホ >> Pi `POST /api/capture` | Wi-Fi 未到達・タイムアウト（API撮影テスト時） |
| Pi 500 + `saved_on_device=1` | SD 成功・HTTP 応答失敗（プレビュー大・切断） |
| `client_disconnect=1` | 応答 JSON 送信中に iPhone 切断 |

---

## 未解決・既知の問題

| 優先度 | 問題 | 状態 |
|--------|------|------|
| P1 | **Zero2W system tune の Pi 反映** | `update.sh` 実行時 SSH が途中で `Permission denied` になることがあり、**最終デプロイ未完了の可能性**。Pi 到達後に再実行要。 |
| P1 | **Pi 時計ずれ** | tune + iPhone 同期で改善見込み。`sudo NOPASSWD` 無しだと `/api/system/time` 失敗。 |
| P2 | **検知漏れ**（暗→明が弱い） | reaction + 再武装で改善。閾値・near-miss ログは今後検討。 |
| P2 | **二重撮影** | 再武装を入れたが、フィールド再確認待ち。 |
| P3 | **iOS 実機再インストール** | 時刻同期・savedOnDevice・client_id は新ビルド必須。 |
| P3 | Git commit | ユーザー明示依頼まで未コミット。 |

---

## デプロイ手順（未反映時）

```bash
cd "home 3"
SSHPASS=raspberry bash ./update.sh 192.168.4.1
```

確認:

```bash
ssh pi@192.168.4.1 "timedatectl status; free -h; swapon --show; zramctl; systemctl is-active picamera-time-sync picamera-system-tune camera-service api-server"
```

手動 tune:

```bash
ssh pi@192.168.4.1 "sudo bash /home/pi/setup_zero2w_system.sh --full"
```

---

## 用語（混同防止）

| 用語 | 意味 |
|------|------|
| **光検知撮影（本番）** | フィルムシャッター → `Light detected` → `photo_YYYYMMDD_*.jpg` |
| **API撮影** | iPhone ボタン / curl → `POST /api/capture` → `manual_*.jpg` |
| **手動撮影** | コード上の旧称。API撮影と同義。**フィルムシャッターを手で切る**意味ではない。 |

---

## 次のアクション

1. Pi 到達時に `update.sh` 再実行 → zram / 時刻 / 再武装を Pi に反映
2. iOS 実機再インストール → PiCamera 接続 → 時刻同期確認
3. reaction モードでシャッター 20 回 → SD 枚数 = 検知回数 ≈ 20 を確認
4. 合格後: 屋外・実フィルムボディ装着テスト

---

## 作業ログ

- 2026-06-07: ログ恒久化、IPC 改善、iOS 相関、フィールドテスト分析
- 2026-06-07 後半: Zero2W system tune、再武装、iOS 時刻同期強化（デプロイ一部未完了）
