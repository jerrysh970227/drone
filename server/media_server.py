import os
import sys
import time
import json
import signal
import logging
import threading
import subprocess
import asyncio
from datetime import datetime
from typing import Optional, Tuple, Dict, Any

from flask import Flask, send_file, abort
from flask_socketio import SocketIO, emit
import eventlet
eventlet.monkey_patch()


# 日誌設定
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler("media_server.log")],
)
logger = logging.getLogger(__name__)

# USB 存储設定
USB_MOUNT_POINT = "/mnt/usb"
USB_DEVICE = "/dev/sda1"

# 基本設定與媒體輸出路徑
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

DEFAULT_DEVICE = os.environ.get("VIDEO_DEVICE", "/dev/video0")
DEFAULT_WIDTH = int(os.environ.get("VIDEO_WIDTH", "1280"))
DEFAULT_HEIGHT = int(os.environ.get("VIDEO_HEIGHT", "720"))
DEFAULT_FPS = int(os.environ.get("VIDEO_FPS", "30"))

# 全局變數用於當前存储路徑
current_media_root = None
current_photos_dir = None
current_videos_dir = None

# WebSocket 連接管理
connected_clients = set()


# USB 掛載相關函數（保持不變）
def is_usb_mounted() -> bool:
    try:
        result = subprocess.run(["mount"], capture_output=True, text=True, check=False)
        return USB_MOUNT_POINT in result.stdout
    except Exception as e:
        logger.warning(f"檢查 USB 掛載狀態失敗: {e}")
        return False


