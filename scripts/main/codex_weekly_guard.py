"""Weekly Codex quota guard, runnable from Bash with Python 3.10+."""

import argparse
import asyncio
import json
import math
import time
import uuid


class GuardError(Exception):
    """A sanitized error; never include raw account or server responses."""


class CodexRpc:
    def __init__(self, command="codex", timeout=15):
        self.command = command
        self.timeout = timeout
        self.proc = None
        self.sequence = 0

    async def __aenter__(self):
        self.proc = await asyncio.create_subprocess_exec(
            self.command, "app-server",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            limit=1048576,
        )
        try:
            await self.call("initialize", {
                "clientInfo": {"name": "weekly-quota-guard", "version": "1.0"},
                "capabilities": {"experimentalApi": True},
            })
            self.proc.stdin.write(b'{"method":"initialized"}\n')
            await self.proc.stdin.drain()
            return self
        except BaseException:
            await self.__aexit__(None, None, None)
            raise

    async def __aexit__(self, *_):
        if self.proc is None:
            return
        if self.proc.returncode is None:
            self.proc.stdin.close()
        try:
            await asyncio.wait_for(self.proc.wait(), 5)
        except asyncio.TimeoutError:
            try:
                self.proc.kill()
            except ProcessLookupError:
                pass
            await self.proc.wait()

    async def call(self, method, params):
        self.sequence += 1
        request = {"id": self.sequence, "method": method, "params": params}

        async def exchange():
            self.proc.stdin.write((json.dumps(request) + "\n").encode())
            await self.proc.stdin.drain()
            while True:
                line = await self.proc.stdout.readline()
                if not line:
                    raise GuardError("Codex からの応答が途切れました")
                reply = json.loads(line)
                if not isinstance(reply, dict):
                    raise GuardError("Codex 応答の形式が不正です")
                if reply.get("id") != self.sequence:
                    continue
                if "error" in reply:
                    raise GuardError(f"{method} が拒否されました")
                if "result" not in reply:
                    raise GuardError("Codex 応答に結果がありません")
                return reply["result"]

        try:
            return await asyncio.wait_for(exchange(), self.timeout)
        except (OSError, ValueError, asyncio.TimeoutError) as exc:
            raise GuardError("Codex API の通信または応答検証に失敗しました") from exc


def weekly_remaining(data, bucket_id="codex", now=None):
    if not isinstance(data, dict):
        raise GuardError("利用枠の形式が不正です")
    buckets = data.get("rateLimitsByLimitId")
    if isinstance(buckets, dict):
        bucket = buckets.get(bucket_id)
    else:
        bucket = data.get("rateLimits")
    if not isinstance(bucket, dict) or bucket.get("limitId") != bucket_id:
        raise GuardError("対象の利用枠を特定できません")
    now = time.time() if now is None else now
    remaining = []
    for name in ("primary", "secondary"):
        window = bucket.get(name)
        if window is None:
            continue
        if not isinstance(window, dict):
            raise GuardError("利用期間の形式が不正です")
        if window.get("windowDurationMins") != 10080:
            continue
        used, resets = window.get("usedPercent"), window.get("resetsAt")
        if (type(used) not in (int, float) or not math.isfinite(used)
                or not 0 <= used <= 100 or type(resets) not in (int, float)
                or not math.isfinite(resets) or resets <= now):
            raise GuardError("週間利用枠が不正または期限切れです")
        remaining.append(100 - used)
    if not remaining:
        raise GuardError("7日間の利用枠を確認できません")
    return min(remaining)


async def read_goal(rpc, thread):
    result = await rpc.call("thread/goal/get", {"threadId": thread})
    goal = result.get("goal") if isinstance(result, dict) else None
    if (not isinstance(goal, dict) or not isinstance(goal.get("objective"), str)
            or not goal["objective"].strip()):
        raise GuardError("対象の Goal が見つかりません")
    if goal.get("threadId") != thread or goal.get("status") not in {
        "active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"
    }:
        raise GuardError("対象の Goal を安全に識別できません")
    if (type(goal.get("tokensUsed")) is not int or goal["tokensUsed"] < 0
            or (goal.get("tokenBudget") is not None
                and (type(goal["tokenBudget"]) is not int or goal["tokenBudget"] < 1))):
        raise GuardError("Goal の予算・使用履歴の形式が不正です")
    return goal


