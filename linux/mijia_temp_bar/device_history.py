"""原廠韌體存在裝置上的每小時紀錄 (service EBE0CCB0，免認證)，與 macOS 的 DeviceHistory.swift 對應。

讀 CCB7 裝置時間、CCB9 筆數，訂閱 CCBC 後寫 CCBA 起始 index，裝置逐筆 notify。
實機確認：紀錄時間是該小時的開始；訂閱後、寫入起始 index 前裝置會先推幾筆舊的，要略過。
"""

import math
import struct
from dataclasses import dataclass
from typing import Iterable, List, Optional, Sequence, Tuple

from .history import HistoryPoint

TIME_UUID = "ebe0ccb7-7a0a-4b0c-8a1a-6ff2997da3a6"
COUNT_UUID = "ebe0ccb9-7a0a-4b0c-8a1a-6ff2997da3a6"
INDEX_UUID = "ebe0ccba-7a0a-4b0c-8a1a-6ff2997da3a6"
RECORDS_UUID = "ebe0ccbc-7a0a-4b0c-8a1a-6ff2997da3a6"

GAP_THRESHOLD = 65 * 60      # 兩筆讀數相隔超過這麼久才算空白 (平常只讀當下數值，省電)
RETENTION_OPTIONS = (30, 90, 180, 365)  # 歷史保存天數的選項 (第一個為預設)；補空白的範圍也跟著這個天數
RETENTION_KEY = "HistoryRetentionDays"
DETAIL_DAYS = 30             # 最近這麼多天完整保留，更舊的每小時留一筆 (控制檔案大小與寫入量)
MAX_RECORDS = 720            # 一次連線最多讀 30 天 (實機約每秒 6~8 筆)；更早的空白下次連線接著讀
SETUP_TIMEOUT = 20.0         # 開始讀之前 (查時間、筆數、訂閱) 的時間上限
IDLE_TIMEOUT = 10.0          # 讀取中超過這麼久沒收到下一筆就結束，保留已收到的部分
TOTAL_TIMEOUT = 150.0        # 整次讀取歷史的上限
RETRY_INTERVAL = 3 * 3600    # 讀歷史沒讀完時，隔這麼久才再試
MAX_AGE = 366 * 86400
COVERED_KEY = "HistoryBackfillCoveredUntil"  # {裝置: 上次完整讀過裝置歷史的時間}


@dataclass(frozen=True)
class HourlyRecord:
    index: int
    device_time: int         # 該小時開始時的裝置秒數，不是真實時間
    max_temperature: float
    max_humidity: float
    min_temperature: float
    min_humidity: float


def retention_days(value) -> int:
    return value if value in RETENTION_OPTIONS else RETENTION_OPTIONS[0]


def gap_start(timestamps: Sequence[float], now: float, covered_until: Optional[float] = None,
              interval: float = 0, retention: int = RETENTION_OPTIONS[0]) -> Optional[float]:
    """保存期間內第一個空白的起點 (空白前的最後一筆；最前面沒資料時是保存期間的起點)；沒有空白回傳 None。

    covered_until：裝置歷史已讀到的時間，之前的空白裝置也沒有紀錄，不再重讀。
    更新間隔很長時，正常輪詢的間隔本身不算空白；超過 30 天的資料每小時一筆，也不算空白。
    """
    recent = max(GAP_THRESHOLD, interval + 600)
    detail_start = now - DETAIL_DAYS * 86400
    prev = max(now - retention * 86400, covered_until or 0.0)
    for t in timestamps:
        if t <= prev:
            continue
        threshold = 2 * 3600 + 600 if t <= detail_start else recent
        if t - prev > threshold:
            return prev
        prev = t
    return prev if now - prev > recent else None


def chunk_end(start: int, total: int) -> int:
    """這次連線讀到哪一筆為止 (一次最多 MAX_RECORDS 筆)。"""
    return min(start + MAX_RECORDS - 1, total - 1)


def real_end(record: HourlyRecord, device_now: int, now: float) -> float:
    """紀錄那一小時結束時的真實時間。"""
    return now - device_now + record.device_time + 3600


