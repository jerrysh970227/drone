import asyncio
import websockets
import json
import logging
from pymavlink import mavutil
import RPi.GPIO as GPIO
import signal
import sys
from contextlib import asynccontextmanager

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

# 硬件配置
LED_PIN = 27
SERVO_PIN = 18

class HardwareManager:
    """統一管理所有硬件組件"""
    def __init__(self):
        self.master = None
        self.servo = None
        self.gpio_initialized = False
        self.connected_clients = set()
    
    def initialize(self):
        """初始化所有硬件"""
        try:
            # 初始化 GPIO
            if not self.gpio_initialized:
                GPIO.setmode(GPIO.BCM)
                GPIO.setwarnings(False)
                self.gpio_initialized = True
                logger.info("GPIO 初始化完成")
            
            # 初始化 MAVLink
            self._init_mavlink()
            
            # 初始化 LED
            self._setup_led()
            
            # 初始化伺服馬達
            self._setup_servo()
            
            return True
        except Exception as e:
            logger.error(f"硬件初始化失敗: {e}")
            return False
    
    def _init_mavlink(self):
        """初始化 MAVLink 連接"""
        try:
            self.master = mavutil.mavlink_connection('/dev/ttyACM0', baud=115200)
            self.master.wait_heartbeat(timeout=5)
            logger.info("成功連接到 Pixhawk")
        except Exception as e:
            logger.error(f"無法連接到 Pixhawk: {e}")
            self.master = None
    
    def _setup_led(self):
        """設置 LED"""
        try:
            # 確保LED_PIN已正確設置
            if not isinstance(LED_PIN, int) or LED_PIN <= 0:
                logger.error(f"LED_PIN設置不正確: {LED_PIN}")
                return
                
            GPIO.setup(LED_PIN, GPIO.OUT, initial=GPIO.LOW)
            # 測試LED是否正常工作
            GPIO.output(LED_PIN, GPIO.HIGH)
            time.sleep(0.1)
            GPIO.output(LED_PIN, GPIO.LOW)
            logger.info(f"LED 已初始化並測試於 GPIO{LED_PIN}")
        except Exception as e:
            logger.error(f"LED 初始化失敗: {e}")
    
    def _setup_servo(self):
        """設置伺服馬達"""
        try:
            self.servo = CameraServo(pin=SERVO_PIN)
            logger.info("伺服馬達初始化完成")
        except Exception as e:
            logger.error(f"伺服馬達初始化失敗: {e}")
            self.servo = None
    
    def cleanup(self):
        """清理所有資源"""
        logger.info("開始清理硬件資源...")
        
        if self.servo:
            self.servo.cleanup()
        
        if self.gpio_initialized:
            GPIO.cleanup()
            self.gpio_initialized = False
        
        logger.info("硬件資源清理完成")

# 全局硬件管理器
hardware = HardwareManager()

class CameraServo:
    """改進的伺服馬達控制類"""
    def __init__(self, pin=18, frequency=333, initial_percentage=0.065):  # Increased frequency to 333Hz
        self.pin = pin
        self.frequency = frequency
        self.duty_cycle = initial_percentage
        self.pwm = None
        self.last_angle = None  # Track last sent angle to prevent jitter
        self.angle_threshold = 0.5  # Minimum angle change to trigger update
        self._setup()
    
    def _setup(self):
        """設置伺服馬達"""
        try:
            GPIO.setup(self.pin, GPIO.OUT)
            self.pwm = GPIO.PWM(self.pin, self.frequency)
            self.pwm.start(self.duty_cycle * 100)
            logger.info(f"伺服馬達設置完成 - Pin: {self.pin}, 頻率: {self.frequency}Hz")
        except Exception as e:
            logger.error(f"伺服馬達設置失敗: {e}")
            self.pwm = None
    
    def set_angle(self, target_angle):
        """設置伺服馬達角度"""
        if self.pwm is None:
            logger.error("伺服馬達未初始化")
            return False
        
        try:
            # 限制角度範圍：-45° 到 90°
            target_angle = max(-45, min(90, target_angle))
            
            # Check if angle change is significant enough to avoid jitter
            if self.last_angle is not None and abs(target_angle - self.last_angle) < self.angle_threshold:
                logger.debug(f"角度變化過小，跳過更新: {target_angle:.1f}° (上次: {self.last_angle:.1f}°)")
                return True  # Still return success but don't update
            
            # Calculate duty cycle with improved precision
            self.duty_cycle = (target_angle + 45) * 0.08 / 135 + 0.025
            self.duty_cycle = max(0.025, min(0.105, self.duty_cycle))
            
            # Update PWM signal
            self.pwm.ChangeDutyCycle(self.duty_cycle * 100)
            self.last_angle = target_angle
            
            # Add small delay for smoother transition (reduces jitter)
            import time
            time.sleep(0.01)
            
            logger.info(f"設置伺服角度: {target_angle:.1f}°")
            return True
        except Exception as e:
            logger.error(f"設置伺服角度失敗: {e}")
            return False
    
    def get_angle(self):
        """獲取當前角度"""
        if self.pwm is None:
            return 0.0
        return 135 * (self.duty_cycle - 0.025) / 0.08 - 45
    
    def cleanup(self):
        """清理伺服馬達資源"""
        if self.pwm:
            self.pwm.stop()
            logger.info("伺服馬達已停止")

