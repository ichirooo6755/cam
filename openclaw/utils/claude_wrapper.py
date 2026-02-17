import subprocess
import os
import sys

def run_claude(prompt):
    """
    Claude Code CLIをサブプロセスとして呼び出し、出力を回収する。
    """
    # 実行コマンドの構築
    # --non-interactive: Yes/Noの確認で止まらないようにする
    # -p: プロンプト（指示）を直接渡す
    command = ["claude", "--non-interactive", "-p", prompt]

    try:
        # 1. Claudeの実行
        # stdout=PIPEで結果をキャッチし、stderr=PIPEでエラーをキャッチ
        process = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=600,  # 10分でタイムアウト（大規模作業用）
            encoding='utf-8'
        )

        stdout = process.stdout
        stderr = process.stderr

        # 2. ログの保存 (shared_memory/REPORT.md)
        # 後でOpenClawが読み取れるように結果をファイルに書き出す
        report_path = os.path.join(os.getcwd(), "shared_memory/REPORT.md")
        with open(report_path, "a", encoding="utf-8") as f:
            f.write(f"\n\n--- [PROMPT] ---\n{prompt[:100]}...\n")
            f.write(f"--- [STDOUT] ---\n{stdout}\n")
            if stderr:
                f.write(f"--- [STDERR] ---\n{stderr}\n")

        # 3. エラー処理
        if process.returncode != 0:
            if "rate limit" in stderr.lower():
                return f"⚠️ 【RATE LIMIT】制限に達しました。5時間後の回復を待つか、APIキーを確認してください。\n{stderr}"
            return f"❌ 【CLI ERROR】\n{stderr}"

        # 4. 結果を返す
        return stdout

    except subprocess.TimeoutExpired:
        return "⏰ 【TIMEOUT】Claudeの応答が制限時間を超えました。"
    except Exception as e:
        return f"🚨 【SYSTEM ERROR】{str(e)}"