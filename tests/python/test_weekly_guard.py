import copy
import asyncio
import importlib.util
import json
from pathlib import Path
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, MagicMock


SPEC = importlib.util.spec_from_file_location(
    "weekly_guard", Path(__file__).resolve().parents[2] / "scripts/main/codex_weekly_guard.py"
)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
THREAD = "11111111-1111-4111-8111-111111111111"


def rates(used=49, slot="primary", **overrides):
    window = {"usedPercent": used, "windowDurationMins": 10080, "resetsAt": time.time() + 1000}
    window.update(overrides)
    return {"rateLimitsByLimitId": {"codex": {"limitId": "codex", slot: window}}}


class FakeRpc:
    def __init__(self, data=None):
        self.data = rates() if data is None else data
        self.goal = {"threadId": THREAD, "objective": "test goal", "status": "active",
                     "tokenBudget": 1000000, "tokensUsed": 600000}
        self.calls = []
        self.ignore_pause = False

    async def call(self, method, params):
        self.calls.append((method, params))
        if method == "thread/goal/get":
            return {"goal": copy.deepcopy(self.goal)}
        if method == "thread/goal/set":
            if not self.ignore_pause:
                self.goal["status"] = params["status"]
            return {"goal": copy.deepcopy(self.goal)}
        if method == "account/rateLimits/read":
            if isinstance(self.data, Exception):
                raise self.data
            return self.data
        raise AssertionError(method)


class QuotaTests(unittest.TestCase):
    def test_weekly_slot_is_not_assumed(self):
        for slot in ("primary", "secondary"):
            with self.subTest(slot=slot):
                self.assertEqual(guard.weekly_remaining(rates(15, slot)), 85)

    def test_single_bucket_compatibility(self):
        self.assertEqual(guard.weekly_remaining({"rateLimits": rates()["rateLimitsByLimitId"]["codex"]}), 51)

    def test_minimum_of_weekly_windows(self):
        data = rates(10)
        data["rateLimitsByLimitId"]["codex"]["secondary"] = rates(60)["rateLimitsByLimitId"]["codex"]["primary"]
        self.assertEqual(guard.weekly_remaining(data), 40)

    def test_short_window_does_not_substitute_for_weekly(self):
        with self.assertRaises(guard.GuardError):
            guard.weekly_remaining(rates(windowDurationMins=300))

    def test_invalid_usage_and_reset_fail_closed(self):
        for value in (None, True, -1, 101, float("nan"), float("inf"), "49"):
            with self.subTest(value=value), self.assertRaises(guard.GuardError):
                guard.weekly_remaining(rates(value))
        for value in (None, True, 0, time.time() - 1, float("inf"), "123"):
            with self.subTest(reset=value), self.assertRaises(guard.GuardError):
                guard.weekly_remaining(rates(resetsAt=value))

    def test_wrong_bucket_and_missing_data_fail_closed(self):
        for data in (None, [], {}, {"rateLimitsByLimitId": {}}, {"rateLimits": {"limitId": "other"}}):
            with self.subTest(data=data), self.assertRaises(guard.GuardError):
                guard.weekly_remaining(data)

    def test_cli_requires_explicit_target(self):
        self.assertTrue(guard.parse_args(["--check"]).check)
        self.assertEqual(guard.parse_args(["--thread", THREAD]).remaining, 50)
        with self.assertRaises(SystemExit):
            guard.parse_args([])
        with self.assertRaises(SystemExit):
            guard.parse_args(["--thread", "not-a-thread"])


