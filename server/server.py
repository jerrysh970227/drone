import asyncio
import websockets
import json
import logging
from pymavlink import mavutil
import pigpio
import signal
import sys
import time
import math

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

# 硬體配置
LED_PIN = 27
SERVO_PIN = 22

class HardwareManager:
    """統一管理所有硬體組件"""
    def __init__(self):
        self.master = None
        self.servo = None
        self.pi = None
        self.connected_clients = set()
        self.last_heartbeat_time = time.time()
    
    def initialize(self):
        """初始化所有硬體"""
        try:
            # 初始化 pigpio
            self.pi = pigpio.pi()
            if not self.pi.connected:
                logger.error("pigpio daemon 未運行,請先執行 'sudo pigpiod'")
                return False
            logger.info("pigpio 連接成功")
            
            # 初始化 MAVLink
            self._init_mavlink()
            
            # 初始化 LED
            self._setup_led()
            
            # 初始化伺服馬達
            self._setup_servo()
            
            return True
        except Exception as e:
            logger.error(f"硬體初始化失敗: {e}")
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
            self.pi.set_mode(LED_PIN, pigpio.OUTPUT)
            self.pi.write(LED_PIN, 0)
            # 測試 LED
            self.pi.write(LED_PIN, 1)
            time.sleep(0.1)
            self.pi.write(LED_PIN, 0)
            logger.info(f"LED 已初始化於 GPIO{LED_PIN}")
        except Exception as e:
            logger.error(f"LED 初始化失敗: {e}")
    
    def _setup_servo(self):
        """設置伺服馬達"""
        try:
            self.servo = CameraServo(self.pi, pin=SERVO_PIN)
            logger.info("伺服馬達初始化完成")
        except Exception as e:
            logger.error(f"伺服馬達初始化失敗: {e}")
            self.servo = None
    
    def cleanup(self):
        """清理所有資源"""
        logger.info("開始清理硬體資源...")
        
        if self.servo:
            self.servo.cleanup()
        
        if self.pi and self.pi.connected:
            self.pi.stop()
        
        logger.info("硬體資源清理完成")

# 全局硬體管理器
hardware = HardwareManager()

