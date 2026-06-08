# openclaw 設定テンプレート
# 1. このファイルを config.py にコピー
# 2. 環境変数を設定するか、下記を直接編集（config.py は git に含めない）

import os

TELEGRAM_TOKEN = os.environ.get('TELEGRAM_TOKEN', '')
ALLOWED_USER_ID = int(os.environ.get('TELEGRAM_ALLOWED_USER_ID', '0'))
RPI_HOST = os.environ.get('RPI_HOST', '192.168.4.1')
RPI_PATH = os.environ.get('RPI_PATH', '/home/pi')
