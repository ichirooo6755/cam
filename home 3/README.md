# PiCamera Control System v2.0 (省電力版)

Raspberry Pi Zero 2 W + カメラモジュールを使った**光検知自動撮影システム**

## 新システムの特徴

- **省電力設計**: カメラは光検知時のみ起動（CLI化済み）
- **高速反応**: 250ms間隔で光を監視、検知時に即撮影（Zero 2W向け軽量化）
- **ライブビュー不要**: 写真一覧中心のシンプルなiOSアプリ
- **軽量API**: 写真取得とステータス確認のみの最小構成
- **手動モード**: 光検知を停止し、アプリのボタンで撮影

## システム構成

### Raspberry Pi側
- `camera_service.py`: 光検知＋自動撮影サービス（常駐）
- `api_server.py`: HTTP APIサーバー（ポート8001）

### iOS アプリ
- タブ1: 写真ギャラリー（自動撮影された写真一覧）
  - 単体表示: 保存 / 削除 / 編集（フォトエディタ）
  - 選択モード: 複数選択→一括保存 / 一括削除
- タブ2: 設定（明るさ閾値調整、システム状態表示）

## デプロイ（Mac → Raspberry Pi）

基本は `home 3/update.sh` を使用します。

```bash
# 家Wi-Fi（推奨）
bash ./update.sh raspberrypi.local

# APモード（PiCameraに接続中）
bash ./update.sh 192.168.4.1
```

`update.sh` は以下を実行します。
- ファイル転送（`wifi_manager.py`, `camera_service.py`, `api_server.py`, `*.service`, `README.md`）
- 旧サービスの停止/disable/ユニット削除/旧ファイル削除
- `camera-service` / `api-server` の有効化と再起動

### 症状: 光が当たり続けると連続撮影になる懸念
**原因**
明るさが閾値を超えた状態が継続すると、毎ループで撮影される可能性がありました。

**解決策**
光検知の「立ち上がり（暗→明）」のみをトリガーにし、連続撮影を抑止しました。さらにクールダウン（0.25秒）を入れて負荷を抑えています。

### 症状: iOSアプリのビルドが失敗する
**原因**
新規追加した Swift ファイル（PhotoGalleryView.swift / SettingsView.swift / SimpleCameraAPI.swift / PhotoEditorView.swift）が Xcode プロジェクトに未登録でした。

**解決策**
`project.pbxproj` にファイル参照と Sources 追加を行い、ビルド成功を確認しました。

### 症状: xcodebuild で "Unable to find a device matching the provided destination specifier" が出てビルドできない
**原因**
指定した Simulator（例: `name=iPhone 15`）がローカル環境に存在しないため。

**解決策**
以下のどちらかで回避できます。
- `xcodebuild -list` で利用可能な destination を確認して指定
- 汎用指定（推奨）: `-destination 'generic/platform=iOS Simulator'`

### 症状: PhotoEditorView.swift のビルドが失敗する（radialGradient の radius 型エラー）
**原因**
`CIFilter.radialGradient()` の `radius0/radius1` が `Float` 型なのに対し、`CGFloat` を代入していました。

**解決策**
`Float(...)` へ明示キャストして型を揃えました。

### 追加: iOSフォトギャラリーの複数選択（まとめて保存 / 削除）
- 「選択」→写真を複数タップ→下部バーから **保存** / **削除** を実行
- 保存は iOS の写真アプリへ書き込み、削除は Pi の写真削除API（`/api/photos/delete`）を呼びます

### 追加: iOSフォトエディタ（Lightroom風）
写真の単体表示画面で **編集アイコン**（スライダー）を押すと編集画面を開けます。

できること:
- 露出 / コントラスト / 彩度
- ハイライト / シャドウ
- 色温度 / モノクロ
- トリミング（スライダーで範囲調整）
- ラジアルマスク（簡易・局所露出）
- リセット
- 編集プリセットの保存 / 適用
- 書き出し（写真アプリへ保存）

注意:
- 編集は非破壊で、Pi上の元画像ファイルは変更しません（書き出しはiOS側に新規保存です）

### 追加: 写真削除API（/api/photos/delete）
iOSアプリの単体削除 / 一括削除はこのAPIを使用します。

```bash
curl -X POST "http://192.168.4.1:8001/api/photos/delete" \
  -H "Content-Type: application/json" \
  -d '{"filenames":["photo_20260101_000000_000000.jpg","photo_20260101_000000_000001.jpg"]}'
```

