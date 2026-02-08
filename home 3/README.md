# PiCamera Control System v2.0 (省電力版)

Raspberry Pi Zero 2 W + カメラモジュールを使った**光検知自動撮影システム**

## 新システムの特徴

- **省電力設計**: カメラは光検知時のみ起動（CLI化済み）
- **高速反応**: 500ms間隔で光を監視、検知時に即撮影（Zero 2W向け軽量化）
- **ライブビュー不要**: 写真一覧中心のシンプルなiOSアプリ
- **軽量API**: 写真取得とステータス確認のみの最小構成
- **手動モード**: 光検知を停止し、アプリのボタンで撮影

## システム構成

### Raspberry Pi側
- `camera_service.py`: 光検知＋自動撮影サービス（常駐）
- `api_server.py`: HTTP APIサーバー（ポート8001）

### iOS アプリ
- タブ1: 写真ギャラリー（自動撮影された写真一覧）
- タブ2: 設定（明るさ閾値調整、システム状態表示）

### 症状: 光が当たり続けると連続撮影になる懸念
**原因**
明るさが閾値を超えた状態が継続すると、毎ループで撮影される可能性がありました。

**解決策**
光検知の「立ち上がり（暗→明）」のみをトリガーにし、連続撮影を抑止しました。さらにクールダウン（3秒）を入れて負荷を抑えています。

### 症状: iOSアプリのビルドが失敗する
**原因**
新規追加した Swift ファイル（PhotoGalleryView.swift / SettingsView.swift / SimpleCameraAPI.swift）が Xcode プロジェクトに未登録でした。

**解決策**
`project.pbxproj` にファイル参照と Sources 追加を行い、ビルド成功を確認しました。

**補足**
シミュレータ用ビルドは以下のスクリプトで自動実行できます。
```bash
cd /Users/sugawaraichirou/Documents/アプリ/PiCameraControl
./build_ios_simulator.sh
```

### 症状: /api/capture で撮影が失敗する（Device or resource busy）
**原因**
`camera-service` がカメラを占有している状態で `libcamera-still` を呼ぶとデバイスがビジーになり失敗します。

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
アプリの **QUALITY** ピッカーから画質を選択できます（Q60〜Q95）。

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

### 症状: 再起動するとAPモードが維持されない
**原因**
nmcliのHotspotは再起動後に自動起動しません。
`wifi_manager.py` が `camera_settings.json` に `wifi_mode` を保存していましたが、
起動時に誰も読んで復元していませんでした。

**解決策**
`api_server.py` の起動時に `camera_settings.json` の `wifi_mode` を読み取り、
保存されたモード（ap/tethering）と現在のモードが異なる場合に自動復元するようにしました。
`api-server.service` を `network-online.target` 待ちに変更し、Wi-Fi準備完了後に実行。

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

### 症状: クラッシュログが確認できない
**原因**
camera-service の異常終了が起きていない場合、エラーログは出力されません。

**解決策**
以下の手順でログを確認し、エラーが出た場合のみ解析対象にします。
```bash
ssh pi@192.168.0.20 "tail -n 120 /home/pi/logs/camera_service.log"
ssh pi@192.168.0.20 "journalctl -u camera-service -p err -n 50 --no-pager"
```
現時点では `ERROR/Traceback` の記録はありません。

---

# 旧システムドキュメント（参考）

Raspberry Pi Zero 2 W を使用した、光検知機能付き高機能カメラシステム。Webブラウザから設定変更、プレビュー、写真閲覧が可能です。

## 📁 プロジェクトの現状 (Current Status)

### ✅ 正常に動作している機能
*   **Web操作パネル (Port 8001)**: ISO、シャッタースピード、検知閾値、ホワイトバランス等の設定変更。
*   **写真ギャラリー (Port 8000)**: 撮影された写真の一覧表示とダウンロード。
*   **光検知撮影**: センサー（カメラ映像解析）による光の変化検知と自動撮影。
*   **手動撮影**: Web UIからの強制シャッター。

### ⚠️ 不安定・調整中の機能
*   **Wi-Fiモード切り替え**: APモードとテザリングモードの切り替え時に、システムがクラッシュする場合がある（後述）。

---

## 📚 前提知識 (Prerequisite Knowledge)

### 1. ハードウェア構成
*   **デバイス**: Raspberry Pi Zero 2 W
*   **OS**: Raspberry Pi OS (Bullseye 64-bit)
*   **カメラ**: Raspberry Pi Camera Module 3 (または互換品)

### 2. ソフトウェア構成
システムは3つの主要な常駐プログラム（Systemd Service）で構成されています。

