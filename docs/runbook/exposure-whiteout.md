# 白飛び・露出トラブル対応ランブック

## 症状
- 写真が全体的に白飛びする
- 日中だけ極端に露出オーバーになる

## 主な原因
- `iso` / `shutter_speed` が手動固定で保存され、AE が無効化されている
- センサー側の gain 下限（1.0）により、強い入射光を抑えきれない

## まず行う確認

```bash
curl -s http://192.168.4.1:8001/api/settings | python3 -m json.tool
```

確認ポイント:
- `iso` が `"auto"` か
- `shutter_speed` が `"auto"` か

## 復旧手順（推奨）

```bash
curl -X POST http://192.168.4.1:8001/api/settings \
  -H 'Content-Type: application/json' \
  -d '{"iso":"auto","shutter_speed":"auto"}'

ssh pi@192.168.4.1 "sudo systemctl restart camera-service api-server"
```

## 日中運用の実践値
- レンズ絞りは `f/8` 以上を推奨（快晴時は `f/11`〜`f/16`）
- ND フィルターを併用すると白飛びを抑えやすい

## 注意点
- 手動露出値を設定すると、モード変更後も残る場合がある
- 1枚目は露出が外れることがあるため、連続撮影で傾向を確認する

## 詳細調査先
- `home 3/TROUBLESHOOTING.md`
