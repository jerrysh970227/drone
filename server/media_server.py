#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import time
import signal
import logging
import threading
import subprocess
from datetime import datetime
from typing import Optional, Tuple

# 🔧 修復 eventlet 衝突 - 在導入 Flask 之前禁用 eventlet
os.environ['EVENTLET_NO_GREENDNS'] = 'yes'
os.environ['GEVENT_SUPPORT'] = 'False'

from flask import Flask, jsonify, request, send_file, abort

# Try to import CORS, but handle the case where it's not available
try:
    from flask_cors import CORS
    cors_available = True
except ImportError:
    cors_available = False
    print("Warning: flask-cors not available. CORS support disabled.")

# 日誌設定
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler("media_server.log")],
)
logger = logging.getLogger(__name__)

# 禁用 eventlet 和 socketio 的日誌警告
logging.getLogger('eventlet').setLevel(logging.ERROR)
logging.getLogger('socketio').setLevel(logging.ERROR)
logging.getLogger('engineio').setLevel(logging.ERROR)

# USB 存儲設定
USB_MOUNT_POINT = "/mnt/usb"
USB_DEVICE = "/dev/sda1"

# 基本設定與媒體輸出路徑
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

DEFAULT_DEVICE = os.environ.get("VIDEO_DEVICE", "/dev/video0")
DEFAULT_WIDTH = int(os.environ.get("VIDEO_WIDTH", "1280"))
DEFAULT_HEIGHT = int(os.environ.get("VIDEO_HEIGHT", "720"))
DEFAULT_FPS = int(os.environ.get("VIDEO_FPS", "30"))

# 全局變數用於當前存儲路徑
current_media_root = None
current_photos_dir = None
current_videos_dir = None

# Flask app
app = Flask(__name__)
app.config['PROPAGATE_EXCEPTIONS'] = True
app.config['PREFERRED_URL_SCHEME'] = 'http'
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB

# Enable CORS if available
if cors_available:
    CORS(app)
    logger.info("CORS support enabled")
else:
    logger.warning("CORS support disabled - flask-cors not available")


# USB 掛載相關函數
def is_usb_mounted() -> bool:
    try:
        result = subprocess.run(["mount"], capture_output=True, text=True, check=False, timeout=5)
        return USB_MOUNT_POINT in result.stdout
    except Exception as e:
        logger.warning(f"檢查 USB 掛載狀態失敗: {e}")
        return False


def mount_usb() -> bool:
    try:
        os.makedirs(USB_MOUNT_POINT, exist_ok=True)
        result = subprocess.run(
            ["sudo", "mount", USB_DEVICE, USB_MOUNT_POINT],
            capture_output=True, text=True, check=False, timeout=10
        )
        if result.returncode == 0:
            logger.info(f"✅ USB 設備已成功掛載到 {USB_MOUNT_POINT}")
            return True
        else:
            logger.warning(f"掛載 USB 失敗: {result.stderr}")
            return False
    except Exception as e:
        logger.error(f"掛載 USB 過程發生錯誤: {e}")
        return False


def unmount_usb() -> bool:
    try:
        result = subprocess.run(
            ["sudo", "umount", USB_MOUNT_POINT],
            capture_output=True, text=True, check=False, timeout=10
        )
        if result.returncode == 0:
            logger.info("✅ USB 設備已成功卸載")
            return True
        else:
            logger.warning(f"⚠️ USB 卸載警告: {result.stderr.strip()}")
            return False
    except Exception as e:
        logger.error(f"卸載 USB 過程發生錯誤: {e}")
        return False


