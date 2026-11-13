"""BlueZ (bleak) 多裝置藍牙管理：原廠 GATT 即連即斷輪詢、開源廣播接收與搜尋新裝置。

bleak 為 asyncio 架構，這裡讓它在獨立的背景執行緒事件迴圈中執行，
所有 delegate 回呼都透過 dispatch 轉回 GTK 主執行緒。

BlueZ 每個程式同時只能有一個掃描，而 BleakClient 連線前自己也會掃描，
所以我們的掃描只由 _reconcile_scanner 統一開關：原廠裝置連線期間一律先停掉。
"""

import asyncio
import contextlib
import math
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Callable, Dict, List, Optional, Protocol, Sequence, Set

from bleak import BleakClient, BleakScanner
from bleak.exc import (
    BleakBluetoothNotAvailableError,
    BleakBluetoothNotAvailableReason,
    BleakDeviceNotFoundError,
    BleakError,
)

from .devices import KIND_BROADCAST, KIND_STOCK, Device, normalize_id
from .discovery import Candidate, DiscoverySession, broadcast_measurement, make_candidate
from .logger import mijia_log
from .parsers import Measurement, SensorReading, parse_stock_gatt
from .scheduler import ADAPTER_RETRY, AdapterUnavailable, PollEngine, is_stale
from .settings import settings

# 原廠韌體 Characteristic (Service EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6)
CHAR_UUID = "ebe0ccc1-7a0a-4b0c-8a1a-6ff2997da3a6"

CONNECT_TIMEOUT = 25.0             # 給予充足時間接收低功耗廣播封包並完成連線
READ_TIMEOUT = CONNECT_TIMEOUT + 20.0
BROADCAST_MIN_INTERVAL = 10.0      # 開源廣播模式下每台裝置最短的介面更新間隔
DISCOVERY_SECONDS = 20.0           # 搜尋新裝置的掃描時間
DISCOVERY_UPDATE_SECONDS = 1.0     # 搜尋期間回報進度的間隔
STALE_CHECK_SECONDS = 60.0         # 檢查開源廣播裝置是否太久沒收到廣播的間隔
DEFAULT_INTERVAL = 300.0


class BluetoothManagerDelegate(Protocol):
    def did_update_adapter_status(self, status: str, available: bool) -> None: ...
    def did_update_device_status(self, device_id: str, status: str, reachable: Optional[bool]) -> None: ...
    def did_update_reading(self, device_id: str, reading: SensorReading) -> None: ...
    def did_fail_with_error(self, error: str) -> None: ...


def load_refresh_interval() -> float:
    """使用者自訂連線更新間隔 (秒)，預設 300 秒 (5 分鐘)。"""
    saved = settings.get("RefreshIntervalSeconds")
    if (isinstance(saved, (int, float)) and not isinstance(saved, bool)
            and math.isfinite(saved) and 10.0 <= saved <= 86400.0):
        return float(saved)
    settings.set("RefreshIntervalSeconds", DEFAULT_INTERVAL)
    return DEFAULT_INTERVAL


def adapter_error(error: BleakBluetoothNotAvailableError) -> AdapterUnavailable:
    reason = error.reason
    if reason == BleakBluetoothNotAvailableReason.POWERED_OFF:
        return AdapterUnavailable("電腦藍牙已關閉", "請在系統設定中開啟藍牙 (或執行 bluetoothctl power on)")
    if reason in (
        BleakBluetoothNotAvailableReason.DENIED_BY_SYSTEM,
        BleakBluetoothNotAvailableReason.DENIED_BY_USER,
        BleakBluetoothNotAvailableReason.DENIED_BY_UNKNOWN,
    ):
        return AdapterUnavailable("藍牙未授權", "請確認目前使用者有權限透過 D-Bus 存取 BlueZ")
    if reason in (
        BleakBluetoothNotAvailableReason.NO_BLUETOOTH,
        BleakBluetoothNotAvailableReason.NO_BLE_CENTRAL_ROLE,
    ):
        return AdapterUnavailable("硬體不支援藍牙", "找不到支援 BLE 的藍牙介面卡")
    return AdapterUnavailable("藍牙初始化中...")


def make_reading(m: Measurement, name: str, rssi: Optional[int], is_broadcast: bool) -> SensorReading:
    return SensorReading(
        temperature=m.temperature,
        humidity=m.humidity,
        battery_percent=m.battery_percent,
        voltage=m.voltage,
        rssi=rssi,
        device_name=name,
        last_updated=datetime.now(),
        mode=m.mode,
        is_broadcast=is_broadcast,
    )


@dataclass
class _BroadcastState:
    last_seen: float
    last_emit: float = 0.0
    stale_reported: bool = False


