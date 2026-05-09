# PiCamera Control 運用ガイド

## 1. システム概要
Raspberry Pi + カメラで光変化を検知して撮影し、iOS アプリから設定・閲覧・編集を行うシステムです。

主な構成:
- Pi 側: `home 3/api_server.py`, `home 3/camera_service.py`, `home 3/wifi_manager.py`
- iOS 側: `PiCameraControl/`

### 1.1 デジタルバックと光検知の意図（シャッター幕が開く瞬間）

本システムは、大判・中判などで **デジタルバック**として Pi ＋イメージセンサーを **レンズシャッターの後ろ**に載せる運用を想定している。

- **シャッター幕が開く**と、センサーへ入射する光が一瞬で **増える**（幕が閉じている間はほぼ光が来ない、または極端に暗い状態から明るい状態へ遷移する）。
- `camera_service.py` の自動撮影は、この **明るさの上昇（正の変化）** を検知して撮影する。実装は `capture_request()` の連続取得で得た明るさを、**直前ループのスムージング済み値**（直近数フレーム相当の中央値）と比較している。**「前回撮影したときの明るさ」とは比較しない。**
- したがって挙動は「**幕が開いて光が入った**」というイベントに寄せて設計されており、**増光トリガー**としてはデジタルバックの機械論理と整合的である。
- 一方、**F値だけを上げる（絞る）**操作は、幕開きとは別の操作であり、かつセンサー上の明るさは **減る方向** に動きやすい。コードは **負の変化を自動撮影の条件から除外**しているため、**絞り操作だけでは自動撮影は発火しない**（これはバグではなく、幕開き＝増光検知という前提に対する仕様）。絞り込みを含む意図的な1枚は **iOS アプリの手動撮影**などで行う。
- **絞り込んだうえでシャッターを切った**場合は話が別である。前回より **F値が高い（絞っている）** と、幕が開いた瞬間にセンサーへ入る光の **立ち上がりが小さく** なり、明るさの **変化率・変化量** が `camera_service` の条件（`brightness_threshold` 等）を **満たさず自動撮影が走らない**ことがある。**そのときは閾値を下げるのが妥当な調整**である（誤作動が増えうるので少しずつ下げ、必要なら `check_interval` や暗所時の最小変化量ロジックも意識する）。設定は iOS の設定画面または `POST /api/settings` で `brightness_threshold` / `detection_threshold` を変更する。

## 2. 接続情報

### AP モード（デフォルト）
- SSID: `PiCamera`
- PASS: `picamera123`
- API: `http://192.168.4.1:8001`

### テザリング（家 Wi-Fi）
- API: `http://raspberrypi.local:8001`

### iPhone から SSH（現地でログ確認・再起動・軽微な修正）

Pi 側で **OpenSSH サーバ（`ssh`）が有効**であれば、Mac と同様に iPhone から入れる。HTTP API だけでは直せない事象（サービス再起動、`journalctl`、設定ファイルの1行修正など）向け。

1. **接続先 Wi-Fi**
   - **AP モード**: iPhone を `PiCamera` に接続 → ホスト `192.168.4.1`、ユーザー `pi`（初回は Raspberry Pi OS のパスワード）。
   - **テザリング**: iPhone を Pi と **同じ家 Wi-Fi** にし、`ssh pi@raspberrypi.local`（mDNS が効かない環境では Pi の実 IP を使う）。
2. **クライアント**: Termius、Blink Shell、Prompt など任意の SSH アプリ。可能なら **公開鍵認証**を登録しておくと、小画面でのパスワード入力が減る。
3. **よく使う例**（AP 接続時）: `journalctl -u api-server -u camera-service -n 80 --no-pager`、`sudo systemctl restart api-server camera-service`。

**注意**: Pi の AP や家 LAN の **中だけ**なら通常は問題になりにくい。インターネット側からそのまま 22 番を晒す構成は避け、遠隔から触りたい場合は **Tailscale 等の VPN** や **SSH 踏み台**を別途検討すること。

