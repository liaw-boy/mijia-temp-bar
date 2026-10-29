"""BlueZ (bleak) 藍牙搜尋、原廠 GATT 即連即斷讀取與開源廣播解析。

bleak 為 asyncio 架構，這裡讓它在獨立的背景執行緒事件迴圈中執行，
所有 delegate 回呼都透過 dispatch 轉回 GTK 主執行緒。
"""

import asyncio
import json
import math
import threading
import time
from datetime import datetime, timedelta
from typing import Callable, Optional, Protocol

from bleak import BleakClient, BleakScanner
from bleak.exc import (
    BleakBluetoothNotAvailableError,
    BleakBluetoothNotAvailableReason,
    BleakDeviceNotFoundError,
    BleakError,
)

from .backoff import retry_delay
from .logger import mijia_log
from .parsers import (
    Measurement,
    SensorReading,
    parse_bthome,
    parse_environmental_service_data,
    parse_stock_gatt,
)
from .settings import RUNTIME_DIR, atomic_write_text, settings

# 原廠韌體 Characteristic (Service EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6)
CHAR_UUID = "ebe0ccc1-7a0a-4b0c-8a1a-6ff2997da3a6"

# 開源韌體常見 Service Data UUID
ENVIRONMENTAL_SENSING_UUID = "0000181a-0000-1000-8000-00805f9b34fb"
BTHOME_UUID = "0000fcd2-0000-1000-8000-00805f9b34fb"

STATUS_JSON_PATH = RUNTIME_DIR / "mijia_status.json"

CONNECT_TIMEOUT = 25.0         # 給予充足時間接收低功耗廣播封包並完成連線
BLUETOOTH_RETRY = 15.0         # 藍牙未開啟時的重新檢查間隔
BROADCAST_MIN_INTERVAL = 10.0  # 開源廣播模式下最短的介面更新間隔


class BluetoothManagerDelegate(Protocol):
    def did_update_status(self, status: str, reachable: Optional[bool] = None) -> None: ...
    def did_update_reading(self, reading: SensorReading) -> None: ...
    def did_fail_with_error(self, error: str) -> None: ...


