# 嘿我忘記儲存這個server

import cv2
import socket
import threading
import logging
import time
import signal
import sys
import numpy as np
import subprocess
import os
import fcntl
import mediapipe as mp
import asyncio
import websockets
import json
from datetime import datetime
from typing import Optional

# 設置日誌
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('stream_server.log')
    ]
)
logger = logging.getLogger(__name__)

# 配置
HOST = '0.0.0.0'
PORT = 8000
WS_PORT = 8001  # WebSocket 通訊埠

# 手勢辨識配置
GESTURE_COOLDOWN = 3  # 手勢觸發冷卻時間（秒）
PHOTOS_DIR = os.path.join(os.path.dirname(__file__), "media", "photos")
os.makedirs(PHOTOS_DIR, exist_ok=True)

# 非阻塞設定
def set_nonblocking(fd):
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

class GestureRecognizer:
    """手勢辨識類別，負責偏測 V 字手勢和窪拇指"""
    def __init__(self):
        self.enabled = False
        self.last_photo_time = 0
        self.hands = None
        self.mp_hands = mp.solutions.hands
        self.mp_draw = mp.solutions.drawing_utils
        self.setup_hands()
        
    def setup_hands(self):
        """Initialize MediaPipe hands detection"""
        self.hands = self.mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=1,
            min_detection_confidence=0.3,
            min_tracking_confidence=0.5
        )
        logger.info("手勢辨識模組初始化完成")
    
    def is_v_sign(self, hand_landmarks):
        """偵測 V 字手勢"""
        return (hand_landmarks.landmark[8].y < hand_landmarks.landmark[6].y and
                hand_landmarks.landmark[12].y < hand_landmarks.landmark[10].y and
                hand_landmarks.landmark[16].y > hand_landmarks.landmark[14].y and
                hand_landmarks.landmark[20].y > hand_landmarks.landmark[18].y)
    
    def is_thumbs_up(self, hand_landmarks):
        """偵測窪拇指手勢"""
        return (hand_landmarks.landmark[4].y < hand_landmarks.landmark[3].y and
                hand_landmarks.landmark[8].y > hand_landmarks.landmark[6].y and
                hand_landmarks.landmark[12].y > hand_landmarks.landmark[10].y and
                hand_landmarks.landmark[16].y > hand_landmarks.landmark[14].y and
                hand_landmarks.landmark[20].y > hand_landmarks.landmark[18].y)
    
    def process_frame(self, frame):
        """處理影像幀並偵測手勢"""
        if not self.enabled:
            return frame, None
            
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        results = self.hands.process(frame_rgb)
        
        gesture_detected = None
        if results.multi_hand_landmarks:
            for hand_landmarks in results.multi_hand_landmarks:
                # 繪製手部標記
                self.mp_draw.draw_landmarks(
                    frame, hand_landmarks, self.mp_hands.HAND_CONNECTIONS
                )
                
                # 偵測手勢並檢查冷卻時間
                current_time = time.time()
                if current_time - self.last_photo_time > GESTURE_COOLDOWN:
                    if self.is_v_sign(hand_landmarks):
                        gesture_detected = "v_sign"
                        self.last_photo_time = current_time
                    elif self.is_thumbs_up(hand_landmarks):
                        gesture_detected = "thumbs_up"
                        self.last_photo_time = current_time
        
        return frame, gesture_detected
    
    def capture_gesture_photo(self, frame, gesture_type):
        """保存手勢觸發的照片"""
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = f'gesture_{gesture_type}_{timestamp}.jpg'
        filepath = os.path.join(PHOTOS_DIR, filename)
        
        # 在照片上標示手勢類型
        cv2.putText(frame, f'Gesture: {gesture_type}', (10, 30), 
                   cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)
        
        cv2.imwrite(filepath, frame)
        logger.info(f"手勢拍照成功：{gesture_type} -> {filepath}")
        return filepath