def compact(points: Sequence[HistoryPoint], now: float, retention: int) -> List[HistoryPoint]:
    """清掉超過保存天數的資料；超過 30 天的合併成每小時一筆 (放在該小時中間，數值取平均)。重複執行結果不變。"""
    cutoff = now - retention * 86400
    detail_start = now - DETAIL_DAYS * 86400
    result: List[HistoryPoint] = []
    bucket: List[HistoryPoint] = []
    bucket_hour = None

    def flush() -> None:
        if not bucket:
            return
        n = len(bucket)
        result.append(HistoryPoint(
            timestamp=bucket_hour * 3600 + 1800,
            temperature=round(sum(p.temperature for p in bucket) / n, 2),
            humidity=round(sum(p.humidity for p in bucket) / n, 1),
            voltage=round(sum(p.voltage for p in bucket) / n, 3),
            batteryPercent=round(sum(p.batteryPercent for p in bucket) / n),
        ))
        bucket.clear()

    for p in sorted(points, key=lambda p: p.timestamp):
        if p.timestamp < cutoff:
            continue
        if p.timestamp >= detail_start:
            result.append(p)
            continue
        hour = int(p.timestamp // 3600)
        if hour != bucket_hour:
            flush()
            bucket_hour = hour
        bucket.append(p)
    flush()
    return sorted(result, key=lambda p: p.timestamp)


def record_index(data: bytes) -> Optional[int]:
    """先取出 index：數值不合理的紀錄也要知道是不是最後一筆，才不會等到逾時。"""
    return struct.unpack_from("<I", data)[0] if len(data) >= 4 else None


def parse_record(data: bytes) -> Optional[HourlyRecord]:
    """CCBC 的一筆：<IIhBhB = index, 裝置時間, 最高溫×10, 最高濕度, 最低溫×10, 最低濕度。"""
    if len(data) < 14:
        return None
    idx, ts, max_t, max_h, min_t, min_h = struct.unpack_from("<IIhBhB", data)
    rec = HourlyRecord(idx, ts, max_t / 10, float(max_h), min_t / 10, float(min_h))
    # 不合理的數值 (損毀或格式不同) 整筆丟掉
    if not (-40 <= rec.min_temperature <= rec.max_temperature <= 85 and rec.min_humidity <= rec.max_humidity <= 100):
        return None
    return rec


def parse_device_time(data: bytes) -> Optional[int]:
    return struct.unpack_from("<I", data)[0] if len(data) >= 4 else None


def parse_count(data: bytes) -> Optional[Tuple[int, int]]:
    """CCB9：(累計寫過幾筆, 目前還存著幾筆)。"""
    return struct.unpack_from("<II", data) if len(data) >= 8 else None


def start_index(total: int, stored: int, since: float, now: float) -> Optional[int]:
    """要從哪一筆開始讀 (從空白起點讀到現在，加一筆緩衝)；沒有可讀的紀錄時回傳 None。"""
    available = min(stored, total)
    if available <= 0:
        return None
    wanted = min(available, math.ceil(max(0.0, now - since) / 3600) + 1)  # 裝置沒存那麼久就從最舊的開始
    return total - wanted


def fill(existing: Sequence[HistoryPoint], records: Iterable[HourlyRecord], device_now: int, now: float,
         voltage: float, battery: int, max_age: float = MAX_AGE) -> List[HistoryPoint]:
    """把每小時紀錄補進歷史的空白處：放在該小時中間，溫濕度取最高最低的平均。

    附近 30 分鐘內已有讀數就不補；紀錄沒有電量，用這次連線讀到的電壓與電量。
    """
    times = [p.timestamp for p in existing]
    added: List[HistoryPoint] = []
    for r in records:
        if r.device_time > device_now:
            continue
        mid = now - (device_now - r.device_time) + 1800
        if mid > now or now - mid > max_age:
            continue
        if any(abs(t - mid) < 1800 for t in times) or any(abs(p.timestamp - mid) < 1800 for p in added):
            continue
        added.append(HistoryPoint(
            timestamp=mid,
            temperature=round((r.max_temperature + r.min_temperature) / 2, 2),
            humidity=round((r.max_humidity + r.min_humidity) / 2, 1),
            voltage=voltage,
            batteryPercent=battery,
        ))
    if not added:
        return list(existing)
    return sorted([*existing, *added], key=lambda p: p.timestamp)