class DecisionTests(unittest.IsolatedAsyncioTestCase):
    async def test_above_threshold_does_not_write(self):
        rpc = FakeRpc(rates(49))
        _, event, code = await guard.evaluate(rpc, THREAD, None, 50, "codex")
        self.assertEqual(code, 0)
        self.assertFalse(event["監視終了"])
        self.assertNotIn("thread/goal/set", [method for method, _ in rpc.calls])

    async def test_boundary_and_below_pause_only_status(self):
        for used in (50, 51, 100):
            with self.subTest(used=used):
                rpc = FakeRpc(rates(used))
                before = copy.deepcopy(rpc.goal)
                _, event, code = await guard.evaluate(rpc, THREAD, None, 50, "codex")
                self.assertEqual(code, 2)
                self.assertEqual(event["状態"], "paused")
                writes = [p for m, p in rpc.calls if m == "thread/goal/set"]
                self.assertEqual(writes, [{"threadId": THREAD, "status": "paused"}])
                before["status"] = "paused"
                self.assertEqual(rpc.goal, before)

    async def test_missing_quota_or_api_failure_attempts_pause(self):
        for data in ({}, guard.GuardError("unavailable")):
            rpc = FakeRpc(data)
            _, event, code = await guard.evaluate(rpc, THREAD, None, 50, "codex")
            self.assertEqual(code, 1)
            self.assertEqual(event["状態"], "paused")

    async def test_existing_inactive_goal_is_not_resumed(self):
        for status in ("paused", "blocked", "complete", "budgetLimited", "usageLimited"):
            rpc = FakeRpc()
            rpc.goal["status"] = status
            _, event, _ = await guard.evaluate(rpc, THREAD, None, 50, "codex")
            self.assertTrue(event["監視終了"])
            self.assertEqual(len(rpc.calls), 1)

    async def test_goal_replacement_is_not_modified(self):
        rpc = FakeRpc(rates(100))
        expected = {"objective": "original"}
        with self.assertRaises(guard.GuardError):
            await guard.evaluate(rpc, THREAD, expected, 50, "codex")
        self.assertEqual(rpc.goal["status"], "active")

    async def test_unconfirmed_pause_is_not_success(self):
        rpc = FakeRpc(rates(100))
        rpc.ignore_pause = True
        with self.assertRaises(guard.GuardError):
            await guard.evaluate(rpc, THREAD, None, 50, "codex")

    async def test_wrong_thread_is_not_modified(self):
        rpc = FakeRpc(rates(100))
        rpc.goal["threadId"] = "different"
        with self.assertRaises(guard.GuardError):
            await guard.evaluate(rpc, THREAD, None, 50, "codex")


class TransportTests(unittest.IsolatedAsyncioTestCase):
    def rpc(self, payload=None):
        rpc = guard.CodexRpc(timeout=0.02)
        reader = asyncio.StreamReader(limit=128)
        if payload is not None:
            reader.feed_data(payload)
            reader.feed_eof()
        rpc.proc = SimpleNamespace(
            stdin=SimpleNamespace(write=MagicMock(), drain=AsyncMock()), stdout=reader
        )
        return rpc

    async def test_notifications_are_not_responses(self):
        rpc = self.rpc(b'{"method":"notice"}\n{"id":9,"result":0}\n{"id":1,"result":{"ok":true}}\n')
        self.assertEqual(await rpc.call("test", {}), {"ok": True})
        request = json.loads(rpc.proc.stdin.write.call_args.args[0])
        self.assertEqual(request, {"id": 1, "method": "test", "params": {}})

    async def test_raw_error_is_not_exposed(self):
        rpc = self.rpc(b'{"id":1,"error":{"message":"private-account-data"}}\n')
        with self.assertRaises(guard.GuardError) as result:
            await rpc.call("test", {})
        self.assertNotIn("private-account-data", str(result.exception))

    async def test_eof_invalid_json_and_oversized_frames_fail(self):
        for payload in (b'', b'not-json\n', b'[]\n', b'x' * 256 + b'\n'):
            with self.subTest(payload=payload), self.assertRaises(guard.GuardError):
                await self.rpc(payload).call("test", {})

    async def test_timeout_is_bounded(self):
        with self.assertRaises(guard.GuardError):
            await self.rpc().call("test", {})


if __name__ == "__main__":
    unittest.main()