def get_storage_paths() -> Tuple[str, str, str]:
    """獲取當前存儲路徑(優先 USB,其次本地)"""
    if is_usb_mounted():
        media_root = os.path.join(USB_MOUNT_POINT, "Movies")
        photos_dir = media_root
        videos_dir = media_root

        try:
            os.makedirs(media_root, exist_ok=True)
            logger.info(f"✅ 使用 USB 存儲: {media_root}")
            return media_root, photos_dir, videos_dir
        except PermissionError:
            logger.warning(f"⚠️ USB 存儲權限不足,切換到本地存儲")
        except Exception as e:
            logger.warning(f"⚠️ USB 存儲初始化失敗: {e},切換到本地存儲")

    # 使用本地存儲
    media_root = os.path.join(BASE_DIR, "media")
    photos_dir = os.path.join(media_root, "photos")
    videos_dir = os.path.join(media_root, "videos")

    os.makedirs(photos_dir, exist_ok=True)
    os.makedirs(videos_dir, exist_ok=True)
    logger.info(f"📁 使用本地存儲: {media_root}")
    return media_root, photos_dir, videos_dir


def init_storage():
    global current_media_root, current_photos_dir, current_videos_dir
    logger.info("🔍 檢查 USB 設備掛載狀態...")

    if is_usb_mounted():
        logger.info(f"USB 已掛載在 {USB_MOUNT_POINT}")
    else:
        logger.info("🔄 USB 未掛載,嘗試掛載...")
        if mount_usb():
            logger.info("✅ USB 掛載成功")
        else:
            logger.info("⚠️ USB 掛載失敗,使用本地存儲")

    current_media_root, current_photos_dir, current_videos_dir = get_storage_paths()


def cleanup_resources():
    logger.info("🗜️ 正在清理資源...")
    if video_recorder.is_recording():
        try:
            video_recorder.stop()
            logger.info("✅ 已停止錄影")
        except Exception as e:
            logger.warning(f"停止錄影失敗: {e}")
    if is_usb_mounted():
        unmount_usb()
    logger.info("✅ 資源清理完成")


# 輔助方法
def which(cmd: str) -> Optional[str]:
    try:
        import shutil
        return shutil.which(cmd)
    except Exception:
        return None


def sanitize_filename(name: str, allowed_exts: Tuple[str, ...]) -> str:
    import re
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    base, ext = os.path.splitext(safe)
    if not ext:
        return base + allowed_exts[0]
    if ext.lower() not in allowed_exts:
        return base + allowed_exts[0]
    return base + ext


def secure_path_join(root: str, filename: str) -> str:
    path = os.path.abspath(os.path.join(root, filename))
    if not path.startswith(os.path.abspath(root) + os.sep):
        raise ValueError("非法檔名或路徑")
    return path


