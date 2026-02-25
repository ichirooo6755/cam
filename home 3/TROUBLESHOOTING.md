# PiCamera Control System v2.0 (省電力版)

Raspberry Pi Zero 2 W + カメラモジュールを使った**光検知自動撮影システム**

## 新システムの特徴

- **省電力設計**: カメラは光検知時のみ起動（CLI化済み）
- **高速反応**: 250ms間隔で光を監視、検知時に即撮影（Zero 2W向け軽量化）
- **ライブビュー不要**: 写真一覧中心のシンプルなiOSアプリ
- **軽量API**: 写真取得とステータス確認のみの最小構成
- **手動モード**: 光検知を停止し、アプリのボタンで撮影

## 要件・条件（ユーザー指定 / 優先）

- Wi-Fi復旧は **APが接続できていても継続** し、再発防止（自動復帰）まで完了させる
- テザリング（家Wi-Fi）に失敗した場合は **自動でAPへ復帰** して復旧できること
- 再起動後も Wi-Fiモード設定が維持され、必要なら起動時に自動復元されること

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

### 症状: IRフィルター無し写真で赤被り（マゼンタ被り）が強い
**原因**
- IRカット無しの撮影では赤/マゼンタ成分が過剰になりやすく、通常のWB調整だけでは追い込みが大変

**解決策**
- `PhotoEditorView` に **IR赤み自動補正**（ON/OFF + 強度）を追加
- 色温度・チャンネルバランス・彩度を複合補正する `applyInfraredAutoCorrection()` を追加
- ワンタップで効く `IR補正プリセット` を追加
- プレビュー長押しで `ORIGINAL` と比較できる比較UIを追加

### 追加: メタデータ拡張（ISO/SS/日時/場所）
- `api_server.py` の `/api/capture` でメタデータに以下を保存
  - `captured_at`（UTC ISO8601）
  - `latitude` / `longitude`（範囲チェック済み）
  - `location_label`（サニタイズ済み）
- iOS側 `CameraAPI.captureWithMetadata()` は `location` ペイロードを送信可能に拡張
- `ContentView` と `PhotoGalleryView` のメタ表示を `DATE` / `LOC` 含む表示へ更新

### 追加: 光検知の一時停止ボタン + ISO/SSクイック操作
- `ContentView` に `LIGHT DETECTION` カードを追加
  - `ACTIVE/PAUSED` 状態表示
  - 1タップで `光検知を一時停止/再開`
- ISO/SSをメニュー選択主体から、チップ選択 + `+/-` ステップ操作へ改善
- ダーク/ライト両方で見やすい背景トーンへ調整（シアン/ティール基調）

### 追加: アプリ外観モード（System / Light / Dark）
- `ContentView` に `APPEARANCE` セクションを追加
- `PiCameraControlApp` で `@AppStorage("appAppearanceMode")` を参照し、
  アプリ全体へ `preferredColorScheme` を適用
- 端末追従（System）と、撮影時に見やすい強制ダーク表示を切替可能

### 症状: APIへ異常な設定値/未知キーを送れてしまう潜在リスク
**原因**
- `/api/settings` が受信キーを広く受け取り、型/範囲チェックも限定的だったため、
  誤った値で設定ファイルが壊れる余地がありました。

**解決策**
- `api_server.py` に設定キーの **ホワイトリスト** を追加
- ISO/SS/quality/threshold/interval/boolean などを **型 + 範囲検証** して不正値を400で拒否
- リクエストJSONサイズ上限（64KB）を追加して過大ボディを拒否

### 症状: 一部POST APIがJSONサイズ制限/検証を通らず、大きなボディや不正JSONで500になる潜在リスク
**原因**
- `/api/metering` / `/api/photo` / `/api/photo/meta` が個別に `Content-Length` を読み取り `json.loads` しており、
  `MAX_JSON_BODY_BYTES` の上限・不正JSON時の400・JSON object強制などが一貫して適用されていませんでした。
- `GET /photos/<filename>` がファイル名検証を行わず、画像をメモリへ丸ごと読み込む実装でした。

**解決策**
- 上記POST APIを `_read_json_body()` に統一し、過大ボディ/不正JSON/非object JSON を 4xx で拒否するように修正
- 写真一覧/写真配信で `SAFE_FILENAME_PATTERN` + `ALLOWED_PHOTO_EXTENSIONS` を適用し、
  `GET /photos/<filename>` はストリーム転送（`shutil.copyfileobj`）へ変更してメモリ消費を抑制

### 症状: APIがAPパスワードを返してしまい、不要な情報露出が発生する潜在リスク
**原因**
- `/api/wifi/status` が保存済みの `ap_password` をレスポンスへ含めていました。
- `/api/settings` が `camera_settings.json` の内容をほぼそのまま返しており、`ap_password` が含まれる可能性がありました。

**解決策**
- APIレスポンスから `ap_password` を除去（内部保存・Wi-Fi切替処理は維持）

### 症状: AP/テザリング切替を連打すると競合し不安定化する潜在リスク
**原因**
- `/api/wifi/switch` が並列要求や短時間連打を防ぐ仕組みを持たず、
  バックグラウンド切替処理同士が競合する余地がありました。

**解決策**
- Wi-Fi切替にロック + クールダウン（12秒）を導入
- 切替中は `409` で拒否し、同一モード要求は即 `200` で no-op 応答
- SSID/PASSWORD の文字/長さ検証を強化
- テザリング切替前に `wpa_supplicant.conf` 存在チェックを追加
- iOS側は非200でもメッセージを復元し、エラー内容をそのまま表示

### 症状: 「APに戻す」操作が成功扱いでも、実際にはAPが復活しないことがある
**原因**
- `/api/wifi/switch` は「現在モードが `ap`」と判定された場合に no-op で早期返却しており、
  実際のAP到達性（`wlan` のAP帯IP）までは検証していませんでした。
- そのため、名目上 `ap` でもAP制御経路が壊れている状態だと、復旧操作が実行されないケースがありました。

**解決策**
- `api_server.py` にモード健全性判定（`_is_mode_operational`）を追加
  - AP: `wlan` のIPv4が `192.168.4.x` / `10.42.0.x` を持つか確認
  - tethering: `check_tethering_connection()` で接続実体を確認
- 同一モード要求でも不健全時は no-op せず、強制再適用へ昇格
- `/api/wifi/switch` に `force: true` を追加（クールダウンをバイパスして復旧を優先）
- 強制AP時は `switch_to_ap_mode()` 失敗後に `ensure_ap_persistence()` を追加試行
- APIサーバに常駐の Wi-Fi watchdog を追加
  - 制御経路断が一定時間継続した場合に AP 強制復旧を自動実行

### 症状: Raspberry Pi が未起動（SDカードとしてMac接続中）のため、SSH配備ができない
**原因**
- Pi本体がネットワーク上に存在しない状態では、`update.sh` による SSH/SCP 配備は実行できません。

**解決策**
- `/Volumes/bootfs/picamera_payload/` を作成し、最新の以下ファイルを配置
  - `api_server.py`
  - `wifi_manager.py`
  - `camera_service.py`
  - `camera-service.service`
  - `api-server.service`
- `/Volumes/bootfs/firstrun.sh` に first boot 適用ブロックを追加
  - 起動時に payload を `/home/pi` と `/etc/systemd/system` へ配置
  - `camera-service` / `api-server` を `daemon-reload` 後に有効化・再起動
  - `/home/pi/camera_settings.json` を補正し、`wifi_mode=ap`（未設定時は `PiCamera` / `picamera123`）を明示保存
- `cmdline.txt` の `systemd.run=/boot/firstrun.sh` が有効であることを確認

### 屋外運用の安全性チェック（現状評価）
- ✅ デフォルトURL検証（ローカルアドレス制限）やファイル名サニタイズは実装済み
- ✅ APパスワードが初期値のときにアプリ内で警告表示を追加
- ⚠ APIはローカルネットワーク内で認証無しのため、外部運用時はAPパスワードを必ず強固化すること
- ⚠ 位置情報メタデータを使う場合はプライバシー配慮（必要時のみ許可）

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

### 症状: iOSアプリのビルドが失敗する（LAST CAPTURE の META 表示）
**原因**
`ContentView.swift` の `Text("META: ...")` の文字列内で **余分な括弧** が入っており、Swift の構文エラーになっていました。

**解決策**
余分な括弧を削除し、`Text("META: \( ... )")` の形に修正しました。

### 症状: ギャラリーの写真詳細で画像が表示されない場合がある（メタ取得失敗時）
**原因**
画像取得とメタデータ取得を同じ `do/catch` で扱っていたため、メタデータ取得が失敗すると画像も表示されない可能性がありました。

**解決策**
画像は先に表示し、メタデータ取得は失敗しても無視（後追いで反映）するように変更しました。

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
複数の要因が重なりました：
1. Wi-Fiモード切替時に `wifi_mode` が `camera_settings.json` に保存されていなかった
2. 起動時に保存されたモードを読んで復元するロジックが無かった
3. NetworkManagerの `Hotspot` が `autoconnect=no` のままだと、再起動後にホットスポットが自動復帰しないことがある
4. `api-server.service` が `network-online.target` 待ちだと、ネットワーク確立が詰まった状態でAPIサーバー起動が遅れ、復元処理が走りにくい
5. `NetworkManager` が `disable` のまま、`dhcpcd` が `enable` の構成だと、AP起動の前提（NetworkManager常駐）が崩れたり、インターフェース管理が競合して不安定になる

