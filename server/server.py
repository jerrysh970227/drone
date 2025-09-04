import asyncio
import websockets
import json
import logging
from pymavlink import mavutil
import RPi.GPIO as GPIO

# 配置日誌
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('server.log')
    ]
)
logger = logging.getLogger(__name__)

# LED 腳位設定
LED_PIN = 17

# 初始化 MAVLink
master = None
def init_mavlink():
    global master
    try:
        master = mavutil.mavlink_connection('/dev/ttyACM0', baud=115200)
        master.wait_heartbeat(timeout=5)
        logger.info("成功連接到 Pixhawk")
        return True
    except Exception as e:
        logger.error(f"無法連接到 Pixhawk: {e}")
        return False

# 設置飛行模式
def set_flight_mode(mode):
    if not master:
        logger.error("無 Pixhawk 連線")
        return
    mode_id = master.mode_mapping().get(mode, -1)
    if mode_id == -1:
        logger.error(f"未知模式: {mode}")
        return
    master.mav.set_mode_send(
        master.target_system,
        mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
        mode_id
    )
    logger.info(f"已設置飛行模式為 {mode}")

# 設置啟動/解除
def set_arm(arm):
    if not master:
        logger.error("無 Pixhawk 連線")
        return
    master.mav.command_long_send(
        master.target_system,
        master.target_component,
        mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
        0,
        1 if arm else 0, 0, 0, 0, 0, 0, 0
    )
    logger.info(f"Pixhawk {'已啟動' if arm else '已解除'}")

# 設置 RC 通道
def set_rc_channels(throttle, yaw, forward, lateral):
    if not master:
        logger.error("無 Pixhawk 連線")
        return
    throttle_pwm = int(1500 + throttle * 500)
    yaw_pwm = int(1500 + yaw * 500)
    pitch_pwm = int(1500 + forward * 500)
    roll_pwm = int(1500 + lateral * 500)
    channels = [roll_pwm, pitch_pwm, throttle_pwm, yaw_pwm, 0, 0, 0, 0]
    master.mav.rc_channels_override_send(
        master.target_system,
        master.target_component,
        *channels
    )
    logger.debug(f"RC 通道: 滾轉={roll_pwm}, 俯仰={pitch_pwm}, 油門={throttle_pwm}, 偏航={yaw_pwm}")

# 伺服馬達控制類（使用 RPi.GPIO PWM）
class CameraServo:
    def __init__(self, pin=18):
        self.pin = pin
        self.current_angle = 0.0  # 追蹤當前角度
        self.pwm = None
        try:
            GPIO.setmode(GPIO.BCM)
            GPIO.setup(self.pin, GPIO.OUT)
            self.pwm = GPIO.PWM(self.pin, 50)  # 50Hz 頻率
            self.pwm.start(0)
            logger.info(f"伺服馬達初始化於 GPIO {self.pin}")
        except Exception as e:
            logger.error(f"伺服馬達初始化失敗: {e}")
            self.pwm = None

    def angle_to_duty_cycle(self, angle):
        """將角度轉換為佔空比（0-180度 -> 2.5-12.5%）"""
        # 將 -45~90 度映射到 0~180 度
        mapped_angle = angle + 45  # -45~90 -> 0~135
        mapped_angle = (mapped_angle / 135) * 180  # 0~135 -> 0~180
        duty_cycle = 2.5 + (mapped_angle / 180.0) * 10.0
        return duty_cycle

    def set_angle(self, angle):
        if not self.pwm:
            logger.error("無伺服馬達連線")
            # 仍然更新追蹤角度
            self.current_angle = max(-45, min(90, angle))
            return False
        try:
            angle = max(-45, min(90, angle))
            duty_cycle = self.angle_to_duty_cycle(angle)
            self.pwm.ChangeDutyCycle(duty_cycle)
            old_angle = self.current_angle
            self.current_angle = angle
            logger.info(f"設置伺服角度: {old_angle:.1f}° -> {angle:.1f}°, 佔空比: {duty_cycle:.2f}%")
            return True
        except Exception as e:
            logger.error(f"設置伺服角度失敗: {e}")
            # 仍然更新追蹤角度
            self.current_angle = max(-45, min(90, angle))
            return False

    def get_angle(self):
        # 直接返回追蹤的角度，因為 GPIO PWM 無法讀取當前值
        return round(self.current_angle, 2)

    def cleanup(self):
        if self.pwm:
            self.pwm.stop()
            GPIO.cleanup()
            logger.info("伺服馬達已清理")

# LED 設置
def setup_led():
    GPIO.setmode(GPIO.BCM)
    GPIO.setup(LED_PIN, GPIO.OUT)

def set_led(state):
    GPIO.output(LED_PIN, GPIO.HIGH if state else GPIO.LOW)
    logger.info(f"LED {'開啟' if state else '關閉'}")

def toggle_led():
    current_state = GPIO.input(LED_PIN)
    set_led(not current_state)
    return not current_state

# 伺服馬達設置
servo = None
def setup_servo():
    global servo
    servo = CameraServo(pin=18)  # 使用 GPIO 18

async def initialize_servo():
    if servo:
        servo.set_angle(0)
        logger.info("伺服馬達初始化至 0 度")

async def set_servo_angle(angle):
    if servo:
        success = servo.set_angle(angle)
        if success:
            logger.info(f"伺服馬達設置至 {angle} 度")
        else:
            logger.warning(f"伺服馬達設置失敗，但已追蹤角度 {angle} 度")
        return success
    return False

