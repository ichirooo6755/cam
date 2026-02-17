# Pi側Python実装専用ルール

## コマンド
```bash
python -m py_compile *.py
bash ./update.sh raspberrypi.local
bash ./wifi_cycle_test.sh
```

## 制約
- Wi-Fi切替: `_WIFI_SWITCH_LOCK`, 409, 12秒CD
- IPC: JSON files (camera_settings.json等)