def mount_usb() -> bool:
    try:
        os.makedirs(USB_MOUNT_POINT, exist_ok=True)
        result = subprocess.run(
            ["sudo", "mount", USB_DEVICE, USB_MOUNT_POINT],
            capture_output=True, text=True, check=False
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
            capture_output=True, text=True, check=False
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
    """獲取當前存储路徑（優先 USB，其次本地）"""
    if is_usb_mounted():
        media_root = os.path.join(USB_MOUNT_POINT, "Movies")
        photos_dir = media_root
        videos_dir = media_root

        try:
            os.makedirs(media_root, exist_ok=True)
            logger.info(f"✅ 使用 USB 存储: {media_root}")
            return media_root, photos_dir, videos_dir
        except PermissionError:
            logger.warning(f"⚠️ USB 存储權限不足，切換到本地存储")
        except Exception as e:
            logger.warning(f"⚠️ USB 存储初始化失敗: {e}，切換到本地存储")

    media_root = os.path.join(BASE_DIR, "media")
    photos_dir = os.path.join(media_root, "photos")
    videos_dir = os.path.join(media_root, "videos")

    os.makedirs(photos_dir, exist_ok=True)
    os.makedirs(videos_dir, exist_ok=True)
    logger.info(f"📁 使用本地存储: {media_root}")
    return media_root, photos_dir, videos_dir


def init_storage():
    global current_media_root, current_photos_dir, current_videos_dir
    logger.info("🔍 檢查 USB 設備掛載狀態...")

    if is_usb_mounted():
        logger.info(f"USB 已掛載在 {USB_MOUNT_POINT}")
    else:
        logger.info("🔄 USB 未掛載，嘗試掛載...")
        if mount_usb():
            logger.info("✅ USB 掛載成功")
        else:
            logger.info("⚠️ USB 掛載失敗，使用本地存储")

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


# 輔助函數
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


def detect_backends() -> Tuple[bool, bool, bool]:
    has_libcamera = bool(which("libcamera-still")) and bool(which("libcamera-vid"))
    has_ffmpeg = bool(which("ffmpeg"))
    has_picamera2 = False
    try:
        from picamera2 import Picamera2
        has_picamera2 = True
    except ImportError:
        pass
    return has_libcamera, has_ffmpeg, has_picamera2


HAS_LIBCAMERA, HAS_FFMPEG, HAS_PICAMERA2 = detect_backends()


def _timestamped_filename(prefix: str, ext: str) -> str:
    return f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.{ext}"


# WebSocket 廣播函數
def broadcast_to_clients(event: str, data: Dict[str, Any]):
    """廣播消息給所有連接的客戶端"""
    if connected_clients:
        socketio.emit(event, data)
        logger.debug(f"廣播事件 {event} 給 {len(connected_clients)} 個客戶端")


def capture_photo(output_path: Optional[str] = None) -> str:
    if output_path is None:
        output_path = os.path.join(current_photos_dir, _timestamped_filename("photo", "jpg"))
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    # 廣播拍照開始
    broadcast_to_clients('photo_start', {'output_path': output_path})

    try:
        # 優先使用 picamera2
        if HAS_PICAMERA2:
            try:
                from picamera2 import Picamera2
                import time

                logger.info("picamera2 拍照: %s", output_path)
                picam2 = Picamera2()
                photo_config = picam2.create_still_configuration(main={"size": (DEFAULT_WIDTH, DEFAULT_HEIGHT)})
                picam2.configure(photo_config)
                picam2.start()
                time.sleep(0.8)
                picam2.capture_file(output_path)
                picam2.stop()
                logger.info("✅ picamera2 拍照成功: %s", output_path)
                broadcast_to_clients('photo_success', {'file': output_path})
                return output_path
            except Exception as exc:
                logger.warning("picamera2 拍照失敗，嘗試其他方法: %s", exc)

        if HAS_LIBCAMERA:
            cmd = ["libcamera-still", "-n", "-o", output_path, "--width", str(DEFAULT_WIDTH), "--height", str(DEFAULT_HEIGHT)]
            logger.info("libcamera 拍照: %s", " ".join(map(str, cmd)))
            subprocess.check_call(cmd)
            broadcast_to_clients('photo_success', {'file': output_path})
            return output_path

        if HAS_FFMPEG:
            cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "v4l2",
                   "-video_size", f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}", "-i", DEFAULT_DEVICE,
                   "-vframes", "1", "-pix_fmt", "yuvj420p", output_path]
            logger.info("ffmpeg 拍照: %s", " ".join(map(str, cmd)))
            subprocess.check_call(cmd)
            broadcast_to_clients('photo_success', {'file': output_path})
            return output_path

        # Fallback to OpenCV
        try:
            import cv2
            logger.info("OpenCV 拍照")
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
            broadcast_to_clients('photo_success', {'file': output_path})
            return output_path
        except Exception as exc:
            logger.exception("OpenCV 拍照失敗")
            raise RuntimeError("沒有可用的拍照後端") from exc

    except Exception as e:
        broadcast_to_clients('photo_error', {'error': str(e)})
        raise