class CameraServo:
    """使用 pigpio 的伺服馬達控制類"""
    def __init__(self, pi, pin=22, min_pw=500, max_pw=2500, angle_min=-45.0, angle_max=90.0):
        self.pi = pi
        self.pin = pin
        self.min_pw = min_pw
        self.max_pw = max_pw
        self.angle_min = angle_min
        self.angle_max = angle_max
        self.current_angle = 0.0
        self.is_moving = False
        self._setup()
    
    def _setup(self):
        """設置伺服馬達"""
        try:
            # 設置為初始位置 (0度)
            initial_pw = self._angle_to_pw(0.0)
            self.pi.set_servo_pulsewidth(self.pin, int(initial_pw))
            time.sleep(0.5)  # 等待穩定
            logger.info(f"伺服馬達設置完成 - Pin: {self.pin}, 範圍: [{self.angle_min}°, {self.angle_max}°]")
        except Exception as e:
            logger.error(f"伺服馬達設置失敗: {e}")
    
    def _angle_to_pw(self, angle):
        """將角度轉換為脈衝寬度 (μs)"""
        angle = max(min(angle, self.angle_max), self.angle_min)
        # 將角度從 [angle_min, angle_max] 映射到 [min_pw, max_pw]
        normalized = (angle - self.angle_min) / (self.angle_max - self.angle_min)
        return self.min_pw + normalized * (self.max_pw - self.min_pw)
    
    def _pw_to_angle(self, pw):
        """將脈衝寬度轉換為角度"""
        if pw <= 0:
            return self.current_angle
        normalized = (pw - self.min_pw) / (self.max_pw - self.min_pw)
        return self.angle_min + normalized * (self.angle_max - self.angle_min)
    
    def _ease(self, t, mode='sine'):
        """緩動函數"""
        if mode == 'linear':
            return t
        elif mode == 'quad':
            return 2*t*t if t < 0.5 else 1 - 2*(1-t)*(1-t)
        elif mode == 'cubic':
            return 4*t*t*t if t < 0.5 else 1 - pow(-2*t+2, 3)/2
        elif mode == 'sine':
            return 0.5 * (1 - math.cos(math.pi * t))
        return t
    
    def get_current_angle(self):
        """獲取當前角度"""
        try:
            pw = self.pi.get_servo_pulsewidth(self.pin)
            if pw > 0:
                return self._pw_to_angle(pw)
        except:
            pass
        return self.current_angle
    
    async def move_to(self, target_angle, duration=0.8, steps=100, easing_mode='sine'):
        """平滑移動到目標角度 (異步版本)"""
        if self.is_moving:
            logger.warning("伺服馬達正在移動中,跳過此次命令")
            return False
        
        self.is_moving = True
        
        try:
            start_angle = self.get_current_angle()
            target_angle = max(min(target_angle, self.angle_max), self.angle_min)
            
            steps = max(1, int(steps))
            step_delay = max(0.001, duration / steps)
            
            logger.info(f"伺服馬達移動: {start_angle:.1f}° → {target_angle:.1f}° (耗時 {duration}s, {easing_mode})")
            
            for i in range(steps + 1):
                t = i / steps
                te = self._ease(t, easing_mode)
                angle = start_angle + (target_angle - start_angle) * te
                pw = self._angle_to_pw(angle)
                self.pi.set_servo_pulsewidth(self.pin, int(pw))
                await asyncio.sleep(step_delay)
            
            self.current_angle = target_angle
            logger.info(f"伺服馬達到達目標位置: {target_angle:.1f}°")
            return True
            
        except Exception as e:
            logger.error(f"伺服馬達移動失敗: {e}")
            return False
        finally:
            self.is_moving = False
    
    def set_angle(self, target_angle):
        """立即設置角度 (同步版本,用於兼容)"""
        try:
            target_angle = max(min(target_angle, self.angle_max), self.angle_min)
            pw = self._angle_to_pw(target_angle)
            self.pi.set_servo_pulsewidth(self.pin, int(pw))
            self.current_angle = target_angle
            logger.info(f"伺服角度已設置: {target_angle:.1f}°")
            return True
        except Exception as e:
            logger.error(f"設置伺服角度失敗: {e}")
            return False
    
    def get_angle(self):
        """獲取角度 (兼容方法)"""
        return self.get_current_angle()
    
    def cleanup(self):
        """清理伺服馬達資源"""
        try:
            # 關閉 PWM 輸出
            self.pi.set_servo_pulsewidth(self.pin, 0)
            logger.info("伺服馬達已停止")
        except Exception as e:
            logger.error(f"伺服馬達清理失敗: {e}")

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
            if not hardware.pi or not hardware.pi.connected:
                logger.warning("pigpio 未連接")
                return False
            hardware.pi.write(LED_PIN, 1 if state else 0)
            logger.info(f"LED 狀態: {'ON' if state else 'OFF'}")
            return True
        except Exception as e:
            logger.error(f"設置 LED 失敗: {e}")
            return False
    
    @staticmethod
    def toggle_led():
        """切換 LED 狀態"""
        try:
            if not hardware.pi or not hardware.pi.connected:
                logger.warning("pigpio 未連接")
                return False
            current = hardware.pi.read(LED_PIN)
            new_state = 0 if current else 1
            hardware.pi.write(LED_PIN, new_state)
            logger.info(f"LED 已切換為: {'ON' if new_state else 'OFF'}")
            return new_state == 1
        except Exception as e:
            logger.error(f"切換 LED 失敗: {e}")
            return False
    
    @staticmethod
    def get_led_state():
        """獲取 LED 狀態"""
        try:
            if not hardware.pi or not hardware.pi.connected:
                return False
            state = hardware.pi.read(LED_PIN) == 1
            return state
        except Exception as e:
            logger.error(f"讀取 LED 狀態失敗: {e}")
            return False

async def initialize_servo():
    """初始化伺服馬達序列"""
    if not hardware.servo:
        logger.warning("伺服馬達未初始化,跳過初始化序列")
        return False
    
    logger.info("開始執行伺服馬達初始化序列")
    try:
        # 優雅的初始化動作序列
        positions = [
            (0, 0.6, 'sine'),      # 回到中心
            (45, 0.8, 'sine'),     # 向上
            (-45, 1.2, 'sine'),    # 向下
            (0, 0.8, 'cubic'),     # 回到中心
        ]
        
        LEDController.set_led(True)
        
        for angle, duration, easing in positions:
            success = await hardware.servo.move_to(angle, duration=duration, steps=100, easing_mode=easing)
            if not success:
                logger.warning(f"無法移動伺服馬達到 {angle}°")
                LEDController.set_led(False)
                return False
            await asyncio.sleep(0.2)  # 短暫停頓
        
        LEDController.set_led(False)
        logger.info("伺服馬達初始化序列完成")
        return True
        
    except Exception as e:
        LEDController.set_led(False)
        logger.error(f"伺服馬達初始化序列失敗: {e}")
        return False