async def pause_goal(rpc, thread, expected):
    before = await read_goal(rpc, thread)
    if before["objective"] != expected["objective"]:
        raise GuardError("監視中に Goal が変更されたため操作を中止しました")
    if before["status"] != "active":
        return before["status"]
    # Resume would compete for the thread writer. Only change persisted goal status.
    await rpc.call("thread/goal/set", {"threadId": thread, "status": "paused"})
    after = await read_goal(rpc, thread)
    if (after["status"] != "paused" or after["objective"] != before["objective"]
            or after.get("tokenBudget") != before.get("tokenBudget")
            or after.get("tokensUsed", -1) < before.get("tokensUsed", 0)):
        raise GuardError("Goal の停止または履歴維持を確認できません")
    return "paused"


async def evaluate(rpc, thread, expected, threshold, bucket):
    goal = await read_goal(rpc, thread)
    if expected is not None and goal["objective"] != expected["objective"]:
        raise GuardError("監視対象の Goal が変更されました")
    if goal["status"] != "active":
        return goal, {"状態": goal["status"], "監視終了": True}, 0
    try:
        data = await rpc.call("account/rateLimits/read", {})
        remaining = weekly_remaining(data, bucket)
    except GuardError:
        status = await pause_goal(rpc, thread, goal)
        return goal, {"状態": status, "理由": "週間残量を確認できないため停止", "監視終了": True}, 1
    if remaining <= threshold:
        status = await pause_goal(rpc, thread, goal)
        return goal, {"状態": status, "週間残量％": remaining, "監視終了": True}, 2
    return goal, {"状態": "監視中", "週間残量％": remaining, "監視終了": False}, 0


def emit(event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


async def run(args):
    expected = None
    while True:
        async with CodexRpc(args.codex) as rpc:
            if args.check:
                remaining = weekly_remaining(await rpc.call("account/rateLimits/read", {}), args.bucket)
                emit({"週間残量％": remaining, "停止条件": remaining <= args.remaining})
                return 0
            expected, event, code = await evaluate(rpc, args.thread, expected, args.remaining, args.bucket)
            emit(event)
            if event["監視終了"] or args.once:
                return code
        await asyncio.sleep(args.interval)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="週間残量が基準以下なら指定 Goal の自動継続を停止")
    parser.add_argument("--check", action="store_true", help="残量の読取のみ。Goal は変更しない")
    parser.add_argument("--thread", type=lambda value: str(uuid.UUID(value)), help="監視対象のスレッド ID")
    parser.add_argument("--once", action="store_true", help="判定を1回だけ実行")
    parser.add_argument("--remaining", type=int, default=50, choices=range(1, 101), metavar="1-100")
    parser.add_argument("--interval", type=int, default=30, choices=range(1, 301), metavar="1-300")
    parser.add_argument("--bucket", default="codex", help="利用枠 ID。既定は codex")
    parser.add_argument("--codex", default="codex", help="利用する Codex 実行ファイル")
    args = parser.parse_args(argv)
    if not args.check and not args.thread:
        parser.error("--thread または --check が必要です")
    if args.check and (args.thread or args.once):
        parser.error("--check と --thread / --once は併用できません")
    return args


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(run(parse_args())))
    except KeyboardInterrupt:
        emit({"エラー": "監視を終了しました。Goal の状態は自動では変更していません"})
        raise SystemExit(130)
    except (GuardError, OSError):
        emit({"エラー": "監視に失敗しました。Goal の停止は保証できません。状態を確認してください"})
        raise SystemExit(1)