class VideoRecorder:
    def __init__(self) -> None:
        self._process: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._start_time: Optional[float] = None
        self._raw_file_path: Optional[str] = None
        self._final_file_path: Optional[str] = None
        self._using_libcamera: bool = False
        self._using_picamera2: bool = False
        self._picam2 = None
        self._encoder = None
        self._output = None
        self._status_thread: Optional[threading.Thread] = None
        self._stop_status_updates = False

    def is_recording(self) -> bool:
        with self._lock:
            if self._using_picamera2 and self._picam2:
                return True
            return self._process is not None and self._process.poll() is None

    def status(self) -> dict:
        with self._lock:
            duration = None
            if self._start_time and self.is_recording():
                duration = time.time() - self._start_time

            return {
                "recording": self.is_recording(),
                "started_at": self._start_time,
                "duration": duration,
                "raw_file": self._raw_file_path,
                "file": self._final_file_path or self._raw_file_path,
                "backend": "picamera2" if self._using_picamera2 else ("libcamera" if self._using_libcamera else ("ffmpeg" if HAS_FFMPEG else "opencv")),
            }

    def _status_updater(self):
        """定期廣播錄影狀態"""
        while not self._stop_status_updates and self.is_recording():
            status = self.status()
            broadcast_to_clients('video_status', status)
            time.sleep(1)  # 每秒更新一次狀態

    def start(self, output_basename: Optional[str] = None, duration_seconds: Optional[int] = None) -> str:
        with self._lock:
            if self.is_recording():
                raise RuntimeError("Recording already in progress")

            base_name = output_basename or _timestamped_filename("video", "mp4")
            base_name = os.path.splitext(base_name)[0]
            output_mp4 = os.path.join(current_videos_dir, f"{base_name}.mp4")
            os.makedirs(os.path.dirname(output_mp4), exist_ok=True)

            # 廣播錄影開始
            broadcast_to_clients('video_start', {
                'file': output_mp4,
                'duration_seconds': duration_seconds
            })

            # 優先使用 picamera2
            if HAS_PICAMERA2:
                try:
                    from picamera2 import Picamera2, encoders, outputs
                    import time

                    raw_h264 = os.path.join(current_videos_dir, f"{base_name}.h264")
                    logger.info("picamera2 開始錄影: %s", raw_h264)

                    self._picam2 = Picamera2()
                    video_config = self._picam2.create_video_configuration(main={"size": (DEFAULT_WIDTH, DEFAULT_HEIGHT)})
                    self._picam2.configure(video_config)

                    encoder = encoders.H264Encoder()
                    output = outputs.FileOutput(raw_h264)

                    self._picam2.start_recording(encoder, output)
                    self._encoder = encoder
                    self._output = output
                    self._using_libcamera = False
                    self._using_picamera2 = True
                    self._raw_file_path = raw_h264
                    self._final_file_path = output_mp4 if HAS_FFMPEG else None
                    self._start_time = time.time()

                    if duration_seconds:
                        threading.Thread(target=self._auto_stop_after, args=(duration_seconds,), daemon=True).start()

                    # 開始狀態更新線程
                    self._stop_status_updates = False
                    self._status_thread = threading.Thread(target=self._status_updater, daemon=True)
                    self._status_thread.start()

                    return self._final_file_path or self._raw_file_path or output_mp4

                except Exception as exc:
                    logger.warning("picamera2 錄影失敗，嘗試其他方法: %s", exc)
                    broadcast_to_clients('video_error', {'error': f'picamera2 錄影失敗: {exc}'})

            if HAS_LIBCAMERA:
                raw_h264 = os.path.join(current_videos_dir, f"{base_name}.h264")
                cmd = ["libcamera-vid", "-n", "--framerate", str(DEFAULT_FPS),
                       "--width", str(DEFAULT_WIDTH), "--height", str(DEFAULT_HEIGHT), "-o", raw_h264]
                if duration_seconds:
                    cmd += ["-t", str(duration_seconds * 1000)]
                self._process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._using_libcamera = True
                self._using_picamera2 = False
                self._raw_file_path = raw_h264
                self._final_file_path = output_mp4 if HAS_FFMPEG else None
            elif HAS_FFMPEG:
                cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "v4l2",
                       "-video_size", f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}",
                       "-framerate", str(DEFAULT_FPS), "-i", DEFAULT_DEVICE,
                       "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
                if duration_seconds:
                    cmd += ["-t", str(duration_seconds)]
                cmd += [output_mp4]
                self._process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._using_libcamera = False
                self._using_picamera2 = False
                self._raw_file_path = output_mp4
                self._final_file_path = output_mp4
            else:
                error_msg = "No available backend for video recording"
                broadcast_to_clients('video_error', {'error': error_msg})
                raise RuntimeError(error_msg)

            self._start_time = time.time()
            if duration_seconds and not self._using_picamera2:
                threading.Thread(target=self._auto_stop_after, args=(duration_seconds,), daemon=True).start()

            # 開始狀態更新線程
            self._stop_status_updates = False
            self._status_thread = threading.Thread(target=self._status_updater, daemon=True)
            self._status_thread.start()

            return self._final_file_path or self._raw_file_path or output_mp4

    def _auto_stop_after(self, duration_seconds: int) -> None:
        time.sleep(max(0, duration_seconds))
        try:
            self.stop()
        except Exception:
            pass

    def stop(self) -> str:
        self._stop_status_updates = True  # 停止狀態更新

        with self._lock:
            if not self.is_recording():
                error_msg = "No active recording"
                broadcast_to_clients('video_error', {'error': error_msg})
                raise RuntimeError(error_msg)

            # 廣播錄影停止開始
            broadcast_to_clients('video_stopping', {})

            # 處理 picamera2 錄影
            if self._using_picamera2 and self._picam2:
                try:
                    self._picam2.stop_recording()
                    if self._output:
                        self._output.close()
                    self._picam2.stop()
                    logger.info("✅ picamera2 錄影已停止")
                except Exception as e:
                    logger.warning(f"picamera2 停止錯誤: {e}")
                    try:
                        if self._output and hasattr(self._output, 'close'):
                            self._output.close()
                    except Exception:
                        pass
                finally:
                    self._picam2 = None
                    self._encoder = None
                    self._output = None
                    self._using_picamera2 = False

            # 處理其他錄影方式
            elif self._process:
                for stop_method in [lambda p: p.send_signal(signal.SIGINT),
                                   lambda p: p.terminate(),
                                   lambda p: p.kill()]:
                    try:
                        stop_method(self._process)
                        if self._process.poll() is not None:
                            break
                        time.sleep(0.5)
                    except Exception as e:
                        logger.debug(f"停止進程方法失敗: {e}")
                        continue

        # 等待進程結束
        if self._process:
            try:
                self._process.wait(timeout=5)
            except Exception:
                try:
                    self._process.kill()
                    self._process.wait(timeout=1)
                except Exception as e:
                    logger.error(f"無法終止錄影進程: {e}")

        with self._lock:
            try:
                final_path = self._finalize_file_if_needed()
                broadcast_to_clients('video_stop_success', {'file': final_path})
            except Exception as e:
                error_msg = f"處理錄影文件時出錯: {e}"
                logger.error(error_msg)
                broadcast_to_clients('video_error', {'error': error_msg})
                final_path = self._raw_file_path or self._final_file_path

            self._process = None
            self._start_time = None
            return final_path

    def _finalize_file_if_needed(self) -> str:
        assert self._raw_file_path is not None
        if (self._using_libcamera or self._using_picamera2) and self._raw_file_path.endswith(".h264"):
            if HAS_FFMPEG and self._final_file_path:
                try:
                    # 廣播轉換開始
                    broadcast_to_clients('video_converting', {'from': self._raw_file_path, 'to': self._final_file_path})

                    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-r", str(DEFAULT_FPS),
                           "-i", self._raw_file_path, "-c", "copy", self._final_file_path]
                    logger.info("ffmpeg 轉換 MP4: %s", " ".join(cmd))
                    subprocess.check_call(cmd)
                    try:
                        os.remove(self._raw_file_path)
                        logger.info("刪除原始 H264 檔案: %s", self._raw_file_path)
                    except Exception:
                        pass

                    broadcast_to_clients('video_convert_success', {'file': self._final_file_path})
                    return self._final_file_path
                except Exception as e:
                    error_msg = f"ffmpeg 轉換失敗: {e}，保留 H264 檔案"
                    logger.warning(error_msg)
                    broadcast_to_clients('video_convert_error', {'error': error_msg, 'file': self._raw_file_path})
                    return self._raw_file_path
            else:
                return self._raw_file_path
        else:
            return self._raw_file_path