**解決策**
1. `api_server.py` の `switch_wifi_mode()` で切替成功時に `wifi_mode`, `ap_ssid`, `ap_password` を `camera_settings.json` に保存
2. `api_server.py` 起動時に `restore_wifi_mode_on_boot()` で保存モードと現在モードを比較し、異なれば自動復元
3. `wifi_manager.py` のAP切替で `nmcli networking on` / `nmcli radio wifi on` / `Hotspot autoconnect=yes` / 省電力OFF を明示設定
4. `api-server.service` は `network.target` 待ちにして、Wi-Fi復元処理を確実に起動させる（ネットワークが未確立でも復旧処理が走る）
5. APモードでは `NetworkManager` を `enable`、`dhcpcd` を `disable` に固定し、テザリング（レガシー）では逆にする

### 症状: APが突然出ない / 起動が不安定（EXT4 recovery required）
**原因**
起動ログに `EXT4-fs (mmcblk0p2): INFO: recovery required on readonly filesystem` が出ている場合、
電源断/低電圧/不適切なシャットダウン等でファイルシステムのジャーナル回復が走っています。
この状態が続くと設定ファイルの読み書き・サービス起動などが不安定になり、Wi-Fi/AP復旧にも悪影響が出ます。

**解決策**
- 5V/2A以上の安定電源（ケーブル含む）を使用
- 可能な限り `sudo shutdown -h now` を実施（強制電源断を避ける）
- 症状が継続する場合は、SDカードのチェック/交換、もしくは再イメージを検討

### 症状: 起動ログに `brcmfmac ... clm_blob failed (-2)` が出る
**原因**
`/lib/firmware/brcm/brcmfmac43436s-sdio.clm_blob` を要求するが、実体が `brcmfmac43436-sdio.clm_blob` のみで
ファイル名が一致していません（-2 = ファイル無し）。その結果
`device may have limited channels available` になり、APのチャンネル選択が制限される可能性があります。

**解決策**
ファイル名の差を吸収するため、シンボリックリンクを作成します（次回起動から反映）。
```bash
ssh pi@192.168.4.1 "sudo ln -sf /lib/firmware/brcm/brcmfmac43436-sdio.clm_blob /lib/firmware/brcm/brcmfmac43436s-sdio.clm_blob"
```

### 症状: 起動ログに `cfg80211: loaded regulatory.db is malformed or signature is missing/invalid` が出る
**原因**
regulatory database の署名検証まわりの互換性で警告が出ることがあります。
即致命的でない場合もありますが、チャンネル制限や初期化の不安定化と関連する可能性があります。

**解決策**
- 現状は `cfg80211.ieee80211_regdom=JP`（kernel cmdline）で国コード指定して運用
- 改善が必要なら `wireless-regdb` / OS更新で改善することがあります

### 症状: `nmcli` では powersave disable なのに `iw` の PowerSave が ON のままになる
**原因**
NetworkManagerの接続プロファイル設定（`802-11-wireless.powersave=2`）と、ドライバの `iw` power_save が
別系統で、起動直後は `iw` がONのまま残ることがあります。

**解決策**
`wifi_manager.py` で
- `nmcli connection modify Hotspot 802-11-wireless.powersave 2`
- `iw dev wlan0 set power_save off`
を併用して確実にOFFにします。

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

### 症状: reactionモードでも検知→撮影が遅い
**原因**
撮影時に `switch_mode_and_capture_file()` を毎回呼んでおり、
モード切替のオーバーヘッドで反応が遅れていました。

**解決策**
既に still 設定で起動している場合は `capture_file()` を使い、
必要な時だけ `switch_mode_and_capture_file()` にフォールバックするよう修正しました。

### 症状: ISO/シャッター(SS)を指定しても露出が明るすぎる
**原因**
ISO/SSを手動指定しても自動露出(AE)が有効のままで、
カメラが明るさを自動で持ち上げていました。

**解決策**
ISO/SSが手動指定のときは `AeEnable = False` にして自動露出を無効化し、
autoに戻した場合のみAEを再有効化するよう修正しました。

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

### write_wpa がタイムアウトする場合（APモード中）
- **症状**
  - `curl` が応答なし（タイムアウト）になる
  - 直後に `PiCamera` のAPが一時的に消える
- **原因**
  - `wpa_supplicant.conf` 更新処理で `wpa_supplicant/dhcpcd` を再起動してしまい、`NetworkManager` の Hotspot と競合してAPが落ちる
- **対策**
  - APモード（`NetworkManager` 稼働中）は **ファイル更新のみ** 実施し、サービス再起動は **テザリング切替時** に行う

### 症状: テザリング切替後に接続が不安定 / APへフォールバックしてしまう
**原因**
- APモード時のIP（`192.168.4.x` / `10.42.0.x`）がインターフェースに残ったままになり、テザリング接続チェックが失敗扱いになることがある
- `wpa_supplicant` の制御ソケット状態が不安定なまま `wpa_cli reconfigure/reconnect` を実行し、`FAIL` になることがある
- 切替直後に Wi‑Fi の power save が有効だとリンクが不安定になることがある

**解決策**
- テザリング切替時に Wi‑Fi インターフェース（例: `wlan0`）のIPv4を flush してから link down/up → DHCP 再要求
- `wpa_supplicant@<iface>` を優先して restart（失敗時は `wpa_supplicant` を restart）し、制御ソケットを作り直す
- テザリング切替でも `iw dev <iface> set power_save off` を実行
- IP取得は `hostname -I` の先頭ではなく、Wi‑Fi インターフェースのIPv4を優先して判定/表示する

### 症状: Pi Zero 2W で連続撮影が発生しフリーズ / SD満杯になる
**原因**
- `capture_cooldown` が 0.25秒で、Pi Zero 2W の JPEG保存時間（1-3秒）より短かった
- 1分あたりの撮影上限がなく、光がチラつく環境で無限に撮影が続いた
- `_compose_images()` が numpy float32 で12MP画像合成を行い、150MB+ メモリ消費（512MB の30%）
- `apply_focus_peaking()` がフル解像度配列に scipy Sobel を実行、OOM 必至
- PIL/ImageDraw/ImageFont のインポートと多重露光ロジックが不要なまま残存
- カメラ制御 `_apply_camera_controls()` が設定変更なしでも毎撮影時に呼ばれていた

**解決策**
- `camera_service.py` を Pi Zero 2W 最適化版に全面刷新:
  - `MIN_CAPTURE_COOLDOWN = 2.0秒`（設定値がこれ以下でも強制適用）
  - `MAX_CAPTURES_PER_MINUTE = 10枚` のハードレートリミット追加
  - `CHECK_INTERVAL` を 0.25秒→0.5秒に変更（CPU負荷半減）
  - `SETTINGS_RELOAD_INTERVAL` / `SENSOR_STATUS_WRITE_INTERVAL` を2秒に拡大
  - `_compose_images()` / `apply_focus_peaking()` / 多重露光ロジック / PIL import を完全削除
  - `_apply_camera_controls()` は設定リロード時に1回だけ適用（`controls_applied` フラグ）
  - lores サイズを統一 `(160, 120)` に縮小（光検知用途に十分）
  - `get_sensor_sample()` の lores 配列計算を1チャンネルのみに軽量化

### 症状: camera-service が起動直後にクラッシュし続ける（restart counter 33505）/ 写真が一切撮影されない
**原因**
- `camera_service.py` の `_add_timestamp()` 関数定義行 (`def ...`) をコメントアウトした際、関数本体のインデントされたコードがそのまま残留していた
- このコードが `write_sensor_status()` 関数の末尾に紛れ込み、`write_sensor_status()` が呼ばれるたびに `NameError: name 'image' is not defined` で即クラッシュ
- systemd の自動再起動で延々クラッシュ→再起動が繰り返され、restart counter が 33505 に到達
- 結果として光検知ループが一度も実行されず、写真が一切撮影されない状態が続いていた

**解決策**
- コメントアウトされた `_add_timestamp` の残留コード本体（`if ImageDraw is None:` 〜 `return image`）を完全に削除
- `load_settings()` 内の毎秒出力されていた `Auto-adjusted quality` ログを削除（ログスパム解消）
- デプロイ後に `camera-service` が正常起動し、撮影APIで写真保存を確認

### 症状: Pi に接続できないのにアプリが「オフライン」を表示しない / 撮った写真が見れない
**原因**
- アプリにグローバルな接続監視が無く、各タブが独立して接続チェックしていた
- `ContentView`（設定タブ）の `loadAllSettings()` 失敗時のみ `errorMessage = "Offline"` を設定する設計で、ギャラリータブ・ステータスタブには常設のオフラインインジケータが存在しなかった
- 定期的な接続チェック（ポーリング）が無いため、接続が切れても即座に反映されなかった
- ギャラリーの写真サムネイルはサーバーから都度取得する設計で、Pi 未到達時はブランク表示になっていた
- サムネイルの Core Data キャッシュ保存が未実装だったため、一度表示した写真もオフライン時に再表示不可だった

**解決策**
- `ConnectionMonitor.swift` を新規追加: 5秒間隔で Pi の `/api/status` をチェックし、`isConnected` をグローバル共有
- `PiCameraControlApp.swift` で `ConnectionMonitor` を `@StateObject` として起動し、`.environmentObject()` で全タブに注入
- 全タブ共通のオフラインバナー `OfflineBannerView` を `TabView` 上部にオーバーレイ表示（赤→オレンジのグラデーション、再チェックボタン付き）
- `UnifiedGalleryView` の空状態表示を接続状態に応じて切替（オフライン時は `wifi.slash` アイコン + 「Pi に接続できません」表示）
- `PhotoCell.loadFromServer()` でダウンロード成功時に `thumbnailData` を Core Data にキャッシュ保存（次回オフラインでも表示可能）
- `preferredColorScheme(.light)` のハードコードを `computedColorScheme`（`appAppearanceMode` 連動）に修正