### 症状: iOSアプリの赤い撮影ボタンを押すとレイアウトが崩れる / 画面からはみ出る
**原因**
撮影失敗時のエラーメッセージが長い場合、設定画面のScrollView内にそのまま表示していたため、コンテンツが押し出されて表示が崩れていました。

**解決策**
エラー表示を画面上部のオーバーレイバナーに変更し、表示高さを制限した上で閉じるボタンを追加しました。これにより長いエラーでも画面レイアウトが崩れません。

### 症状: /api/capture で撮影が失敗する（Device or resource busy）
**原因**
`camera-service` がカメラを占有していて、`libcamera-still` を呼ぶとデバイスがビジーになり失敗します。

**解決策**
`/api/capture` 実行時に `camera-service` を一時停止し、撮影後に再開するよう修正しました。

### 症状: 光検知が単純な閾値判定になり、旧版の高速検知と挙動が異なる
**原因**
閾値超過のみの判定に変更していたため、明るさの「変化量/変化率」を使う旧版ロジックが外れていました。

**解決策**
旧版と同じく変化率 + 変化量で判定し、検知間隔を 0.25 秒に戻しました。

### 変更: シャッタースピード選択肢
- **手動モード時は 1/400 まで**（通常モードは 1/250 まで）
- **1/15〜1sの間に 1/8・1/4・1/2 を追加**
- **1秒刻みで20秒まで追加**（1s〜20s）

### 変更: 画質(quality)の制御
アプリの **QUALITY** ピッカーから画質を選択できます（Q60〜Q100）。

### 変更: カメラ4モード（REACTION / QUALITY / STANDARD / BATTERY）
Pi側は `camera_mode` を設定として保持し、モードに応じて以下を自動適用します。

- **REACTION**: `quality=80`, `size=1280x720`, `detection_interval=0.1`, `check_interval=0.1`, `capture_cooldown=0.1`（合成/タイムスタンプは自動OFF）
- **QUALITY**: `quality=100`, `size=4056x3040`, `detection_interval=1.0`, `check_interval=0.25`, `capture_cooldown=0.25`
- **STANDARD**: `quality=90`, `size=1920x1080`, `detection_interval=0.25`, `check_interval=0.25`, `capture_cooldown=0.25`
- **BATTERY**: `quality=90`, `size=1920x1080`, `detection_interval=2.0`, `check_interval=1.0`, `capture_cooldown=0.0`, `monitoring_enabled=false`（合成/タイムスタンプは自動OFF）

設定方法:
- iOSアプリの **MODE** ピッカーから選択
- またはAPIで設定
```bash
curl -X POST "http://192.168.4.1:8001/api/settings" \
  -H "Content-Type: application/json" \
  -d '{"camera_mode":"reaction"}'
```

### 追加: 一時設定（temporary / reset_temporary）
iOSアプリからの設定変更のうち、ISO/シャッター/WB/画質/閾値/各種トグル等は **「一時変更」** として送信できます。
一時変更は永続設定（`camera_settings.json`）を書き換えず、セッション用の上書きファイルへ保存されます。

- 永続設定: `/home/pi/camera_settings.json`
- 一時上書き: `/home/pi/camera_session_overrides.json`

挙動:
- `temporary=true` のリクエストは一時上書きファイルに保存され、`/api/settings` 取得時および `camera-service` の自動撮影に **上書き適用** されます
- `camera_mode` は一時変更できません（`temporary=true` のときは無視されます）
- `camera_mode` を変更すると、一時上書きは自動的にクリアされます
- `reset_temporary=true` で一時上書きをリセットできます
- `camera-service` 起動時にも一時上書きファイルは削除され、再起動でリセットされます

API例:
```bash
BASE="http://192.168.4.1:8001"

# 一時変更（例: ISO と 画質）
curl -sS -X POST "$BASE/api/settings" \
  -H "Content-Type: application/json" \
  -d '{"iso":200,"quality":80,"temporary":true}'

# 一時変更をリセット
curl -sS -X POST "$BASE/api/settings" \
  -H "Content-Type: application/json" \
  -d '{"reset_temporary":true}'
```

iOSアプリ:
- 設定画面の「一時変更をリセット」ボタンで `reset_temporary` を呼びます

### 症状: ライブラリの写真が重なって見える / 光検知から撮影まで遅い
**原因**
多重露光 or 2in1合成が有効だと、2枚目を待って合成するため、
撮影が遅く感じたり重なった写真になります。さらに長秒露光（1s〜20s）やタイムスタンプ、
高品質(quality=90)は処理時間が増えます。Pi側の処理が主因です。