class BluetoothManager:
    def __init__(self, dispatch: Callable[..., None]):
        self.delegate: Optional[BluetoothManagerDelegate] = None
        self._dispatch = dispatch

        # 使用者自訂連線更新間隔 (秒)，預設 300 秒 (5 分鐘)
        saved = settings.get("RefreshIntervalSeconds")
        if isinstance(saved, (int, float)) and not isinstance(saved, bool) and math.isfinite(saved) and 10.0 <= saved <= 86400.0:
            self.refresh_interval = float(saved)
        else:
            self.refresh_interval = 300.0
            settings.set("RefreshIntervalSeconds", 300.0)

        self.current_reading: Optional[SensorReading] = None
        self._target_address: Optional[str] = settings.get("TargetAddress")

        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run_loop, name="mijia-bluetooth", daemon=True)
        self._scanner: Optional[BleakScanner] = None
        self._fetch_task: Optional[asyncio.Task] = None
        self._poll_handle: Optional[asyncio.TimerHandle] = None
        self._next_update_time: Optional[datetime] = None
        self._last_broadcast_emit = 0.0
        self._consecutive_failures = 0

        mijia_log(f"BluetoothManager 初始化 (省電輪詢模式，設定間隔: {int(self.refresh_interval)} 秒)...")

    # MARK: - 公開介面 (GTK 主執行緒呼叫)

    def start(self) -> None:
        self._thread.start()
        self._loop.call_soon_threadsafe(self._connect_and_fetch)

    def set_refresh_interval(self, seconds: float) -> None:
        self.refresh_interval = seconds
        settings.set("RefreshIntervalSeconds", seconds)
        mijia_log(f"連線間隔已調整為: {int(seconds)} 秒")
        self._loop.call_soon_threadsafe(self._plan_next_poll)

    def manual_refresh(self) -> None:
        mijia_log("手動要求立即重新整理...")
        self._consecutive_failures = 0
        self._loop.call_soon_threadsafe(self._connect_and_fetch)

    def shutdown(self) -> None:
        if not self._thread.is_alive():
            return
        future = asyncio.run_coroutine_threadsafe(self._shutdown(), self._loop)
        try:
            future.result(timeout=5.0)
        except Exception:
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2.0)

    # MARK: - 事件迴圈 (背景執行緒)

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _connect_and_fetch(self) -> None:
        if self._fetch_task is not None and not self._fetch_task.done():
            return
        self._fetch_task = self._loop.create_task(self._fetch())

    async def _fetch(self) -> None:
        self._cancel_poll()

        # 若尚未發現過設備，啟動掃描
        if not self._target_address:
            await self._start_scan()
            return

        address = self._target_address
        mijia_log(f"正在快速連線至設備 {address}...")
        self._emit_status("更新數據連線中...")

        try:
            reading = await asyncio.wait_for(self._read_stock_sensor(address), CONNECT_TIMEOUT + 20.0)
        except BleakBluetoothNotAvailableError as e:
            self._handle_bluetooth_unavailable(e)
            self._plan_next_poll(BLUETOOTH_RETRY)
            return
        except (asyncio.TimeoutError, BleakDeviceNotFoundError):
            mijia_log("連線超時 (可能設備暫時超出範圍)，取消並排定下次重試...")
            self._emit_status("設備未在連線範圍內", reachable=False)
            self._plan_retry()
            return
        except Exception as e:
            mijia_log(f"連線失敗: {e or type(e).__name__}")
            self._emit_status("連線失敗，等待下次輪詢", reachable=False)
            self._plan_retry()
            return

        self._consecutive_failures = 0
        self._publish(reading, "已連線運作中")
        self._plan_next_poll()
        mijia_log("設備已成功進入省電休眠。")
        next_str = self._next_update_time.strftime("%H:%M") if self._next_update_time else "--:--"
        self._emit_status(f"省電休眠中 (下次更新 {next_str})")

    async def _read_stock_sensor(self, address: str) -> SensorReading:
        async with BleakClient(address, timeout=CONNECT_TIMEOUT) as client:
            name = client.name
            if not name or name.replace("-", ":").upper() == address.upper():
                name = "米家溫濕度計 2"
            mijia_log(f"已連線至 {name}，單次讀取溫濕度數據 (不開 Notify 以杜絕頻繁喚醒)...")
            self._emit_status("讀取感測數據中...")

            # 注意：絕對不要開啟 Notify，否則硬體會每 6 秒主動發射一次射頻，導致嚴重耗電！
            data = bytes(await client.read_gatt_char(CHAR_UUID))
            measurement = parse_stock_gatt(data)
            if measurement is None:
                raise BleakError(f"數據長度不足: {data.hex()}")

            mijia_log(
                f"收到原廠數據: 溫度={measurement.temperature}°C, 濕度={measurement.humidity}%, "
                f"電壓={measurement.voltage}V, 電量={measurement.battery_percent}%"
            )
            # ★ 極致省電核心機制：讀取完畢立刻斷開 BLE 連線 (離開 async with 即斷線)，
            # 讓 TLSR8251 晶片立刻回到 Deep Sleep，鈕扣電池負載消失、電壓不再虛降。
            mijia_log(f"數據讀取完成，立刻主動斷開連線以讓硬體休眠省電 (下次連線間隔: {int(self.refresh_interval)} 秒)...")

        return self._make_reading(measurement, name, rssi=None, is_broadcast=False)

    async def _start_scan(self) -> None:
        if self._scanner is not None:
            return
        scanner = BleakScanner(detection_callback=self._on_advertisement)
        self._scanner = scanner
        try:
            await scanner.start()
        except BleakBluetoothNotAvailableError as e:
            self._scanner = None
            self._handle_bluetooth_unavailable(e)
            self._plan_next_poll(BLUETOOTH_RETRY)
            return
        except Exception as e:
            self._scanner = None
            mijia_log(f"無法啟動藍牙掃描: {e or type(e).__name__}")
            self._emit_status("無法存取藍牙服務", reachable=False)
            self._emit_error("請確認 bluetooth 服務 (BlueZ) 已啟動")
            self._save_status_json("無法存取藍牙服務")
            self._plan_next_poll(BLUETOOTH_RETRY)
            return
        mijia_log("開始掃描周圍藍牙設備...")
        self._emit_status("搜尋溫濕度計中...")

    async def _stop_scan(self) -> None:
        scanner, self._scanner = self._scanner, None
        if scanner is None:
            return
        try:
            await scanner.stop()
        except Exception as e:
            mijia_log(f"停止掃描時發生錯誤: {e}")
        mijia_log("停止掃描。")

    def _on_advertisement(self, device, adv) -> None:
        name = adv.local_name or device.name or ""
        service_data = adv.service_data

        # 情況 A：開源韌體廣播
        if ENVIRONMENTAL_SENSING_UUID in service_data:
            measurement = parse_environmental_service_data(service_data[ENVIRONMENTAL_SENSING_UUID])
            if measurement is not None:
                self._publish_broadcast(measurement, name or "ATC 溫濕度計", adv.rssi)
                return
        elif BTHOME_UUID in service_data:
            measurement = parse_bthome(service_data[BTHOME_UUID])
            if measurement is not None:
                self._publish_broadcast(measurement, name or "BTHome 溫濕度計", adv.rssi)
                return

        # 情況 B：原廠韌體設備
        if ("LYWSD03MMC" in name or name.startswith("MJ_HT_")) and not self._target_address:
            mijia_log(f"發現目標原廠設備: {name} [{device.address}]，記住並連線...")
            self._target_address = device.address
            settings.set("TargetAddress", device.address)
            self._loop.create_task(self._switch_to_stock_mode())

    async def _switch_to_stock_mode(self) -> None:
        if self._fetch_task is not None and not self._fetch_task.done():
            await asyncio.wait([self._fetch_task])
        await self._stop_scan()
        self._connect_and_fetch()

    def _plan_next_poll(self, delay: Optional[float] = None) -> None:
        self._cancel_poll()
        delay = self.refresh_interval if delay is None else delay
        self._next_update_time = datetime.now() + timedelta(seconds=delay)
        self._poll_handle = self._loop.call_later(delay, self._on_poll_timer)

    def _plan_retry(self) -> None:
        self._consecutive_failures += 1
        delay = retry_delay(self._consecutive_failures, self.refresh_interval)
        mijia_log(f"離線退避 (連續失敗 {self._consecutive_failures} 次)，{int(delay)} 秒後重試")
        self._plan_next_poll(delay)

    def _cancel_poll(self) -> None:
        if self._poll_handle is not None:
            self._poll_handle.cancel()
            self._poll_handle = None

    def _on_poll_timer(self) -> None:
        self._poll_handle = None
        mijia_log("省電定時喚醒：準備發起下一次輪詢連線...")
        self._connect_and_fetch()

    async def _shutdown(self) -> None:
        self._cancel_poll()
        if self._fetch_task is not None and not self._fetch_task.done():
            self._fetch_task.cancel()
            await asyncio.wait([self._fetch_task])
        await self._stop_scan()

    # MARK: - 輔助

    def _make_reading(self, m: Measurement, name: str, rssi: Optional[int], is_broadcast: bool) -> SensorReading:
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

    def _publish_broadcast(self, m: Measurement, name: str, rssi: Optional[int]) -> None:
        now = time.monotonic()
        if now - self._last_broadcast_emit < BROADCAST_MIN_INTERVAL:
            return
        self._last_broadcast_emit = now
        self._publish(self._make_reading(m, name, rssi, is_broadcast=True), "廣播接收中")

    def _publish(self, reading: SensorReading, status: str) -> None:
        self.current_reading = reading
        self._emit("did_update_reading", reading)
        self._save_status_json(status)

    def _handle_bluetooth_unavailable(self, error: BleakBluetoothNotAvailableError) -> None:
        reason = error.reason
        hint: Optional[str]
        if reason == BleakBluetoothNotAvailableReason.POWERED_OFF:
            status, hint = "電腦藍牙已關閉", "請在系統設定中開啟藍牙 (或執行 bluetoothctl power on)"
        elif reason in (
            BleakBluetoothNotAvailableReason.DENIED_BY_SYSTEM,
            BleakBluetoothNotAvailableReason.DENIED_BY_USER,
            BleakBluetoothNotAvailableReason.DENIED_BY_UNKNOWN,
        ):
            status, hint = "藍牙未授權", "請確認目前使用者有權限透過 D-Bus 存取 BlueZ"
        elif reason in (
            BleakBluetoothNotAvailableReason.NO_BLUETOOTH,
            BleakBluetoothNotAvailableReason.NO_BLE_CENTRAL_ROLE,
        ):
            status, hint = "硬體不支援藍牙", "找不到支援 BLE 的藍牙介面卡"
        else:
            status, hint = "藍牙初始化中...", None

        mijia_log(f"錯誤: {status} ({error})")
        self._emit_status(status, reachable=False)
        if hint:
            self._emit_error(hint)
        self._save_status_json(status)

    def _emit(self, method: str, *args) -> None:
        delegate = self.delegate
        if delegate is not None:
            self._dispatch(getattr(delegate, method), *args)

    def _emit_status(self, status: str, reachable: Optional[bool] = None) -> None:
        self._emit("did_update_status", status, reachable)

    def _emit_error(self, error: str) -> None:
        self._emit("did_fail_with_error", error)

    def _save_status_json(self, status: str) -> None:
        payload = {
            "status": status,
            "timestamp": datetime.now().astimezone().isoformat(timespec="seconds"),
            "refreshIntervalSeconds": int(self.refresh_interval),
        }
        r = self.current_reading
        if r is not None:
            payload.update(
                temperature=r.temperature,
                humidity=r.humidity,
                batteryPercent=r.battery_percent,
                voltage=r.voltage,
                deviceName=r.device_name,
                mode=r.mode,
            )
        try:
            atomic_write_text(STATUS_JSON_PATH, json.dumps(payload, ensure_ascii=False, indent=2))
        except OSError:
            pass