### 症状: テザリング切替の途中失敗で AP に戻らず Pi が無通信になる
**原因**
- `switch_to_tethering_mode()` の途中（`wpa_supplicant restart` / `wpa_cli reconfigure` / `wpa_cli reconnect`）で失敗した場合、失敗レスポンスを返して終了し、APフォールバックが未実行になる経路があった
- この経路では `NetworkManager` 停止後に復旧処理が打ち切られるため、AP未復帰のまま到達不能になる可能性があった

**解決策**
- `wifi_manager.py` の `switch_to_tethering_mode()` に `_fail_with_ap_fallback()` を導入し、途中失敗時も必ず AP 復帰を試行
- 失敗時フォールバック後に `_save_wifi_settings('ap', ...)` を実行し、次回起動時の復元方向も AP 側へ一致させる

### 症状: AP/テザリング切替で `iw` / `wpa_cli` が見つからず復旧が不安定になる
**原因**
- `sudo -n` や systemd 実行時は PATH が最小化されるため、環境によって `iw` / `wpa_cli` が解決できない
- その結果、`power_save off` や `wpa_cli reconfigure/reconnect` が失敗し、切替直後の安定化処理が抜ける

**解決策**
- `wifi_manager.py` に `_resolve_executable()` を追加し、`/usr/sbin`, `/sbin`, `/usr/bin`, `/bin` を含めて実体パスを探索
- `_detect_wifi_interface()` / `_run_wpa_cli()` / `_run_wpa_cli_readonly()` / AP・テザリング切替の `iw` 呼び出しを解決済み実行ファイルに統一

### 症状: テザリング→AP切替のレスポンス成功後に AP が復帰せず再接続不能になる
**原因**
- `switch_to_ap_mode()` が `nmcli hotspot` 実行後の即時成功を返し、`Hotspot` の active 状態と AP 用 IP 帯 (`192.168.4.x` / `10.42.0.x`) の実体確認が不足していた
- 一部環境で `wpa_supplicant`（汎用ユニット）が残存し、AP 起動時にインターフェース競合が発生する余地があった

**解決策**
- `switch_to_ap_mode()` / `ensure_ap_persistence()` で `wpa_supplicant@<iface>` だけでなく `wpa_supplicant` も stop+disable して競合を抑止
- `wifi_manager.py` に `_is_hotspot_active()` と `_wait_for_ap_ready()` を追加し、`Hotspot` が active かつ AP IP 帯が付与されるまで待機
- AP 準備確認に失敗した場合は `nmcli connection up Hotspot` を再試行し、再確認後に失敗を返すよう変更（成功偽装を防止）

### 症状: デプロイ直後に Pi が到達不能になる（起動時Wi-Fi復元が即時発火）
**原因**
- `home 3/update.sh` は再起動前に `/run/picamera_boot_network_applied` を作成しているが、`api_server.py` 側でこのマーカーを消費していなかった
- そのため `api-server` 再起動のたびに `restore_wifi_mode_on_boot()` が即時実行され、保存済みモードへの切替が走って接続中ネットワークが切断される場合があった

**解決策**
- `api_server.py` に `BOOT_NETWORK_APPLIED_MARKERS`（`/run` と `/tmp`）と `_consume_boot_network_applied_marker()` を追加
- `main()` 起動時にマーカーがあれば 1 回だけ復元をスキップし、マーカーを削除して通常動作へ戻す
- マーカー削除で `PermissionError` が出る環境向けに `sudo -n rm -f` フォールバックを追加
- これにより「デプロイ直後だけは現在の到達経路を維持」し、次回以降の通常起動では従来どおり復元ロジックを有効化

### 症状: 家Wi-Fi→AP切替が途中失敗すると Pi が無通信になる
**原因**
- `switch_to_ap_mode()` は切替冒頭で `dhcpcd` / `wpa_supplicant` を停止し、`NetworkManager` 側へ寄せる設計だが、
  `NetworkManager` 起動失敗・`nmcli hotspot` 失敗・AP準備確認失敗時に **失敗レスポンスのみ** を返して終了する経路があった
- この経路では AP もテザリングも未成立の中間状態で復旧が打ち切られ、到達不能になり得た

**解決策**
- `wifi_manager.py` の `switch_to_ap_mode()` に `_fail_with_tethering_recovery()` を追加し、途中失敗時は
  `switch_to_tethering_mode(allow_ap_fallback=False)` でクライアント接続の復旧を即時試行するよう変更
- `switch_to_tethering_mode()` に `allow_ap_fallback` 引数を追加し、AP失敗復旧時はAP再帰フォールバックを抑止して
  ループを防止

### 症状: AP切替失敗後にテザリング復旧も失敗すると最終復旧先がなくなる
**原因**
- AP切替失敗時はまずテザリング復旧を試みるが、周辺Wi-Fi環境不良でテザリング復旧も失敗した場合、
  そのまま失敗レスポンスを返して終わるため最終到達経路が確保されない場合があった

**解決策**
- `switch_to_ap_mode()` の `_fail_with_tethering_recovery()` で、テザリング復旧失敗時に
  `ensure_ap_persistence(allow_recursive_ap_recovery=False)` を追加実行する第3段復旧を実装
- `ensure_ap_persistence()` を拡張し、`Hotspot` プロファイル欠損時は保存済み SSID/PASS で再作成し、
  `connection up` 失敗時も `device wifi hotspot` で再生成して AP 再起動を試行
- これにより「AP失敗→テザリング失敗」の連続失敗時も AP 復旧経路を残す

### 症状: 再起動後に AP へ戻らず、家Wi-Fi側のままになる
**原因**
- AP切替要求中に `switch_to_ap_mode()` が途中失敗すると、保険としてテザリング復旧を試す設計になっている
- その復旧が成功した場合、これまでは `wifi_mode=tethering` を保存していたため、再起動時の `restore_wifi_mode_on_boot()` が AP 再試行を行わず、
  結果として AP SSID が再掲出されないケースが発生していた

**解決策**
- `switch_to_ap_mode()` の失敗復旧経路で、テザリング復旧成功時でも保存モードを `ap`（要求意図）として保持するよう修正
- これにより再起動時に AP 復元ロジックが有効になり、AP再試行へ入る

### 症状: Mac側で同一サブネットを複数NICが保持すると Pi 探索を誤る
**原因**
- Macで `en0`（Wi-Fi）と `en11`（USB LAN 等）が同時に `192.168.0.0/24` を保持していると、
  宛先 `192.168.0.20` の経路が意図しないIF（今回 `en11`）へ吸われることがある
- この状態では `curl --interface en0 ...` を付けても ARP/経路判断との不整合で到達判定が不安定になり、
  Pi未到達時の切り分けが難しくなる

**解決策**
- `home 3/wifi_cycle_test.sh` に Wi-Fi IF自動検出（`networksetup`）を追加し、未指定時は `AP_INTERFACE/HOME_INTERFACE` を自動補完
- `route -n get <HOME_IP>` を確認して、要求IFと実経路IFが不一致なら警告ログを出す処理を追加
- `HOME_HOST`/`HOME_IP` が不達でも、`fping` で同一サブネットを走査して `/api/wifi/status` 応答ホストを動的発見するフォールバックを追加
- `HOME_MAC`（既定: `88-A2-9E-40-1E-B4`）を使った ARP ベース探索を追加し、DHCP再割当でIPが変わっても Home 側ホスト発見を試行
- `curl --interface <IF>` で失敗した場合に、`/api/wifi/status` / `/api/wifi/switch` を IF未指定（OSルーティング）で再試行するフォールバックを追加

### 追加: センサーステータスAPI + 測光提案API（iOS連携）
- `camera_service.py`:
  - `/home/pi/sensor_status.json` を 1秒周期で更新
  - `brightness/lux/ae_gain/ae_exposure_us/last_change_percent/last_detect_to_capture_ms` を出力
- `api_server.py`:
  - `GET /api/sensor/status` を追加（実行時センサー状態 + 有効設定）
  - `POST /api/metering` を追加（現在露出を基準に ISO/SS の提案値を返却）
- iOS (`ContentView`):
  - `SENSOR STATUS` パネルを追加
  - `測光` ボタンで提案値を取得し、`提案をISO/SSに適用` で一時設定として反映

API例:
```bash
BASE="http://192.168.4.1:8001"

curl -sS "$BASE/api/sensor/status"

curl -sS -X POST "$BASE/api/metering" \
  -H "Content-Type: application/json" \
  -d '{}'

curl -sS -X POST "$BASE/api/metering" \
  -H "Content-Type: application/json" \
  -d '{"target_iso":400}'
```

### 追加: Wi-Fi切替の自動サイクル試験スクリプト
- 追加ファイル: `home 3/wifi_cycle_test.sh`
- 目的: `AP -> tethering -> AP` の連続切替を API で自動実行し、`/api/wifi/status` 到達性を検証
- 挙動:
  - 開始時に AP 側 (`192.168.4.1`) を先に確認
  - AP が不可なら Home 側 (`raspberrypi.local` / `192.168.0.20`) を確認し、まず AP へ戻してからサイクル開始
  - 各サイクル末尾で `GET /api/sensor/status` と `POST /api/metering` も疎通確認

実行例:
```bash
# 1サイクル実行（既定ホスト）
bash "home 3/wifi_cycle_test.sh" 1

# 待機時間を短縮して試験
AP_WAIT_SEC=20 HOME_WAIT_SEC=20 STEP_WAIT_SEC=2 \
  bash "home 3/wifi_cycle_test.sh" 1

# 必要に応じてIFを固定（デュアルNIC環境向け）
AP_INTERFACE=en0 HOME_INTERFACE=en0 \
  bash "home 3/wifi_cycle_test.sh" 2

# AP復旧を毎回強制して検証（既定値 FORCE_AP_SWITCH=1）
FORCE_AP_SWITCH=1 AP_INTERFACE=en0 HOME_INTERFACE=en0 \
  bash "home 3/wifi_cycle_test.sh" 1
```

---

## 作業ログ

