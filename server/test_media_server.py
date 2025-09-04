#!/usr/bin/env python3
import os
import subprocess
from datetime import datetime
import time
from picamera2 import Picamera2, encoders, outputs

USB_MOUNT = "/mnt/usb"
DEV_PATH = "/dev/sda1"
MOVIES_DIR = os.path.join(USB_MOUNT, "Movies")

def check_mount():
    if not os.path.ismount(USB_MOUNT):
        print(f"⚠️ {USB_MOUNT} 未掛載，嘗試掛載...")
        os.makedirs(USB_MOUNT, exist_ok=True)
        ret = subprocess.run(["sudo", "mount", DEV_PATH, USB_MOUNT])
        if ret.returncode != 0:
            print(f"❌ 掛載失敗: {ret}")
            raise RuntimeError(f"掛載 {DEV_PATH} 到 {USB_MOUNT} 失敗")
        else:
            print(f"✅ 已掛載 {DEV_PATH} 到 {USB_MOUNT}")
    else:
        print(f"✅ {USB_MOUNT} 已掛載")
    print("📂 /mnt/usb 內容：", os.listdir(USB_MOUNT))

def timestamp_filename(ext):
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    return os.path.join(MOVIES_DIR, f"{ts}.{ext}")

def main():
    check_mount()
    os.makedirs(MOVIES_DIR, exist_ok=True)
    picam2 = Picamera2()
    RESOLUTION = (640, 480)  # 可調整解析度
    # 拍照
    try:
        photo_config = picam2.create_still_configuration(main={"size": RESOLUTION})
        picam2.configure(photo_config)
        picam2.start()
        time.sleep(2)
        photo_path = timestamp_filename("jpg")
        picam2.capture_file(photo_path)
        print(f"✅ 已存照片: {photo_path}")
        if not os.path.exists(photo_path):
            print(f"❌ 拍照失敗，檔案未產生: {photo_path}")
        picam2.stop()
    except Exception as e:
        print(f"❌ 拍照錯誤: {e}")
    # 錄影 5 秒
    try:
        video_config = picam2.create_video_configuration(main={"size": RESOLUTION})
        picam2.configure(video_config)
        video_path = timestamp_filename("h264")
        encoder = encoders.H264Encoder()
        output = outputs.FileOutput(video_path)
        picam2.start_recording(encoder, output)
        print(f"🎥 開始錄影 5 秒: {video_path}")
        time.sleep(5)
        picam2.stop_recording()
        output.close()
        print(f"✅ 已存錄影 (H264): {video_path}")
        if not os.path.exists(video_path):
            print(f"❌ 錄影失敗，檔案未產生: {video_path}")
    except Exception as e:
        print(f"❌ 錄影錯誤: {e}")
    # 轉 MP4
    try:
        mp4_path = video_path.replace(".h264", ".mp4")
        result = subprocess.run(["ffmpeg", "-y", "-i", video_path, "-c", "copy", mp4_path])
        if result.returncode == 0 and os.path.exists(mp4_path):
            print(f"✅ 已轉 MP4: {mp4_path}")
        else:
            print(f"❌ MP4 轉檔失敗: {mp4_path}")
    except Exception as e:
        print(f"❌ MP4 轉檔錯誤: {e}")

if __name__ == "__main__":
    main()
