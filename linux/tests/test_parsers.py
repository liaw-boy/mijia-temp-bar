import unittest

from mijia_temp_bar.parsers import (
    MODE_ATC,
    MODE_BTHOME,
    MODE_PVVX,
    MODE_STOCK,
    battery_from_voltage,
    parse_bthome,
    parse_environmental_service_data,
    parse_stock_gatt,
)

MAC = bytes.fromhex("a4c1388c9b32")


def atc1441_packet(temp: float, hum: int, bat: int, mv: int) -> bytes:
    return (MAC + int(round(temp * 10)).to_bytes(2, "big", signed=True) + bytes([hum, bat])
            + mv.to_bytes(2, "big") + b"\x01")


def pvvx_packet(temp: float, hum: float, mv: int, bat: int) -> bytes:
    return (MAC[::-1] + int(round(temp * 100)).to_bytes(2, "little", signed=True)
            + int(round(hum * 100)).to_bytes(2, "little") + mv.to_bytes(2, "little") + bytes([bat, 0x01, 0x05]))


class StockGattTests(unittest.TestCase):
    def test_real_device_payload(self):
        # 實機 LYWSD03MMC 讀到的原始數據
        m = parse_stock_gatt(bytes.fromhex("1b09203c0b"))
        self.assertEqual(m.temperature, 23.31)
        self.assertEqual(m.humidity, 32.0)
        self.assertEqual(m.voltage, 2.876)
        self.assertEqual(m.battery_percent, 86)
        self.assertEqual(m.mode, MODE_STOCK)

    def test_negative_temperature(self):
        m = parse_stock_gatt(bytes.fromhex("f3fd50b80b"))
        self.assertEqual(m.temperature, -5.25)
        self.assertEqual(m.humidity, 80.0)
        self.assertEqual(m.voltage, 3.0)
        self.assertEqual(m.battery_percent, 100)

    def test_short_payload(self):
        self.assertIsNone(parse_stock_gatt(b"\x1b\x09\x20"))


class BatteryTests(unittest.TestCase):
    def test_clamped_range(self):
        self.assertEqual(battery_from_voltage(3.3), 100)
        self.assertEqual(battery_from_voltage(2.0), 0)
        self.assertEqual(battery_from_voltage(2.6), 55)


class EnvironmentalServiceDataTests(unittest.TestCase):
    def test_atc1441(self):
        m = parse_environmental_service_data(atc1441_packet(23.5, 45, 87, 2950))
        self.assertEqual((m.temperature, m.humidity, m.battery_percent, m.voltage, m.mode),
                         (23.5, 45.0, 87, 2.95, MODE_ATC))

    def test_atc1441_negative(self):
        m = parse_environmental_service_data(atc1441_packet(-12.3, 60, 50, 2700))
        self.assertEqual(m.temperature, -12.3)

    def test_pvvx(self):
        m = parse_environmental_service_data(pvvx_packet(23.45, 45.67, 2950, 87))
        self.assertEqual((m.temperature, m.humidity, m.battery_percent, m.voltage, m.mode),
                         (23.45, 45.67, 87, 2.95, MODE_PVVX))

    def test_pvvx_not_misread_as_atc(self):
        # 這組數值若先以 ATC1441 格式解讀，會得到看似合理的 1.0°C / 0% 錯誤結果
        m = parse_environmental_service_data(pvvx_packet(25.60, 51.20, 2950, 87))
        self.assertEqual((m.temperature, m.humidity, m.mode), (25.6, 51.2, MODE_PVVX))

    def test_garbage(self):
        self.assertIsNone(parse_environmental_service_data(b"\xff" * 13))
        self.assertIsNone(parse_environmental_service_data(b"\x00\x01"))


class BTHomeTests(unittest.TestCase):
    def test_v2_unencrypted(self):
        data = bytes.fromhex("40" "0001" "015a" "022909" "03d711" "0c860b")
        m = parse_bthome(data)
        self.assertEqual((m.temperature, m.humidity, m.battery_percent, m.voltage, m.mode),
                         (23.45, 45.67, 90, 2.95, MODE_BTHOME))

    def test_alternative_objects(self):
        # 0x45 溫度 (0.1°C) + 0x2E 濕度 (1%)
        m = parse_bthome(bytes.fromhex("40" "45eb00" "2e2d"))
        self.assertEqual((m.temperature, m.humidity, m.battery_percent, m.voltage), (23.5, 45.0, 100, 3.0))

    def test_stops_at_unknown_object(self):
        m = parse_bthome(bytes.fromhex("40" "022909" "03d711" "ff0102"))
        self.assertEqual((m.temperature, m.humidity), (23.45, 45.67))

    def test_encrypted_is_ignored(self):
        self.assertIsNone(parse_bthome(bytes.fromhex("41" "022909" "03d711")))

    def test_missing_humidity(self):
        self.assertIsNone(parse_bthome(bytes.fromhex("40" "015a" "022909")))


if __name__ == "__main__":
    unittest.main()
