"""搜尋新裝置：把掃描到的廣播分類成候選溫濕度計 (純函式，可單元測試)。"""

from dataclasses import dataclass
from typing import Collection, Dict, Iterable, List, Mapping, Optional

from .devices import KIND_BROADCAST, KIND_STOCK, KIND_TITLES, normalize_id
from .parsers import Measurement, parse_bthome, parse_environmental_service_data

# 開源韌體常見 Service Data UUID
ENVIRONMENTAL_SENSING_UUID = "0000181a-0000-1000-8000-00805f9b34fb"
BTHOME_UUID = "0000fcd2-0000-1000-8000-00805f9b34fb"

GENERIC_NAMES = {ENVIRONMENTAL_SENSING_UUID: "ATC 溫濕度計", BTHOME_UUID: "BTHome 溫濕度計"}


@dataclass(frozen=True)
class Candidate:
    id: str
    name: str                           # 廣播中的名稱 (例如 LYWSD03MMC、ATC_8C9B32)
    kind: str
    rssi: Optional[int]
    measurement: Optional[Measurement]  # 開源廣播型才有即時讀數


def broadcast_measurement(service_data: Mapping[str, bytes]) -> Optional[Measurement]:
    """解析開源韌體 (ATC / pvvx / BTHome) 的廣播數據；無法解析回傳 None。"""
    if ENVIRONMENTAL_SENSING_UUID in service_data:
        return parse_environmental_service_data(service_data[ENVIRONMENTAL_SENSING_UUID])
    if BTHOME_UUID in service_data:
        return parse_bthome(service_data[BTHOME_UUID])
    return None


def is_stock_name(name: str) -> bool:
    return "LYWSD03MMC" in name or name.startswith("MJ_HT_")


def make_candidate(address: str, name: str, rssi: Optional[int],
                   service_data: Mapping[str, bytes]) -> Optional[Candidate]:
    """可解析的廣播優先判定為開源廣播型；否則依名稱判定原廠韌體；都不是回傳 None。"""
    measurement = broadcast_measurement(service_data)
    if measurement is not None:
        generic = next((GENERIC_NAMES[u] for u in GENERIC_NAMES if u in service_data), "溫濕度計")
        return Candidate(normalize_id(address), name or generic, KIND_BROADCAST, rssi, measurement)
    if is_stock_name(name):
        return Candidate(normalize_id(address), name, KIND_STOCK, rssi, None)
    return None


def merge_candidate(old: Optional[Candidate], new: Candidate) -> Candidate:
    """同一台多次出現時合併：保留最強訊號、最新名稱與讀數；看過廣播就算廣播型。"""
    if old is None:
        return new
    rssis = [r for r in (old.rssi, new.rssi) if r is not None]
    kind = KIND_BROADCAST if KIND_BROADCAST in (old.kind, new.kind) else KIND_STOCK
    return Candidate(
        id=new.id,
        name=new.name or old.name,
        kind=kind,
        rssi=max(rssis) if rssis else None,
        measurement=new.measurement or old.measurement,
    )


def new_candidates(found: Iterable[Candidate], existing_ids: Collection[str]) -> List[Candidate]:
    """排除已加入的裝置，依訊號強度由強到弱排序 (沒有訊號值的排最後)。"""
    fresh = [c for c in found if c.id not in existing_ids]
    return sorted(fresh, key=lambda c: (c.rssi is None, -(c.rssi or 0), c.name, c.id))


def candidate_label(c: Candidate) -> str:
    parts = [c.name, c.id, KIND_TITLES.get(c.kind, c.kind)]
    if c.rssi is not None:
        parts.append(f"{c.rssi} dBm")
    if c.measurement is not None:
        parts.append(f"{c.measurement.temperature:.1f}°C {c.measurement.humidity:.0f}%")
    return " · ".join(parts)


class DiscoverySession:
    """一次搜尋期間累積的候選 (只在藍牙執行緒使用)。"""

    def __init__(self) -> None:
        self._found: Dict[str, Candidate] = {}
        self.cancelled = False

    def observe(self, candidate: Optional[Candidate]) -> None:
        if candidate is not None:
            self._found[candidate.id] = merge_candidate(self._found.get(candidate.id), candidate)

    def snapshot(self) -> List[Candidate]:
        return list(self._found.values())