- 2026-02-25 10:48 JST
  - 問題1: Swap 100%枯渇 (99MB/99MB使用、空き0KB)
    - RAM 419MBのPi Zero 2Wでデスクトップ環境(Xorg, lxpanel, pcmanfm)が
      メモリを消費。OOM Killは未発生だがパフォーマンス低下・WiFi不安定の潜在原因。
  - 修正1: Swap 100MB→512MBに拡大 (`/etc/dphys-swapfile`)
  - 修正2: 不要サービス無効化（ヘッドレスサーバー化）
    - `lightdm` (デスクトップ), `bluetooth`, `cups` (プリンタ),
      `avahi-daemon`, `ModemManager`, `triggerhappy` を disable
    - `systemctl set-default multi-user.target` でGUI起動を無効化
  - 改善結果:
    - メモリ: used 160Mi→134Mi, free 81Mi→96Mi, available 202Mi→227Mi
    - Swap: 99Mi/99Mi(100%)→0B/511Mi(0%) — 完全に解放
  - 問題2: dmesgに `brcmf_vif_set_mgmt_ie: vndr ie set error : -52` が複数
    - Pi Zero 2WのBroadcom WiFiチップの既知の無害な警告（AP起動時の一時的なエラー）
    - 実際のAP動作には影響なし
  - 問題3: `plymouth-start.service` が failed
    - ブートスプラッシュ画面のサービス。ヘッドレス運用では不要・無害。
  - 問題4: bluetoothd SAP/privacy エラー
    - Bluetooth無効化で解消済み
  - 実行コマンド:
    - `sudo systemctl set-default multi-user.target`
    - `sudo systemctl disable --now lightdm bluetooth cups avahi-daemon ModemManager triggerhappy`
    - `sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile`
    - `sudo systemctl restart dphys-swapfile`

- 2026-02-25 10:30 JST
  - 問題: camera-serviceが「Camera(s) not found」で4088回クラッシュ→リスタートの無限ループ
  - 根本原因: `Picamera2()` 初期化でRuntimeError発生時にmain()が即終了し、
    systemdの `Restart=always` (10秒間隔) で無限リスタート。CPU・ログ帯域を無駄に消費。
    カメラハードウェア自体はCSIケーブル接続不良または物理的問題で未検出。
  - 修正: `camera_service.py` のカメラ初期化を try/except で捕捉し、
    指数バックオフリトライ（10s→20s→40s→...最大120s）でプロセス内リトライに変更。
    プロセスが生存したまま `sensor_state['state'] = 'camera_unavailable'` を書き込み、
    カメラ復帰時に自動的に初期化を完了する。
  - 変更ファイル: `home 3/camera_service.py`
  - 確認結果:
    - デプロイ後 NRestarts=0（以前は4088回）
    - プロセス生存・指数バックオフ確認: 10s→20s→40s
    - api-serverログにエラーなし、WiFi watchdog正常稼働
  - ハードウェア診断:
    - `libcamera-hello --list-cameras` → No cameras available
    - `vcgencmd get_camera` → supported=0 detected=0
    - CSIケーブル接続・カメラモジュールの物理確認が必要

- 2026-02-24 13:55 JST
  - 問題1: SS 1/1000s が適用できない（1/250はOK）
  - 根本原因1: `api_server.py` の `_sanitize_settings_patch` でシャッタースピードの下限が `2500μs` (=1/400)
    → 1/1000(1000μs), 1/2000(500μs), 1/4000(250μs), 1/8000(125μs) が全てバリデーションエラーでリジェクト
  - 修正1: 下限を `100μs` に変更、上限も `120_000_000μs` (120秒長時間露光対応) に拡大
  - 問題2: 光を検知するとWiFiが切断される（Piが完全に到達不能になる）
  - 根本原因2:
    1. Pi Zero 2W で撮影時のCPUスパイク（JPEG 12.3MP エンコード）がWiFi APプロセスを飢餓状態にし、
       ビーコンフレームが送出できなくなりiOSが切断される
    2. WiFi recovery watchdog が APモード時に `continue` でスキップしていたため、
       撮影でAPが壊れても復旧メカニズムが一切動作しなかった
  - 修正2:
    - `camera_service.py`: `os.nice(10)` でプロセス優先度を下げ、WiFiプロセスにCPU時間を確保
    - `camera_service.py`: 撮影後 `time.sleep(0.15)` でCPU明示的yield
    - `api_server.py`: WiFi watchdog をAPモード時にも `_is_ap_healthy()` で10秒毎にチェックするよう改修
      → AP不健全が15秒以上続くと `ensure_ap_persistence()` で自動復旧
  - 変更ファイル:
    - `home 3/api_server.py` (SS バリデーション + watchdog AP監視)
    - `home 3/camera_service.py` (nice + CPU yield)
  - 実行コマンド:
    - `python3 -m py_compile` 全ファイル成功
    - `git push` dd4f368
  - 確認結果:
    - デプロイ前: Piが光検知→撮影でWiFi AP完全ダウン（ping 100% loss）
    - デプロイ後 (2026-02-24 15:00 JST):
      - 両サービス active (camera-service, api-server)
      - camera_service の nice=10 適用確認済み
      - WiFi watchdog AP監視ログ確認済み
      - SS 1/1000(1000μs) → success ✅
      - SS 1/2000(500μs) → success ✅
      - SS 1/4000(250μs) → success ✅
      - SS 1/8000(125μs) → success ✅
      - SS auto → success ✅
      - WiFi status: AP mode, SSID=PiCamera, IP=192.168.4.1 ✅
      - Sensor: state=monitoring, lux=0.611 ✅
      - Settings fetch/update 正常 ✅
    - iOS側修正:
      - ConnectionMonitor NWPathMonitorリーク修正 → BUILD SUCCEEDED
      - ContentView デッドコード削除 → BUILD SUCCEEDED
    - git push: f110d09

- 2026-02-23 22:57 JST
  - 問題: SSHがタイムアウトする（WiFiに繋がっているのにPiに接続できない）
  - 根本原因:
    1. `ensure_ap_persistence()` がAPが正常動作中でも全ネットワークを破壊→再構築していた
       - `ip addr flush dev wlan0` で全IPアドレスを削除
       - `ip link set wlan0 down` でインターフェースをDOWN
       - この間（30〜60秒）SSH/API接続が全て切断される
    2. `restore_wifi_mode_on_boot()` が起動毎に上記を呼び出していた
       - `saved_mode=ap, current_mode=ap` でもensure_ap_persistence()を実行
       - APが既に正常動作中でも不要な破壊→再構築が走る
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `_is_ap_healthy()` 追加: Hotspotがアクティブ+AP IPが割り当て済みかを非破壊的にチェック
      - `ensure_ap_persistence()` 書き換え:
        - フェーズ1: APが正常なら軽量調整のみ（powersave OFF + 不要サービス停止）→接続を切断しない
        - フェーズ2: APが壊れている場合のみフル再構築（旧ロジック）
      - `switch_to_ap_mode()`: Hotspotプロファイル再利用（delete→recreate廃止）
    - `home 3/api_server.py`
      - `restore_wifi_mode_on_boot()` 改善:
        - まず`_is_ap_healthy()`で健全性チェック
        - APが正常動作中ならpowersave OFFのみ適用して即return（SSH切断なし）
        - APが不健全な場合のみensure_ap_persistence()呼び出し
  - 実行コマンド:
    - `python3 -m py_compile` 全ファイル成功
    - `bash update.sh 192.168.4.1` デプロイ成功
  - 確認結果:
    - デプロイ後: API応答OK、SSH接続OK、WiFi AP正常動作
    - ログ: `Skip boot Wi-Fi restore once: deployment marker consumed`（デプロイ直後のWiFi不要切替スキップ確認）

- 2026-02-23 22:36 JST
  - 問題: WiFi頻繁切断、タイムアウト、パスワード拒否、スリープ切断、OFFLINEバナー被り、撮影フィードバック不足
  - 根本原因分析:
    1. ConnectionMonitorにNWPathMonitor未使用→ネットワーク変化をリアルタイム検知不可
    2. scenePhase未監視→スリープ復帰時にTimer停止のまま
    3. Hotspotプロファイルを毎回delete→recreate→iOSのパスワードキャッシュが壊れる
    4. APIにリトライロジックなし→一時的な接続不安定で即失敗
    5. OfflineBannerがZStack+ignoresSafeAreaで旧デザインと被る
  - 変更ファイル:
    - `PiCameraControl/PiCameraControl/ConnectionMonitor.swift`
      - 全面書き換え: NWPathMonitor追加（ネットワーク変化即検知）
      - handleForegroundReturn() / handleBackgroundEntry() 追加
      - デバウンス（1秒以内の連続チェック抑制）
      - consecutiveFailures カウンター追加
      - 切断時は2秒間隔の高速ポーリング、接続時は5秒間隔
    - `PiCameraControl/PiCameraControl/PiCameraControlApp.swift`
      - @Environment(\.scenePhase) 追加→.active時にhandleForegroundReturn()
      - OfflineBannerをZStackからsafeAreaInset(edge: .top)に変更→被り解消
      - OfflineBannerViewをシンプル化（失敗回数表示追加）
    - `PiCameraControl/PiCameraControl/CameraAPI.swift`
      - withRetry() ヘルパー追加（最大1回リトライ、1秒間隔）
      - fetchSettings() をwithRetryでラップ
    - `PiCameraControl/PiCameraControl/SimpleCameraAPI.swift`
      - withRetry() ヘルパー追加
      - fetchPhotos() / fetchStatus() をwithRetryでラップ
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - captureToast State追加→撮影成功/失敗をカプセル型トーストで表示
      - capturePhoto()にHaptic Feedback追加（成功:ブルッ/失敗:ブブッ）
      - トースト3秒後に自動消去
    - `home 3/wifi_manager.py`
      - switch_to_ap_mode(): Hotspotプロファイルを再利用（delete→recreateを廃止）
      - 既存プロファイルがあればmodifyのみ、なければ新規作成
      - ap-isolation=no 追加（iOS向けDTIM最適化）
      - powersave=2(OFF)を全パスで強制
  - 実行コマンド:
    - `xcodebuild build` BUILD SUCCEEDED
    - `python3 -m py_compile` 全ファイル成功
  - 確認結果:
    - iOS: BUILD SUCCEEDED
    - Pi: SSH接続不可のためデプロイ保留（Piが起動したら `bash update.sh 192.168.4.1` で適用）

