# PiCamera Control v2

Raspberry Pi（IMX477）+ iOS アプリによる光検知・自動撮影システム。

## システム構成

| 層 | 技術 |
|---|---|
| カメラ | Raspberry Pi Camera HQ (Sony IMX477, 12MP) |
| Pi サーバー | Python / Picamera2 / Flask |
| iOS アプリ | SwiftUI / Swift Concurrency |
| 通信 | HTTP :8001、AP モード（192.168.4.1）またはテザリング |

## クイックスタート

```bash
# Pi へデプロイ（AP モード）
cd "home 3" && bash ./update.sh 192.168.4.1

# Pi へデプロイ（家 Wi-Fi）
cd "home 3" && bash ./update.sh raspberrypi.local

# iOS シミュレータビルド
bash PiCameraControl/build_ios_simulator.sh
```

接続: SSID `PiCamera` / パスワード `picamera123` → `http://192.168.4.1:8001`

## ドキュメント

| ファイル | 内容 |
|---|---|
| [`docs/operations/OPERATIONS.md`](docs/operations/OPERATIONS.md) | 接続情報・API・デプロイ手順・白飛び対応 |
| [`docs/runbook/TROUBLESHOOTING.md`](docs/runbook/TROUBLESHOOTING.md) | 総合トラブルシューティング |
| [`docs/architecture/performance.md`](docs/architecture/performance.md) | 省電力・性能最適化方針 |
| [`docs/changelog/DEV_STATUS_FULL.md`](docs/changelog/DEV_STATUS_FULL.md) | 直近の実施内容・未解決問題 |
| [`docs/plans/2026-02-18-ui-ux-redesign-design.md`](docs/plans/2026-02-18-ui-ux-redesign-design.md) | UI/UX 詳細設計（参考） |
