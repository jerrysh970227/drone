# Media Server 使用說明

## 功能概述

這個 media server 提供拍照和錄影功能，支援多種後端：
- **libcamera** (優先，適用於 Raspberry Pi)
- **ffmpeg** (其次，適用於一般 Linux 系統)
- **OpenCV** (僅拍照，作為備用方案)

## 快速開始

### 1. 啟動 Media Server

```bash
cd server
python3 media_server.py
```

預設會在 `http://0.0.0.0:8770` 啟動。

### 2. 環境變數配置

```bash
export MEDIA_SERVER_HOST="0.0.0.0"
export MEDIA_SERVER_PORT="8770"
export VIDEO_DEVICE="/dev/video0"
export VIDEO_WIDTH="1280"
export VIDEO_HEIGHT="720"
export VIDEO_FPS="30"
```

### 3. USB 掛載與測試功能

本專案支援自動掛載 USB 隨身碟（/mnt/usb），並將照片與影片儲存於 `/mnt/usb/Movies` 目錄。

執行測試腳本：
```bash
python3 test_media_server.py
```
腳本會自動：
- 檢查並掛載 USB 隨身碟
- 拍照並儲存至 Movies 目錄
- 錄影 5 秒並儲存 H264 檔
- 自動轉檔為 MP4
所有檔案皆自動加上時間戳。

## API 端點

### 健康檢查
```bash
GET /health
```
回傳可用後端資訊。

### 拍照
```bash
POST /photo
POST /photo?filename=custom_name.jpg
```

### 錄影控制
```bash
# 開始錄影
POST /video/start
POST /video/start?filename=custom_name&duration=10

# 停止錄影
POST /video/stop

# 查詢狀態
GET /video/status
```

### 檔案下載
```bash
GET /media/photos/{filename}
GET /media/videos/{filename}
```

## Flutter 應用整合

### 功能說明

1. **拍照/錄影模式切換**
   - 藍色按鈕：拍照模式
   - 橘色按鈕：錄影模式
   - 點擊可切換模式

2. **Joystick 控制**
   - 拍照模式：按下按鈕拍照
   - 錄影模式：按下開始/停止錄影

3. **檔案儲存**
   - 照片：`server/media/photos/`
   - 影片：`server/media/videos/`
   - 自動產生時間戳檔名

### 使用流程

1. 啟動 media server
2. 在 Flutter 應用中連接到正確的 IP 位址
3. 選擇拍照或錄影模式
4. 使用 joystick 按鈕進行操作

## 故障排除

### 常見問題

1. **無法連線到 media server**
   - 確認 server 是否正在運行
   - 檢查防火牆設定
   - 確認 IP 位址和埠號

2. **拍照/錄影/轉檔失敗**
   - 檢查相機設備是否可用
   - 確認 USB 是否正確掛載（/mnt/usb）
   - 檢查 Movies 目錄權限
   - 確認 ffmpeg 是否安裝
   - 查看 server 日誌與錯誤訊息

3. **檔案無法下載**
   - 確認檔案路徑正確
   - 檢查檔案權限
   - 確認 media 資料夾存在

### 日誌查看

```bash
tail -f server/media_server.log
```

## 系統需求

### 必要套件
- Python 3.7+
- picamera2
- ffmpeg

### 可選套件
- Flask (如需 API)
- libcamera-tools (Raspberry Pi)
- opencv-python (備用方案)

### 安裝指令
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install libcamera-tools ffmpeg python3-picamera2

# 或使用 pip
pip3 install picamera2 ffmpeg flask opencv-python

# Raspberry Pi
sudo apt install libcamera-tools python3-picamera2
```

## 安全注意事項

1. **網路安全**
   - 預設綁定到 `0.0.0.0`，請在生產環境中限制存取
   - 考慮加入認證機制

2. **檔案安全**
   - 檔案路徑已過濾，防止路徑穿越攻擊
   - 檔名會自動清理，移除危險字元

3. **權限管理**
   - 確保 media 資料夾有適當的讀寫權限
   - 定期清理舊檔案

## 進階配置

### 自定義後端
可以修改 `media_server.py` 來支援其他相機後端。

### 檔案格式
- 照片：JPG
- 影片：H264（自動轉檔 MP4）

### 品質設定
透過環境變數調整解析度和幀率。

## 支援

如有問題，請檢查：
1. Server 日誌與錯誤訊息
2. USB 掛載狀態與目錄權限
3. 相機設備狀態
4. ffmpeg、picamera2 等工具安裝狀態