class MAVLinkController:
    """MAVLink 控制器"""
    def __init__(self, master):
        self.master = master
    
    def set_flight_mode(self, mode):
        """設置飛行模式"""
        if not self.master:
            logger.error("無 Pixhawk 連線")
            return False
        
        try:
            mode_id = self.master.mode_mapping().get(mode, -1)
            if mode_id == -1:
                logger.error(f"未知模式: {mode}")
                return False
            
            self.master.mav.set_mode_send(
                self.master.target_system,
                mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED,
                mode_id
            )
            logger.info(f"已設置飛行模式為 {mode}")
            return True
        except Exception as e:
            logger.error(f"設置飛行模式失敗: {e}")
            return False
    
    def set_arm(self, arm):
        """設置啟動/解除"""
        if not self.master:
            logger.error("無 Pixhawk 連線")
            return False
        
        try:
            self.master.mav.command_long_send(
                self.master.target_system,
                self.master.target_component,
                mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
                0,
                1 if arm else 0, 0, 0, 0, 0, 0, 0
            )
            logger.info(f"Pixhawk {'已啟動' if arm else '已解除'}")
            return True
        except Exception as e:
            logger.error(f"設置啟動/解除失敗: {e}")
            return False
    
    def set_rc_channels(self, throttle, yaw, forward, lateral):
        """設置 RC 通道"""
        if not self.master:
            logger.error("無 Pixhawk 連線")
            return False
        
        try:
            throttle_pwm = int(1500 + throttle * 500)
            yaw_pwm = int(1500 + yaw * 500)
            pitch_pwm = int(1500 + forward * 500)
            roll_pwm = int(1500 + lateral * 500)
            
            channels = [roll_pwm, pitch_pwm, throttle_pwm, yaw_pwm, 0, 0, 0, 0]
            self.master.mav.rc_channels_override_send(
                self.master.target_system,
                self.master.target_component,
                *channels
            )
            logger.debug(f"RC 通道設置完成")
            return True
        except Exception as e:
            logger.error(f"設置 RC 通道失敗: {e}")
            return False

class LEDController:
    """LED 控制器"""
    @staticmethod
    def set_led(state: bool):
        """設置 LED 狀態"""
        try:
            if not hardware.gpio_initialized:
                logger.warning("GPIO 未初始化")
                return False
            GPIO.output(LED_PIN, GPIO.HIGH if state else GPIO.LOW)
            logger.info(f"LED 狀態: {'ON' if state else 'OFF'}")
            return True
        except Exception as e:
            logger.error(f"設置 LED 失敗: {e}")
            return False
    
    @staticmethod
    def toggle_led():
        """切換 LED 狀態"""
        try:
            if not hardware.gpio_initialized:
                logger.warning("GPIO 未初始化")
                return False
            current = GPIO.input(LED_PIN)
            new_state = GPIO.LOW if current == GPIO.HIGH else GPIO.HIGH
            GPIO.output(LED_PIN, new_state)
            logger.info(f"LED 已切換為: {'ON' if new_state == GPIO.HIGH else 'OFF'}")
            return new_state == GPIO.HIGH
        except Exception as e:
            logger.error(f"切換 LED 失敗: {e}")
            return False
    
    @staticmethod
    def get_led_state():
        """獲取 LED 狀態"""
        try:
            if not hardware.gpio_initialized:
                logger.info("GPIO 未初始化，返回默認 LED 狀態: False")
                return False
            state = GPIO.input(LED_PIN) == GPIO.HIGH
            logger.info(f"讀取 LED 狀態: {'ON' if state else 'OFF'}")
            return state
        except Exception as e:
            logger.error(f"讀取 LED 狀態失敗: {e}")
            return False