| サービス名 | 役割 | 関連ファイル |
|:---|:---|:---|
| `camera-control` | Web操作画面 (Port 8001) の提供、設定管理、Wi-Fi制御 | `camera_control.py` |
| `shutter-trigger` | 光検知アルゴリズムの実行、自動撮影 | `shutter_trigger.py`, `light_detection_algorithm.py` |
| `photo-server` | 写真閲覧ギャラリー (Port 8000) の提供 | `server.py` |

### 3. 通信・ネットワーク
*   **APモード**: ラズパイ自身がWi-Fi親機になります。（SSID: `PiCamera`, Pass: `picamera123`）
    *   アドレス: `http://192.168.4.1:8001`（AP_IP固定）
*   **テザリングモード**: ラズパイがスマホなどのWi-Fiに接続します。
    *   アドレス: `http://raspberrypi.local:8001`

### 4. APIステータス仕様（Wi-Fi）
* `/api/wifi/status` は `ip` と後方互換の `ip_address` を返します（いずれも同値）。
* APモードでIP取得に失敗した場合でも `ip`/`ip_address` は `192.168.4.1` を返すようにフェイルセーフしています。

---

## 🤔 なぜ急に動かなくなったのか？ (Failure Analysis)

ユーザー様からの「前はうまくいってたのに急にダメになった」という点について、技術的な分析は以下の通りです。

### 結論: 「ドライバーの限界を超えた」可能性が高い
今回発生したのは **Kernel Panic（カーネルパニック）** です。アプリのエラーではなく、OSの根幹部分（Wi-Fiドライバー `brcmfmac`）のクラッシュです。

### なぜ今発生したのか？

1.  **処理速度の違い**
    *   以前（手動でコマンドを打っていた時など）は、人間が操作するスピードだったので、ドライバーの処理が間に合っていました。
    *   今回（Webアプリ化）は、プログラムが「Wi-Fi切断」→「設定削除」→「再接続」を**ミリ秒単位の超高速**で連続実行したため、ドライバー内部の処理が追いつかず、メモリの矛盾などが起きてクラッシュしました。

2.  **タイミングの悪戯（レースコンディション）**
    *   この種のエラーは「運」も絡みます。99回成功しても、たまたまOSの裏側で別の重い処理（ログ書き込みなど）が走った瞬間に1回でもコマンドが重なるとクラッシュすることがあります。
    *   Web UIをリッチにしたことで、裏で通信処理が増え、負荷のタイミングが変わったことも一因かもしれません。

### 今後の対策
人間が操作するのと同じように、プログラム側で「一休み」を入れる修正（`time.sleep`）を行います。「切断して、2秒待ってから、設定を削除する」といった具合に優しく操作することで、安定性は劇的に向上します。

sshでraspiで実行したりxcodeでそちらでテストしてユーザーに報告

---

## 🔒 セキュリティ修正 (Security Fixes) - 2025年2月

Snykスキャンによるセキュリティ指摘に対応し、以下の修正を実装しました。

### 1. Path Traversal (High) - camera_control.py
- `/photos/*` エンドポイントでファイル名を厳密に検証
- `os.path.basename()` でパス区切り除去、`os.path.normpath()` で正規化
- `os.path.realpath()` で実際のパス解決し、PHOTOS_DIR内かチェック
- 親ディレクトリ参照 (`..`) や外部パスは403エラーで拒否

### 2. DOM XSS (Medium) - gallery.html
- `escapeHtml()` 関数を追加（divにtextContent設定してinnerHTML取得）
- `displayPhotos()` でファイル名とパスをエスケープしてからDOM挿入
- `safeFilename` と `safePhoto` を使用してXSS攻撃を防止

### 3. ハードコードパスワード (Medium) - wifi_manager.py
- `_get_default_ap_ssid()` / `_get_default_ap_password()` 関数を追加
- 環境変数 `AP_SSID` / `AP_PASSWORD` でデフォルト値を上書き可能に
- コード内の `"picamera123"` を環境変数経由に変更

**使用方法:**
```bash
export AP_SSID="MyCamera"
export AP_PASSWORD="securepass123"
sudo systemctl restart camera-control
```

