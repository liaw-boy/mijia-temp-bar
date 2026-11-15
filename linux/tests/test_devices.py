import unittest

from mijia_temp_bar.devices import (
    KIND_BROADCAST,
    KIND_STOCK,
    MAX_NAME_LENGTH,
    Device,
    add_devices,
    clean_name,
    default_name,
    file_id,
    normalize_id,
    parse_devices,
    remove_device,
    rename_device,
    resolve_primary,
    serialize_devices,
)

A = "A4:C1:38:8C:9B:32"
B = "A4:C1:38:00:11:22"


class IdTests(unittest.TestCase):
    def test_normalize_id(self):
        self.assertEqual(normalize_id(" a4:c1:38:8c:9b:32 "), A)

    def test_file_id_strips_separators(self):
        self.assertEqual(file_id(A), "A4C1388C9B32")

    def test_file_id_blocks_path_traversal(self):
        self.assertEqual(file_id("../../etc/passwd"), "etcpasswd")

    def test_file_id_rejects_empty(self):
        with self.assertRaises(ValueError):
            file_id("::/..")


class ParseTests(unittest.TestCase):
    def test_round_trip(self):
        devices = (Device(A, "客廳", KIND_STOCK), Device(B, "臥室", KIND_BROADCAST))
        self.assertEqual(parse_devices(serialize_devices(devices)), devices)

    def test_drops_malformed_and_duplicates(self):
        raw = [
            {"id": A.lower(), "name": "客廳", "kind": KIND_STOCK},
            {"id": A, "name": "重複", "kind": KIND_STOCK},
            {"id": "", "name": "空的", "kind": KIND_STOCK},
            {"id": B, "name": "x", "kind": "unknown"},
            "not a dict",
            {"name": "沒有 id"},
        ]
        self.assertEqual(parse_devices(raw), (Device(A, "客廳", KIND_STOCK),))

    def test_blank_name_gets_default(self):
        parsed = parse_devices([{"id": A, "name": "  ", "kind": KIND_STOCK}])
        self.assertEqual(parsed[0].name, "溫濕度計 1")

    def test_non_list_is_empty(self):
        self.assertEqual(parse_devices(None), ())
        self.assertEqual(parse_devices({"id": A}), ())


class ListOperationTests(unittest.TestCase):
    def setUp(self):
        self.devices = (Device(A, "溫濕度計 1", KIND_STOCK),)

    def test_default_name_uses_smallest_free_number(self):
        self.assertEqual(default_name(()), "溫濕度計 1")
        self.assertEqual(default_name(self.devices), "溫濕度計 2")
        gap = (Device(A, "溫濕度計 2", KIND_STOCK),)
        self.assertEqual(default_name(gap), "溫濕度計 1")

    def test_add_skips_existing_ids(self):
        result = add_devices(self.devices, [Device(A.lower(), "x", KIND_STOCK), Device(B, "臥室", KIND_BROADCAST)])
        self.assertEqual([d.id for d in result], [A, B])
        self.assertEqual(self.devices, (Device(A, "溫濕度計 1", KIND_STOCK),))  # 原清單不變

    def test_remove(self):
        both = add_devices(self.devices, [Device(B, "臥室", KIND_BROADCAST)])
        self.assertEqual(remove_device(both, A), (Device(B, "臥室", KIND_BROADCAST),))
        self.assertEqual(remove_device(both, "missing"), both)

    def test_rename(self):
        renamed = rename_device(self.devices, A, "  客廳  ")
        self.assertEqual(renamed[0].name, "客廳")

    def test_rename_rejects_blank_and_too_long(self):
        with self.assertRaises(ValueError):
            rename_device(self.devices, A, "   ")
        with self.assertRaises(ValueError):
            clean_name("字" * (MAX_NAME_LENGTH + 1))

    def test_resolve_primary(self):
        both = add_devices(self.devices, [Device(B, "臥室", KIND_BROADCAST)])
        self.assertEqual(resolve_primary(both, B), B)
        self.assertEqual(resolve_primary(both, "missing"), A)
        self.assertEqual(resolve_primary(both, None), A)
        self.assertIsNone(resolve_primary((), A))


if __name__ == "__main__":
    unittest.main()
