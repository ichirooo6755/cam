# USB OTG（gadget）有効化 — Pi Zero / Zero 2 W

Pi Zero 系の **データ用 micro USB** を、PC 側から見た「USB デバイス」（gadget）として使うための設定です。  
Wi-Fi が使えないときに **USB 経由で SSH して書き換え・デプロイ**する用途向け。

## 前提

- 対象: **Raspberry Pi Zero / Zero W / Zero 2 W** の **中央の USB ポート**（「USB」の刻印側）。電源だけのポートでは OTG は使えません。
- OS: Raspberry Pi OS（Bookworm 想定）。ブート設定は **`/boot/firmware/`** にあります（古いイメージでは `/boot/`）。

## 1. カーネルに dwc2 を載せる（必須）

`/boot/firmware/config.txt` の末尾に次を追加します（重複しないように）。

```ini
dtoverlay=dwc2
```

## 2. gadget モードの選び方

### A. USB Ethernet（推奨・ヘッドレスで書き換えしやすい）

PC と USB ケーブルで接続すると、有線相当のインタフェースとして Pi が見え、SSH できます。

`/boot/firmware/cmdline.txt` は **1 行だけ**のファイルです。行末に **スペース区切り**で追記します。

追記例（既に `modules-load=...` がある場合は内容を調整し、**二重に書かない**こと）:

```text
modules-load=dwc2,g_ether
```

- 追記後に `sudo reboot`
- macOS では「RNDIS/ECM」としてネットワークインタフェースが増えることがあります。Pi のドキュメントに従い、必要なら **共有インターネット** を有効化
- 接続後、`ssh pi@raspberrypi.local` または表示されたアドレスへ SSH

### B. USB シリアル（コンソールだけ欲しい場合）

`cmdline.txt` に `modules-load=dwc2,g_serial` など、用途に応じたモジュールを載せる方式があります。  
詳細は [Raspberry Pi USB gadget 公式](https://www.raspberrypi.com/documentation/computers/configuration.html#usb-device-mode) を参照。

### C. USB 大容量ストレージ（マスストレージ gadget）

イメージを「USB メモリ」として見せる構成は **configfs** での設定が必要で、上記より手順が長いです。  
単に **ファイルの書き換え・update.sh 実行**が目的なら **A. USB Ethernet** を推奨します。

## 3. 自動追記スクリプト（Pi 上で実行）

リポジトリの `home 3/enable_usb_otg_gadget.sh` を Pi にコピーし、SSH で実行してください。

```bash
# Mac 側（例）
scp "home 3/enable_usb_otg_gadget.sh" pi@192.168.4.1:/home/pi/
ssh pi@192.168.4.1 "bash /home/pi/enable_usb_otg_gadget.sh --ether"
```

- `--ether`: `g_ether` を `cmdline.txt` に追記（未設定のときのみ）
- `--config-only`: `config.txt` に `dtoverlay=dwc2` だけ追加

実行後 **必ず再起動**します。

```bash
ssh pi@192.168.4.1 "sudo reboot"
```

## 4. Pi 側の固定 IP（usb0）

Mac 側を `192.168.7.1/24`、Pi 側を `192.168.7.2/24` にそろえると SSH が安定しやすいです。

- リポジトリの **`home 3/usb0-static-ip.service`** を `update.sh` が Pi に配置し、`systemctl enable --now` します（`ip addr replace` で **冪等**／既存アドレスがあっても失敗しません）。
- 手動のみの場合:

```bash
sudo install -m 644 /home/pi/usb0-static-ip.service /etc/systemd/system/usb0-static-ip.service
sudo systemctl daemon-reload
sudo systemctl enable --now usb0-static-ip.service
```

## 5. 既存の Wi-Fi AP との関係

- gadget 用の USB と **Wi-Fi AP は別物**です。USB で PC とつないでも、従来どおり `PiCamera` AP は動く構成にできます。
- `cmdline.txt` を誤って壊すと起動しないので、変更前にバックアップを取るか、スクリプトを使ってください。

## 6. トラブルシュート

| 症状 | 確認 |
|------|------|
| PC が Pi を認識しない | データ用 USB か、ケーブルがデータ対応か |
| 起動しない | `cmdline.txt` が複数行になっていないか、バックアップから復元 |
| gadget だけ欲しいがネットが二重 | NetworkManager の設定や `g_ether` のホスト側ドライバ |

詳細ランブック: `docs/runbook/TROUBLESHOOTING.md`
