# 写真白飛び問題 — 診断と修正手順

## 根本原因

**`camera_settings.json` に固定露出値が保存されており、自動露出(AE)が無効になっている。**

現在のPi上の設定ファイル (`/home/pi/camera_settings.json`):
```json
{
  "iso": 100,
  "shutter_speed": 1000000
}
```

### なぜ白飛びするか

| 項目 | 現在の値 | 意味 |
|------|---------|------|
| `shutter_speed` | `1000000` | **1秒間** シャッターを開く |
| `iso` | `100` | ISO 100（数値 = auto以外） |
| `AeEnable` | `false` | **自動露出OFF**（iso/shutterどちらかが非autoだとOFF） |

- 昼間の適正露出は約 **1/500秒（2,000µs）** @ ISO 100
- 現在は **1秒（1,000,000µs）** = 適正値の **500倍** の光量
- → 完全に白飛び

### 影響範囲

1. **自動検知撮影** (`camera_service.py`): `_apply_camera_controls()` が `AeEnable=False, ExposureTime=1000000` を設定
2. **手動撮影** (`api_server.py`): `libcamera-still --shutter 1000000 --gain 1.0` を実行
3. 両方の撮影パスで白飛びが発生

### コード該当箇所

```python
# camera_service.py:217-218
manual_exposure = iso_value != 'auto' or shutter_value != 'auto'
controls['AeEnable'] = not manual_exposure  # → False（AE無効）
```

`iso` が数値(100)、`shutter_speed` が数値(1000000)なので、`manual_exposure = True` → `AeEnable = False`。

---

## 帰宅後の修正手順

### 準備

1. iPhoneでPiCameraのWi-Fiに接続
2. MacのターミナルまたはiPhoneのSSHアプリを使用

### ステップ1: SSH接続

```bash
ssh pi@192.168.4.1
# パスワード: raspberry（必要な場合）
```

### ステップ2: 現在の設定を確認

```bash
cat /home/pi/camera_settings.json
```

`iso` と `shutter_speed` の値を確認する。数値になっている場合が白飛びの原因。

### ステップ3: 設定をautoに修正

**方法A: アプリから修正（推奨）**

iOSアプリのUI上で：
1. ISO を **AUTO** に変更
2. シャッタースピード を **AUTO** に変更

これで `camera_session_overrides.json` にautoが書き込まれ、次回撮影からAEが有効になる。

ただし、永続設定 (`camera_settings.json`) には残るため、再起動後に元に戻る可能性がある。

**方法B: SSHから直接修正（確実）**

```bash
# バックアップ
cp /home/pi/camera_settings.json /home/pi/camera_settings.json.bak

# isoとshutter_speedをautoに変更
python3 -c "
import json
with open('/home/pi/camera_settings.json', 'r') as f:
    s = json.load(f)
s['iso'] = 'auto'
s['shutter_speed'] = 'auto'
with open('/home/pi/camera_settings.json', 'w') as f:
    json.dump(s, f, indent=2)
print('Updated:', json.dumps(s, indent=2))
"
```

**方法C: curlで設定APIを叩く**

```bash
# SSHなしでも、PiCamera WiFiに接続していれば実行可能
curl -X POST http://192.168.4.1:8001/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"iso": "auto", "shutter_speed": "auto"}'
```

注意: この方法は `temporary: true` が付かないのでcamera_settings.jsonに直接書き込まれる。

### ステップ4: サービス再起動

```bash
ssh pi@192.168.4.1 'sudo systemctl restart camera-service api-server'
```

### ステップ5: 動作確認

```bash
# 現在の設定を確認
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool

# isoとshutter_speedが"auto"になっていることを確認

# テスト撮影
curl -X POST http://192.168.4.1:8001/api/capture \
  -H 'Content-Type: application/json' \
  -d '{}'

# センサーステータス（AEが動作しているか確認）
curl -s http://192.168.4.1:8001/api/sensor/status | python3 -m json.tool
# ae_gain と ae_exposure_us が null でないこと = AE稼働中
```

### ステップ6: ログで確認

```bash
ssh pi@192.168.4.1 'journalctl -u camera-service --no-pager -n 20'
ssh pi@192.168.4.1 'journalctl -u api-server --no-pager -n 20'
```

---

## 今後の再発防止（コード修正が必要）

### 問題点

1. アプリからISO/シャッタースピードを手動設定 → 値が保存される
2. カメラモード変更（standard等）しても iso/shutter_speed は **リセットされない**
3. ユーザーが明示的にAUTOに戻さない限り、手動値が永続する

### 実施済みの修正

**1. `api_server.py` — モード変更時にiso/shutter_speedを自動リセット**

カメラモード変更時（manual以外）、`iso` と `shutter_speed` が明示的に指定されていなければ `'auto'` にリセットされるようにした。これにより手動露出値がモード変更後も残り続ける問題を防止。

**2. `camera_service.py` — 長時間露出の警告ログ追加**

`shutter_speed > 100,000µs（1/10秒）` の手動設定時に警告ログを出力。ログ確認で白飛びリスクに気付ける。

### 残り作業（帰宅後）

- `camera_settings.json` の `iso`/`shutter_speed` を `"auto"` に修正（上記ステップ2〜3）
- 修正コードをPiにデプロイ（`/deploy` ワークフロー参照）

---

作成日: 2026-02-27 09:44 JST