- 2026-02-23 02:58 JST
  - 変更ファイル:
    - `PiCameraControl/PiCameraControl/Models.swift`
      - SS 1/8000 (125μs) 追加（HQ カメラ IMX477 は最速 13μs まで対応）
      - `CameraModeOption` に `icon` / `subtitle` プロパティ追加（UI改善用）
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - モード選択UI改善: アイコン+サブタイトル付きコンパクトボタンに変更
      - SS選択UI改善: HIGH SPEED / STANDARD / LONG EXPOSURE のカテゴリ分割表示
      - ISO/SS の現在値表示をモノスペースボールドに統一
      - `capturePhoto()` に `ImageCompositor` 接続:
        - 多重露光ON → 2枚撮影して iPhone 側で blend/additive 合成
        - 2-in-1 ON → 2枚撮影して横並び合成
        - タイムスタンプON → iPhone 側でオーバーレイ
      - `shutterOptions` フィルター: 非手動モードでは20s超のみ非表示に変更
    - `PiCameraControl/PiCameraControl/ImageCompositor.swift`
      - `CIContext` の `guard let` バグ修正（non-optional を optional binding していた）
    - `PiCameraControl/PiCameraControl.xcodeproj/project.pbxproj`
      - `ImageCompositor.swift` / `Nikon35TiComponents.swift` / `JonyIveDesignSystem.swift` / `PhotoPickerView.swift` をプロジェクトに追加（ビルドソースフェーズ含む）
  - 実行コマンド:
    - `xcodebuild build` BUILD SUCCEEDED
    - `python3 -m py_compile` 全ファイル成功
    - `bash update.sh 192.168.4.1` 成功
    - 撮影テスト成功
  - 確認結果:
    - 全機能正常動作、NRestarts=0
    - 多重露光/2in1/タイムスタンプが iPhone 側 ImageCompositor で処理されるようになった
    - SS 1/8000〜120s がカテゴリ分割で見やすくなった

- 2026-02-23 02:50 JST
  - 変更ファイル:
    - `home 3/camera_service.py`
      - `twilight` モード削除 → `night` に統一（実質同一プロファイルだった）
    - `home 3/api_server.py`
      - `CAMERA_MODE_PRESETS` を Pi Zero 2W 安全値に全面更新 + `night` プリセット追加
      - 古い `check_interval: 0.02` / `capture_cooldown: 0.1` 等の危険値を修正
      - `enable_multiple_exposure` / `enable_2in1_composition` / `enable_timestamp` をプリセットから除去（Pi側で未使用）
      - `METERING_ISO_STOPS` に ISO 6400 追加
      - エラーメッセージに `night` を追記
    - `PiCameraControl/PiCameraControl/Models.swift`
      - `CameraModeOption` に `.night` 追加（`twilight` 廃止）
      - `ISOOption` に `.iso6400` 追加（HQ カメラ ISO 100-16000 対応）
      - `ShutterSpeedOption` に `.ss4000` (1/4000), `.ss2000` (1/2000), `.ss1000` (1/1000) 追加（HQ カメラ 13μs-670s 対応）
      - `CameraSettings` デフォルト値修正: quality=90, 1920x1080, captureCooldown=3.0
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - `shutterOptions` フィルター修正: 旧 `ss400` 除外 → 20s超の長時間露光のみ制限
      - `qualityDescriptionForMode` に `.night` case 追加
  - 実行コマンド:
    - `python3 -m py_compile` 全ファイル成功
    - `xcodebuild build` BUILD SUCCEEDED
    - `bash update.sh 192.168.4.1`（成功 × 2回）
    - night モード切替 + 撮影テスト: `check=0.5, cooldown=3.0, quality=95` 確認
  - 確認結果:
    - 全モード（reaction/standard/quality/night/battery/manual/raw）正常切替・撮影可能
    - ISO 6400 / SS 1/4000 が HQ カメラで設定可能に
    - 電源断→自動復帰: systemd `Restart=always` + `WantedBy=multi-user.target` で保証

- 2026-02-23 02:46 JST
  - 変更ファイル:
    - `home 3/camera_service.py`
      - **モード別パフォーマンスプロファイル導入** — `MODE_PROFILES` で各モードの check_interval / min_cooldown / max_per_minute / lores_size / quality / denoise_override を定義
        - reaction: 100ms ポーリング、0.5s クールダウン、24枚/分、quality=70、denoise=off（最速）
        - standard/manual: 200ms ポーリング、1.5s クールダウン、15枚/分
        - quality/twilight/night: 500ms ポーリング、3.0s クールダウン、cdn_hq
        - raw: 5.0s クールダウン（DNG大ファイル書込み対応）
        - battery: 1.0s ポーリング、5.0s クールダウン、6枚/分
      - lores_size を `(80,60)` → `(128,96)` に修正（IMX477 HQ カメラで小さすぎるサイズがクラッシュ原因）
      - JPEG品質をプロファイルから設定リロード時に1回だけ適用（毎撮影時の再設定を廃止）
      - `_active_max_per_minute` でモード別レートリミットを動的適用
    - `PiCameraControl/PiCameraControl/PiCameraControlApp.swift`
      - ステータスタブ（CameraStatusView）を TabView から削除（ギャラリー＋設定の2タブ構成に）
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - フォーカスピーキング残骸（`enableFocusPeaking` / `focusPeakingColor` / `focusPeakingImage` state変数＋`fetchFocusPeaking()` 関数）を完全除去
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/camera_service.py'`（成功）
    - `xcodebuild -scheme PiCameraControl build`（BUILD SUCCEEDED）
    - `bash 'home 3/update.sh' 192.168.4.1`（成功 × 2回）
    - reaction モード切替: `curl POST /api/settings {"camera_mode":"reaction"}`（成功）
    - reaction モード sensor 確認: `check=0.1, cooldown=0.5, max/min=24, state=monitoring`
    - standard モード切替 + 撮影確認: `check=0.25, cooldown=1.5, max/min=15`
    - 手動撮影テスト: reaction（quality=75）、standard（quality=90）ともに成功
  - 確認結果:
    - reaction モード: NRestarts=0、100ms ポーリング、0.5s クールダウンで安定動作
    - standard モード: 正常切替、撮影正常
    - lores (80,60) によるクラッシュループ解消（(128,96) で安定）
    - iOS ステータスタブ削除・フォーカスピーキング残骸除去完了

- 2026-02-23 02:04 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - `serve_focus_peaking()` と `/api/focus_peaking` ルートを完全削除（`camera_service.apply_focus_peaking` が削除済みでインポート時にクラッシュ）
      - `_is_wifi_switching()` ヘルパー関数を追加（Wi-Fiスキャン時の切替中チェックで未定義エラーだった）
      - `DEFAULT_SETTINGS` の `detection_interval`/`check_interval` を0.5秒、`capture_cooldown` を3.0秒に更新（Pi Zero 2W 安全値に統一）
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - フォーカスピーキングトグルUI削除（Pi側APIが削除済み）
    - Pi上の `camera_settings.json`
      - `detection_interval`/`check_interval` を0.5秒、`capture_cooldown` を3.0秒に直接更新
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/api_server.py' 'home 3/camera_service.py'`（成功）
    - `xcodebuild -scheme PiCameraControl -destination 'generic/platform=iOS Simulator' build`（BUILD SUCCEEDED）
    - `bash 'home 3/update.sh' 192.168.4.1`（成功 × 2回）
    - API全テスト: `/api/settings` GET/POST, `/api/wifi/status`, `/api/sensor/status`, `/api/capture`, `/api/photos`（全て正常）
    - `curl /api/settings` で `capture_cooldown:3.0`, `detection_interval:0.5` を確認
  - 確認結果:
    - APモード正常稼働（`mode:"ap"`, `ip:"192.168.4.1"`, `ssid:"PiCamera"`）
    - ISO一時変更→リセット正常、手動撮影3回成功
    - フォーカスピーキングAPI呼び出しによるクラッシュリスク解消
    - Wi-Fiスキャン時の未定義エラー解消

- 2026-02-23 02:00 JST
  - 変更ファイル:
    - `home 3/camera_service.py`
      - **Pi Zero 2W 最適化版に全面刷新**（652行→507行）
      - 削除: `_compose_images()`（numpy float32 画像合成, 150MB+）、`apply_focus_peaking()`（scipy Sobel, OOM危険）、多重露光ロジック、PIL/ImageDraw/ImageFont import
      - 追加: `MIN_CAPTURE_COOLDOWN=2.0秒`（設定値が低くても強制適用）、`MAX_CAPTURES_PER_MINUTE=10枚` ハードレートリミット
      - `CHECK_INTERVAL` 0.25秒→0.5秒（CPU負荷半減）、`SETTINGS_RELOAD_INTERVAL`/`SENSOR_STATUS_WRITE_INTERVAL` 2秒
      - `_apply_camera_controls()` を設定リロード時に1回だけ適用（`controls_applied` フラグ）
      - lores サイズを `(160,120)` に統一、`get_sensor_sample()` を1チャンネル計算に軽量化
    - `home 3/TROUBLESHOOTING.md`
      - 上記の症状・原因・解決策と作業ログを追記
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/camera_service.py' 'home 3/api_server.py'`（成功）
    - `bash 'home 3/update.sh' 192.168.4.1`（成功）
    - `ssh pi@192.168.4.1 "systemctl is-active camera-service"`（`active`）
    - `tail -15 camera_service.log`（`Pi Zero 2W optimized` 起動確認、ログスパムなし）
    - `cat sensor_status.json`（`capture_cooldown:2.0`, `detection_interval:0.5`, `state:"monitoring"` 確認）
    - `curl -sS -X POST http://192.168.4.1:8001/api/capture -d '{}'`（success 確認）

