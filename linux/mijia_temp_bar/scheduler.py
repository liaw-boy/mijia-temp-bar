"""原廠直連裝置的輪詢排程：一次只讀一台、每台各自的到期時間與離線退避。

排程判斷為純函式 (可單元測試)；PollEngine 只依賴 asyncio，讀取動作由外部注入，
所以不需要藍牙也能測試。所有方法都必須在同一個 asyncio 事件迴圈執行緒中呼叫。
"""

import asyncio
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Dict, List, Mapping, Optional, Protocol, Sequence, Tuple

from .backoff import retry_delay
from .logger import mijia_log

MAX_WAIT = 60.0                  # 每次最多等 60 秒就重新檢查 (睡眠喚醒後能及時補讀)
ADAPTER_RETRY = 15.0             # 藍牙未開啟時，全部裝置延後多久再試
BROADCAST_STALE_SECONDS = 300.0  # 開源廣播裝置超過此時間沒收到廣播即視為不在範圍內


def pick_next_due(due: Mapping[str, float], order: Sequence[str], now: float,
                  max_wait: float = MAX_WAIT) -> Tuple[Optional[str], float]:
    """回傳 (現在該讀的裝置, 等待秒數)。

    已到期的裝置依 order 的順序挑第一台 (主裝置排在最前面)；都還沒到期時回傳 None
    與距離最早到期的秒數 (最多 max_wait)。
    """
    candidates = [device_id for device_id in order if device_id in due]
    for device_id in candidates:
        if due[device_id] <= now:
            return device_id, 0.0
    if not candidates:
        return None, max_wait
    earliest = min(due[device_id] for device_id in candidates)
    return None, min(max(0.0, earliest - now), max_wait)


def is_stale(last_seen: Optional[float], now: float, threshold: float = BROADCAST_STALE_SECONDS) -> bool:
    return last_seen is None or now - last_seen > threshold


def due_after_interval_change(last_success: Optional[float], interval: float, now: float) -> float:
    """調整間隔後的下次到期時間：以上次成功時間重新起算，已過期就立刻讀。"""
    if last_success is None:
        return now
    return max(now, last_success + interval)


class AdapterUnavailable(Exception):
    """電腦藍牙無法使用 (關閉、未授權、沒有藍牙)：不算任何一台裝置的失敗。"""

    def __init__(self, status: str, hint: Optional[str] = None):
        super().__init__(status)
        self.status = status
        self.hint = hint


class PollListener(Protocol):
    def on_poll_success(self, device_id: str, result: Any, next_due: float) -> None: ...
    def on_poll_failure(self, device_id: str, error: BaseException, delay: float, failures: int) -> None: ...
    def on_adapter_unavailable(self, error: AdapterUnavailable, delay: float) -> None: ...
    def on_poll_preempted(self, device_id: str) -> None: ...


@dataclass
class _Runtime:
    due: float
    failures: int = 0
    last_success: Optional[float] = None
    # 手動更新前已連續失敗 (退避被手動重設)：這次連線仍視為連不到的裝置，可被另一台的手動更新插隊
    was_failing: bool = False