**解決策**
- 手動モードON時は **多重露光/2in1合成を自動OFF**
- アプリの設定で **多重露光 / 2in1合成 / タイムスタンプ** をOFF
- 画質(quality)を下げる（速度優先）
- ログで遅延の実測
```bash
ssh pi@192.168.0.20 "grep -E 'Light change detected|Detect->Capture delay|Photo captured' /home/pi/logs/camera_service.log | tail -n 20"
```

### 症状: 写真が増えない（Refreshしても反映されない）
**原因**
手動モードがONだと光検知が停止するため、自動撮影が行われません。

**解決策**
- 手動モードをOFFにして光検知を再開する
- 手動モードのままなら撮影ボタンで撮影する

### 症状: 「SWITCH TO AP / CLIENT」を押しても表示が切り替わらない
**原因**
画面の切替パネル表示が現在モード (`isAPMode`) と直結していたため、
トグルしても本来の切替先 (`targetAPMode`) が反映されていませんでした。

**解決策**
切替先を `targetAPMode` として分離し、パネル表示と実行先を一致させました。

### 症状: APモード時のIPが家Wi-FiのIPと違う
**原因**
APモードは固定IPのため、家Wi-Fiとは別のネットワークになります。

**解決策**
APモード時は `192.168.4.1` を表示/使用するように統一しました。

### 症状: Wi-Fi切替が失敗したように見える / タイムアウトする
**原因**
APモード切替はネットワークが即座に切り替わるため、HTTP応答を待っているときにクライアント側の接続が切断され、
タイムアウトや失敗扱いになります。

**解決策**
- Pi側: `/api/wifi/switch` は先にレスポンスを返し、切替処理はバックグラウンドで実行するように変更しました。
- iOS側: 切替後の通信断を想定内として扱い、切替先へ再接続するためのガイド表示と `serverIP` 更新を行います。

### 症状: `update.sh` が `REMOTE HOST IDENTIFICATION HAS CHANGED!` で転送できない
**原因**
Pi側のOS入れ替えやホスト鍵再生成で SSH host key が変わったのに、Mac側の `~/.ssh/known_hosts` に古い鍵が残っているため、`scp/ssh` が安全のため接続を拒否します。

**解決策**
- 手動: `ssh-keygen -R raspberrypi.local`（またはIP）で古い鍵を削除してから再実行
- 自動: `home 3/update.sh` にホスト鍵不一致検出→自動削除→再接続の処理を追加しました（転送に失敗した場合は `set -e` によりスクリプトが停止します）

### 症状: ホワイトバランスを変更してもPiに反映されない
**原因**
iOSアプリのWBボタンが状態を変更するだけで、APIへの送信処理が欠落していました。

**解決策**
ボタンタップ時に `updateWhiteBalance()` を呼ぶよう修正しました。

### 症状: アプリの検知閾値(DETECTION THRESHOLD)が常に30になる
**原因**
Pi側のAPIレスポンスに `detection_threshold` キーが無く、
iOS側が常にデフォルト値30を使用していました。

**解決策**
`api_server.py` の `serve_settings()` で `brightness_threshold` → `detection_threshold` の
双方向マッピングを追加しました。

### 症状: 画質(quality)設定が通常写真に反映されない
**原因**
`camera_service.py` の `capture_photo()` で、合成やタイムスタンプ無しの通常写真は
`switch_mode_and_capture_file()` のデフォルト品質(95)で保存されていました。

**解決策**
通常写真でもPILで再保存してquality設定を反映するよう修正しました。

### 症状: api-serverが起動しない（Address already in use）
**原因**
旧`camera-control.service`（`camera_control.py`）が同じポート8001を使用しており、
新`api-server.service`と競合していました。

**解決策**
1. `camera-control.service`を`disable`して無効化
2. `update.sh`の再起動処理から旧サービスを除去し、停止+無効化を追加
3. `api_server.py`に`ReusableHTTPServer`（`allow_reuse_address=True`）を導入し、
   TIME_WAITによるポート占有でも起動できるようにした

### 症状: 再起動するとAPモードが維持されない
**原因**
2つの問題がありました：
1. Wi-Fiモード切替時に `wifi_mode` が `camera_settings.json` に保存されていなかった
2. 起動時に保存されたモードを読んで復元するロジックが無かった