video_recorder = VideoRecorder()

# Flask 和 SocketIO 設置
app = Flask(__name__)
app.config['SECRET_KEY'] = 'your-secret-key-here'
socketio = SocketIO(app, cors_allowed_origins="*", logger=True, engineio_logger=True)


# WebSocket 事件處理
@socketio.on('connect')
def handle_connect():
    connected_clients.add(request.sid)
    logger.info(f"客戶端已連接: {request.sid}, 總連接數: {len(connected_clients)}")

    # 發送服務器狀態
    emit('server_status', {
        'status': 'connected',
        'backends': {
            'libcamera': HAS_LIBCAMERA,
            'ffmpeg': HAS_FFMPEG,
            'picamera2': HAS_PICAMERA2
        },
        'storage': {
            'usb_mounted': is_usb_mounted(),
            'current_path': current_media_root
        }
    })

    # 發送當前錄影狀態
    emit('video_status', video_recorder.status())


@socketio.on('disconnect')
def handle_disconnect():
    connected_clients.discard(request.sid)
    logger.info(f"客戶端已斷開: {request.sid}, 剩餘連接數: {len(connected_clients)}")


@socketio.on('photo_capture')
def handle_photo_capture(data):
    try:
        filename = data.get('filename') if data else None
        if filename:
            safe_name = sanitize_filename(filename, (".jpg", ".jpeg", ".png"))
            output_path = secure_path_join(current_photos_dir, safe_name)
        else:
            output_path = None

        output_path = capture_photo(output_path)
        emit('photo_success', {'file': output_path})

    except Exception as e:
        error_msg = f"拍照失敗: {str(e)}"
        logger.error(error_msg)
        emit('photo_error', {'error': error_msg})


