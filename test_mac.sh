#!/bin/sh
# 編譯並執行純邏輯測試 (解析、退避排程、裝置清單、遷移、歷史、通知規則、顯示規則)
# macOS 與 Linux 的 Swift 工具鏈都能執行；不需要 AppKit / CoreBluetooth。
set -e
cd "$(dirname "$0")"

OUT="${TMPDIR:-/tmp}/mijia-temp-bar-tests"
SWIFTC="${SWIFTC:-swiftc}"

"$SWIFTC" -module-cache-path "${TMPDIR:-/tmp}/clang_cache" \
    Sources/SensorModels.swift \
    Sources/AdvertisementParser.swift \
    Sources/Backoff.swift \
    Sources/DeviceStore.swift \
    Sources/Migration.swift \
    Sources/HistoryManager.swift \
    Sources/AlertPolicies.swift \
    Sources/DeviceDiscovery.swift \
    Sources/StatusFile.swift \
    Sources/NetworkSignature.swift \
    Sources/UpdateChecker.swift \
    Sources/DeviceHistory.swift \
    Tests/Stubs.swift \
    Tests/main.swift \
    -o "$OUT"

"$OUT"
