import tempfile
import unittest
from pathlib import Path

from mijia_temp_bar.network_signature import (
    NETWORK_GAP_SECONDS,
    WAKE_GAP_SECONDS,
    NetworkSignature,
    ReprobeGate,
    after_network_change,
    after_pending_due,
    after_wake,
    is_different_place,
    parse_arp_mac,
    parse_default_gateway,
    pending_due_at,
    read_signature,
)

ROUTE_HEADER = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
# 192.168.2.1 (Wi-Fi, metric 600)、10.0.0.1 (有線, metric 100)、Docker 子網路 (不是預設路由)
ROUTE_TEXT = ROUTE_HEADER + (
    "wlp2s0\t00000000\t0102A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n"
    "enx001\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n"
    "docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n"
)
ARP_HEADER = "IP address       HW type     Flags       HW address            Mask     Device\n"
ARP_TEXT = ARP_HEADER + (
    "192.168.2.1      0x1         0x2         AA:BB:CC:00:11:22     *        wlp2s0\n"
    "10.0.0.1         0x1         0x0         00:00:00:00:00:00     *        enx001\n"
)

HOME = NetworkSignature("192.168.1.1", "aa:aa:aa:aa:aa:aa")
OFFICE = NetworkSignature("192.168.1.1", "bb:bb:bb:bb:bb:bb")   # 不同地方的路由器常用同一個 IP
NO_NETWORK = NetworkSignature()


class ParseTests(unittest.TestCase):
    def test_picks_lowest_metric_default_route(self):
        self.assertEqual(parse_default_gateway(ROUTE_TEXT), ("enx001", "10.0.0.1"))

    def test_single_default_route(self):
        text = ROUTE_HEADER + "wlp2s0\t00000000\t0102A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n"
        self.assertEqual(parse_default_gateway(text), ("wlp2s0", "192.168.2.1"))

    def test_no_default_route(self):
        self.assertIsNone(parse_default_gateway(ROUTE_HEADER))
        self.assertIsNone(parse_default_gateway(""))

    def test_ignores_malformed_and_down_routes(self):
        text = ROUTE_HEADER + "bad line\n" + "wlp2s0\t00000000\tZZZZ\t0003\t0\t0\t1\t00000000\t0\t0\t0\n" + \
            "wlp2s0\t00000000\t0102A8C0\t0002\t0\t0\t1\t00000000\t0\t0\t0\n"
        self.assertIsNone(parse_default_gateway(text))

    def test_skips_vpn_and_virtual_interfaces(self):
        """全通道 VPN 的預設路由不代表所在地點，改看實體網卡的。"""
        text = ROUTE_HEADER + "tun0\t00000000\t0100080A\t0003\t0\t0\t0\t00000000\t0\t0\t0\n" + \
            "wlp2s0\t00000000\t0102A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n"
        self.assertEqual(parse_default_gateway(text), ("wlp2s0", "192.168.2.1"))
        only_vpn = ROUTE_HEADER + "wg0\t00000000\t0100080A\t0003\t0\t0\t0\t00000000\t0\t0\t0\n"
        self.assertIsNone(parse_default_gateway(only_vpn))

    def test_arp_mac(self):
        self.assertEqual(parse_arp_mac(ARP_TEXT, "192.168.2.1", "wlp2s0"), "aa:bb:cc:00:11:22")

    def test_arp_incomplete_or_missing(self):
        self.assertIsNone(parse_arp_mac(ARP_TEXT, "10.0.0.1", "enx001"))
        self.assertIsNone(parse_arp_mac(ARP_TEXT, "192.168.2.1", "eth9"))
        self.assertIsNone(parse_arp_mac("", "192.168.2.1", "wlp2s0"))