@socketio.on('video_start')
def handle_video_start(data):
    try:
        if video_recorder.is_recording():
            emit('video_error', {'error': 'Recording already in progress'})
            return

        filename = data.get('filename') if data else None
        duration = data.get('duration') if data else None
        duration_seconds = int(duration) if duration and str(duration).isdigit() else None

        safe_base = os.path.splitext(sanitize_filename(filename, (".mp4", ".h264")))[0] if filename else None
        path = video_recorder.start(output_basename=safe_base, duration_seconds=duration_seconds)

        emit('video_start_success', {'file': path})

    except Exception as e:
        error_msg = f"開始錄影失敗: {str(e)}"
        logger.error(error_msg)
        emit('video_error', {'error': error_msg})


@socketio.on('video_stop')
def handle_video_stop():
    try:
        path = video_recorder.stop()
        emit('video_stop_success', {'file': path})

    except Exception as e:
        error_msg = f"停止錄影失敗: {str(e)}"
        logger.error(error_msg)
        emit('video_error', {'error': error_msg})


@socketio.on('video_status')
def handle_video_status():
    emit('video_status', video_recorder.status())


@socketio.on('storage_status')
def handle_storage_status():
    emit('storage_status', {
        'usb_mounted': is_usb_mounted(),
        'current_path': current_media_root,
        'photos_dir': current_photos_dir,
        'videos_dir': current_videos_dir
    })


# HTTP 路由（用於文件下載）
@app.route('/media/<path:filename>')
def get_media(filename: str):
    try:
        path = secure_path_join(current_media_root, filename)
    except Exception:
        abort(400)
    if not os.path.isfile(path):
        abort(404)
    return send_file(path)


@app.route('/health')
def health():
    return {
        "status": "ok",
        "websocket": True,
        "libcamera": HAS_LIBCAMERA,
        "ffmpeg": HAS_FFMPEG,
        "picamera2": HAS_PICAMERA2
    }


def main() -> None:
    def signal_handler(signum, frame):
        logger.info("收到終止信號，正在清理...")
        cleanup_resources()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        logger.info("🚀 啟動 WebSocket Media Server...")
        init_storage()
        host = os.environ.get("MEDIA_SERVER_HOST", "0.0.0.0")
        port = int(os.environ.get("MEDIA_SERVER_PORT", "8770"))

        logger.info(f"WebSocket 服務器啟動於 ws://{host}:{port}")
        socketio.run(app, host=host, port=port, debug=False)

    except Exception as e:
        logger.error(f"服務啟動失敗: {e}")
    finally:
        cleanup_resources()


if __name__ == "__main__":
    main()