def start_pipeline():
    rpicam_command = [
        'rpicam-vid',
        '-t', '0',
        '--width', '640',  # 提高分辨率
        '--height', '480',
        '--framerate', '15',  # 提高幀率
        '--codec', 'yuv420',
        '--profile', 'baseline',
        '--nopreview',  # 關閉預覽以提高性能
        '--timeout', '0',
        '--inline',  # 啟用內聯模式減少延遲
        '-o', '-'
    ]

    rpicam_proc = subprocess.Popen(rpicam_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    ffmpeg_command = [
        'ffmpeg',
        '-f', 'rawvideo',
        '-pixel_format', 'yuv420p',
        '-video_size', '640x480',  # 匹配新的分辨率
        '-framerate', '15',  # 匹配新的幀率
        '-i', '-',
        '-f', 'mjpeg',
        '-q:v', '5',  # 提高畫質（範圍1-31，數字越小質量越好）
        '-preset', 'ultrafast',  # 使用最快的編碼速度
        '-tune', 'zerolatency',  # 優化低延遲
        '-an',
        'pipe:1'
    ]

    ffmpeg_proc = subprocess.Popen(
        ffmpeg_command,
        stdin=rpicam_proc.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=10*1024*1024  # 增加緩衝區大小
    )

    set_nonblocking(ffmpeg_proc.stdout.fileno())

    # 記錄 FFmpeg 和 rpicam-vid 錯誤
    def log_stderr(proc, name):
        for line in iter(proc.stderr.readline, b''):
            print(f"{name} stderr: {line.decode().strip()}")
    threading.Thread(target=log_stderr, args=(rpicam_proc, 'rpicam-vid'), daemon=True).start()
    threading.Thread(target=log_stderr, args=(ffmpeg_proc, 'FFmpeg'), daemon=True).start()

    return rpicam_proc, ffmpeg_proc

def video_streamer(conn, ffmpeg_proc, addr, gesture_recognizer):
    try:
        # 設置 TCP 選項以優化傳輸
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)  # 增加發送緩衝區

        frame_buffer = b''
        
        while True:
            try:
                data = ffmpeg_proc.stdout.read(8192)  # 增加讀取緩衝區大小
                if not data:
                    time.sleep(0.005)  # 減少等待時間
                    continue
                    
                # 如果啟用手勢辨識，處理影像庀
                if gesture_recognizer.enabled:
                    frame_buffer += data
                    
                    # 簡單的 JPEG 庀分離邏輯（尋找 JPEG 標記）
                    start_marker = b'\xff\xd8'  # JPEG 開始標記
                    end_marker = b'\xff\xd9'    # JPEG 結束標記
                    
                    start_idx = frame_buffer.find(start_marker)
                    if start_idx != -1:
                        end_idx = frame_buffer.find(end_marker, start_idx)
                        if end_idx != -1:
                            # 提取完整的 JPEG 庀
                            jpeg_frame = frame_buffer[start_idx:end_idx + 2]
                            frame_buffer = frame_buffer[end_idx + 2:]
                            
                            # 解碼并處理手勢辨識
                            try:
                                frame_array = np.frombuffer(jpeg_frame, dtype=np.uint8)
                                frame = cv2.imdecode(frame_array, cv2.IMREAD_COLOR)
                                
                                if frame is not None:
                                    processed_frame, gesture = gesture_recognizer.process_frame(frame)
                                    
                                    if gesture:
                                        # 保存手勢照片
                                        gesture_recognizer.capture_gesture_photo(processed_frame, gesture)
                                        
                                        # 可以在這裡發送 WebSocket 通知給主控制器
                                        logger.info(f"偵測到手勢: {gesture}，已觸發拍照")
                                    
                                    # 重新編碼處理後的庀
                                    _, encoded_frame = cv2.imencode('.jpg', processed_frame, 
                                                                   [cv2.IMWRITE_JPEG_QUALITY, 85])
                                    data = encoded_frame.tobytes()
                            except Exception as e:
                                logger.error(f"手勢辨識處理錯誤: {e}")
                                # 使用原始數據
                                pass
                
                conn.sendall(data)
                print(f"Sent {len(data)} bytes to {addr}")
            except (BlockingIOError, BrokenPipeError, ConnectionResetError):
                break
    except Exception as e:
        print(f"Streaming error for {addr}: {e}")
    finally:
        conn.close()
        print(f"Client {addr} disconnected")

# 全域手勢辨識器
gesture_recognizer = GestureRecognizer()

# WebSocket 處理器
async def handle_websocket(websocket, path):
    """處理 WebSocket 連接，接收手勢辨識控制指令"""
    logger.info(f"WebSocket client connected: {websocket.remote_address}")
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                command = data.get('command')
                
                if command == 'enable_gesture':
                    gesture_recognizer.enabled = True
                    logger.info("手勢辨識已啟用")
                    await websocket.send(json.dumps({"status": "success", "message": "手勢辨識已啟用"}))
                    
                elif command == 'disable_gesture':
                    gesture_recognizer.enabled = False
                    logger.info("手勢辨識已停用")
                    await websocket.send(json.dumps({"status": "success", "message": "手勢辨識已停用"}))
                    
                elif command == 'status':
                    await websocket.send(json.dumps({
                        "status": "success", 
                        "gesture_enabled": gesture_recognizer.enabled
                    }))
                    
            except json.JSONDecodeError:
                await websocket.send(json.dumps({"status": "error", "message": "Invalid JSON"}))
                
    except websockets.exceptions.ConnectionClosed:
        logger.info(f"WebSocket client disconnected: {websocket.remote_address}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")

def start_websocket_server():
    """啟動 WebSocket 服務器"""
    return websockets.serve(handle_websocket, HOST, WS_PORT)

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(5)
    print(f"Streaming server started on {HOST}:{PORT}")
    print(f"WebSocket server will start on {HOST}:{WS_PORT}")

    rpicam_proc, ffmpeg_proc = start_pipeline()
    
    # 啟動 WebSocket 服務器
    def run_websocket():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        start_server = start_websocket_server()
        loop.run_until_complete(start_server)
        loop.run_forever()
    
    ws_thread = threading.Thread(target=run_websocket, daemon=True)
    ws_thread.start()
    print(f"WebSocket server started on {HOST}:{WS_PORT}")

    try:
        while True:
            print("Waiting for connection...")
            try:
                conn, addr = server.accept()
                print(f"Client connected from {addr}")
                stream_thread = threading.Thread(target=video_streamer, args=(conn, ffmpeg_proc, addr, gesture_recognizer))
                stream_thread.start()
            except Exception as e:
                print(f"Server error: {e}")
    finally:
        ffmpeg_proc.kill()
        rpicam_proc.kill()
        ffmpeg_proc.wait()
        rpicam_proc.wait()

if __name__ == '__main__':
    main() 