async def handle_connection(websocket, path=None):
    """處理客戶端連接"""
    client_id = f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
    logger.info(f"新客戶端連接: {client_id}")
    
    hardware.connected_clients.add(websocket)
    mavlink_controller = MAVLinkController(hardware.master)
    
    try:
        await websocket.send(json.dumps({
            "status": "ok",
            "message": "Connected to drone server",
            "timestamp": time.time()
        }))
        
        async for message in websocket:
            logger.debug(f"收到來自 {client_id} 的消息: {message}")
            
            try:
                data = json.loads(message)
                response = await process_message(data, mavlink_controller)
                await websocket.send(json.dumps(response))
                hardware.last_heartbeat_time = time.time()
                
            except json.JSONDecodeError as e:
                logger.error(f"無效 JSON 來自 {client_id}: {e}")
                await websocket.send(json.dumps({"status": "error", "message": f"無效 JSON: {str(e)}"}))
                
            except Exception as e:
                logger.error(f"處理消息時出錯 {client_id}: {e}")
                await websocket.send(json.dumps({"status": "error", "message": f"處理錯誤: {str(e)}"}))
    
    except websockets.exceptions.ConnectionClosed as e:
        logger.info(f"客戶端 {client_id} 正常斷開: {e.code}")
    except Exception as e:
        logger.error(f"客戶端 {client_id} 異常斷開: {e}")
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
        return {
            "status": "ok",
            "message": "Status request received",
            "angle": hardware.servo.get_angle() if hardware.servo else 0,
            "led": LEDController.get_led_state()
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
        current_led_state = LEDController.get_led_state()
        return {"status": "ok" if success else "error", "led": current_led_state, "message": "LED ON" if success else "Failed to turn LED ON"}
    
    elif action == "LED_OFF":
        success = LEDController.set_led(False)
        current_led_state = LEDController.get_led_state()
        return {"status": "ok" if success else "error", "led": current_led_state, "message": "LED OFF" if success else "Failed to turn LED OFF"}
    
    elif action == "LED_TOGGLE":
        new_state = LEDController.toggle_led()
        current_led_state = LEDController.get_led_state()
        return {"status": "ok", "led": current_led_state, "message": f"LED {'ON' if current_led_state else 'OFF'}"}
    
    elif action == "REQUEST_SERVO_ANGLE":
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
        duration = float(data.get('duration', 0.8))
        steps = int(data.get('steps', 100))
        easing = data.get('easing', 'sine')
        
        if not (hardware.servo.angle_min <= angle <= hardware.servo.angle_max):
            return {
                "status": "error",
                "message": f"角度 {angle} 超出範圍 [{hardware.servo.angle_min}, {hardware.servo.angle_max}]",
                "angle": hardware.servo.get_angle()
            }
        
        # 使用異步平滑移動
        success = await hardware.servo.move_to(angle, duration=duration, steps=steps, easing_mode=easing)
        
        return {
            "status": "ok" if success else "error",
            "angle": hardware.servo.get_angle(),
            "message": "角度設置成功" if success else "角度設置失敗"
        }
        
    except ValueError as e:
        return {"status": "error", "message": f"無效角度值: {e}"}

def signal_handler(signum, frame):
    """信號處理器"""
    logger.info(f"收到信號 {signum},正在關閉服務器...")
    hardware.cleanup()
    sys.exit(0)

async def main():
    """主函數"""
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # 初始化硬體
    if not hardware.initialize():
        logger.error("硬體初始化失敗,退出程序")
        return
    
    # 初始化伺服馬達
    await initialize_servo()
    
    # 啟動 WebSocket 服務器
    try:
        server = await websockets.serve(
            handle_connection,
            "0.0.0.0", 8766,
            ping_interval=30,
            ping_timeout=20,
            close_timeout=10
        )
        logger.info("WebSocket 伺服器啟動於 ws://0.0.0.0:8766")
        
        async def report_clients():
            while True:
                await asyncio.sleep(60)
                logger.info(f"當前連接的客戶端數量: {len(hardware.connected_clients)}")
        
        asyncio.create_task(report_clients())
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