def check_camera_available() -> bool:
    """檢查相機是否可用（未被佔用）"""
    try:
        # 檢查 /dev/video0 是否被佔用
        result = subprocess.run(
            ["sudo", "lsof", "/dev/video0"],
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.stdout.strip():
            logger.warning(f"⚠️ 相機設備被佔用:\n{result.stdout}")
            return False
        return True
    except subprocess.TimeoutExpired:
        logger.warning("檢查相機狀態超時")
        return True  # 假設可用
    except FileNotFoundError:
        # lsof 未安裝，跳過檢查
        return True
    except Exception as e:
        logger.warning(f"檢查相機狀態失敗: {e}")
        return True


def release_camera() -> bool:
    """嘗試釋放被佔用的相機資源"""
    try:
        logger.info("🔧 嘗試釋放相機資源...")

        # 方法1: 使用 fuser 強制釋放
        result = subprocess.run(
            ["sudo", "fuser", "-k", "/dev/video0"],
            capture_output=True,
            text=True,
            timeout=3
        )

        if result.returncode == 0:
            time.sleep(0.5)  # 等待進程終止
            logger.info("✅ 相機資源已釋放")
            return True

        # 方法2: 終止常見的相機進程
        for proc_name in ["libcamera-vid", "libcamera-still", "ffmpeg", "raspivid"]:
            subprocess.run(
                ["sudo", "killall", proc_name],
                capture_output=True,
                timeout=2
            )

        time.sleep(0.5)
        logger.info("✅ 已嘗試終止相關進程")
        return True

    except Exception as e:
        logger.error(f"❌ 釋放相機資源失敗: {e}")
        return False


def detect_backends() -> Tuple[bool, bool, bool]:
    has_libcamera = bool(which("libcamera-still")) and bool(which("libcamera-vid"))
    has_ffmpeg = bool(which("ffmpeg"))
    has_picamera2 = False
    try:
        from picamera2 import Picamera2  # type: ignore
        has_picamera2 = True
    except ImportError:
        pass
    return has_libcamera, has_ffmpeg, has_picamera2


HAS_LIBCAMERA, HAS_FFMPEG, HAS_PICAMERA2 = detect_backends()


def _timestamped_filename(prefix: str, ext: str) -> str:
    return f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.{ext}"


def capture_photo(output_path: Optional[str] = None) -> str:
    if output_path is None:
        output_path = os.path.join(current_photos_dir, _timestamped_filename("photo", "jpg"))
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    # 優先使用 picamera2
    if HAS_PICAMERA2:
        try:
            from picamera2 import Picamera2  # type: ignore

            logger.info(f"📷 picamera2 拍照: {output_path}")
            picam2 = Picamera2()
            try:
                photo_config = picam2.create_still_configuration(main={"size": (DEFAULT_WIDTH, DEFAULT_HEIGHT)})
                picam2.configure(photo_config)
                picam2.start()
                time.sleep(0.5)
                picam2.capture_file(output_path)
                logger.info(f"✅ picamera2 拍照成功: {output_path}")
                # 强制写入
                try:
                    os.sync()
                except Exception:
                    pass
                return output_path
            finally:
                try:
                    picam2.stop()
                except Exception:
                    pass
                try:
                    picam2.close()
                except Exception:
                    pass
        except Exception as exc:
            logger.warning(f"picamera2 拍照失敗,嘗試其他方法: {exc}")

    if HAS_LIBCAMERA:
        cmd = ["libcamera-still", "-n", "-o", output_path, "--width", str(DEFAULT_WIDTH), "--height", str(DEFAULT_HEIGHT)]
        logger.info(f"📷 libcamera 拍照: {' '.join(map(str, cmd))}")
        subprocess.check_call(cmd)
        try:
            os.sync()
        except Exception:
            pass
        return output_path

    if HAS_FFMPEG:
        cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "v4l2",
               "-video_size", f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}", "-i", DEFAULT_DEVICE,
               "-vframes", "1", "-pix_fmt", "yuvj420p", output_path]
        logger.info(f"📷 ffmpeg 拍照: {' '.join(map(str, cmd))}")
        subprocess.check_call(cmd)
        try:
            os.sync()
        except Exception:
            pass
        return output_path

    # Fallback to OpenCV
    try:
        import cv2
        logger.info("📷 OpenCV 拍照")
        cap = cv2.VideoCapture(0)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, DEFAULT_WIDTH)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, DEFAULT_HEIGHT)
        for _ in range(3):
            cap.read()
        ret, frame = cap.read()
        cap.release()
        if not ret:
            raise RuntimeError("Failed to capture frame")
        cv2.imwrite(output_path, frame)
        try:
            os.sync()
        except Exception:
            pass
        return output_path
    except Exception as exc:
        logger.exception("OpenCV 拍照失敗")
        raise RuntimeError("沒有可用的拍照後端") from exc


