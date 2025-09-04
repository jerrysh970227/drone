import os
import sys
import time
import signal
import logging
import threading
import subprocess
from datetime import datetime
from typing import Optional, Tuple

from flask import Flask, jsonify, request, send_file, abort



# 日誌設定（寫到 stdout 與檔案）
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout), logging.FileHandler("media_server.log")],
)
logger = logging.getLogger(__name__)


# 基本設定與媒體輸出路徑
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MEDIA_ROOT = os.path.join(BASE_DIR, "media")
PHOTOS_DIR = os.path.join(MEDIA_ROOT, "photos")
VIDEOS_DIR = os.path.join(MEDIA_ROOT, "videos")

DEFAULT_DEVICE = os.environ.get("VIDEO_DEVICE", "/dev/video0")
DEFAULT_WIDTH = int(os.environ.get("VIDEO_WIDTH", "1280"))
DEFAULT_HEIGHT = int(os.environ.get("VIDEO_HEIGHT", "720"))
DEFAULT_FPS = int(os.environ.get("VIDEO_FPS", "30"))

os.makedirs(PHOTOS_DIR, exist_ok=True)
os.makedirs(VIDEOS_DIR, exist_ok=True)



# 工具方法：偵測可用後端、產生安全檔名與路徑
def which(cmd: str) -> Optional[str]:
    """回傳指令的絕對路徑，若不存在則回傳 None。使用 shutil.which 提升可攜性。"""
    try:
        import shutil

        return shutil.which(cmd)
    except Exception:
        return None


def sanitize_filename(name: str, allowed_exts: Tuple[str, ...]) -> str:
    """簡單檔名過濾：僅允許字母、數字、底線、減號與點，且副檔名需在允許清單中。
    若副檔名不在清單中，會自動替換為第一個允許的副檔名。
    """
    import re

    safe = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    base, ext = os.path.splitext(safe)
    if not ext:
        # 若無副檔名，使用第一個允許的副檔名
        return base + allowed_exts[0]
    if ext.lower() not in allowed_exts:
        return base + allowed_exts[0]
    return base + ext


def secure_path_join(root: str, filename: str) -> str:
    """避免路徑穿越：將檔名與資料夾 join 後，確認仍在 root 內。"""
    path = os.path.abspath(os.path.join(root, filename))
    if not path.startswith(os.path.abspath(root) + os.sep):
        raise ValueError("非法檔名或路徑")
    return path


def detect_backends() -> Tuple[bool, bool]:
    has_libcamera = bool(which("libcamera-still")) and bool(which("libcamera-vid"))
    has_ffmpeg = bool(which("ffmpeg"))
    return has_libcamera, has_ffmpeg


HAS_LIBCAMERA, HAS_FFMPEG = detect_backends()



# 拍照實作：優先 libcamera → 其次 ffmpeg → 最後 OpenCV
def _timestamped_filename(prefix: str, ext: str) -> str:
    return f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.{ext}"


def capture_photo(output_path: Optional[str] = None) -> str:
    """拍一張照片並回傳檔案儲存路徑。"""
    if output_path is None:
        output_path = os.path.join(PHOTOS_DIR, _timestamped_filename("photo", "jpg"))

    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    if HAS_LIBCAMERA:
        cmd = [
            "libcamera-still",
            "-n",
            "-o",
            output_path,
            "--width",
            str(DEFAULT_WIDTH),
            "--height",
            str(DEFAULT_HEIGHT),
        ]
        logger.info("libcamera 拍照: %s", " ".join(map(str, cmd)))
        subprocess.check_call(cmd)
        return output_path

    if HAS_FFMPEG:
        cmd = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "v4l2",
            "-input_format",
            "mjpeg",
            "-video_size",
            f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}",
            "-i",
            DEFAULT_DEVICE,
            "-frames:v",
            "1",
            output_path,
        ]
        logger.info("ffmpeg 拍照: %s", " ".join(map(str, cmd)))
        subprocess.check_call(cmd)
        return output_path

    # Fallback to OpenCV if installed
    try:
        import cv2  # type: ignore

        logger.info("OpenCV 拍照")
        cap = cv2.VideoCapture(0)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, DEFAULT_WIDTH)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, DEFAULT_HEIGHT)
        if not cap.isOpened():
            raise RuntimeError("Unable to open camera device 0")
        # Warm up
        for _ in range(3):
            cap.read()
        ret, frame = cap.read()
        cap.release()
        if not ret:
            raise RuntimeError("Failed to capture frame from camera")
        cv2.imwrite(output_path, frame)
        return output_path
    except Exception as exc:
        logger.exception("OpenCV 拍照失敗")
        raise RuntimeError("沒有可用的拍照後端") from exc


