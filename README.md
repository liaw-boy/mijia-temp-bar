# MijiaTempBar (米家溫濕度計 2 macOS 狀態列監控工具)

專為 **小米/米家藍牙溫濕度計 2 (LYWSD03MMC)** 設計的 macOS 原生狀態列 (Menu Bar) 工具。

![macOS 12+](https://img.shields.io/badge/macOS-12.0%2B-blue)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

## 🌟 功能特點

- **零依賴、純原生**：使用 Swift + 原生 `CoreBluetooth` 與 `AppKit` 打造，不需安裝 Python、Homebrew 或任何第三方函式庫。
- **Stats / iStat 風格雙行膠囊**：
  - 頂天立地吃滿 24pt 選單列高度，字體超大、超清晰。
  - 上排：`[TMP]` 暖橙色圓角膠囊 ＋ 即時溫度數值。
  - 下排：`[HUM]` 湛藍色圓角膠囊 ＋ 即時濕度數值。
  - 橫向寬度僅約 40px，極致節省 MacBook 瀏海螢幕的選單列空間。
- **雙模式智慧支援**：
  - **原廠韌體直連模式**：出廠原裝免刷機，開機自動搜尋 GATT 數值。
  - **開源廣播模式**：自動偵測並相容 ATC / pvvx / BTHome 開源廣播封包。
- **連線間隔自選**：
  - 支援 30 秒（即時模式）、1 分鐘、3 分鐘、5 分鐘（推薦省電）、10 分鐘（極致省電）彈性切換。
- **智慧隱藏與自動重連**：
  - 「僅連線時顯示」：離家 / 斷線時自動完全隱藏圖示，返家進入藍牙範圍秒級自動重連並浮現。
- **Google Stitch「Vibe Design」專屬 App 圖示**：
  - 採用 Tech Noir 黑曜石底板 ＋ 雙向漫射霓虹光暈 ＋ 懸浮氣候膠囊設計，質感卓越。

---

## 🚀 安裝與啟動

### 1. 編譯與打包
在終端機執行專案內的打包腳本：
```bash
./bundle.sh
```
建置完成後會生成 `MijiaTempBar.app`。

### 2. 啟動應用程式
```bash
open MijiaTempBar.app
```
*(首次啟動時，若系統提示「MijiaTempBar 想使用藍牙」，請點擊允許)*

### 3. 設定開機自動啟動 (選用)
1. 打開 Mac **系統設定** > **一般** > **登入項目與擴充功能**。
2. 在「登入時打開」列表中點擊 `+` 號。
3. 選取本專案的 `MijiaTempBar.app` 即可。

---

## 🛠️ 技術架構

```
mijia-temp-bar/
├── Sources/
│   ├── main.swift              # AppKit 進入點與生命週期管理
│   ├── StatusBarController.swift# 狀態列 UI、Stats 雙行膠囊繪製、選單事件
│   ├── BluetoothManager.swift  # CoreBluetooth 藍牙搜尋、GATT 連線、廣播解碼
│   └── Logger.swift            # 輕量除錯日誌
├── generate_icon.swift         # Google Stitch 風格 AppIcon 渲染器
├── bundle.sh                   # 一鍵編譯與打包腳本
└── README.md
```

---

## 📄 開源授權

本專案採用 [MIT License](LICENSE) 授權。