### 4. SSRF (High) - iOSアプリ (CameraAPI.swift)
- `validateServerURL()` 関数を追加（プライベートIP/.localのみ許可）
- `CameraAPI.init` でURL検証、無効時はデフォルト値 (`192.168.4.1`) 使用
- 許可パターン: `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `127.x.x.x`, `*.local`
- 撮影画像の取得を `POST /api/photo` に変更し、ファイル名をサニタイズしてから配信

### 検証結果
- **iOSアプリ**: Xcodeビルド成功、シミュレータインストール完了
- **モックサーバー**: PythonでAPI動作確認済み (`mock_server.py`)
- **Raspberry Pi**: 実機検証待ち（家Wi-Fi接続情報必要）

---

## 🚀 Wi-Fiモード切替手順

### 症状: 家Wi-Fiへ切替してもAP(PiCamera)に戻る
家Wi-Fiへ切り替えたつもりでも、しばらくすると `PiCamera` のAPが復活し、家Wi-Fi側（例: `192.168.0.x`）から到達できないことがあります。

**原因**
`nmcli` が無い環境では切替処理が `Legacy mode`（`wpa_supplicant`）にフォールバックしますが、従来の実装では `wpa_cli reconfigure` だけで、SSID/PSKの更新や再接続・DHCP更新まで完結していませんでした。また `sudo` がパスワード待ちになると、サービス再起動や再起動コマンドがハングしたように見えることがあります。

**解決策**
AP(192.168.4.1) で接続している状態で、HTTP API経由でSSID/PSKを書き込み → 再接続 → テザリング切替を実行します。

### 症状: 電源断後にAP(PiCamera)が復活する
電源を切って入れ直すと、以前は家Wi-Fiにいたはずなのに AP (`PiCamera`) が再び出てくることがあります。

**原因**
起動初期は `hostapd/dnsmasq` が先に立ち上がり、APが一時的に有効になります。そのタイミングで `camera-control` が起動すると、ネットワークが安定しておらず `wpa_cli` が制御ソケットに接続できないため、テザリングへの復帰が失敗してAPが残ることがあります。

**解決策**
起動時に **必ずテザリング再適用**するように修正し、`camera-control.service` を `network-online.target` 待ちに変更しました。これにより、Wi-Fi準備が整った後にテザリング処理が動作します。

### 症状: テザリング設定後もどこにも接続できない（APも出ない）
`wpa_supplicant.conf` が空または接続情報が無効な状態でテザリングモードに切り替わると、家Wi-Fiにも接続できず、APモードにもならず、Piが孤立します。

**原因**
テザリング再適用は成功しても、実際の接続確認が行われていなかったため、接続失敗時のフォールバック処理がありませんでした。

**解決策**
起動時のテザリング適用後に接続確認（SSID取得・IP取得）を行い、失敗した場合は自動的にAPモードへフォールバックするようにしました。これにより、接続できない場合でもAPが立ち上がってアクセス可能になります。

### APモード → 家Wi-Fi (テザリング) 切替
#### アプリから簡単切替（推奨）
1. iPhone を AP (PiCamera) に接続
2. アプリの **設定タブ** 内の NETWORK セクションで **HOME WIFI SSID/PASSWORD** を入力
3. **CONNECT HOME WIFI** を押す

※ AP接続中でも家Wi-Fiへ切替できるよう `/api/wifi/write_wpa` → `/api/wifi/switch` を自動実行します。

#### 手動（curl）
```bash
# 0. (推奨) コード反映
# Mac側の /Users/sugawaraichirou/Documents/アプリ/home 3 から
# bash ./update.sh 192.168.4.1

# 1. SSID/PSK を HTTP 経由で書き込み（SSH不要）
curl -X POST "http://192.168.4.1:8001/api/wifi/write_wpa" \
  -H "Content-Type: application/json" \
  -d '{"ssid":"家のSSID","psk":"パスワード"}'

# 2. テザリングへ切替
curl -X POST "http://192.168.4.1:8001/api/wifi/switch" \
  -H "Content-Type: application/json" \
  -d '{"mode":"tethering"}'

# 1. Wi-Fi設定ファイルを編集
ssh pi@192.168.4.1 "sudo tee /etc/wpa_supplicant/wpa_supplicant.conf >/dev/null <<'EOF'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=JP

network={
    ssid=\"家のSSID\"
    psk=\"パスワード\"
    priority=1
}
EOF"

# 2. camera_settings.jsonをtetheringに変更
ssh pi@192.168.4.1 "sudo tee /home/pi/camera_settings.json >/dev/null <<'EOF'
{
  \"wifi_mode\": \"tethering\",
  \"ap_ssid\": \"PiCamera\",
  \"ap_password\": \"picamera123\"
}
EOF"

# 3. 再起動
ssh pi@192.168.4.1 "sudo reboot"
```
再起動後、ラズパイは家Wi-Fiに接続し、`http://raspberrypi.local:8001` でアクセス可能になります。

---

## ✅ 家Wi-Fiでのスマホテスト手順（次の作業）
1. iPhoneを家Wi-Fiに接続
2. アプリを開いて **Refresh** を押す
3. 右上のIP設定が `192.168.0.xx` に変わることを確認
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