# 獲取 GPS 數據
async def get_gps_data():
    if not master:
        logger.warning("無 Pixhawk 連線，使用模擬 GPS 數據")
        # 返回台北市的模擬座標
        import time
        base_lat = 25.0330
        base_lon = 121.5654
        # 添加小幅度隨機移動模擬無人機移動
        import random
        offset_lat = random.uniform(-0.001, 0.001)
        offset_lon = random.uniform(-0.001, 0.001)
        return {
            'lat': base_lat + offset_lat,
            'lon': base_lon + offset_lon
        }
    try:
        msg = master.recv_match(type='GLOBAL_POSITION_INT', blocking=True, timeout=1)
        if msg:
            lat = msg.lat / 1e7
            lon = msg.lon / 1e7
            logger.debug(f"GPS 數據: 緯度={lat}, 經度={lon}")
            return {'lat': lat, 'lon': lon}
        else:
            logger.warning("無 GPS 數據")
            return None
    except Exception as e:
        logger.error(f"獲取 GPS 數據失敗: {e}")
        return None

# 定期發送 GPS 數據
async def send_gps_periodically(websocket):
    while True:
        try:
            gps_data = await get_gps_data()
            if gps_data:
                await websocket.send(json.dumps({'type': 'gps', 'data': gps_data}))
            await asyncio.sleep(1)  # 每秒發送一次
        except websockets.exceptions.ConnectionClosed:
            logger.info("GPS 發送任務因客戶端斷線停止")
            break
        except Exception as e:
            logger.error(f"GPS 發送錯誤: {e}")
            await asyncio.sleep(1)

async def handle_connection(websocket):
    logger.info(f"客戶端已連線")
    gps_task = asyncio.create_task(send_gps_periodically(websocket))
    try:
        async for message in websocket:
            logger.debug(f"收到消息: {message}")
            try:
                data = json.loads(message)
                response = {"status": "received"}
                if data.get("type") == "control":
                    throttle = float(data.get('throttle', 0))
                    yaw = float(data.get('yaw', 0))
                    forward = float(data.get('forward', 0))
                    lateral = float(data.get('lateral', 0))
                    set_rc_channels(throttle, yaw, forward, lateral)
                    response = {"status": "ok"}
                elif data.get("type") == "flight_mode":
                    mode = data.get('mode')
                    set_flight_mode(mode)
                    response = {"status": "ok"}
                elif data.get("type") == "arm":
                    arm = data.get('arm', False)
                    set_arm(arm)
                    response = {"status": "ok"}
                elif data.get("type") == "led_control":
                    action = data.get('action')
                    if action == "LED_ON":
                        set_led(True)
                        response = {"status": "ok", "led": True}
                    elif action == "LED_OFF":
                        set_led(False)
                        response = {"status": "ok", "led": False}
                    elif action == "LED_TOGGLE":
                        new_state = toggle_led()
                        response = {"status": "ok", "led": new_state}
                elif data.get("type") == "servo_control":
                    angle = float(data.get('angle', 0))
                    logger.info(f"伺服控制: 角度={angle}")
                    if not (-45 <= angle <= 90):
                        current_angle = servo.get_angle() if servo else 0
                        response = {"status": "error", "message": f"角度 {angle} 超出範圍 [-45, 90]", "type": "angle_update", "angle": current_angle}
                    else:
                        await set_servo_angle(angle)
                        # Get the actual angle after setting it
                        actual_angle = servo.get_angle() if servo else angle
                        logger.debug(f"設定角度: {angle}, 實際角度: {actual_angle}")
                        response = {"status": "ok", "type": "angle_update", "angle": actual_angle}
                elif data.get("type") == "request_angle":
                    current_angle = servo.get_angle() if servo else 0
                    logger.debug(f"獲取當前伺服角度: {current_angle}")
                    response = {"status": "ok", "type": "angle_update", "angle": current_angle}
                await websocket.send(json.dumps(response))
            except json.JSONDecodeError as e:
                logger.error(f"無效 JSON: {e}")
                await websocket.send(json.dumps({"status": "error", "message": f"無效 JSON: {e}"}))
            except ValueError as e:
                logger.error(f"數據格式錯誤: {e}")
                await websocket.send(json.dumps({"status": "error", "message": f"數據格式錯誤: {e}"}))
    except websockets.exceptions.ConnectionClosed as e:
        logger.info(f"客戶端斷線: 代碼={e.code}, 原因={e.reason}")
    except Exception as e:
        logger.error(f"WebSocket 錯誤: {e}")
    finally:
        gps_task.cancel()

async def main():
    if not init_mavlink():
        logger.error("因 Pixhawk 連線失敗退出")
        return
    setup_led()
    setup_servo()
    await initialize_servo()
    
    # Create server with proper handler
    async def connection_handler(websocket, path=None):
        await handle_connection(websocket)
    
    server = await websockets.serve(
        connection_handler,
        "0.0.0.0", 8766,
        ping_interval=20,
        ping_timeout=15
    )
    logger.info("WebSocket 伺服器啟動於 ws://0.0.0.0:8766")
    
    try:
        await server.wait_closed()
    except KeyboardInterrupt:
        logger.info("伺服器手動關閉")
    finally:
        if servo:
            servo.cleanup()
        logger.info("程式清理完成")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("伺服器手動關閉")
        if servo:
            servo.cleanup()