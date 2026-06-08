"""openclaw 設定 — シークレットは環境変数または openclaw/.env から読み込む。"""

import os

# ローカル .env（gitignore 済み）
_env_path = os.path.join(os.path.dirname(__file__), '.env')
if os.path.exists(_env_path):
    with open(_env_path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, _, val = line.partition('=')
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))

TELEGRAM_TOKEN = os.environ.get('TELEGRAM_TOKEN', '')
ALLOWED_USER_ID = int(os.environ.get('TELEGRAM_ALLOWED_USER_ID', '0'))
RPI_HOST = os.environ.get('RPI_HOST', '192.168.4.1')
RPI_PATH = os.environ.get('RPI_PATH', '/home/pi')