## 3. 重要運用ルール
- Wi-Fi 切替は排他制御されるため、短時間連打しない
- AP/テザリング関連変更は実機デプロイして確認する
- API 追加時は Pi 側実装と iOS 側モデル/API クライアントを合わせて更新する

## 4. 基本コマンド

```bash
# Python 構文確認
python -m py_compile "home 3/api_server.py"

# Pi へデプロイ（家Wi-Fi）
cd "home 3" && bash ./update.sh raspberrypi.local

# Pi へデプロイ（AP）
cd "home 3" && bash ./update.sh 192.168.4.1

# Wi-Fi 切替試験
cd "home 3" && bash ./wifi_cycle_test.sh
```

### 4.1 デプロイ後の zram（AP で apt が使えないとき）

- `update.sh` は `home 3/vendor/debian/zram-tools_*_all.deb` を Pi の `/home/pi/` にコピーする（bookworm の公式 `all` パッケージ）。
- Pi 上で性能調整を一括適用: `bash ~/tune_performance_zero2w.sh`  
  （ネット無しでも、上記 deb があれば `dpkg -i` で `zram-tools` を入れてから `zramswap` を有効化する）
- **USB OTG** 経由の例: Mac 側で `cd "home 3" && SSHPASS='...' bash ./update.sh 192.168.7.2`

## 5. 主要 API
- `GET/POST /api/settings`: 設定の取得/更新
- `GET /api/wifi/status`: Wi-Fi 状態
- `POST /api/wifi/switch`: AP/テザリング切替
- `GET /api/photos`: 写真一覧
- `POST /api/photo`: 写真取得（サムネ対応）
- `POST /api/capture`: 手動撮影
- `GET /api/sensor/status`: センサー状態
- `GET /api/status`: 状態（`server_time_unix` 含む。AP 単独で NTP が効かないときの時刻合わせ用）
- `POST /api/system/time`: ボディ `{"unix_time": <1970年からの秒>}` で Pi システム時刻を設定（`sudo date`、iOS は接続時に自動送信）

## 6. 白飛び・露出トラブル対応

### 症状
- 写真が全体的に白飛びする
- 日中だけ極端に露出オーバーになる

### 主な原因
- `iso` / `shutter_speed` が手動固定で保存され、AE が無効化されている
- センサー側の gain 下限（1.0）により、強い入射光を抑えきれない

### 設定確認

```bash
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool
# iso が "auto"、shutter_speed が "auto" かを確認
```

### 復旧手順

```bash
curl -X POST http://192.168.4.1:8001/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"iso":"auto","shutter_speed":"auto"}'
ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"
```

### 日中運用の実践値
- レンズ絞りは `f/8` 以上を推奨（快晴時は `f/11`〜`f/16`）
- ND フィルターを併用すると白飛びを抑えやすい
- 手動露出値はモード変更後も残る場合があるため注意

## 7. トラブル時の最短確認

```bash
ping 192.168.4.1
ping raspberrypi.local

ssh pi@192.168.4.1 "systemctl status api-server camera-service"
ssh pi@192.168.4.1 "journalctl -u camera-service -n 50 --no-pager"
```

詳細ランブック: `docs/runbook/TROUBLESHOOTING.md`

## 8. USB OTG（Wi-Fi なしで書き換え）

Pi Zero / Zero 2 W のデータ用 USB を gadget 化し、PC から USB Ethernet 経由で SSH する手順は `docs/runbook/USB_OTG.md` を参照。  
補助スクリプト: `home 3/enable_usb_otg_gadget.sh`（Pi 上で `sudo bash ... --ether` 実行後に再起動）。  
`home 3/update.sh` 実行時に **`usb0-static-ip.service`**（Pi 側 `192.168.7.2/24`、`ip addr replace` で冪等）も配置・有効化を試みる。
