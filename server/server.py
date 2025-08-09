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

# 伺服馬達控制類（與 C# 一致）
class CameraServo:
    def __init__(self, chip=0, channel=0, frequency=50, initial_percentage=0.065):
        self.chip = chip
        self.channel = channel
        self.frequency = frequency
        self.duty_cycle = initial_percentage
        self.pwm = None
        self.setup()

    def setup(self):
        try:
            GPIO.setmode(GPIO.BCM)
            self.pin = 18  # 假設使用 GPIO 18
            GPIO.setup(self.pin, GPIO.OUT)
            self.pwm = GPIO.PWM(self.pin, self.frequency)
            self.pwm.start(self.duty_cycle * 100)
            logger.info(f"伺服馬達初始化成功 - Chip: {self.chip}, Channel: {self.channel}, 頻率: {self.frequency}Hz")
        except Exception as e:
            logger.error(f"伺服馬達初始化失敗: {e}")
            self.pwm = None

    def start(self):
        if self.pwm:
            self.pwm.start(self.duty_cycle * 100)
            logger.info("伺服馬達已啟動")

    def adjust(self, movement):
        if self.pwm is None:
            logger.error("伺服馬達未初始化")
            return
        self.duty_cycle = max(0.025, min(0.105, self.duty_cycle + movement * 0.0005))
        self.pwm.ChangeDutyCycle(self.duty_cycle * 100)
        logger.debug(f"調整伺服馬達 - 移動: {movement:.3f}, 占空比: {self.duty_cycle:.3f}")

    def get_angle(self):
        return 135 * (self.duty_cycle - 0.025) / 0.08 - 45

    def set_angle(self, target_angle):
        if self.pwm is None:
            logger.error("伺服馬達未初始化")
            return
        # 限制角度範圍：-45° 到 90°
        target_angle = max(-45, min(90, target_angle))
        self.duty_cycle = (target_angle + 45) * 0.08 / 135 + 0.025
        self.duty_cycle = max(0.025, min(0.105, self.duty_cycle))
        self.pwm.ChangeDutyCycle(self.duty_cycle * 100)
        logger.info(f"設置伺服角度: {target_angle:.1f}°, 占空比: {self.duty_cycle:.3f}")

    def stop(self):
        if self.pwm:
            self.pwm.stop()
            logger.info("伺服馬達已停止")

    def cleanup(self):
        if self.pwm:
            self.pwm.stop()
        GPIO.cleanup()
        logger.info("伺服馬達資源已清理")

# 全局伺服馬達實例
servo = None

# LED 控制相關
def setup_led():
    try:
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(LED_PIN, GPIO.OUT, initial=GPIO.LOW)
        logger.info(f"LED 已初始化於 GPIO{LED_PIN}")
    except Exception as e:
        logger.error(f"LED 初始化失敗: {e}")

def set_led(state: bool):
    try:
        GPIO.output(LED_PIN, GPIO.HIGH if state else GPIO.LOW)
        logger.info(f"LED 狀態: {'ON' if state else 'OFF'}")
    except Exception as e:
        logger.error(f"設置 LED 失敗: {e}")

def toggle_led() -> bool:
    try:
        current = GPIO.input(LED_PIN)
        new_state = GPIO.LOW if current == GPIO.HIGH else GPIO.HIGH
        GPIO.output(LED_PIN, new_state)
        logger.info(f"LED 已切換為: {'ON' if new_state == GPIO.HIGH else 'OFF'}")
        return new_state == GPIO.HIGH
    except Exception as e:
        logger.error(f"切換 LED 失敗: {e}")
        return False

def get_led_state() -> bool:
    try:
        return GPIO.input(LED_PIN) == GPIO.HIGH
    except Exception:
        return False

def setup_servo():
    global servo
    if servo is None:
        servo = CameraServo(chip=0, channel=0, frequency=50, initial_percentage=0.065)
    return servo

async def set_servo_angle(target_angle):
    global servo
    if servo is None:
        servo = setup_servo()
    servo.set_angle(target_angle)
    return servo.get_angle()

async def initialize_servo():
    global servo
    if servo is None:
        servo = setup_servo()

    logger.info("開始執行伺服馬達初始化序列")
    await set_servo_angle(0)   # 中間位置
    await asyncio.sleep(0.5)
    await set_servo_angle(-45) # 最左
    await asyncio.sleep(0.5)
    await set_servo_angle(0)   # 中間位置
    await asyncio.sleep(0.5)
    await set_servo_angle(90)  # 最右
    await asyncio.sleep(0.5)
    await set_servo_angle(0)   # 回到中間位置
    await asyncio.sleep(0.5)
    logger.info("伺服馬達初始化序列完成")

async def handle_connection(websocket, path=None):
    logger.info(f"新的客戶端連線: {path}")
    try:
        async for message in websocket:
            logger.info(f"收到消息: {message}")
            try:
                data = json.loads(message)
                response = {"status": "received", "angle": servo.get_angle() if servo else 0}
                if data.get("type") == "control":
                    throttle = float(data.get('throttle', 0))
                    yaw = float(data.get('yaw', 0))
                    forward = float(data.get('forward', 0))
                    lateral = float(data.get('lateral', 0))
                    logger.info(f"控制指令: 油門={throttle}, 偏航={yaw}, 前進={forward}, 橫移={lateral}")
                    set_rc_channels(throttle, yaw, forward, lateral)
                elif data.get("type") == "command":
                    action = data.get('action')
                    logger.info(f"命令: {action}")
                    if action == "ARM":
                        set_arm(True)
                        set_flight_mode("STABILIZE")
                    elif action == "DISARM":
                        set_arm(False)
                    elif action == "LED_ON":
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
                        response = {"status": "error", "message": f"角度 {angle} 超出範圍 [-45, 90]", "angle": current_angle}
                    else:
                        await set_servo_angle(angle)
                        response = {"status": "ok", "angle": servo.get_angle() if servo else 0}
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
        logger.error(f"未預期錯誤: {e}")
    finally:
        if servo:
            servo.stop()
        logger.info(f"連線關閉: {path}")

async def main():
    if not init_mavlink():
        logger.error("因 Pixhawk 連線失敗退出")
        return
    setup_led()
    setup_servo()
    await initialize_servo()
    server = await websockets.serve(
        handle_connection,
        "0.0.0.0", 8766,
        ping_interval=20,
        ping_timeout=15
    )
    logger.info("WebSocket 伺服器啟動於 ws://0.0.0.0:8766")
    await server.wait_closed()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("伺服器手動關閉")
        if servo:
            servo.cleanup()