import asyncio
import unittest

from mijia_temp_bar.scheduler import (
    AdapterUnavailable,
    PollEngine,
    due_after_interval_change,
    is_stale,
    pick_next_due,
)

A, B = "A4:C1:38:8C:9B:32", "AA:BB:CC:DD:EE:FF"


class PickNextDueTests(unittest.TestCase):
    def test_nothing_configured(self):
        self.assertEqual(pick_next_due({}, [], 100.0, max_wait=60.0), (None, 60.0))

    def test_ready_devices_follow_priority_order(self):
        due = {A: 90.0, B: 50.0}
        self.assertEqual(pick_next_due(due, [A, B], 100.0), (A, 0.0))
        self.assertEqual(pick_next_due(due, [B, A], 100.0), (B, 0.0))

    def test_waits_until_earliest_due(self):
        self.assertEqual(pick_next_due({A: 130.0, B: 110.0}, [A, B], 100.0, max_wait=60.0), (None, 10.0))

    def test_wait_is_capped(self):
        self.assertEqual(pick_next_due({A: 1000.0}, [A], 100.0, max_wait=60.0), (None, 60.0))

    def test_ignores_ids_not_in_order(self):
        self.assertEqual(pick_next_due({A: 0.0}, [B], 100.0, max_wait=60.0), (None, 60.0))


class PolicyTests(unittest.TestCase):
    def test_is_stale(self):
        self.assertTrue(is_stale(None, 1000.0, threshold=300.0))
        self.assertFalse(is_stale(800.0, 1000.0, threshold=300.0))
        self.assertTrue(is_stale(699.0, 1000.0, threshold=300.0))

    def test_due_after_interval_change(self):
        self.assertEqual(due_after_interval_change(None, 300.0, 1000.0), 1000.0)
        self.assertEqual(due_after_interval_change(900.0, 300.0, 1000.0), 1200.0)
        self.assertEqual(due_after_interval_change(100.0, 300.0, 1000.0), 1000.0)


class Recorder:
    def __init__(self):
        self.successes, self.failures, self.adapter = [], [], []

    def on_poll_success(self, device_id, result, next_due):
        self.successes.append((device_id, result))

    def on_poll_failure(self, device_id, error, delay, failures):
        self.failures.append((device_id, type(error).__name__, delay, failures))

    def on_adapter_unavailable(self, error, delay):
        self.adapter.append(delay)


def quick_retry(failures, interval):
    return 0.05 * failures


class PollEngineTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.recorder = Recorder()
        self.reads = []
        self.bad = set()
        self.block = None
        self.engine = PollEngine(self._read, self.recorder, retry=quick_retry, adapter_retry=0.2, max_wait=0.05)
        self.engine.set_interval(0.1)
        self.task = asyncio.create_task(self.engine.run())

    async def asyncTearDown(self):
        self.task.cancel()
        try:
            await self.task
        except asyncio.CancelledError:
            pass

    async def _read(self, device_id):
        self.reads.append(device_id)
        if self.block is not None:
            await self.block.wait()
        if device_id in self.bad:
            raise asyncio.TimeoutError()
        return f"reading-{device_id}"

    async def test_reads_primary_first_and_repeats(self):
        self.engine.set_devices([A, B])
        await asyncio.sleep(0.35)
        self.assertEqual(self.reads[:2], [A, B])
        self.assertGreaterEqual(self.reads.count(A), 3)
        self.assertIn((A, f"reading-{A}"), self.recorder.successes)

    async def test_unreachable_device_does_not_block_others(self):
        self.bad.add(B)
        self.engine.set_devices([B, A])
        await asyncio.sleep(0.45)
        self.assertGreaterEqual(self.reads.count(A), 3)
        failures = [f for f in self.recorder.failures if f[0] == B]
        self.assertEqual([f[3] for f in failures[:2]], [1, 2])
        self.assertEqual(failures[0][1], "TimeoutError")
        self.assertAlmostEqual(failures[1][2], 0.1)

    async def test_refresh_resets_backoff(self):
        self.bad.add(A)
        self.engine.set_devices([A])
        await asyncio.sleep(0.12)
        self.bad.clear()
        self.engine.refresh(A)
        await asyncio.sleep(0.05)
        self.assertIn((A, f"reading-{A}"), self.recorder.successes)
        self.assertEqual(self.engine.failures(A), 0)

    async def test_removed_device_result_is_dropped(self):
        self.block = asyncio.Event()
        self.engine.set_devices([A])
        await asyncio.sleep(0.02)
        self.engine.set_devices([])
        self.block.set()
        await asyncio.sleep(0.05)
        self.assertEqual(self.recorder.successes, [])

    async def test_adapter_unavailable_is_not_a_device_failure(self):
        async def read(device_id):
            self.reads.append(device_id)
            raise AdapterUnavailable("電腦藍牙已關閉", None)

        engine = PollEngine(read, self.recorder, retry=quick_retry, adapter_retry=0.3, max_wait=0.05)
        engine.set_devices([A, B])
        task = asyncio.create_task(engine.run())
        await asyncio.sleep(0.15)
        task.cancel()
        self.assertEqual(self.reads, [A])
        self.assertEqual(self.recorder.adapter, [0.3])
        self.assertEqual(self.recorder.failures, [])
        self.assertEqual(engine.failures(A), 0)

    async def test_pause_waits_for_inflight_read_and_blocks_new_ones(self):
        self.block = asyncio.Event()
        self.engine.set_devices([A])
        await asyncio.sleep(0.02)
        pausing = asyncio.create_task(self.engine.pause())
        await asyncio.sleep(0.02)
        self.assertFalse(pausing.done())
        self.block.set()
        await asyncio.wait_for(pausing, 0.5)
        count = len(self.reads)
        await asyncio.sleep(0.2)
        self.assertEqual(len(self.reads), count)
        self.engine.resume()
        self.engine.refresh()
        await asyncio.sleep(0.05)
        self.assertGreater(len(self.reads), count)

    async def test_manual_refresh_preempts_a_backoff_probe(self):
        # B 連不到 (第一次失敗後進入退避)；B 重試期間手動更新 A，A 要插隊，B 的這次不算失敗
        slow = asyncio.Event()

        async def read(device_id):
            self.reads.append(device_id)
            if device_id == B:
                await slow.wait()
                raise asyncio.TimeoutError()
            return f"reading-{device_id}"

        engine = PollEngine(read, self.recorder, retry=lambda n, i: 0.05, max_wait=0.05)
        engine.set_interval(10.0)
        engine.set_devices([B, A])
        task = asyncio.create_task(engine.run())
        await asyncio.sleep(0.02)
        slow.set()                      # B 第一次失敗
        await asyncio.sleep(0.03)
        slow.clear()
        await asyncio.sleep(0.05)       # B 的退避重試卡在連線中
        self.assertEqual(engine.failures(B), 1)
        before = len(self.recorder.successes)
        engine.refresh(A)
        await asyncio.sleep(0.03)
        task.cancel()
        self.assertGreater(len(self.recorder.successes), before)
        self.assertEqual(self.recorder.successes[-1][0], A)
        self.assertEqual(engine.failures(B), 1)  # 被插隊中斷的那次不算失敗

    async def test_manual_refresh_does_not_preempt_a_healthy_read(self):
        self.block = asyncio.Event()
        self.engine.set_devices([A, B])
        await asyncio.sleep(0.02)       # A 正常讀取中
        self.engine.refresh(B)
        await asyncio.sleep(0.02)
        self.assertEqual(self.recorder.successes, [])
        self.block.set()
        await asyncio.sleep(0.05)
        self.assertEqual([s[0] for s in self.recorder.successes[:2]], [A, B])

    async def test_reprobe_reads_every_device_now_but_keeps_backoff(self):
        self.bad.add(B)
        self.engine.set_interval(10.0)
        self.engine.set_devices([A, B])
        await asyncio.sleep(0.05)       # A 成功、B 失敗一次
        count = len(self.reads)
        self.engine.reprobe()
        await asyncio.sleep(0.05)
        self.assertEqual(sorted(self.reads[count:count + 2]), sorted([A, B]))
        self.assertEqual(self.engine.failures(B), 2)  # 失敗次數保留 (逾時維持縮短)

    async def test_interval_change_rebases_healthy_devices(self):
        self.engine.set_devices([A])
        await asyncio.sleep(0.02)
        self.engine.set_interval(10.0)
        count = len(self.reads)
        await asyncio.sleep(0.2)
        self.assertEqual(len(self.reads), count)


if __name__ == "__main__":
    unittest.main()