class VideoRecorder:
    """優化後的錄影類別 - 解決堵塞問題並修復 USB/exFAT 不寫入問題"""

    def __init__(self) -> None:
        self._process: Optional[subprocess.Popen] = None
        self._lock = threading.RLock()  # 使用可重入鎖
        self._start_time: Optional[float] = None
        self._raw_file_path: Optional[str] = None
        self._final_file_path: Optional[str] = None
        self._using_backend: str = "none"  # 統一後端標記

        # picamera2 相關
        self._picam2 = None
        self._encoder = None
        self._output = None
        self._recording_thread = None

    def is_recording(self) -> bool:
        """檢查是否正在錄影"""
        with self._lock:
            # 判斷更嚴謹：如果 picam2 存在且已 start_recording，視為 recording
            if self._picam2:
                return True
            return self._process is not None and self._process.poll() is None

    def status(self) -> dict:
        """獲取錄影狀態"""
        with self._lock:
            return {
                "recording": self.is_recording(),
                "started_at": self._start_time,
                "raw_file": self._raw_file_path,
                "file": self._final_file_path or self._raw_file_path,
                "backend": self._using_backend,
            }

    def start(self, output_basename: Optional[str] = None, duration_seconds: Optional[int] = None) -> str:
        """啟動錄影 - 優化版本"""
        with self._lock:
            if self.is_recording():
                raise RuntimeError("Recording already in progress")

            # 準備檔案路徑
            base_name = output_basename or _timestamped_filename("video", "mp4")
            base_name = os.path.splitext(base_name)[0]
            output_mp4 = os.path.join(current_videos_dir, f"{base_name}.mp4")
            os.makedirs(os.path.dirname(output_mp4), exist_ok=True)

            logger.info(f"🎥 準備開始錄影: {output_mp4}")

            # 優先使用 picamera2
            if HAS_PICAMERA2:
                return self._start_picamera2(base_name, output_mp4, duration_seconds)
            elif HAS_LIBCAMERA:
                return self._start_libcamera(base_name, output_mp4, duration_seconds)
            elif HAS_FFMPEG:
                return self._start_ffmpeg(output_mp4, duration_seconds)
            else:
                raise RuntimeError("No available backend for video recording")

    def _start_picamera2(self, base_name: str, output_mp4: str, duration_seconds: Optional[int]) -> str:
        try:
            from picamera2 import Picamera2
            from picamera2.encoders import H264Encoder
            from picamera2.outputs import FileOutput

            logger.info(f"🎥 使用 picamera2 後端錄影")

            # 初始化相機
            self._picam2 = Picamera2()
            video_config = self._picam2.create_video_configuration(main={"size": (DEFAULT_WIDTH, DEFAULT_HEIGHT)})
            self._picam2.configure(video_config)

            # 建立 H264 原始檔案
            raw_h264 = os.path.join(current_videos_dir, f"{base_name}.h264")
            os.makedirs(os.path.dirname(raw_h264), exist_ok=True)
            try:
                fd = os.open(raw_h264, os.O_CREAT | os.O_WRONLY)
                os.fsync(fd)
                os.close(fd)
            except Exception:
                pass

            encoder = H264Encoder()
            output = FileOutput(raw_h264)

            # 記錄狀態
            self._encoder = encoder
            self._output = output
            self._raw_file_path = raw_h264
            self._final_file_path = output_mp4
            self._using_backend = "picamera2"
            self._start_time = time.time()

            # 開始錄影
            self._picam2.start_recording(encoder, output)
            logger.info(f"✅ picamera2 錄影已啟動: {raw_h264}")

            # 自動停止線程
            if duration_seconds:
                self._recording_thread = threading.Thread(
                    target=self._auto_stop_after,
                    args=(duration_seconds,),
                    daemon=True
                )
                self._recording_thread.start()

            return self._final_file_path or self._raw_file_path

        except Exception as exc:
            self._cleanup_picamera2()
            logger.error(f"❌ picamera2 錄影失敗: {exc}")
            # fallback to other backends
            if HAS_LIBCAMERA:
                return self._start_libcamera(base_name, output_mp4, duration_seconds)
            elif HAS_FFMPEG:
                return self._start_ffmpeg(output_mp4, duration_seconds)
            else:
                raise
       
    


    def _start_libcamera(self, base_name: str, output_mp4: str, duration_seconds: Optional[int]) -> str:
        """使用 libcamera 啟動錄影"""
        raw_h264 = os.path.join(current_videos_dir, f"{base_name}.h264")
        cmd = [
            "libcamera-vid", "-n",
            "--framerate", str(DEFAULT_FPS),
            "--width", str(DEFAULT_WIDTH),
            "--height", str(DEFAULT_HEIGHT),
            "-o", raw_h264
        ]
        if duration_seconds:
            cmd += ["-t", str(duration_seconds * 1000)]

        logger.info(f"🎥 libcamera 開始錄影: {' '.join(cmd)}")
        self._process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )
        self._using_backend = "libcamera"
        self._raw_file_path = raw_h264
        self._final_file_path = output_mp4 if HAS_FFMPEG else None
        self._start_time = time.time()

        if duration_seconds:
            self._recording_thread = threading.Thread(
                target=self._auto_stop_after,
                args=(duration_seconds + 1,),  # 多等1秒確保進程結束
                daemon=True
            )
            self._recording_thread.start()

        logger.info(f"✅ libcamera 錄影已啟動")
        return self._final_file_path or self._raw_file_path

    def _start_ffmpeg(self, output_mp4: str, duration_seconds: Optional[int]) -> str:
        """使用 ffmpeg 啟動錄影"""
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "v4l2",
            "-video_size", f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}",
            "-framerate", str(DEFAULT_FPS),
            "-i", DEFAULT_DEVICE,
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-pix_fmt", "yuv420p"
        ]
        if duration_seconds:
            cmd += ["-t", str(duration_seconds)]
        cmd += [output_mp4]

        logger.info(f"🎥 ffmpeg 開始錄影: {' '.join(cmd)}")
        self._process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )
        self._using_backend = "ffmpeg"
        self._raw_file_path = output_mp4
        self._final_file_path = output_mp4
        self._start_time = time.time()

        if duration_seconds:
            self._recording_thread = threading.Thread(
                target=self._auto_stop_after,
                args=(duration_seconds + 1,),
                daemon=True
            )
            self._recording_thread.start()

        logger.info(f"✅ ffmpeg 錄影已啟動")
        return output_mp4

    def _auto_stop_after(self, duration_seconds: int) -> None:
        """自動停止錄影"""
        time.sleep(max(0, duration_seconds))
        try:
            self.stop()
            logger.info(f"⏱️ 自動停止錄影 (時長: {duration_seconds}秒)")
        except Exception as e:
            logger.error(f"自動停止錄影失敗: {e}")

    def stop(self) -> str:
        """停止錄影 - 優化版本,防止堵塞"""
        with self._lock:
            if not self.is_recording():
                raise RuntimeError("No active recording")

            logger.info("🛑 正在停止錄影...")

            # 根據後端類型停止錄影
            if self._using_backend == "picamera2":
                self._stop_picamera2()
            else:
                self._stop_process()

            # 處理檔案轉換
            final_path = self._finalize_file_if_needed()

            # 在 finalization 後再強制 sync（雙重保險）
            try:
                time.sleep(0.5)
                os.sync()
            except Exception:
                pass

            # 重置狀態
            self._reset_state()

            logger.info(f"✅ 錄影已停止,檔案: {final_path}")
            return final_path

    def _stop_picamera2(self) -> None:
        """停止 picamera2 錄影"""
        if not self._picam2:
            return

        try:
            # 停止錄影
            self._picam2.stop_recording()
            logger.info("✅ picamera2 錄影已停止")
        except Exception as e:
            logger.warning(f"picamera2 停止錄影警告: {e}")
        finally:
            self._cleanup_picamera2()

    def _cleanup_picamera2(self) -> None:
        """清理 picamera2 資源"""
        try:
            if self._picam2:
                try:
                    self._picam2.stop()
                except Exception:
                    pass
                try:
                    self._picam2.close()
                except Exception:
                    pass
                logger.info("✅ picamera2 資源已釋放")
        except Exception as e:
            logger.warning(f"picamera2 資源清理警告: {e}")
        finally:
            # 等待一點時間讓 backend/ffmpeg flush
            try:
                time.sleep(1)
                os.sync()
                logger.info("💾 已強制同步磁碟寫入 (cleanup_picamera2)")
            except Exception:
                pass
            self._picam2 = None
            self._encoder = None
            self._output = None

    def _stop_process(self) -> None:
        """停止子進程 - 優化版本"""
        if not self._process:
            return

        # 嘗試優雅地停止進程
        try:
            # 1. 先嘗試發送 SIGINT
            self._process.send_signal(signal.SIGINT)
            try:
                self._process.wait(timeout=2)
                logger.info("✅ 進程已正常停止 (SIGINT)")
                return
            except subprocess.TimeoutExpired:
                pass

            # 2. 嘗試 SIGTERM
            self._process.terminate()
            try:
                self._process.wait(timeout=2)
                logger.info("✅ 進程已正常停止 (SIGTERM)")
                return
            except subprocess.TimeoutExpired:
                pass

            # 3. 強制終止
            self._process.kill()
            self._process.wait(timeout=1)
            logger.warning("⚠️ 進程已強制終止 (SIGKILL)")

        except Exception as e:
            logger.error(f"停止進程時發生錯誤: {e}")

        # 停止子進程後強制 sync
        try:
            time.sleep(0.5)
            os.sync()
        except Exception:
            pass

    def _finalize_file_if_needed(self) -> str:
        """處理 H264 -> MP4 轉檔"""
        if not self._raw_file_path:
            return self._final_file_path or ""

        # H264 -> MP4
        if self._raw_file_path.endswith(".h264") and self._final_file_path and HAS_FFMPEG:
            try:
                if not os.path.exists(self._raw_file_path):
                    logger.warning(f"⚠️ 原始檔案不存在: {self._raw_file_path}")
                    return self._raw_file_path

                cmd = [
                    "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-r", str(DEFAULT_FPS),
                    "-i", self._raw_file_path,
                    "-c", "copy",
                    self._final_file_path
                ]
                logger.info(f"🔄 轉換 H264 為 MP4: {' '.join(cmd)}")
                subprocess.run(cmd, check=True, timeout=60)

                # 刪除原始檔
                try:
                    os.remove(self._raw_file_path)
                    logger.info(f"✅ 已刪除原始檔案: {self._raw_file_path}")
                except Exception as e:
                    logger.warning(f"刪除原始檔失敗: {e}")

                # 強制 sync
                try:
                    os.sync()
                except Exception:
                    pass

                return self._final_file_path

            except subprocess.TimeoutExpired:
                logger.error("❌ ffmpeg 轉換超時")
                return self._raw_file_path
            except Exception as e:
                logger.error(f"❌ 檔案轉換失敗: {e}")
                return self._raw_file_path

        return self._final_file_path or self._raw_file_path


    def _reset_state(self) -> None:
        """重置錄影狀態"""
        self._process = None
        self._start_time = None
        self._using_backend = "none"
        self._recording_thread = None