class BluetoothManager:
    def __init__(self, dispatch: Callable[..., None]):
        self.delegate: Optional[BluetoothManagerDelegate] = None
        self._dispatch = dispatch
        self.refresh_interval = load_refresh_interval()

        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run_loop, name="mijia-bluetooth", daemon=True)
        self._engine = PollEngine(self._read_stock_sensor, self)
        self._engine.set_interval(self.refresh_interval)
        self._engine_task: Optional[asyncio.Task] = None
        self._tasks: Set[asyncio.Task] = set()

        # 以下狀態只在藍牙執行緒存取
        self._devices: Dict[str, Device] = {}
        self._broadcast: Dict[str, _BroadcastState] = {}
        self._scanner: Optional[BleakScanner] = None
        self._scan_lock = asyncio.Lock()
        self._scanner_retry_pending = False
        self._gatt_busy = False
        self._discovery: Optional[DiscoverySession] = None
        self._discovery_task: Optional[asyncio.Task] = None
        self._scan_paused_at: Optional[float] = None
        self._adapter_ok = True
        self._closing = False

        mijia_log(f"BluetoothManager 初始化 (多裝置省電輪詢模式，設定間隔: {int(self.refresh_interval)} 秒)...")

    # MARK: - 公開介面 (GTK 主執行緒呼叫)

    def start(self, devices: Sequence[Device], order: Sequence[str]) -> None:
        self._thread.start()
        self._call(self._start_background_tasks)
        self.set_devices(devices, order)

    def set_devices(self, devices: Sequence[Device], order: Sequence[str]) -> None:
        """更新裝置清單與輪詢優先順序 (order 第一台為主裝置)。"""
        self._call(self._apply_devices, tuple(devices), tuple(order))

    def set_refresh_interval(self, seconds: float) -> None:
        self.refresh_interval = seconds
        settings.set("RefreshIntervalSeconds", seconds)
        mijia_log(f"連線間隔已調整為: {int(seconds)} 秒")
        self._call(self._engine.set_interval, seconds)

    def manual_refresh(self, device_id: Optional[str] = None) -> None:
        """立即更新指定的原廠裝置 (None 為全部)；開源廣播裝置本來就會持續更新。"""
        mijia_log(f"手動要求立即重新整理 [{device_id or '全部'}]...")
        self._call(self._engine.refresh, device_id)

    def start_discovery(self, on_update: Callable[[List[Candidate]], None],
                        on_finished: Callable[[List[Candidate]], None],
                        duration: float = DISCOVERY_SECONDS) -> None:
        """搜尋新裝置；進度與結果都在 GTK 主執行緒回呼。"""
        self._call(lambda: self._spawn(self._run_discovery(on_update, on_finished, duration)))

    def cancel_discovery(self) -> None:
        self._call(self._cancel_discovery)

    def shutdown(self) -> None:
        if not self._thread.is_alive():
            return
        future = asyncio.run_coroutine_threadsafe(self._shutdown(), self._loop)
        try:
            future.result(timeout=5.0)
        except TimeoutError:
            mijia_log("關閉藍牙逾時，直接結束")
        except Exception as e:
            mijia_log(f"關閉藍牙時發生錯誤: {e!r}")
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2.0)

    # MARK: - 事件迴圈 (背景執行緒)

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _call(self, fn: Callable, *args) -> None:
        self._loop.call_soon_threadsafe(fn, *args)

    def _spawn(self, coro) -> None:
        task = self._loop.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _start_background_tasks(self) -> None:
        self._engine_task = self._loop.create_task(self._engine.run())
        self._loop.call_later(STALE_CHECK_SECONDS, self._check_broadcast_staleness)

    def _apply_devices(self, devices: Sequence[Device], order: Sequence[str]) -> None:
        self._devices = {d.id: d for d in devices}
        self._engine.set_devices([i for i in order if i in self._devices and self._devices[i].kind == KIND_STOCK])
        now = time.time()
        # 新加入的廣播裝置給 5 分鐘緩衝，才會被判定為未收到廣播
        self._broadcast = {
            d.id: self._broadcast.get(d.id) or _BroadcastState(last_seen=now)
            for d in devices if d.kind == KIND_BROADCAST
        }
        self._spawn(self._reconcile_scanner())

    async def _shutdown(self) -> None:
        self._closing = True
        if self._discovery is not None:
            self._discovery.cancelled = True
        if self._engine_task is not None:
            self._engine_task.cancel()
            await asyncio.gather(self._engine_task, return_exceptions=True)
        await self._reconcile_scanner()

    # MARK: - 原廠韌體 GATT 讀取 (由 PollEngine 呼叫，一次只讀一台)

    async def _read_stock_sensor(self, address: str) -> SensorReading:
        device = self._devices.get(address)
        name = device.name if device else address
        async with self._gatt_session():
            mijia_log(f"正在快速連線至設備 {name} [{address}]...")
            self._emit_device_status(address, "更新數據連線中...", None)
            try:
                return await asyncio.wait_for(self._connect_and_read(address, name), READ_TIMEOUT)
            except BleakBluetoothNotAvailableError as e:
                raise adapter_error(e) from e

    async def _connect_and_read(self, address: str, name: str) -> SensorReading:
        async with BleakClient(address, timeout=CONNECT_TIMEOUT) as client:
            mijia_log(f"已連線至 {name} [{address}]，單次讀取溫濕度數據 (不開 Notify 以杜絕頻繁喚醒)...")
            self._emit_device_status(address, "讀取感測數據中...", None)

            # 注意：絕對不要開啟 Notify，否則硬體會每 6 秒主動發射一次射頻，導致嚴重耗電！
            data = bytes(await client.read_gatt_char(CHAR_UUID))
            measurement = parse_stock_gatt(data)
            if measurement is None:
                raise BleakError(f"數據長度不足: {data.hex()}")

            mijia_log(
                f"收到原廠數據: 溫度={measurement.temperature}°C, 濕度={measurement.humidity}%, "
                f"電壓={measurement.voltage}V, 電量={measurement.battery_percent}% [{address}]"
            )
            # ★ 極致省電核心機制：讀取完畢立刻斷開 BLE 連線 (離開 async with 即斷線)，
            # 讓 TLSR8251 晶片立刻回到 Deep Sleep，鈕扣電池負載消失、電壓不再虛降。
            mijia_log(f"數據讀取完成，立刻主動斷開連線以讓硬體休眠省電 (下次連線間隔: {int(self.refresh_interval)} 秒)...")

        return make_reading(measurement, name, rssi=None, is_broadcast=False)

    @contextlib.asynccontextmanager
    async def _gatt_session(self):
        """連線期間停掉我們的掃描 (BleakClient 會自己掃描找裝置)，結束後再依需要恢復。"""
        try:
            self._gatt_busy = True
            await self._reconcile_scanner()
            yield
        finally:
            self._gatt_busy = False
            await self._reconcile_scanner()

    # MARK: - PollEngine 回呼 (藍牙執行緒)

    def on_poll_success(self, device_id: str, reading: SensorReading, next_due: float) -> None:
        self._set_adapter_ok()
        self._emit("did_update_reading", device_id, reading)
        mijia_log(f"設備已成功進入省電休眠 [{device_id}]。")
        next_str = datetime.fromtimestamp(next_due).strftime("%H:%M")
        self._emit_device_status(device_id, f"省電休眠中 (下次更新 {next_str})", True)

    def on_poll_failure(self, device_id: str, error: BaseException, delay: float, failures: int) -> None:
        if isinstance(error, (asyncio.TimeoutError, BleakDeviceNotFoundError)):
            mijia_log(f"連線超時 (可能設備暫時超出範圍) [{device_id}]")
            status = "設備未在連線範圍內"
        else:
            mijia_log(f"連線失敗 [{device_id}]: {error or type(error).__name__}")
            status = "連線失敗，等待下次輪詢"
        mijia_log(f"離線退避 [{device_id}] (連續失敗 {failures} 次)，{int(delay)} 秒後重試")
        self._emit_device_status(device_id, status, False)

    def on_adapter_unavailable(self, error: AdapterUnavailable, delay: float) -> None:
        self._report_adapter(error)
        for device in self._devices.values():
            if device.kind == KIND_STOCK:
                self._emit_device_status(device.id, error.status, None)

    # MARK: - 掃描 (開源廣播與搜尋新裝置共用同一個掃描)

    async def _reconcile_scanner(self) -> None:
        async with self._scan_lock:
            want = (bool(self._broadcast) or self._discovery is not None) and not self._gatt_busy and not self._closing
            if want and self._scanner is None:
                await self._start_scanner()
            elif not want and self._scanner is not None:
                await self._stop_scanner()

    async def _start_scanner(self) -> None:
        scanner = BleakScanner(detection_callback=self._on_advertisement)
        try:
            await scanner.start()
        except BleakBluetoothNotAvailableError as e:
            self._report_adapter(adapter_error(e))
            self._retry_scanner_later()
            return
        except Exception as e:
            mijia_log(f"無法啟動藍牙掃描: {e or type(e).__name__}")
            self._report_adapter(AdapterUnavailable("無法存取藍牙服務", "請確認 bluetooth 服務 (BlueZ) 已啟動"))
            self._retry_scanner_later()
            return
        self._scanner = scanner
        self._set_adapter_ok()
        if self._scan_paused_at is not None:
            paused = time.time() - self._scan_paused_at
            for state in self._broadcast.values():
                state.last_seen += paused
            self._scan_paused_at = None
        mijia_log("開始掃描周圍藍牙設備...")

    async def _stop_scanner(self) -> None:
        scanner, self._scanner = self._scanner, None
        self._scan_paused_at = time.time()
        try:
            await scanner.stop()
        except Exception as e:
            mijia_log(f"停止掃描時發生錯誤: {e}")
        mijia_log("停止掃描。")

    def _retry_scanner_later(self) -> None:
        if self._scanner_retry_pending or self._closing:
            return
        self._scanner_retry_pending = True

        def retry() -> None:
            self._scanner_retry_pending = False
            self._spawn(self._reconcile_scanner())

        self._loop.call_later(ADAPTER_RETRY, retry)

    def _on_advertisement(self, device, adv) -> None:
        address = normalize_id(device.address)
        if self._discovery is not None:
            name = adv.local_name or device.name or ""
            self._discovery.observe(make_candidate(address, name, adv.rssi, adv.service_data))

        state = self._broadcast.get(address)
        if state is None:
            return  # 只接受已加入的開源廣播裝置
        measurement = broadcast_measurement(adv.service_data)
        if measurement is None:
            return
        now = time.time()
        state.last_seen = now
        if not state.stale_reported and now - state.last_emit < BROADCAST_MIN_INTERVAL:
            return
        state.last_emit = now
        state.stale_reported = False
        self._set_adapter_ok()
        name = self._devices[address].name if address in self._devices else address
        self._emit("did_update_reading", address, make_reading(measurement, name, adv.rssi, is_broadcast=True))

    def _check_broadcast_staleness(self) -> None:
        now = time.time()
        for device_id, state in self._broadcast.items():
            if not state.stale_reported and is_stale(state.last_seen, now):
                state.stale_reported = True
                mijia_log(f"超過 5 分鐘未收到廣播 [{device_id}]")
                self._emit_device_status(device_id, "未收到廣播", False)
        if not self._closing:
            self._loop.call_later(STALE_CHECK_SECONDS, self._check_broadcast_staleness)

    # MARK: - 搜尋新裝置

    async def _run_discovery(self, on_update, on_finished, duration: float) -> None:
        # 前一次搜尋還沒結束 (例如關掉視窗後馬上重開)：先取消並等它收尾
        previous = self._discovery_task
        if previous is not None and not previous.done():
            if self._discovery is not None:
                self._discovery.cancelled = True
            await asyncio.gather(previous, return_exceptions=True)
        if self._discovery is not None:
            self._dispatch(on_finished, [])
            return
        self._discovery_task = asyncio.current_task()
        session = DiscoverySession()
        self._discovery = session
        try:
            # 先暫停輪詢並等目前的連線結束，掃描才不會和 BleakClient 衝突
            await self._engine.pause()
            await self._reconcile_scanner()
            mijia_log("開始搜尋新裝置...")
            deadline = time.monotonic() + duration
            while not session.cancelled and time.monotonic() < deadline:
                await asyncio.sleep(DISCOVERY_UPDATE_SECONDS)
                self._dispatch(on_update, session.snapshot())
        finally:
            self._discovery = None
            await self._reconcile_scanner()
            self._engine.resume()
            found = session.snapshot()
            mijia_log(f"搜尋結束，找到 {len(found)} 台溫濕度計 (含已加入的)")
            self._dispatch(on_finished, found)

    def _cancel_discovery(self) -> None:
        if self._discovery is not None:
            self._discovery.cancelled = True

    # MARK: - 輔助

    def _report_adapter(self, error: AdapterUnavailable) -> None:
        self._adapter_ok = False
        mijia_log(f"錯誤: {error.status}")
        self._emit("did_update_adapter_status", error.status, False)
        if error.hint:
            self._emit("did_fail_with_error", error.hint)

    def _set_adapter_ok(self) -> None:
        if not self._adapter_ok:
            self._adapter_ok = True
            self._emit("did_update_adapter_status", "藍牙已就緒", True)

    def _emit(self, method: str, *args) -> None:
        delegate = self.delegate
        if delegate is not None:
            self._dispatch(getattr(delegate, method), *args)

    def _emit_device_status(self, device_id: str, status: str, reachable: Optional[bool]) -> None:
        self._emit("did_update_device_status", device_id, status, reachable)
