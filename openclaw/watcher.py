import time
import os
import asyncio
from telegram import Bot
import config

# 監視対象のファイル（WindsurfのClaudeがここに追記するように設定）
REPORT_PATH = "shared_memory/REPORT.md"

async def watch_and_notify():
    if not config.TELEGRAM_TOKEN:
        raise RuntimeError(
            'TELEGRAM_TOKEN が未設定です。openclaw/.env を作成してください。'
            '漏洩した旧トークンは @BotFather で revoke してください。'
        )
    bot = Bot(token=config.TELEGRAM_TOKEN)
    last_size = os.path.getsize(REPORT_PATH) if os.path.exists(REPORT_PATH) else 0
    
    print(f"👀 Windsurfのログ監視を開始しました: {REPORT_PATH}")
    
    while True:
        try:
            current_size = os.path.getsize(REPORT_PATH)
            if current_size > last_size:
                with open(REPORT_PATH, "r", encoding="utf-8") as f:
                    f.seek(last_size)
                    new_content = f.read()
                
                if new_content.strip():
                    # Telegramに送信（1500文字制限で分割）
                    print(f"📩 新しいログを検知。送信中...")
                    await bot.send_message(chat_id=config.ALLOWED_USER_ID, text=f"🤖 Claudeの出力:\n\n{new_content[:1500]}")
                
                last_size = current_size
        except Exception as e:
            print(f"Error: {e}")
        
        await asyncio.sleep(2) # 2秒ごとにチェック

if __name__ == "__main__":
    asyncio.run(watch_and_notify())