class VideoRecorder:
    """錄影管理：啟動、停止、狀態查詢與檔案後處理。"""
    def __init__(self) -> None:
        self._process: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._start_time: Optional[float] = None
        self._raw_file_path: Optional[str] = None
        self._final_file_path: Optional[str] = None
        self._using_libcamera: bool = False

    def is_recording(self) -> bool:
        with self._lock:
            return self._process is not None and self._process.poll() is None

    def status(self) -> dict:
        with self._lock:
            return {
                "recording": self.is_recording(),
                "started_at": self._start_time,
                "raw_file": self._raw_file_path,
                "file": self._final_file_path or self._raw_file_path,
                "backend": "libcamera" if self._using_libcamera else ("ffmpeg" if HAS_FFMPEG else "opencv"),
            }

    def start(self, output_basename: Optional[str] = None, duration_seconds: Optional[int] = None) -> str:
        with self._lock:
            if self.is_recording():
                raise RuntimeError("Recording already in progress")

            base_name = output_basename or _timestamped_filename("video", "mp4")
            base_name = os.path.splitext(base_name)[0]
            output_mp4 = os.path.join(VIDEOS_DIR, f"{base_name}.mp4")
            os.makedirs(os.path.dirname(output_mp4), exist_ok=True)

            if HAS_LIBCAMERA:
                # libcamera-vid writes H.264 elementary stream; we'll remux to mp4 on stop if ffmpeg exists
                raw_h264 = os.path.join(VIDEOS_DIR, f"{base_name}.h264")
                cmd = [
                    "libcamera-vid",
                    "-n",
                    "--framerate",
                    str(DEFAULT_FPS),
                    "--width",
                    str(DEFAULT_WIDTH),
                    "--height",
                    str(DEFAULT_HEIGHT),
                    "-o",
                    raw_h264,
                ]
                if duration_seconds is not None and duration_seconds > 0:
                    cmd += ["-t", str(duration_seconds * 1000)]

                logger.info("libcamera 開始錄影: %s", " ".join(map(str, cmd)))
                self._process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._using_libcamera = True
                self._raw_file_path = raw_h264
                self._final_file_path = output_mp4 if HAS_FFMPEG else None
            elif HAS_FFMPEG:
                # 注意：-t 位置需在輸出檔案之前，否則參數可能無效
                cmd = [
                    "ffmpeg",
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-f",
                    "v4l2",
                    "-input_format",
                    "mjpeg",
                    "-video_size",
                    f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}",
                    "-framerate",
                    str(DEFAULT_FPS),
                    "-i",
                    DEFAULT_DEVICE,
                    "-c:v",
                    "libx264",
                    "-preset",
                    "ultrafast",
                    "-pix_fmt",
                    "yuv420p",
                ]
                if duration_seconds is not None and duration_seconds > 0:
                    cmd += ["-t", str(duration_seconds)]
                cmd += [output_mp4]

                logger.info("ffmpeg 開始錄影: %s", " ".join(map(str, cmd)))
                self._process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._using_libcamera = False
                self._raw_file_path = output_mp4
                self._final_file_path = output_mp4
            else:
                raise RuntimeError("No available backend for video recording (libcamera/ffmpeg not found)")

            self._start_time = time.time()

            if duration_seconds is not None and duration_seconds > 0:
                # Fire a watcher to stop on timeout (only for libcamera which may also stop by itself)
                threading.Thread(target=self._auto_stop_after, args=(duration_seconds,), daemon=True).start()

            return self._final_file_path or self._raw_file_path or output_mp4

    def _auto_stop_after(self, duration_seconds: int) -> None:
        time.sleep(max(0, duration_seconds))
        try:
            self.stop()
        except Exception:
            pass

    def stop(self) -> str:
        with self._lock:
            if not self.is_recording():
                raise RuntimeError("No active recording")

            assert self._process is not None
            # 嘗試優雅停止，若失敗則強制結束
            try:
                if hasattr(signal, "SIGINT"):
                    self._process.send_signal(signal.SIGINT)
                else:
                    self._process.terminate()
            except Exception:
                try:
                    self._process.terminate()
                except Exception:
                    pass

        # 在鎖外等待，避免阻塞其他狀態查詢
        try:
            self._process.wait(timeout=10)
        except Exception:
            try:
                self._process.kill()
            except Exception:
                pass

        with self._lock:
            final_path = self._finalize_file_if_needed()
            self._process = None
            self._start_time = None
            return final_path

    def _finalize_file_if_needed(self) -> str:
        """若 libcamera 產生 .h264，且存在 ffmpeg，則 remux 成 .mp4。"""
        assert self._raw_file_path is not None
        if self._using_libcamera and self._raw_file_path.endswith(".h264"):
            if HAS_FFMPEG:
                assert self._final_file_path is not None
                cmd = [
                    "ffmpeg",
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-r",
                    str(DEFAULT_FPS),
                    "-i",
                    self._raw_file_path,
                    "-c",
                    "copy",
                    self._final_file_path,
                ]
                logger.info("ffmpeg remux 成 MP4: %s", " ".join(map(str, cmd)))
                subprocess.check_call(cmd)
                try:
                    os.remove(self._raw_file_path)
                except Exception:
                    pass
                return self._final_file_path
            else:
                # Return raw .h264 if ffmpeg not available
                return self._raw_file_path
        else:
            # ffmpeg path already produced final mp4
            return self._raw_file_path