**解決策**
1. `api_server.py` の `switch_wifi_mode()` で切替成功時に `wifi_mode`, `ap_ssid`, `ap_password` を `camera_settings.json` に保存
2. `api_server.py` 起動時に `restore_wifi_mode_on_boot()` で保存モードと現在モードを比較し、異なれば自動復元
3. `api-server.service` を `network-online.target` 待ちに変更し、Wi-Fi準備完了後に実行

### 症状: 画質(quality)設定を変えても写真がぼやける / 劣化する
**原因**
`camera_service.py` が撮影後にPILで再保存していたため、JPEG二重圧縮が発生し画質が劣化していました。

**解決策**
撮影前に `camera.options["quality"] = quality` を設定することで、picamera2内部のJPEGエンコーダが
指定品質で直接保存します。タイムスタンプ付与時のみPIL再保存を行います。

> **注意**: `switch_mode_and_capture_file()` は `quality` キーワード引数を受け付けません。
> picamera2では `camera.options["quality"]` を通じてJPEG品質を制御します。
> 誤って引数として渡すと `unexpected keyword argument 'quality'` エラーで撮影が全て失敗します。

### 症状: 同一秒内の連続撮影でファイルが上書きされる
**原因**
ファイル名が `photo_YYYYMMDD_HHMMSS.jpg` で秒単位だったため、同一秒内に2回撮影すると上書き。

**解決策**
マイクロ秒 (`%f`) をファイル名に追加し `photo_YYYYMMDD_HHMMSS_ffffff.jpg` 形式に変更。

### 症状: 手動撮影で `--awb shade` エラー
**原因**
`api_server.py` の手動撮影が `libcamera-still` に `--awb shade` を渡すが、
一部libcameraバージョンでは未対応。

**解決策**
サポート済みAWBモードリストに無い場合は `auto` にフォールバックするよう修正。

### 症状: Capture failed: AwbModeEnum.Shade が無い
**原因**
libcameraのバージョンによって `AwbModeEnum.Shade` が存在せず、
ホワイトバランスが `shade` のときに例外が発生して撮影が失敗します。

**解決策**
`shade` が使えない環境では `Auto` にフォールバックするよう修正しました。

### 症状: フォトエディタでトリミングを選ぶとアプリがフリーズ/クラッシュする
**原因**
`cropControls` 内の X/Y スライダーで、幅・高さが 1.0 のとき `range` が `0...0`（スパン 0）になり、
`step=0.01` が範囲を超えるため SwiftUI の `Slider` がランタイムアサーション失敗を起こしていました。

**解決策**
X/Y スライダーの上限を `max(0.01, 1 - width/height)` で最低 0.01 に保証し、
`step` も `min(0.01, 上限)` に制限して範囲ゼロを防止しました。

### 症状: ギャラリーが重い / 写真削除で -1005 エラー
**原因**
`PhotoThumbnail` がフル解像度画像をキャッシュなし・同時接続制限なしでダウンロードしていたため、
メモリが爆発し URLSession の接続数上限に達して `-1005 (network connection was lost)` が発生していました。
また `liquidGlassStyle`（blur エフェクト）が各サムネイルに適用され、GPU 負荷が高かったです。

**解決策**
1. `ThumbnailCache`（NSCache / 100枚 / 50MB上限）を導入し、ダウンロード済み画像を再利用
2. ダウンロード後に 300px にダウンサンプルしてメモリ使用量を大幅削減
3. 同時ダウンロード数を `DownloadLimiter` actor で制限（最大4本）
4. `liquidGlassStyle` を除去し、軽量な `shadow` に置換
5. Pi側 `/api/photo` にサムネ生成/キャッシュを追加し、サムネ取得は縮小画像を配信（ストリーミング送信でメモリ負荷も低減）

### 症状: フォトエディタの UI が重い
**原因**
操作パネルやプリセットリストに `.ultraThinMaterial`（リアルタイムぼかし）を多用しており、
スライダー操作中に GPU 負荷が高くなっていました。

**解決策**
`.ultraThinMaterial` を `Color(.systemBackground).opacity(0.95)` や
`Color(.secondarySystemBackground)` に置換し、描画コストを削減しました。

### 症状: Pi側の負荷が高い（サムネ取得時にCPU/メモリ/IOが増える）
**原因**
サムネ用途でもフル解像度画像を毎回読み込み・送信していたため、
Pi側で大きな画像データ読み込み/送信が繰り返されていました。