class PollEngine:
    def __init__(self, read: Callable[[str], Awaitable[Any]], listener: PollListener, *,
                 clock: Callable[[], float] = time.time,
                 retry: Callable[[int, float], float] = retry_delay,
                 adapter_retry: float = ADAPTER_RETRY, max_wait: float = MAX_WAIT):
        self._read = read
        self._listener = listener
        self._clock = clock
        self._retry = retry
        self._adapter_retry = adapter_retry
        self._max_wait = max_wait
        self._interval = 300.0
        self._order: List[str] = []
        self._runtimes: Dict[str, _Runtime] = {}
        self._paused = False
        self._priority: List[str] = []             # 手動要求更新的裝置，下次優先讀
        self._current: Optional[asyncio.Future] = None
        self._current_id: Optional[str] = None
        self._preempted = False
        self.hold_preemption = False  # 讀裝置歷史期間 (當下數值已讀到) 不讓手動更新插隊，否則會丟掉讀數
        self._wake = asyncio.Event()
        self._idle = asyncio.Event()
        self._idle.set()

    # MARK: - 設定 (同一事件迴圈中呼叫)

    def set_devices(self, device_ids: Sequence[str]) -> None:
        """設定要輪詢的裝置與優先順序；新裝置立刻到期，移除的裝置丟棄其狀態。"""
        now = self._clock()
        self._order = list(device_ids)
        self._runtimes = {i: self._runtimes.get(i) or _Runtime(due=now) for i in self._order}
        self._priority = [i for i in self._priority if i in self._runtimes]
        self._wake.set()

    def set_interval(self, seconds: float) -> None:
        """調整間隔：正常的裝置以上次成功時間重新起算；退避中的裝置維持原排程。"""
        self._interval = seconds
        now = self._clock()
        for runtime in self._runtimes.values():
            if runtime.failures == 0:
                runtime.due = due_after_interval_change(runtime.last_success, seconds, now)
        self._wake.set()

    def refresh(self, device_id: Optional[str] = None) -> None:
        """立刻更新指定裝置 (None 為全部)，並重設其退避。

        若目前正在對另一台連不到的裝置連線 (離線重試，或對它的手動更新)，先中斷那次 (不算失敗)，
        否則手動更新要等它連線逾時才會開始。
        """
        now = self._clock()
        targets = [key for key in self._runtimes if device_id is None or key == device_id]
        for key in targets:
            runtime = self._runtimes[key]
            runtime.was_failing = runtime.was_failing or runtime.failures > 0
            runtime.due = now
            runtime.failures = 0
            if key not in self._priority:
                self._priority.append(key)
        current = self._runtimes.get(self._current_id) if self._current_id else None
        if (self._current is not None and self._current_id not in targets and not self.hold_preemption
                and current is not None and (current.failures > 0 or current.was_failing)):
            # 讀取剛好已結束時 cancel() 回傳 False，不能留下旗標，否則之後關閉時的取消會被當成插隊吞掉
            self._preempted = self._current.cancel()
        self._wake.set()

    def reprobe(self) -> None:
        """換地方 (喚醒、換網路) 時所有裝置立刻重讀一次；失敗次數保留，久未出現的裝置逾時仍較短。"""
        now = self._clock()
        for runtime in self._runtimes.values():
            runtime.due = now
        self._wake.set()

    async def pause(self) -> None:
        """暫停輪詢，並等目前進行中的讀取結束 (搜尋新裝置前使用)。"""
        self._paused = True
        await self._idle.wait()

    def resume(self) -> None:
        self._paused = False
        self._wake.set()

    def failures(self, device_id: str) -> int:
        runtime = self._runtimes.get(device_id)
        return runtime.failures if runtime else 0

    def next_due(self, device_id: str) -> Optional[float]:
        runtime = self._runtimes.get(device_id)
        return runtime.due if runtime else None

    # MARK: - 主迴圈

    async def run(self) -> None:
        while True:
            if self._paused:
                device_id, wait = None, self._max_wait
            else:
                due = {key: runtime.due for key, runtime in self._runtimes.items()}
                order = self._priority + [i for i in self._order if i not in self._priority]
                device_id, wait = pick_next_due(due, order, self._clock(), self._max_wait)
            if device_id is None:
                await self._sleep(wait)
            else:
                await self._read_one(device_id)

    async def _sleep(self, seconds: float) -> None:
        try:
            await asyncio.wait_for(self._wake.wait(), timeout=seconds)
        except asyncio.TimeoutError:
            pass
        self._wake.clear()

    async def _read_one(self, device_id: str) -> None:
        if device_id in self._priority:
            self._priority.remove(device_id)
        self._idle.clear()
        self._current_id = device_id
        self._current = asyncio.ensure_future(self._read(device_id))
        try:
            result = await self._current
        except asyncio.CancelledError:
            if self._preempted:
                self._preempted = False
                mijia_log(f"手動更新插隊：中斷 [{device_id}] 的連線 (這台原本就連不到，不算失敗)")
                preempted = getattr(self._listener, "on_poll_preempted", None)
                if preempted is not None:
                    self._notify(preempted, device_id)
                return
            raise
        except AdapterUnavailable as e:
            self._delay_all(e)
        except Exception as e:  # 單一裝置的任何失敗都只影響它自己
            self._record_failure(device_id, e)
        else:
            self._record_success(device_id, result)
        finally:
            self._current = None
            self._current_id = None
            self._idle.set()

    def _record_success(self, device_id: str, result: Any) -> None:
        runtime = self._runtimes.get(device_id)
        if runtime is None:
            return  # 讀取期間被移除的裝置：結果丟棄
        now = self._clock()
        runtime.failures = 0
        runtime.was_failing = False
        runtime.last_success = now
        runtime.due = now + self._interval
        self._notify(self._listener.on_poll_success, device_id, result, runtime.due)

    def _record_failure(self, device_id: str, error: BaseException) -> None:
        runtime = self._runtimes.get(device_id)
        if runtime is None:
            return
        runtime.failures += 1
        runtime.was_failing = False
        delay = self._retry(runtime.failures, self._interval)
        runtime.due = self._clock() + delay
        self._notify(self._listener.on_poll_failure, device_id, error, delay, runtime.failures)

    def _delay_all(self, error: AdapterUnavailable) -> None:
        due = self._clock() + self._adapter_retry
        for runtime in self._runtimes.values():
            runtime.due = max(runtime.due, due)
        self._notify(self._listener.on_adapter_unavailable, error, self._adapter_retry)

    @staticmethod
    def _notify(callback: Callable[..., None], *args) -> None:
        try:
            callback(*args)
        except Exception as e:  # 回呼出錯不能讓輪詢迴圈停止
            mijia_log(f"輪詢回呼發生錯誤: {e!r}")