- 2026-02-23 01:54 JST
  - 変更ファイル:
    - `home 3/camera_service.py`
      - **致命的バグ修正**: コメントアウトされた `_add_timestamp()` の残留コード本体（`if ImageDraw is None:` 〜 `return image`）が `write_sensor_status()` 内に紛れ込み、`NameError: name 'image' is not defined` で即クラッシュしていた問題を修正
      - `load_settings()` の毎秒 `Auto-adjusted quality` ログ出力を削除（ログスパム解消）
    - `home 3/TROUBLESHOOTING.md`
      - 上記の症状・原因・解決策と作業ログを追記
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/camera_service.py'`（成功）
    - `bash 'home 3/update.sh' 192.168.4.1`（成功 × 2回）
    - `ssh pi@192.168.4.1 "systemctl is-active camera-service"`（`active`）
    - `curl -sS -X POST http://192.168.4.1:8001/api/capture -H 'Content-Type: application/json' -d '{}'`（success × 2回）
    - `curl -sS http://192.168.4.1:8001/api/photos`（写真一覧取得成功）
    - `curl -sS http://192.168.4.1:8001/api/sensor/status`（`state: "monitoring"` 確認）
  - 状況:
    - camera-service が正常起動し、光検知ループが動作中
    - 手動撮影APIで写真保存を2回確認
    - restart counter 33505 のクラッシュループが完全解消

- 2026-02-23 01:50 JST
  - 変更ファイル:
    - `PiCameraControl/PiCameraControl/ConnectionMonitor.swift`（新規）
      - 5秒間隔で Pi の `/api/status` をチェックするグローバル接続監視
      - `@MainActor` + `ObservableObject` で全タブから `isConnected` を参照可能
      - `startMonitoring()` / `stopMonitoring()` / `checkNow()` を提供
    - `PiCameraControl/PiCameraControl/PiCameraControlApp.swift`
      - `ConnectionMonitor` を `@StateObject` として起動し、`.environmentObject()` で全タブに注入
      - 全タブ共通の `OfflineBannerView`（赤→オレンジグラデーション）を `TabView` 上部にオーバーレイ
      - `preferredColorScheme(.light)` のハードコードを `computedColorScheme`（`appAppearanceMode` 連動）に修正
    - `PiCameraControl/PiCameraControl/UnifiedGalleryView.swift`
      - `@EnvironmentObject var connectionMonitor` を追加
      - 空状態表示を接続状態に応じて切替（オフライン時は `wifi.slash` + 「Pi に接続できません」）
      - `PhotoCell.loadFromServer()` でサムネイルを Core Data にキャッシュ保存（オフラインでも再表示可能）
    - `PiCameraControl/PiCameraControl.xcodeproj/project.pbxproj`
      - `ConnectionMonitor.swift` をプロジェクトに登録
    - `home 3/TROUBLESHOOTING.md`
      - 上記の症状・原因・解決策と作業ログを追記
  - 実行コマンド:
    - `ping -c 2 -W 1000 192.168.4.1`（Host unreachable）
    - `ping -c 2 -W 1000 raspberrypi.local`（Unknown host）
    - `xcodebuild -project PiCameraControl.xcodeproj -scheme PiCameraControl -destination 'generic/platform=iOS Simulator' -quiet build`（** BUILD SUCCEEDED **）
  - 状況:
    - Pi 実機は `192.168.4.1` / `raspberrypi.local` とも到達不可
    - iOS側のオフライン検出・表示・キャッシュの改善を完了
    - Pi 側の光検知・撮影問題は実機接続後に調査継続

- 2026-02-15 19:16 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - `/api/wifi/status` / `/api/settings` から `ap_password` を除外（不要な情報露出を防止）
    - `home 3/README.md`
      - 上記の症状・原因・解決策、作業ログを追記
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/api_server.py'`（成功）
    - `bash 'home 3/update.sh' raspberrypi.local`（成功）
    - `curl -sS http://raspberrypi.local:8001/api/wifi/status`（`ap_password` が含まれないことを確認）
    - `curl -sS http://raspberrypi.local:8001/api/settings`（`ap_password` が含まれないことを確認）

- 2026-02-15 18:32 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `sudo sh -c 'pkill ... || true'` を廃止し、`sudo pkill -f ...` の直接実行へ変更（shell呼び出し削減）
    - `home 3/README.md`
      - 上記の作業ログを追記
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/wifi_manager.py' 'home 3/api_server.py' 'home 3/camera_service.py'`（成功）
    - `bash 'home 3/update.sh' raspberrypi.local`（成功）
    - `curl -sS http://raspberrypi.local:8001/api/status`（成功）
    - `curl -sS http://raspberrypi.local:8001/api/sensor/status`（成功）
    - `curl -sS -X POST http://raspberrypi.local:8001/api/metering -H 'Content-Type: application/json' -d '{}'`（成功）

- 2026-02-15 18:02 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - JSONパーサ `_read_json_body()` を `/api/metering` / `/api/photo` / `/api/photo/meta` へ適用
      - `GET /api/photos` の拡張子/ファイル名フィルタを強化
      - `GET /photos/<filename>` にファイル名検証を追加し、ストリーム転送へ変更
    - `.gitignore`
      - `contact.md` / `.windsurf/contact.md` / `.windsurf/rules/rule.md` / `wifi_cycle_test_*.log` を git 対象外へ
  - 実行コマンド:
    - `python3 -m py_compile 'home 3/api_server.py' 'home 3/wifi_manager.py' 'home 3/camera_service.py' 'mock_server.py'`（成功）
    - `bash -n 'home 3/update.sh' 'home 3/deploy.sh' 'home 3/wifi_cycle_test.sh' 'PiCameraControl/build_ios_simulator.sh'`（成功）

- 2026-02-15 14:56 JST
  - 変更ファイル:
    - `/Volumes/bootfs/firstrun.sh`（SDカード上）
      - first boot 時に `/home/pi/camera_settings.json` へ `wifi_mode=ap` を明示保存する処理を追加
  - 実行コマンド:
    - `bash -n '/Volumes/bootfs/firstrun.sh'`（成功）

- 2026-02-15 14:52 JST
  - 変更ファイル:
    - `/Volumes/bootfs/firstrun.sh`（SDカード上）
      - `picamera_payload` を first boot で `/home/pi` / `/etc/systemd/system` へ反映する処理を追加
      - 旧サービス停止・無効化、`camera-service` / `api-server` の有効化・再起動を追加
    - `/Volumes/bootfs/picamera_payload/*`（SDカード上）
      - `api_server.py` / `wifi_manager.py` / `camera_service.py`
      - `camera-service.service` / `api-server.service`
    - `home 3/README.md`
      - 上記の症状・原因・解決策、作業ログを追記
  - 実行コマンド:
    - `mkdir -p '/Volumes/bootfs/picamera_payload' && cp ... '/Volumes/bootfs/picamera_payload/'`（成功）
    - `bash -n '/Volumes/bootfs/firstrun.sh'`（成功）
    - `cat '/Volumes/bootfs/cmdline.txt'`（`systemd.run=/boot/firstrun.sh` を確認）

- 2026-02-15 14:45 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - 同一モード no-op 判定を「モード文字列一致」から「実体健全性判定」へ修正
      - `/api/wifi/switch` に `force: true` を追加し、強制復旧時はクールダウンをバイパス
      - 強制AP時に `switch_to_ap_mode()` 失敗後 `ensure_ap_persistence()` を再試行
      - 通信断継続時にAPを自動復旧する Wi-Fi watchdog を追加
      - Wi-Fiモード保存処理を `_persist_wifi_mode()` へ共通化
    - `home 3/wifi_cycle_test.sh`
      - `FORCE_AP_SWITCH` 環境変数を追加（既定 `1`）
      - AP切替時に `{"mode":"ap","force":true}` を送れるよう修正
    - `home 3/README.md`
      - 上記の症状・原因・解決策、検証コマンドを追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）

