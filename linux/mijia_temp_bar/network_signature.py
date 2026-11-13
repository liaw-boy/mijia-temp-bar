"""判斷「真的換到另一個網路」與重新偵測的觸發規則 (純邏輯，可單元測試)。

網路變動通知很頻繁 (VPN、Docker 等虛擬介面一變就會通知)，每次都把所有溫濕度計重讀一次
會多耗它們的電池。這裡記住預設閘道的 IP 與硬體位址，只有閘道換了才算換地方。
"""

import socket
import struct
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Optional, Tuple

ROUTE_PATH = Path("/proc/net/route")
ARP_PATH = Path("/proc/net/arp")
WAKE_GAP_SECONDS = 60.0       # 喚醒觸發的重新偵測至少間隔 60 秒
NETWORK_GAP_SECONDS = 600.0   # 換網路觸發的保底間隔 10 分鐘 (網路在兩台路由器間反覆切換時)
# VPN 等虛擬介面：經由它們的預設路由不代表所在地點 (全通道 VPN 通常仍留著實體網卡的預設路由)
VIRTUAL_INTERFACE_PREFIXES = ("tun", "tap", "wg", "ppp", "tailscale", "utun", "zt", "ipsec")

_RTF_UP_GATEWAY = 0x1 | 0x2   # 路由已啟用且經過閘道
_DEFAULT_ROUTE = "00000000"
_UNRESOLVED_MAC = "00:00:00:00:00:00"


@dataclass(frozen=True)
class NetworkSignature:
    gateway_ip: Optional[str] = None
    gateway_mac: Optional[str] = None

    @property
    def known(self) -> bool:
        """沒有預設閘道 = 目前沒有網路，無法判斷在哪裡。"""
        return self.gateway_ip is not None


def _default_route(fields) -> Optional[Tuple[int, str, str]]:
    """一列 /proc/net/route；是啟用中的 IPv4 預設路由才回傳 (metric, 介面, 閘道 IP)。"""
    if len(fields) < 8 or fields[1] != _DEFAULT_ROUTE or fields[7] != _DEFAULT_ROUTE:
        return None
    if fields[0].startswith(VIRTUAL_INTERFACE_PREFIXES):
        return None
    try:
        if int(fields[3], 16) & _RTF_UP_GATEWAY != _RTF_UP_GATEWAY:
            return None
        ip = socket.inet_ntoa(struct.pack("<I", int(fields[2], 16)))
        return int(fields[6]), fields[0], ip
    except (ValueError, struct.error):
        return None


def parse_default_gateway(route_text: str) -> Optional[Tuple[str, str]]:
    """從 /proc/net/route 找出實體網卡 metric 最小的預設路由，回傳 (介面, 閘道 IP)。"""
    routes = [r for r in (_default_route(line.split()) for line in route_text.splitlines()[1:]) if r]
    if not routes:
        return None
    _metric, iface, ip = min(routes)
    return iface, ip


def parse_arp_mac(arp_text: str, ip: str, iface: str) -> Optional[str]:
    """從 /proc/net/arp 找出閘道的硬體位址；還沒查到 (全為 0) 時回傳 None。"""
    for line in arp_text.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 6 and fields[0] == ip and fields[5] == iface:
            mac = fields[3].lower()
            return None if mac == _UNRESOLVED_MAC else mac
    return None


def read_signature(route_path: Path = ROUTE_PATH, arp_path: Path = ARP_PATH) -> NetworkSignature:
    try:
        gateway = parse_default_gateway(route_path.read_text())
    except OSError:
        return NetworkSignature()
    if gateway is None:
        return NetworkSignature()
    iface, ip = gateway
    try:
        mac = parse_arp_mac(arp_path.read_text(), ip, iface)
    except OSError:
        mac = None
    return NetworkSignature(ip, mac)


def is_different_place(previous: Optional[NetworkSignature], current: NetworkSignature) -> bool:
    """是否換到另一個網路：兩邊都有閘道硬體位址就比對它 (不同地方的路由器常用同一個 IP)，否則比對 IP。
    之前或現在沒有網路時無法判斷，視為沒換。"""
    if previous is None or not previous.known or not current.known:
        return False
    if previous.gateway_mac and current.gateway_mac:
        return previous.gateway_mac.lower() != current.gateway_mac.lower()
    return previous.gateway_ip != current.gateway_ip


@dataclass(frozen=True)
class ReprobeGate:
    """重新偵測的觸發狀態：上次的網路特徵、喚醒與換網路各自上次觸發的時間，
    以及保底間隔內發生、還沒重讀的換網路。"""
    baseline: Optional[NetworkSignature] = None
    last_wake: float = float("-inf")
    last_network: float = float("-inf")
    pending_move: bool = False


def after_wake(gate: ReprobeGate, now: float) -> Tuple[ReprobeGate, bool]:
    """從睡眠喚醒：可能已經換了地方，間隔夠就全部重讀 (也涵蓋還沒補讀的換網路)。"""
    if now - gate.last_wake < WAKE_GAP_SECONDS:
        return gate, False
    return replace(gate, last_wake=now, pending_move=False), True


def _next_baseline(previous: Optional[NetworkSignature], current: NetworkSignature, moved: bool) -> NetworkSignature:
    """同一個閘道 IP 但硬體位址還沒查到時，保留原本查到的硬體位址。"""
    keep_previous = (not moved and previous is not None and current.gateway_mac is None
                     and previous.gateway_ip == current.gateway_ip)
    return previous if keep_previous else current


def after_network_change(gate: ReprobeGate, current: NetworkSignature, now: float) -> Tuple[ReprobeGate, bool]:
    """網路變動：只有換到另一個網路 (預設閘道不同) 才全部重讀。

    虛擬介面的假變動、斷線後重連同一個網路都不觸發；沒有網路時維持原本的記錄。
    喚醒後一分鐘內連上的網路只更新記錄 (喚醒時已全部重讀)；保底間隔內的換網路先記著，由 after_pending_due 補讀。
    """
    if not current.known:
        return gate, False
    moved = is_different_place(gate.baseline, current)
    updated = replace(gate, baseline=_next_baseline(gate.baseline, current, moved))
    if not moved:
        return updated, False
    if now - gate.last_wake < WAKE_GAP_SECONDS:
        return replace(updated, pending_move=False), False
    if now - gate.last_network < NETWORK_GAP_SECONDS:
        return replace(updated, pending_move=True), False
    return replace(updated, last_network=now, pending_move=False), True


def pending_due_at(gate: ReprobeGate) -> Optional[float]:
    """還沒重讀的換網路要在什麼時候補讀；沒有則為 None。"""
    return gate.last_network + NETWORK_GAP_SECONDS if gate.pending_move else None


def after_pending_due(gate: ReprobeGate, now: float) -> Tuple[ReprobeGate, bool]:
    """保底間隔到了：補讀之前記著的換網路。"""
    due = pending_due_at(gate)
    if due is None or now < due:
        return gate, False
    return replace(gate, last_network=now, pending_move=False), True