# 創建全局錄影實例
video_recorder = VideoRecorder()


# ==================== Flask API 端點 ====================

@app.get("/")
def index():
    """根路徑 - API 文檔"""
    return jsonify({
        "service": "Media Server",
        "version": "2.0",
        "status": "running",
        "endpoints": {
            "health": "GET /health",
            "photo": "POST /photo?filename=xxx",
            "video_start": "POST /video/start?filename=xxx&duration=10",
            "video_stop": "POST /video/stop",
            "video_status": "GET /video/status",
            "media": "GET /media/<filename>"
        }
    }), 200


@app.get("/health")
def health() -> tuple:
    """健康檢查端點"""
    return jsonify({
        "status": "ok",
        "backends": {
            "libcamera": HAS_LIBCAMERA,
            "ffmpeg": HAS_FFMPEG,
            "picamera2": HAS_PICAMERA2
        },
        "storage": {
            "media_root": current_media_root,
            "usb_mounted": is_usb_mounted()
        }
    }), 200


@app.post("/photo")
def api_photo() -> tuple:
    """拍照端點"""
    filename = request.args.get("filename")
    try:
        if filename:
            safe_name = sanitize_filename(filename, (".jpg", ".jpeg", ".png"))
            output_path = secure_path_join(current_photos_dir, safe_name)
        else:
            output_path = None
        output_path = capture_photo(output_path)
        return jsonify({"status": "ok", "file": output_path}), 200
    except Exception as exc:
        logger.exception("拍照失敗")
        return jsonify({"status": "error", "message": str(exc)}), 500


