# MijiaTempBar 🌡️💧

[![Release](https://img.shields.io/github/v/release/liaw-boy/mijia-temp-bar?color=blue&logo=github)](https://github.com/liaw-boy/mijia-temp-bar/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2012.0%2B-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange?logo=swift)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

專為 **小米 / 米家藍牙溫濕度計 2（LYWSD03MMC）** 打造的極致原生 macOS 狀態列（Menu Bar）監控工具。

採用與知名 macOS 系統監控工具 **[Stats](https://github.com/exelban/stats)** 相同的上下雙行膠囊設計，頂天立地吃滿選單列空間，兼顧大字體與極致橫向省空間。

---

```text
┌─────────────────────────┐
│  [TMP] 24.5°            │  <-- 上排：暖橙色圓角膠囊 TMP ＋ 即時溫度
│  [HUM] 68%              │  <-- 下排：湛藍色圓角膠囊 HUM ＋ 即時濕度
└─────────────────────────┘
      (寬度僅約 40px，極致節省瀏海螢幕選單列空間)
```

---

## 🌟 功能亮點 (Key Features)

- **Stats 風格雙行微型膠囊**：
  - 完美適配 macOS 現代選單列 24.0pt 高度，上下完全貼滿。
  - 字體放大至 **11.2 pt 粗體**，坐在辦公桌前遠遠一眼即看清。
  - 橫向寬度僅約 **40 像素**，絲毫不擠壓 MacBook 瀏海螢幕兩側的空間。
- **📊 獨立原生即時儀表板與歷史趨勢折線圖 (GUI Dashboard)**：
  - 點擊狀態列選單 **「開啟即時儀表板 (⌘D)...」**，彈出獨立深色磨砂玻璃面板。
  - 內嵌**小米官方原廠硬體產品渲染圖 (LYWSD03MMC)**，清晰展示連線狀態與型號。
  - **三大巨型指標卡片**：即時溫度（附今日最高/最低溫）、相對濕度（附舒適度評估）、電池電量與電壓回彈監控。
  - **CoreGraphics 雙 Y 軸互動折線圖**：預設進入 **「📊 綜合總覽」** 同步繪製溫度（暖橙）與濕度（湛藍）雙軌對比走勢，亦可單獨切換「溫度走勢 / 濕度走勢 / 電壓回彈」，滑鼠懸停 (Hover) 即時顯示全維度數值氣泡，支援一鍵匯出 CSV 歷史數據。
- **純原生極速、零依賴**：
  - 基於純 Swift 與 macOS 系統原生 `CoreBluetooth` + `AppKit` 打造。
  - **不需要** 安裝 Python、Node.js、Homebrew 或任何第三方 Runtime，下載即用。
- **原廠與開源雙模式自動相容**：
  - **原廠出廠韌體**：免刷機、出廠即用，直接透過 BLE GATT 協議讀取。
  - **開源自製韌體**：自動嗅探並解析 ATC / pvvx / BTHome 格式的未加密廣播。
- **彈性可調連線間隔（支援 1 小時與任意自訂）**：
  - 支援從選單直接切換預設值或彈跳視窗任意輸入分鐘數：
    - `30 秒`：即時更新模式（即時性最高，連線負載較重）
    - `1 分鐘` / `3 分鐘`：一般動態監控
    - `5 分鐘`：**推薦平衡模式**（預設）
    - `10 分鐘` / `15 分鐘` / `30 分鐘`：深度省電模式
    - `1 小時` / `2 小時`：**超省電休眠模式**（連線 1 秒休眠 3599 秒，電池續航 1 年以上）
    - `自訂時間 (分鐘)...`：支援任意輸入分鐘數（例如輸入 60、120 或更多），滿足極致省電需求！
- **「即連即斷 (Connect-Read-Disconnect)」極致省電架構**：
  - 讀取數據僅花 1 秒，讀完立即中斷 BLE GATT 連線，使硬體即刻進入出廠極致休眠 (Deep Sleep)，功耗驟降 95% 以上，徹底根除連續連線造成的電池負載電壓虛降 (Voltage Sag)。
- **智慧隱藏與自動秒連**：
  - 開啟「僅連線時顯示」功能後，帶著筆電出門或超出藍牙範圍時，圖示會**自動完全隱藏**，保持桌面乾淨。
  - 回到房間進入藍牙範圍，數秒內**自動無感重連並重新浮現**。
- **Google Stitch「Vibe Design」專屬 App 圖示**：
  - 摒棄廉價塑膠白盒造型，採用 Google Labs Stitch 的 Tech Noir 黑曜石底板 ＋ 雙向漫射霓虹光暈 ＋ 懸浮氣候膠囊設計。

---

## 📥 下載與安裝 (Installation)

### 方式 1：直接下載發行版本（最推薦）
1. 前往 **[Releases 頁面](https://github.com/liaw-boy/mijia-temp-bar/releases)** 下載最新版 `MijiaTempBar-v1.0.0-macos.zip`。
2. 解壓縮後將 `MijiaTempBar.app` 拖入 `/Applications`（應用程式）資料夾。
3. 雙擊啟動即可！（首次啟動若系統跳出「想使用藍牙」，請點擊允許）。

### 方式 2：從原始碼自行編譯 (Build from Source)
```bash
git clone https://github.com/liaw-boy/mijia-temp-bar.git
cd mijia-temp-bar
./bundle.sh
open MijiaTempBar.app
```

---

## ⚙️ 開機自動啟動 (Launch at Login)

若希望每次開機自動在狀態列顯示：
1. 打開 Mac **系統設定** > **一般** > **登入項目與擴充功能**。
2. 在「**登入時打開**」區域點擊 `+` 號。
3. 選取本專案的 `MijiaTempBar.app` 即可。

---

## 🏷️ 支援硬體規格 (Supported Hardware)

| 設備型號 | 官方名稱 | 支援方式 |
| :--- | :--- | :--- |
| **LYWSD03MMC** | 米家藍牙溫濕度計 2 (代工廠：秒秒測) | **完全支援**（原廠出廠 / 開源韌體雙模） |
| **MJWSD05MMC** | 米家溫濕度計 3 代 | 開源廣播模式完全相容 |
| **MHO-C401** | 秒秒測電子墨水屏溫濕度計 | 開源廣播模式完全相容 |
| **CGG1 / CGDK2** | 青萍藍牙溫濕度計系列 | 開源廣播模式完全相容 |

> **名詞解析（什麼是 LYWSD03MMC？）**：  
> `LYWSD03MMC` 是小米官方出廠在機身背面與藍牙廣播中所使用的正式硬體型號代碼：  
> `L`（藍牙 BLE）+ `Y`（溫）+ `W`（濕）+ `S`（感測器 Sensor）+ `D`（螢幕/電池 Display）+ `03`（第3代專案代號）+ `MMC`（小米生態鏈原廠製造商：北京秒秒測科技有限公司 Miaomiaoce）。  
> 全世界出廠的每一台「米家藍牙溫濕度計 2」都具備這個名稱。

---

## 🛠️ 專案檔案結構 (Project Structure)

```
mijia-temp-bar/
├── Sources/
│   ├── main.swift              # AppKit 生命週期與常駐模式進入點
│   ├── StatusBarController.swift# 狀態列介面、Stats 雙行膠囊渲染、下拉選單
│   ├── BluetoothManager.swift  # CoreBluetooth 藍牙搜尋、GATT 連線、廣播解析
│   └── Logger.swift            # 輕量本機除錯日誌 (/tmp/mijia_temp_bar.log)
├── generate_icon.swift         # Google Stitch Vibe Design 原生圖示生成腳本
├── bundle.sh                   # 一鍵編譯、資源打包與 Ad-hoc 本機簽名腳本
├── LICENSE                     # MIT 開源授權
└── README.md
```

---

## 📄 授權條款 (License)

本專案採用 [MIT License](LICENSE) 授權開放原始碼。