async def initialize_servo():
    """初始化伺服馬達序列"""
    if not hardware.servo:
        logger.warning("伺服馬達未初始化，跳過初始化序列")
        return False
    
    logger.info("開始執行伺服馬達初始化序列")
    try:
        positions = [0, -45, 0, 90, 0]
        # 使用LEDController來控制LED
        LEDController.set_led(True)
        for position in positions:
            if hardware.servo.set_angle(position):
                await asyncio.sleep(0.5)
            else:
                logger.warning(f"無法設置伺服角度到 {position}")
        LEDController.set_led(False)
        logger.info("伺服馬達初始化序列完成")
        return True
    except Exception as e:
        # 確保在出錯時關閉LED
        try:
            LEDController.set_led(False)
        except:
            pass
        logger.error(f"伺服馬達初始化序列失敗: {e}")
        return False

async def handle_connection(websocket, path=None):
    """處理客戶端連接"""
    client_id = f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
    logger.info(f"新客戶端連接: {client_id}")
    
    hardware.connected_clients.add(websocket)
    mavlink_controller = MAVLinkController(hardware.master)
    
    try:
        async for message in websocket:
            logger.debug(f"收到來自 {client_id} 的消息: {message}")
            
            try:
                data = json.loads(message)
                response = await process_message(data, mavlink_controller)
                await websocket.send(json.dumps(response))
                
            except json.JSONDecodeError as e:
                logger.error(f"無效 JSON 來自 {client_id}: {e}")
                error_response = {"status": "error", "message": f"無效 JSON: {str(e)}"}
                await websocket.send(json.dumps(error_response))
                
            except Exception as e:
                logger.error(f"處理消息時出錯 {client_id}: {e}")
                error_response = {"status": "error", "message": f"處理錯誤: {str(e)}"}
                await websocket.send(json.dumps(error_response))
    
    except websockets.exceptions.ConnectionClosed as e:
        logger.info(f"客戶端 {client_id} 正常斷開: {e.code}")
    except websockets.exceptions.ConnectionClosedError as e:
        logger.info(f"客戶端 {client_id} 連接錯誤: {e}")
    except websockets.exceptions.ConnectionClosedOK as e:
        logger.info(f"客戶端 {client_id} 正常關閉: {e}")
    except Exception as e:
        logger.error(f"客戶端 {client_id} 異常斷開: {e}")
        # Send error response before closing
        try:
            error_response = {"status": "error", "message": f"連接異常: {str(e)}"}
            await websocket.send(json.dumps(error_response))
        except:
            pass
    finally:
        hardware.connected_clients.discard(websocket)
        logger.info(f"客戶端 {client_id} 連接已清理")

async def process_message(data, mavlink_controller):
    """處理收到的消息"""
    message_type = data.get("type")
    
    if message_type == "control":
        return await handle_control_message(data, mavlink_controller)
    elif message_type == "command":
        return await handle_command_message(data, mavlink_controller)
    elif message_type == "servo_control":
        return await handle_servo_message(data)
    elif message_type == "status_request":
        # Handle status request messages
        return {
            "status": "ok",
            "message": "Status request received",
            "angle": hardware.servo.get_angle() if hardware.servo else 0,
            "led": LEDController.get_led_state() if hardware.gpio_initialized else False
        }
    else:
        return {"status": "error", "message": f"未知消息類型: {message_type}"}

async def handle_control_message(data, mavlink_controller):
    """處理控制消息"""
    try:
        throttle = float(data.get('throttle', 0))
        yaw = float(data.get('yaw', 0))
        forward = float(data.get('forward', 0))
        lateral = float(data.get('lateral', 0))
        
        success = mavlink_controller.set_rc_channels(throttle, yaw, forward, lateral)
        
        return {
            "status": "ok" if success else "error",
            "message": "控制命令已執行" if success else "控制命令執行失敗"
        }
    except ValueError as e:
        return {"status": "error", "message": f"無效的控制參數: {e}"}

