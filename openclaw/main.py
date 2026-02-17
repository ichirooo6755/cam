import os
import sys
import shutil
import subprocess
from datetime import datetime

# パス解決: 常に実行ファイルの階層を基準にする
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(CURRENT_DIR)

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, MessageHandler, CallbackQueryHandler, filters, ContextTypes
from skills import skills_engine
from utils.claude_wrapper import run_claude
import config

# グローバル状態管理
STATE = {
    "sleep_mode": False,
    "pending_prompt": None,
    "last_task_desc": ""
}

REPORT_PATH = os.path.join(CURRENT_DIR, "../shared_memory/REPORT.md")
EXPORT_DIR = os.path.join(CURRENT_DIR, "../shared_memory/exports/")

# --- 物理操作実行エンジン (OpenClawの手足) ---

def execute_physical_tasks(claude_output):
    """Claudeの回答から命令を抽出して実行する"""
    logs = []
    
    # 1. コンテキスト管理: /export
    if "OpenClaw: /export" in claude_output:
        os.makedirs(EXPORT_DIR, exist_ok=True)
        filename = f"export_{datetime.now().strftime('%Y%m%d_%H%M%S')}.md"
        shutil.copy(REPORT_PATH, os.path.join(EXPORT_DIR, filename))
        logs.append(f"📦 Exported to {filename}")

    # 2. コンテキスト管理: /clear
    if "OpenClaw: /clear" in claude_output:
        with open(REPORT_PATH, "w", encoding="utf-8") as f:
            f.write(f"# Context Cleared at {datetime.now()}\n")
        logs.append("🧹 Context Cleared")

    # 3. Git Push
    if "OpenClaw: PUSH" in claude_output:
        msg = "Auto commit by OpenClaw"
        subprocess.run(["git", "add", "."], cwd=os.path.join(CURRENT_DIR, ".."))
        subprocess.run(["git", "commit", "-m", msg], cwd=os.path.join(CURRENT_DIR, ".."))
        subprocess.run(["git", "push"], cwd=os.path.join(CURRENT_DIR, ".."))
        logs.append("🚀 Git Pushed")

    # 4. Raspberry Pi デプロイ
    if "OpenClaw: DEPLOY_RPI" in claude_output:
        rpi_dest = f"pi@{config.RPI_HOST}:{config.RPI_PATH}"
        subprocess.run(["rsync", "-avz", "--exclude", "node_modules", ".", rpi_dest], cwd=os.path.join(CURRENT_DIR, ".."))
        logs.append("📡 Deployed to Raspberry Pi Zero 2 W")

    # 5. テスト実行
    if "OpenClaw: RUN_TEST" in claude_output:
        # デフォルトで pytest を想定
        res = subprocess.run(["pytest"], capture_output=True, text=True, cwd=os.path.join(CURRENT_DIR, ".."))
        logs.append(f"🧪 Test Result: {'✅ Pass' if res.returncode == 0 else '❌ Fail'}\n{res.stdout[:200]}")

    return logs

# --- Telegram ハンドラ ---

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text
    
    if text == "睡眠":
        STATE["sleep_mode"] = True
        await update.message.reply_text("💤 睡眠モード（全自動・自律判断）に移行しました。")
        return
    if text == "起床":
        STATE["sleep_mode"] = False
        await update.message.reply_text("☀️ 起床しました。重要な判断は確認を求めます。")
        return

    # 戦略立案 (Claudeに指示出し)
    sys_inst = skills_engine.get_system_instruction()
    refined_prompt = f"{sys_inst}\n\nユーザーの現在の要求: {text}"
    STATE["pending_prompt"] = refined_prompt
    STATE["last_task_desc"] = text

    if STATE["sleep_mode"]:
        await execute_cycle(update, refined_prompt)
    else:
        keyboard = [[InlineKeyboardButton("🚀 実行を承認", callback_data="approve")]]
        await update.message.reply_text(
            f"🤔 **Claudeが戦略を立てました**\n\n指示内容: {text}\n\n"
            "Claudeは自ら優先順位を決め、必要に応じて物理操作（デプロイ等）をOpenClawに命じます。実行しますか？",
            reply_markup=InlineKeyboardMarkup(keyboard)
        )

async def execute_cycle(update_obj, prompt):
    msg = await update_obj.effective_message.reply_text("⚙️ Claude & MCP Skills が思考・作業中...")
    
    # Claude実行
    response = run_claude(prompt)
    
    # 物理操作の検知と実行
    physical_logs = execute_physical_tasks(response)
    
    # 結果の構築
    log_text = "\n".join([f"・{l}" for l in physical_logs]) if physical_logs else "・物理操作なし"
    
    final_report = (
        f"🏁 **タスク完了報告**\n\n"
        f"【実行された物理操作】\n{log_text}\n\n"
        f"【Claudeの回答要約】\n{response[:1000]}..."
    )
    
    if "【重要判断】" in response:
        await update_obj.effective_message.reply_text(f"⚠️ **重要判断の要求:**\n\n{response}")
    else:
        await update_obj.effective_message.reply_text(final_report)

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    if query.data == "approve":
        await execute_cycle(query, STATE["pending_prompt"])

def main():
    # 起動ディレクトリをプロジェクトルートに固定
    os.chdir(os.path.join(CURRENT_DIR, ".."))
    
    app = ApplicationBuilder().token(config.TELEGRAM_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), handle_message))
    app.add_handler(CallbackQueryHandler(button_handler))
    
    print("🚀 OpenClaw v4.2 Autonomous System Started.")
    app.run_polling()

if __name__ == '__main__':
    main()