@app.post("/video/start")
def api_video_start() -> tuple:
    """啟動錄影端點"""
    # 檢查是否已在錄影中
    if video_recorder.is_recording():
        logger.warning("拒絕錄影請求:錄影已在進行中")
        return jsonify({"status": "error", "message": "Recording already in progress"}), 400

    # 獲取參數
    filename = request.args.get("filename")
    duration = request.args.get("duration")

    # 驗證 duration
    duration_seconds = None
    if duration:
        try:
            duration_seconds = int(duration)
            if duration_seconds <= 0:
                return jsonify({"status": "error", "message": "Duration must be positive"}), 400
        except ValueError:
            return jsonify({"status": "error", "message": "Invalid duration parameter"}), 400

    # 驗證 filename
    safe_base = None
    if filename:
        try:
            safe_base = os.path.splitext(sanitize_filename(filename, (".mp4", ".h264")))[0]
        except Exception as e:
            logger.error(f"檔案名稱驗證失敗: {e}")
            return jsonify({"status": "error", "message": "Invalid filename"}), 400

    logger.info(f"📹 開始錄影請求 - 檔名: {filename}, 時長: {duration_seconds}秒")

    # 啟動錄影
    try:
        path = video_recorder.start(output_basename=safe_base, duration_seconds=duration_seconds)
        logger.info(f"✅ 錄影已啟動: {path}")
        return jsonify({"status": "ok", "file": path}), 200
    except Exception as exc:
        logger.exception("錄影啟動失敗")
        return jsonify({"status": "error", "message": str(exc)}), 500