video_recorder = VideoRecorder()



# HTTP API（Flask）
app = Flask(__name__)


@app.get("/health")
def health() -> tuple:
    return jsonify(
        {
            "status": "ok",
            "libcamera": HAS_LIBCAMERA,
            "ffmpeg": HAS_FFMPEG,
        }
    ), 200


@app.post("/photo")
def api_photo() -> tuple:
    # 可選參數：filename（輸出檔名，將被過濾）；未提供則以時間戳產生
    filename = request.args.get("filename")
    try:
        if filename:
            safe_name = sanitize_filename(filename, (".jpg", ".jpeg", ".png"))
            output_path = secure_path_join(PHOTOS_DIR, safe_name)
        else:
            output_path = None
        output_path = capture_photo(output_path)
        return jsonify({"status": "ok", "file": output_path}), 200
    except Exception as exc:
        logger.exception("拍照失敗")
        return jsonify({"status": "error", "message": str(exc)}), 500


@app.post("/video/start")
def api_video_start() -> tuple:
    if video_recorder.is_recording():
        return jsonify({"status": "error", "message": "Recording already in progress"}), 400
    # 可選參數：filename（輸出檔名，將被過濾，不需副檔名或將自動套用 .mp4）
    filename = request.args.get("filename")
    duration = request.args.get("duration")
    duration_seconds = int(duration) if duration and duration.isdigit() else None
    try:
        if filename:
            # 僅保留基底名（不含副檔名），並確保輸出目錄合理
            safe_name = sanitize_filename(filename, (".mp4", ".h264"))
            safe_base = os.path.splitext(safe_name)[0]
        else:
            safe_base = None
        path = video_recorder.start(output_basename=safe_base, duration_seconds=duration_seconds)
        return jsonify({"status": "ok", "file": path}), 200
    except Exception as exc:
        logger.exception("開始錄影失敗")
        return jsonify({"status": "error", "message": str(exc)}), 500


@app.post("/video/stop")
def api_video_stop() -> tuple:
    try:
        path = video_recorder.stop()
        return jsonify({"status": "ok", "file": path}), 200
    except Exception as exc:
        return jsonify({"status": "error", "message": str(exc)}), 400


@app.get("/video/status")
def api_video_status() -> tuple:
    return jsonify({"status": "ok", **video_recorder.status()}), 200


@app.get("/media/photos/<path:filename>")
def get_photo(filename: str):
    # 檔案下載前進行路徑檢查，避免 ../ 路徑穿越
    try:
        path = secure_path_join(PHOTOS_DIR, filename)
    except Exception:
        abort(400)
    if not os.path.isfile(path):
        abort(404)
    return send_file(path)


@app.get("/media/videos/<path:filename>")
def get_video(filename: str):
    # 檔案下載前進行路徑檢查，避免 ../ 路徑穿越
    try:
        path = secure_path_join(VIDEOS_DIR, filename)
    except Exception:
        abort(400)
    if not os.path.isfile(path):
        abort(404)
    return send_file(path)


def main() -> None:
    host = os.environ.get("MEDIA_SERVER_HOST", "0.0.0.0")
    port = int(os.environ.get("MEDIA_SERVER_PORT", "8770"))
    logger.info(f"Media server starting on http://{host}:{port}")
    app.run(host=host, port=port, debug=False, threaded=True)


if __name__ == "__main__":
    main()


