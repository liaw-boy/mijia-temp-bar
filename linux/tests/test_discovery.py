import unittest

from mijia_temp_bar.devices import KIND_BROADCAST, KIND_STOCK
from mijia_temp_bar.discovery import (
    BTHOME_UUID,
    ENVIRONMENTAL_SENSING_UUID,
    Candidate,
    DiscoverySession,
    broadcast_measurement,
    candidate_label,
    make_candidate,
    merge_candidate,
    new_candidates,
)
from mijia_temp_bar.parsers import MODE_BTHOME, Measurement

A, B, C = "A4:C1:38:8C:9B:32", "A4:C1:38:00:11:22", "A4:C1:38:33:44:55"
BTHOME = bytes.fromhex("40" "0001" "015a" "022909" "03d711" "0c860b")


class ClassifyTests(unittest.TestCase):
    def test_stock_name(self):
        c = make_candidate(A.lower(), "LYWSD03MMC", -61, {})
        self.assertEqual((c.id, c.kind, c.name, c.rssi, c.measurement), (A, KIND_STOCK, "LYWSD03MMC", -61, None))

    def test_mj_ht_prefix(self):
        self.assertEqual(make_candidate(A, "MJ_HT_V1", -70, {}).kind, KIND_STOCK)

    def test_parseable_broadcast_wins_over_name(self):
        c = make_candidate(A, "LYWSD03MMC", -50, {BTHOME_UUID: BTHOME})
        self.assertEqual(c.kind, KIND_BROADCAST)
        self.assertEqual(c.measurement.mode, MODE_BTHOME)

    def test_broadcast_without_name_gets_generic_name(self):
        self.assertEqual(make_candidate(A, "", -50, {BTHOME_UUID: BTHOME}).name, "BTHome 溫濕度計")

    def test_unrelated_device(self):
        self.assertIsNone(make_candidate(A, "Phone", -40, {}))
        self.assertIsNone(make_candidate(A, "", -40, {ENVIRONMENTAL_SENSING_UUID: b"\x00"}))

    def test_broadcast_measurement(self):
        self.assertIsNone(broadcast_measurement({}))
        self.assertEqual(broadcast_measurement({BTHOME_UUID: BTHOME}).temperature, 23.45)


class MergeTests(unittest.TestCase):
    def test_keeps_strongest_rssi_and_latest_reading(self):
        m1 = Measurement(20.0, 50.0, 90, 3.0, MODE_BTHOME)
        m2 = Measurement(21.0, 51.0, 90, 3.0, MODE_BTHOME)
        old = Candidate(A, "ATC_1", KIND_BROADCAST, -50, m1)
        new = Candidate(A, "", KIND_BROADCAST, -70, m2)
        merged = merge_candidate(old, new)
        self.assertEqual((merged.name, merged.rssi, merged.measurement), ("ATC_1", -50, m2))

    def test_broadcast_kind_is_sticky(self):
        old = Candidate(A, "LYWSD03MMC", KIND_BROADCAST, -50, None)
        new = Candidate(A, "LYWSD03MMC", KIND_STOCK, None, None)
        self.assertEqual(merge_candidate(old, new).kind, KIND_BROADCAST)

    def test_first_observation(self):
        new = Candidate(A, "x", KIND_STOCK, -60, None)
        self.assertEqual(merge_candidate(None, new), new)


class NewCandidatesTests(unittest.TestCase):
    def test_excludes_existing_and_sorts_by_signal(self):
        found = [
            Candidate(A, "a", KIND_STOCK, -80, None),
            Candidate(B, "b", KIND_STOCK, None, None),
            Candidate(C, "c", KIND_STOCK, -40, None),
        ]
        result = new_candidates(found, {A})
        self.assertEqual([c.id for c in result], [C, B])

    def test_session_accumulates(self):
        session = DiscoverySession()
        session.observe(make_candidate(A, "LYWSD03MMC", -80, {}))
        session.observe(make_candidate(A, "LYWSD03MMC", -60, {}))
        session.observe(None)
        snapshot = session.snapshot()
        self.assertEqual(len(snapshot), 1)
        self.assertEqual(snapshot[0].rssi, -60)


class LabelTests(unittest.TestCase):
    def test_label_includes_reading(self):
        c = Candidate(A, "ATC_1", KIND_BROADCAST, -55, Measurement(23.45, 45.6, 90, 3.0, MODE_BTHOME))
        self.assertEqual(candidate_label(c), f"ATC_1 · {A} · 開源廣播 · -55 dBm · 23.4°C 46%")

    def test_label_without_rssi(self):
        c = Candidate(A, "LYWSD03MMC", KIND_STOCK, None, None)
        self.assertEqual(candidate_label(c), f"LYWSD03MMC · {A} · 原廠直連")


if __name__ == "__main__":
    unittest.main()