- 2026-02-15 12:11 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - `MAX_JSON_BODY_BYTES` によるJSONサイズ制限を追加
      - `/api/settings` のホワイトリスト検証・型/範囲検証を追加
      - `/api/wifi/switch` にロック + クールダウン + 同一モードno-opを追加
      - AP/テザリング切替前の入力・前提条件チェックを追加
    - `PiCameraControl/PiCameraControl/CameraAPI.swift`
      - Wi-Fi APIで非200時もJSONメッセージを復元してUIへ返却
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - `APPEARANCE` セクション（System/Light/Dark）を追加
      - Wi-Fi切替失敗時に固定文言ではなく実エラーメッセージを表示
    - `PiCameraControl/PiCameraControl/PiCameraControlApp.swift`
      - `preferredColorScheme` を `appAppearanceMode` でアプリ全体適用
    - `home 3/README.md`
      - 上記の症状・原因・解決策と作業ログを追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash './build_ios_simulator.sh'`（初回失敗: `invalid redeclaration of 'colorScheme'`）
    - `bash './build_ios_simulator.sh'`（修正後 `** BUILD SUCCEEDED **`）

- 2026-02-15 11:52 JST
  - 変更ファイル:
    - `PiCameraControl/PiCameraControl/PhotoEditorView.swift`
      - IR赤み自動補正（ON/OFF + 強度）を追加
      - `IR補正プリセット` と、長押し `ORIGINAL` 比較表示を追加
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - 光検知の一時停止/再開カード（`LIGHT DETECTION`）を追加
      - ISO/SS をチップ + `+/-` で素早く調整できるUIへ改善
      - 手動撮影時に位置情報を添付できるよう `CaptureLocationProvider` を追加
      - `LAST CAPTURE` のメタ表示を `DATE` / `LOC` 対応に拡張
    - `PiCameraControl/PiCameraControl/CameraAPI.swift`
      - `captureWithMetadata` に `location` ペイロード対応を追加
    - `PiCameraControl/PiCameraControl/Models.swift`
      - `PhotoMetadata` に `captured_at` / `latitude` / `longitude` / `location_label` を追加
      - `capturedDateDisplay` / `locationDisplay` を追加
    - `PiCameraControl/PiCameraControl/PhotoGalleryView.swift`
      - 詳細メタ表示を `DATE` / `LOC` 対応に拡張
    - `PiCameraControl/PiCameraControl/Info.plist`
      - `NSLocationWhenInUseUsageDescription` を追加
    - `home 3/api_server.py`
      - `/api/capture` メタデータに `captured_at` / 位置情報（バリデーション付き）を保存
    - `home 3/README.md`
      - 上記の症状・原因・解決策、屋外運用の安全性チェックを追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/PiCameraControl/build_ios_simulator.sh'`（成功）
    - `bash './build_ios_simulator.sh'`（`** BUILD SUCCEEDED **`）

- 2026-02-15 11:35 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `switch_to_ap_mode()` の失敗復旧で、テザリング復旧成功時に `wifi_mode=tethering` を保存していた挙動を修正
      - 代わりに AP 要求意図（`wifi_mode=ap` + SSID/PASS）を保存するよう変更し、再起動時の AP 復元を保証
    - `home 3/README.md`
      - 上記の症状・原因・解決策と検証ログを追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）

- 2026-02-15 04:43 JST
  - 変更ファイル:
    - `home 3/wifi_cycle_test.sh`
      - `HOME_MAC` 環境変数（既定 `88-A2-9E-40-1E-B4`）を追加
      - `discover_home_host_by_mac()` を追加し、ARP情報 + `/api/wifi/status` で Home 側ホストを探索
      - macOS `awk` 互換性問題（`match(..., array)`）を回避するため、ARP解析を `sed` ベースへ修正
    - `home 3/README.md`
      - 上記の症状・原因・解決策と検証ログを追記
  - 実行コマンド:
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）
    - `AP_INTERFACE=en0 HOME_INTERFACE=en0 AP_WAIT_SEC=8 HOME_WAIT_SEC=8 STEP_WAIT_SEC=1 '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh' 1`
      - 結果: AP/Home とも未到達（MAC探索含め未解決）
    - `bash './update.sh' raspberrypi.local`
      - 結果: `Could not resolve hostname raspberrypi.local` で転送失敗
    - `curl http://192.168.0.1/webpages/index.html` / `curl .../cgi-bin/luci/...`
      - 結果: ルータUI到達は正常（Pi探索用の直接ホスト情報は取得不可）
    - `python3` サブネットスキャン（`192.168.0.x/1..5.x/10.42.0.x`, port `22/8001`）
      - 結果: `TOTAL 0`

- 2026-02-15 04:33 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `ensure_ap_persistence(allow_recursive_ap_recovery=True)` を追加し、非再帰モードでの安全復旧を実装
      - `Hotspot` プロファイル欠損時の再作成（保存済み SSID/PASS 使用）を追加
      - `switch_to_ap_mode()` 失敗時の復旧で、テザリング復旧失敗後に AP 永続化復旧を試す第3段フォールバックを追加
      - 復旧レスポンスに `ap_recovery` を追加し、復旧経路を可視化
    - `home 3/README.md`
      - 上記の症状・原因・解決策と検証ログを追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）
    - `AP_INTERFACE=en0 HOME_INTERFACE=en0 AP_WAIT_SEC=8 HOME_WAIT_SEC=8 STEP_WAIT_SEC=1 '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh' 1`
      - 結果: AP/Home とも未到達（実機未接続）
    - `ifconfig` / `netstat -rn -f inet` / `fping -a -q -g 192.168.0.0/24`
      - 結果: `en11` は inactive で経路は `en0` に収束、応答ホストは `192.168.0.1`, `192.168.0.165`, `192.168.0.196` のみ

- 2026-02-15 04:23 JST
  - 変更ファイル:
    - `home 3/wifi_cycle_test.sh`
      - `curl_json_with_auto_route()` を追加し、`--interface` 指定失敗時に IF未指定で再試行するよう修正
      - `wait_for_status()` / `discover_home_host()` を上記フォールバック経路へ統一
      - `post_mode_switch()` を強化し、IF固定送信失敗時は自動ルーティングで再送するよう修正
    - `home 3/README.md`
      - 上記の症状・原因・解決策と診断ログを追記
  - 実行コマンド:
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）
    - `AP_INTERFACE=en0 HOME_INTERFACE=en0 AP_WAIT_SEC=8 HOME_WAIT_SEC=8 STEP_WAIT_SEC=1 '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh' 1`
      - 結果: AP/Home とも未到達で終了（スクリプト構文・再試行ロジックは正常動作）
    - `networksetup -setnetworkserviceenabled "AX88179A" off` → `on`
      - 結果: 一時的に `route -n get 192.168.0.20` が `en0` へ収束、`en11` は inactive へ遷移することを確認
    - `networksetup -setairportnetwork en0 PiCamera picamera123`
      - 結果: `Could not find network PiCamera.`（現時点で AP SSID 未観測）

- 2026-02-15 03:48 JST
  - 変更ファイル:
    - `home 3/wifi_cycle_test.sh`
      - `networksetup` ベースの Wi-Fi IF 自動検出を追加（`AP_INTERFACE/HOME_INTERFACE` の自動補完）
      - `route -n get <HOME_IP>` による経路IF不一致警告を追加
      - `discover_home_host()` を追加し、`fping` + `/api/wifi/status` で Home 側ホストを動的探索するフォールバックを追加
    - `home 3/README.md`
      - 上記の症状・原因・解決策と検証ログを追記
  - 実行コマンド:
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）
    - `AP_WAIT_SEC=10 HOME_WAIT_SEC=10 STEP_WAIT_SEC=1 '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh' 1`
      - 結果: `route to 192.168.0.20 is via en11 (requested en0)` 警告を出力し、AP/Home とも未到達で終了
    - `system_profiler SPAirPortDataType`
      - 結果: `en0` は `TP-Link_CE5D` 接続中、周辺ネットワークに `PiCamera` は未検出

- 2026-02-15 03:33 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `switch_to_ap_mode()` に `_fail_with_tethering_recovery()` を追加
      - `NetworkManager` 起動失敗 / `nmcli hotspot` 失敗 / AP準備確認失敗 / 例外経路で、
        失敗返却のみで終了せずテザリング復旧を試行するよう修正
      - `switch_to_tethering_mode(allow_ap_fallback=True)` を導入し、
        AP失敗復旧経路では `allow_ap_fallback=False` で再帰ループを防止
    - `home 3/README.md`
      - 上記の症状・原因・解決策と診断ログを追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py'`（成功）
    - `fping -a -q -g 192.168.0.0/24`（応答: `192.168.0.1`, `192.168.0.16`, `192.168.0.68` のみ。`192.168.0.20` なし）
    - `curl --interface en0 --max-time 4 http://192.168.0.20:8001/api/wifi/status`（タイムアウト）
    - `curl --interface en11 --max-time 4 http://192.168.0.20:8001/api/wifi/status`（タイムアウト）
    - `ping -S 192.168.0.165 -c 2 -W 1000 192.168.0.20` / `ping -S 192.168.0.68 -c 2 -W 1000 192.168.0.20`
      - 結果: どちらも `Host is down`
    - `route -n get 192.168.0.20`
      - 結果: `interface: en11`（同一サブネットの別IF経路に吸われる状態を確認）
    - `ifconfig en0` / `ifconfig en11`
      - 結果: `en0=192.168.0.165`, `en11=192.168.0.68`（同一 `192.168.0.0/24` で同時活性）
  - 状況:
    - AP/テザリング切替の失敗復旧コードは強化済み。
    - ただし現時点で Pi 実機は `192.168.0.20` / `192.168.4.1` とも到達不可のため、再接続後に実機反映と再検証を継続する。

- 2026-02-15 02:58 JST
  - 変更ファイル:
    - `home 3/README.md`
      - 到達性再診断（`contact.md` 更新確認を含む）の実施ログを追記
  - 実行コマンド:
    - `cat /Users/sugawaraichirou/Documents/アプリ/contact.md`
      - 進捗報告: 「0:24 に 192.168.0.20 で接続したらしい / MAC: `88-A2-9E-40-1E-B4`」を確認
    - `ping -S 192.168.0.165 -c 3 -W 1000 192.168.0.20` / `ping -S 192.168.0.68 -c 3 -W 1000 192.168.0.20`
      - 結果: `100% packet loss`（`Host is down` / `No route to host`）
    - `curl --max-time 4 http://192.168.0.20:8001/api/wifi/status`
      - 結果: タイムアウト
    - `curl --max-time 4 http://raspberrypi.local:8001/api/wifi/status`
      - 結果: 名前解決タイムアウト
    - `arp -an | grep '192.168.0.20'`
      - 結果: `incomplete`（ARP解決不能）
  - 状況:
    - AP (`PiCamera`) も Home (`192.168.0.20`) も現時点で到達不可。
    - ローカル修正（テザリング途中失敗時のAP強制フォールバック）は反映済みだが、Pi到達経路未復旧のため実機適用/再検証待ち。