@app.post("/video/stop")
def api_video_stop() -> tuple:
    """停止錄影端點"""
    try:
        path = video_recorder.stop()
        return jsonify({"status": "ok", "file": path}), 200
    except Exception as exc:
        logger.exception("停止錄影失敗")
        return jsonify({"status": "error", "message": str(exc)}), 400


@app.get("/video/status")
def api_video_status() -> tuple:
    """獲取錄影狀態端點"""
    return jsonify({"status": "ok", **video_recorder.status()}), 200


@app.get("/media/<path:filename>")
def get_media(filename: str):
    """獲取媒體檔案端點"""
    try:
        path = secure_path_join(current_media_root, filename)
    except Exception:
        abort(400)
    if not os.path.isfile(path):
        abort(404)
    return send_file(path)


# ==================== 主程式 ====================

def main() -> None:
    """主程式入口"""
    def signal_handler(signum, frame):
        logger.info("🛑 收到終止信號,正在關閉...")
        cleanup_resources()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        logger.info("🚀 啟動 Media Server...")
        init_storage()

        host = os.environ.get("MEDIA_SERVER_HOST", "0.0.0.0")
        port = int(os.environ.get("MEDIA_SERVER_PORT", "8770"))

        logger.info(f"🌐 伺服器啟動於 http://{host}:{port}")
        logger.info(f"📁 媒體目錄: {current_media_root}")
        logger.info(f"🎥 可用後端: picamera2={HAS_PICAMERA2}, libcamera={HAS_LIBCAMERA}, ffmpeg={HAS_FFMPEG}")

        # 使用標準 Flask 開發伺服器 (不使用 eventlet/gevent)
        app.run(
            host=host,
            port=port,
            debug=False,
            threaded=True,  # 使用標準執行緒
            use_reloader=False
        )
    except Exception as e:
        logger.error(f"❌ 服務啟動失敗: {e}")
        logger.exception(e)
    finally:
        cleanup_resources()


if __name__ == "__main__":
    main()