async def handle_command_message(data, mavlink_controller):
    """處理命令消息"""
    action = data.get('action')
    
    if action == "ARM":
        arm_success = mavlink_controller.set_arm(True)
        mode_success = mavlink_controller.set_flight_mode("STABILIZE")
        return {
            "status": "ok" if (arm_success and mode_success) else "error",
            "message": "啟動並設置穩定模式" if (arm_success and mode_success) else "啟動或模式設置失敗"
        }
    
    elif action == "DISARM":
        success = mavlink_controller.set_arm(False)
        return {
            "status": "ok" if success else "error",
            "message": "已解除啟動" if success else "解除啟動失敗"
        }
    
    elif action == "LED_ON":
        success = LEDController.set_led(True)
        # Always return the current LED state, even if the command failed
        current_led_state = LEDController.get_led_state()
        return {"status": "ok" if success else "error", "led": current_led_state, "message": "LED ON" if success else "Failed to turn LED ON"}
    
    elif action == "LED_OFF":
        success = LEDController.set_led(False)
        # Always return the current LED state, even if the command failed
        current_led_state = LEDController.get_led_state()
        return {"status": "ok" if success else "error", "led": current_led_state, "message": "LED OFF" if success else "Failed to turn LED OFF"}
    
    elif action == "LED_TOGGLE":
        new_state = LEDController.toggle_led()
        # Always return the current LED state after toggle
        current_led_state = LEDController.get_led_state()
        return {"status": "ok", "led": current_led_state, "message": f"LED {'ON' if current_led_state else 'OFF'}"}
    
    elif action == "REQUEST_SERVO_ANGLE":
        # Handle servo angle request
        angle = hardware.servo.get_angle() if hardware.servo else 0
        return {
            "status": "ok",
            "angle": angle,
            "message": f"當前伺服角度: {angle:.1f}°"
        }
    
    else:
        return {"status": "error", "message": f"未知命令: {action}"}

async def handle_servo_message(data):
    """處理伺服馬達消息"""
    if not hardware.servo:
        return {"status": "error", "message": "伺服馬達未初始化"}
    
    try:
        angle = float(data.get('angle', 0))
        
        if not (-45 <= angle <= 90):
            return {
                "status": "error",
                "message": f"角度 {angle} 超出範圍 [-45, 90]",
                "angle": hardware.servo.get_angle()
            }
        
        success = hardware.servo.set_angle(angle)
        return {
            "status": "ok" if success else "error",
            "angle": hardware.servo.get_angle(),
            "message": "角度設置成功" if success else "角度設置失敗"
        }
        
    except ValueError as e:
        return {"status": "error", "message": f"無效角度值: {e}"}

def signal_handler(signum, frame):
    """信號處理器"""
    logger.info(f"收到信號 {signum}，正在關閉服務器...")
    hardware.cleanup()
    sys.exit(0)

async def main():
    """主函數"""
    # 設置信號處理
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # 初始化硬件
    if not hardware.initialize():
        logger.error("硬件初始化失敗，退出程序")
        return
    
    # 初始化伺服馬達
    await initialize_servo()
    
    # 啟動 WebSocket 服務器
    try:
        server = await websockets.serve(
            handle_connection,
            "0.0.0.0", 8766,
            ping_interval=30,
            ping_timeout=20
        )
        logger.info("WebSocket 伺服器啟動於 ws://0.0.0.0:8766")
        logger.info(f"當前連接的客戶端數量: {len(hardware.connected_clients)}")
        
        # 定期報告客戶端連接狀態
        async def report_clients():
            while True:
                await asyncio.sleep(60)  # 每分鐘報告一次
                logger.info(f"當前連接的客戶端數量: {len(hardware.connected_clients)}")
                if hardware.connected_clients:
                    logger.info(f"連接的客戶端: {[str(client.remote_address) for client in hardware.connected_clients]}")
        
        # 啟動客戶端報告任務
        asyncio.create_task(report_clients())
        
        # 等待服務器運行
        await server.wait_closed()
        
    except Exception as e:
        logger.error(f"服務器運行錯誤: {e}")
    finally:
        hardware.cleanup()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("服務器手動關閉")
    except Exception as e:
        logger.error(f"程序異常退出: {e}")
    finally:
        hardware.cleanup()