- 2026-02-15 02:01 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `switch_to_tethering_mode()` に `_fail_with_ap_fallback()` を追加
      - `wpa_supplicant restart` / `wpa_cli reconfigure` / `wpa_cli reconnect` / 例外経路でも AP フォールバックを必ず実行するよう統一
      - フォールバック成功時に `_save_wifi_settings('ap', ...)` を実行し、保存モード不整合を防止
    - `home 3/README.md`
      - 上記の症状・原因・解決策を追記
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）
    - `python3` ソケットスキャン（送信元 `192.168.0.165` / `192.168.0.68`、宛先 `192.168.0.0/24`、port `22/8001`）
      - 結果: `no open ports 22/8001`
    - `networksetup -setairportnetwork en0 PiCamera picamera123`（`Could not find network PiCamera.`）
    - `curl --interface en0 http://192.168.4.1:8001/api/wifi/status` / `curl --interface en0 http://10.42.0.1:8001/api/wifi/status`（タイムアウト）

- 2026-02-15 01:48 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - デプロイマーカーを単一パスから複数パス対応へ拡張（`/run/picamera_boot_network_applied`, `/tmp/picamera_boot_network_applied`）
      - マーカー削除時に `PermissionError` の場合 `sudo -n rm -f` で再試行するよう改善
    - `home 3/README.md`
      - 症状/原因/解決策の記述を上記実装に合わせて更新
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash -n '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh'`（成功）
    - `curl --interface en0 http://192.168.0.20:8001/api/wifi/status` / `curl --interface en11 ...`（タイムアウト）
    - `ping -c 1 -W 1000 192.168.0.20`（Host is down）

- 2026-02-15 00:39 JST
  - 変更ファイル:
    - `home 3/api_server.py`
      - デプロイ直後の誤切替抑止として `BOOT_NETWORK_APPLIED_MARKER` を追加
      - `_consume_boot_network_applied_marker()` を追加し、`main()` でマーカー消費時は `restore_wifi_mode_on_boot()` を1回スキップ
    - `home 3/wifi_cycle_test.sh`
      - 新規追加（Wi-Fi切替の自動サイクル試験）
      - 開始時に AP 未到達なら Home 側から AP へブートストラップして試験開始する前処理を追加
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py'`（成功）
    - `networksetup -setairportnetwork en0 PiCamera picamera123`（`PiCamera` が見つからず未接続）
    - `fping -aqg 192.168.0.0/24` + `nc`/`curl` でスキャン（Pi API/SSH 到達なし）
    - `AP_WAIT_SEC=20 HOME_WAIT_SEC=20 STEP_WAIT_SEC=2 '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_cycle_test.sh' 1`（開始前到達性チェック失敗）
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）

- 2026-02-15 00:05 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - `has_nmcli()` を実体パス解決ベースに変更（低PATH環境対応）
      - `get_current_mode()` / `_is_networkmanager_running()` / `ensure_ap_persistence()` の `nmcli` 呼び出しを実体パス統一
      - `wpa_supplicant`（汎用ユニット）の stop/disable を AP 系処理に追加
      - `_is_hotspot_active()` / `_wait_for_ap_ready()` を追加し、AP起動確認（Hotspot active + AP帯IP）を強化
      - AP準備失敗時に `nmcli connection up Hotspot` 再試行を追加
  - 実行コマンド:
    - `python3 -m py_compile '/Users/sugawaraichirou/Documents/アプリ/home 3/wifi_manager.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/api_server.py' '/Users/sugawaraichirou/Documents/アプリ/home 3/camera_service.py'`（成功）
    - `bash './home 3/update.sh' 192.168.4.1`（転送・サービス再起動成功）
    - `curl http://192.168.4.1:8001/api/wifi/status` など到達確認（この時点で Pi 到達不可）

- 2026-02-14 19:03 JST
  - 変更ファイル:
    - `home 3/wifi_manager.py`
      - 実行ファイル探索 `_resolve_executable()` 追加
      - `iw` / `wpa_cli` を実体パス解決して呼び出すよう修正
    - `home 3/camera_service.py`
      - センサー状態ファイル出力 (`/home/pi/sensor_status.json`) 追加
      - `lux/ae_gain/ae_exposure_us` と `last_detect_to_capture_ms` を記録
    - `home 3/api_server.py`
      - `GET /api/sensor/status` / `POST /api/metering` を追加
      - 露出提案ロジック（ISO/シャッターストップ丸め）を追加
    - `PiCameraControl/PiCameraControl/Models.swift`
      - `SensorStatusResponse` / `MeteringResponse` モデル追加
    - `PiCameraControl/PiCameraControl/CameraAPI.swift`
      - センサー取得 / 測光取得 / 提案適用APIを追加
    - `PiCameraControl/PiCameraControl/ContentView.swift`
      - SENSOR STATUS表示と測光UI（提案適用ボタン）を追加
  - 実行コマンド:
    - `python3 -m py_compile "home 3/wifi_manager.py" "home 3/camera_service.py" "home 3/api_server.py"`（成功）
    - `bash ./build_ios_simulator.sh`（`** BUILD SUCCEEDED **`）
    - `bash ./update.sh raspberrypi.local`（転送・再起動成功）

- 2026-02-12 16:02 JST
  - `wifi_manager.py`: AP切替時に `nmcli networking on` / `nmcli radio wifi on` / `Hotspot autoconnect=yes` / `powersave` 無効化を追加
  - `api_server.py`: 起動時に saved_mode=tethering でも未接続なら再接続を試行し、失敗時はAPへフォールバック
  - `api-server.service`: `network-online.target` 依存をやめ、`network.target` に変更
  - ログ確認: `journalctl` / `systemctl status` / `nmcli` で Hotspot 設定（autoconnect=no）と EXT4 recovery を確認

- 2026-02-12 16:55 JST
  - `wifi_manager.py`: `ensure_ap_persistence()` を追加し、APモード時に Hotspot の永続設定適用（autoconnect/省電力OFF/IP固定/Hotspot up）を実施
  - `api_server.py`: 起動時 saved_mode=ap の場合でも `ensure_ap_persistence()` を呼び、再起動後のAP復帰性を強化
  - `api_server.py`: `BrokenPipeError` / `ConnectionResetError` を握りつぶし、クライアント切断でAPIが500にならないよう修正
  - 再デプロイ: `home 3/update.sh 192.168.4.1` 実行

- 2026-02-12 18:25 JST
  - `wifi_manager.py`: APモードでは `NetworkManager enable` / `dhcpcd disable`、テザリングでは逆にしてAP自動復帰性を強化
  - 再デプロイ: `home 3/update.sh 192.168.4.1` 実行

- 2026-02-12 19:19 JST
  - `wifi_manager.py`: Hotspot を `2.4GHz(bg)+ch6` に固定し、`iw power_save off` を併用してAP安定性を改善
  - 再デプロイ: `home 3/update.sh 192.168.4.1` 実行

- 2026-02-12 19:45 JST
  - Pi側: `/lib/firmware/brcm/brcmfmac43436s-sdio.clm_blob` の不足をシンボリックリンクで補完（次回起動から反映）

- 2026-02-12
  - `wifi_manager.py`: `/api/wifi/write_wpa` は **サービス再起動せずファイル更新のみ**（AP切断・HTTPタイムアウト回避、適用はテザリング切替時）
  - `update.sh`: 実行ディレクトリ依存を解消（スクリプト配置ディレクトリを基準に転送）
  - デプロイ: `home 3/update.sh <PiのIP>`（未実施/接続先確認中）

- 2026-02-12
  - `api_server.py`: `/api/photo/meta` を追加（写真のJSON sidecarメタデータ取得）
  - `api_server.py`: 写真削除時に `.json` メタも削除
  - iOS: 手動撮影UIでキーボードを閉じる＋直近撮影メタ（LAST CAPTURE）表示
  - iOS: ギャラリーの写真詳細でMETADATA表示（`/api/photo/meta` から取得）
  - iOS: `LAST CAPTURE` の META 表示の構文エラーを修正
  - iOS: 写真詳細はメタ取得に失敗しても画像を先に表示（メタは取得できた場合のみ表示）

- 2026-02-12
  - `wifi_manager.py`: テザリング切替の安定化（インターフェースIPv4 flush / link down-up / `wpa_supplicant@<iface>` restart / power save off / IP取得をWi‑Fiインターフェース優先へ）
  - `README.md`: テザリング切替の不安定（症状/原因/解決策）を追記

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

## ✅ 手動撮影モード + メタデータ付与（実機テスト）

**iOSアプリ**
- 設定画面のMANUAL MODEで撮影モードを選択
- METAに任意のタグ（例: `test01` / `lensA`）を入力して撮影

**APIテスト**
```bash
BASE="http://192.168.4.1:8001"

# 現在の設定で手動撮影
curl -sS -X POST "$BASE/api/capture" -H 'Content-Type: application/json' -d '{}'

# 手動撮影をREACTIONで実行し、メタタグを付与
curl -sS -X POST "$BASE/api/capture" \
  -H 'Content-Type: application/json' \
  -d '{"manual_mode":"reaction","meta":"test01"}'
```

**保存ファイル**
- 画像: `manual_<timestamp>_<mode>_<meta>.jpg`（metaは安全化して付与）
- メタ: 同名 `.json` を保存（ISO/SS/WB/quality/size など）

**メタデータ取得API（写真単体）**
```bash
BASE="http://192.168.4.1:8001"

curl -sS -X POST "$BASE/api/photo/meta" \
  -H 'Content-Type: application/json' \
  -d '{"filename":"manual_XXXXXXXXXX.jpg"}'
```

**iOSアプリでの表示**
- ギャラリーの写真詳細画面で下部にMETADATAを表示
- 設定画面の手動撮影後に「LAST CAPTURE」で直近の撮影メタを表示

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