**解決策**
`/api/photo` に `thumbnail` オプションを追加し、Pi側で縮小画像を生成・キャッシュ。
送信はストリーミングに変更してメモリ負荷を低減しました。

### 症状: クラッシュログが確認できない
**原因**
camera-service の異常終了が起きていない場合、エラーログは出力されません。
以下の手順でログを確認し、エラーが出た場合のみ解析対象にします。
```bash
ssh pi@192.168.0.20 "tail -n 120 /home/pi/logs/camera_service.log"
ssh pi@192.168.0.20 "journalctl -u camera-service -p err -n 50 --no-pager"
```
現時点では `ERROR/Traceback` の記録はありません。

---

## 🚀 Wi-Fiモード切替手順

### 基本
- **APモード**: SSID `PiCamera`, PASS `picamera123`（変更可）
  - API: `http://192.168.4.1:8001`
- **テザリング（家Wi-Fi）**:
  - API: `http://raspberrypi.local:8001`

### APモード → 家Wi-Fi (テザリング) 切替
#### アプリから簡単切替（推奨）
1. iPhone を AP (`PiCamera`) に接続
2. 設定タブの NETWORK セクションで HOME WIFI SSID/PASSWORD を入力
3. CONNECT HOME WIFI を押す

#### 手動（curl）
```bash
# 1) SSID/PSK を HTTP 経由で書き込み（SSH不要）
curl -X POST "http://192.168.4.1:8001/api/wifi/write_wpa" \
  -H "Content-Type: application/json" \
  -d '{"ssid":"家のSSID","psk":"パスワード"}'

# 2) テザリングへ切替（レスポンスは即返る）
curl -X POST "http://192.168.4.1:8001/api/wifi/switch" \
  -H "Content-Type: application/json" \
  -d '{"mode":"tethering"}'
```

切替後はWi-Fiが切断されるので、iPhone を家Wi-Fiへ接続し直してから `raspberrypi.local` で再接続します。
テザリング接続に失敗した場合は、自動的にAPへフォールバックします。

### 家Wi-Fi → APモード 切替
```bash
curl -X POST "http://raspberrypi.local:8001/api/wifi/switch" \
  -H "Content-Type: application/json" \
  -d '{"mode":"ap"}'
```

数十秒後に `PiCamera` が復活するので、iPhone を `PiCamera` に接続し直して `192.168.4.1` へ戻ります。

---

## ✅ カメラ4モード 統合テスト（API）

```bash
BASE="http://192.168.4.1:8001" # AP時

curl -sS "$BASE/api/settings"

curl -sS -X POST "$BASE/api/settings" \
   -H 'Content-Type: application/json' \
   -d '{"camera_mode":"reaction"}'
curl -sS "$BASE/api/settings"

curl -sS -X POST "$BASE/api/settings" \
   -H 'Content-Type: application/json' \
   -d '{"camera_mode":"quality"}'
curl -sS "$BASE/api/settings"

curl -sS -X POST "$BASE/api/settings" \
   -H 'Content-Type: application/json' \
   -d '{"camera_mode":"standard"}'
curl -sS "$BASE/api/settings"

curl -sS -X POST "$BASE/api/settings" \
   -H 'Content-Type: application/json' \
   -d '{"camera_mode":"battery"}'
curl -sS "$BASE/api/settings"

curl -sS -X POST "$BASE/api/capture" \
   -H 'Content-Type: application/json' \
   -d '{}'

curl -sS "$BASE/api/photos" | head
```

---

## ✅ 家Wi-Fiでのスマホテスト手順（次の作業）
1. iPhoneを家Wi-Fiに接続
2. アプリを開いて **Refresh** を押す
3. 右上のIP設定が `raspberrypi.local`（または `192.168.0.xx`）に変わることを確認
4. 写真一覧が更新されることを確認
5. **APに戻る場合**
   - NETWORK セクションで `SWITCH TO AP` → `APPLY & RESTART`
   - 数十秒後に `PiCamera` が復活することを確認

### ✅ 家Wi-Fi → AP移行までの最終確認（推奨）
1. 家Wi-Fi接続中に **SWITCH TO AP** → **APPLY & RESTART** を実行
2. iPhone側のWi-Fi一覧に `PiCamera` が出ることを確認
3. iPhoneを `PiCamera` に接続
4. アプリの右上IPが `192.168.4.1` に戻ることを確認
5. 写真一覧が再取得できることを確認
