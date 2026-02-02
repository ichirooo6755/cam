# Raspberry Pi デプロイ手順

## 前提条件の確認
- Raspberry Pi Zero 2 W
- Raspberry Pi OS 64bit Bullseye
- カメラが接続されている

このシステムは上記環境で動作します。

## 1. 必要なパッケージのインストール

```bash
# システムを最新に更新
sudo apt update
sudo apt upgrade -y

# 必要なパッケージをインストール
sudo apt install -y python3-opencv python3-numpy python3-pil libcamera-apps

# カメラの有効化確認
libcamera-still --list-cameras
```

## 2. ファイルの配置

現在のディレクトリ（`/Users/sugawaraichirou/Downloads/home 3`）から、
Raspberry Piの `/home/pi/` にファイルを転送します。

**ローカル（Mac）から実行するコマンド：**

```bash
# Raspberry PiのIPアドレスを設定（例: 192.168.1.100）
RASPI_IP="192.168.1.100"

# ファイルを転送
cd "/Users/sugawaraichirou/Downloads/home 3"
scp camera_control.py pi@${RASPI_IP}:/home/pi/
scp shutter_trigger.py pi@${RASPI_IP}:/home/pi/
scp light_detection_algorithm.py pi@${RASPI_IP}:/home/pi/
scp server.py pi@${RASPI_IP}:/home/pi/
scp index.html pi@${RASPI_IP}:/home/pi/
scp style.css pi@${RASPI_IP}:/home/pi/
scp camera_settings.json pi@${RASPI_IP}:/home/pi/

# サービスファイルを転送
scp camera-control.service pi@${RASPI_IP}:/tmp/
scp shutter-trigger.service pi@${RASPI_IP}:/tmp/
scp photo-server.service pi@${RASPI_IP}:/tmp/
```

## 3. Raspberry Pi上での設定

**Raspberry Piにログインして実行：**

```bash
# SSH接続
ssh pi@192.168.1.100

# Pythonスクリプトに実行権限を付与
cd /home/pi
chmod +x camera_control.py
chmod +x shutter_trigger.py
chmod +x server.py

# photosディレクトリを作成
mkdir -p /home/pi/photos

# サービスファイルを正しい場所に移動
sudo mv /tmp/camera-control.service /etc/systemd/system/
sudo mv /tmp/shutter-trigger.service /etc/systemd/system/
sudo mv /tmp/photo-server.service /etc/systemd/system/

# systemdを再読み込み
sudo systemctl daemon-reload

# サービスを有効化（起動時に自動起動）
sudo systemctl enable camera-control
sudo systemctl enable shutter-trigger
sudo systemctl enable photo-server

# サービスを起動
sudo systemctl start camera-control
sudo systemctl start shutter-trigger
sudo systemctl start photo-server

# サービスの状態を確認
sudo systemctl status camera-control
sudo systemctl status shutter-trigger
sudo systemctl status photo-server
```

## 4. 動作確認

```bash
# ログを確認
tail -f /home/pi/camera_control.log
tail -f /home/pi/shutter_trigger.log
journalctl -u photo-server -f

# Webブラウザでアクセス
# スマホやPCのブラウザで以下にアクセス：
# - http://192.168.1.100:8000  （写真閲覧）
# - http://192.168.1.100:8001  （設定・操作）
```

## 5. トラブルシューティング

### サービスが起動しない場合

```bash
# エラーログを確認
sudo journalctl -u camera-control -n 50
sudo journalctl -u shutter-trigger -n 50
sudo journalctl -u photo-server -n 50

# サービスを再起動
sudo systemctl restart camera-control
sudo systemctl restart photo-server
sudo systemctl restart shutter-trigger
```

### カメラが認識されない場合

```bash
# カメラの確認
vcgencmd get_camera

# libcameraでカメラをテスト
libcamera-still -o test.jpg
```

### 設定を変更した場合

```bash
# サービスを再起動して設定を反映
sudo systemctl restart shutter-trigger
```

## 6. 再起動とテザリング環境での利用

### 自動起動の設定（再起動対策）

Raspberry Piの電源を切っても、次回起動時に自動的にシステムが立ち上がるように設定します。

```bash
# 以下のコマンドを一度だけ実行してください
sudo systemctl enable camera-control
sudo systemctl enable shutter-trigger
sudo systemctl enable photo-server
```

### テザリング（外出先）での利用方法

外出先でスマートフォンのテザリングなどを使用する場合、Wi-Fiの接続設定とアクセス方法に注意が必要です。

#### 1. Wi-Fi設定の追加

Raspberry PiにテザリングのSSIDとパスワードを登録します。

```bash
sudo nano /etc/wpa_supplicant/wpa_supplicant.conf
```

ファイルの末尾に以下を追加してください：

```text
network={
    ssid="あなたのスマホのSSID"
    psk="パスワード"
    priority=1
}
```

#### 2. アクセス方法（mDNSの利用）

テザリング環境ではIPアドレスが変わる可能性があるため、IPアドレスの代わりに「ホスト名」を使ってアクセスすることをお勧めします。

*   **iPhone / Mac / Windows (iTunesインストール済み) の場合:**
    *   ギャラリー: `http://raspberrypi.local:8000`
    *   設定画面: `http://raspberrypi.local:8001`

※ `raspberrypi` の部分は、Raspberry Piのホスト名設定（デフォルトは raspberrypi）に依存します。

#### 3. IPアドレスがわからない場合

もし `raspberrypi.local` でアクセスできない場合は、スマホのテザリング設定画面で「接続されているデバイス」を確認し、Raspberry Piに割り当てられたIPアドレスを探してください。

---

## 変更点まとめ

1.  **shutter_trigger.py**: 撮影後の待機時間を3秒追加（フリーズ対策）、`libcamera-still`への完全移行
2.  **light_detection_algorithm.py**: 検知ロジックを`libcamera-still`ベースに変更（安定化）
3.  **camera_control.py**: UI改善（露出モード削除、WB追加）、監視制御機能の追加
4.  **server.py**: ポート再利用設定の追加、`/api/photos`エンドポイントの実装
5.  **index.html**: UI刷新（シンプル化、ステータス表示強化）
6.  **gallery.html**: 写真一覧取得ロジックの修正