class ReadSignatureTests(unittest.TestCase):
    def test_reads_proc_files(self):
        with tempfile.TemporaryDirectory() as d:
            route, arp = Path(d, "route"), Path(d, "arp")
            route.write_text(ROUTE_HEADER + "wlp2s0\t00000000\t0102A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n")
            arp.write_text(ARP_TEXT)
            self.assertEqual(read_signature(route, arp), NetworkSignature("192.168.2.1", "aa:bb:cc:00:11:22"))

    def test_missing_files(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(read_signature(Path(d, "none"), Path(d, "none")), NO_NETWORK)
            route = Path(d, "route")
            route.write_text(ROUTE_TEXT)
            self.assertEqual(read_signature(route, Path(d, "none")), NetworkSignature("10.0.0.1", None))


class DifferentPlaceTests(unittest.TestCase):
    def test_compares_mac_when_both_known(self):
        self.assertTrue(is_different_place(HOME, OFFICE))
        self.assertFalse(is_different_place(HOME, NetworkSignature("192.168.50.1", "AA:AA:AA:AA:AA:AA")))

    def test_falls_back_to_ip(self):
        self.assertFalse(is_different_place(HOME, NetworkSignature("192.168.1.1", None)))
        self.assertTrue(is_different_place(HOME, NetworkSignature("10.0.0.1", None)))

    def test_unknown_is_not_a_move(self):
        self.assertFalse(is_different_place(None, HOME))
        self.assertFalse(is_different_place(NO_NETWORK, HOME))
        self.assertFalse(is_different_place(HOME, NO_NETWORK))


class ReprobeGateTests(unittest.TestCase):
    def test_first_network_reading_only_sets_baseline(self):
        gate, fired = after_network_change(ReprobeGate(), HOME, 0.0)
        self.assertFalse(fired)
        self.assertEqual(gate.baseline, HOME)

    def test_same_network_never_fires(self):
        """VPN、虛擬介面造成的假變動：閘道沒變，2.5 小時內 18 次都不重讀。"""
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        fires = 0
        for i in range(1, 19):
            gate, fired = after_network_change(gate, HOME, i * 510.0)
            fires += fired
        self.assertEqual(fires, 0)

    def test_new_network_fires_once_then_waits(self):
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, fired = after_network_change(gate, OFFICE, 1000.0)
        self.assertTrue(fired)
        gate, fired = after_network_change(gate, HOME, 1000.0 + NETWORK_GAP_SECONDS - 1)
        self.assertFalse(fired)
        self.assertEqual(gate.baseline, HOME)
        gate, fired = after_network_change(gate, OFFICE, 1000.0 + 2 * NETWORK_GAP_SECONDS)
        self.assertTrue(fired)

    def test_reconnecting_same_network_does_not_fire(self):
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, fired = after_network_change(gate, NO_NETWORK, 1000.0)
        self.assertFalse(fired)
        self.assertEqual(gate.baseline, HOME)
        gate, fired = after_network_change(gate, HOME, 2000.0)
        self.assertFalse(fired)

    def test_reconnecting_elsewhere_fires(self):
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, _ = after_network_change(gate, NO_NETWORK, 1000.0)
        gate, fired = after_network_change(gate, OFFICE, 2000.0)
        self.assertTrue(fired)

    def test_unresolved_mac_keeps_known_mac(self):
        """閘道硬體位址還沒查到時保留原本的，之後才分得出同 IP 的另一台路由器。"""
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, fired = after_network_change(gate, NetworkSignature("192.168.1.1", None), 1000.0)
        self.assertFalse(fired)
        self.assertEqual(gate.baseline, HOME)
        gate, fired = after_network_change(gate, OFFICE, 2000.0)
        self.assertTrue(fired)

    def test_wake_gap(self):
        gate, fired = after_wake(ReprobeGate(), 0.0)
        self.assertTrue(fired)
        gate, fired = after_wake(gate, WAKE_GAP_SECONDS - 1)
        self.assertFalse(fired)
        gate, fired = after_wake(gate, WAKE_GAP_SECONDS)
        self.assertTrue(fired)

    def test_move_within_gap_is_read_when_gap_ends(self):
        """保底間隔內又換了網路：先記著，間隔到了補讀一次，不會漏掉。"""
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, fired = after_network_change(gate, OFFICE, 1000.0)
        self.assertTrue(fired)
        self.assertIsNone(pending_due_at(gate))
        gate, fired = after_network_change(gate, HOME, 1100.0)
        self.assertFalse(fired)
        self.assertEqual(pending_due_at(gate), 1000.0 + NETWORK_GAP_SECONDS)
        gate, fired = after_pending_due(gate, 1000.0 + NETWORK_GAP_SECONDS - 1)
        self.assertFalse(fired)
        gate, fired = after_pending_due(gate, 1000.0 + NETWORK_GAP_SECONDS)
        self.assertTrue(fired)
        self.assertIsNone(pending_due_at(gate))
        gate, fired = after_pending_due(gate, 5000.0)
        self.assertFalse(fired)

    def test_wake_clears_pending_move(self):
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, _ = after_network_change(gate, OFFICE, 1000.0)
        gate, _ = after_network_change(gate, HOME, 1100.0)
        gate, fired = after_wake(gate, 1200.0)
        self.assertTrue(fired)
        self.assertIsNone(pending_due_at(gate))

    def test_move_some_minutes_after_wake_fires(self):
        """喚醒只擋住緊接著的網路連線；幾分鐘後真的換網路照樣重讀。"""
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, _ = after_wake(gate, 5000.0)
        gate, fired = after_network_change(gate, OFFICE, 5000.0 + 180)
        self.assertTrue(fired)

    def test_network_right_after_wake_only_updates_baseline(self):
        """喚醒已全部重讀，幾秒後 Wi-Fi 連上新地方的網路不必再讀一次。"""
        gate, _ = after_network_change(ReprobeGate(), HOME, 0.0)
        gate, fired = after_wake(gate, 5000.0)
        self.assertTrue(fired)
        gate, fired = after_network_change(gate, OFFICE, 5008.0)
        self.assertFalse(fired)
        self.assertEqual(gate.baseline, OFFICE)


if __name__ == "__main__":
    unittest.main()
