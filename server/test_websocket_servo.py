#!/usr/bin/env python3
"""
WebSocket client test for debugging servo communication
"""

import asyncio
import websockets
import json
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

async def test_servo_websocket():
    """Test servo control via WebSocket"""
    uri = "ws://localhost:8766"
    
    try:
        async with websockets.connect(uri) as websocket:
            logger.info("Connected to WebSocket server")
            
            # Test sequence
            test_angles = [0, 30, -20, 45, -30, 0]
            
            for angle in test_angles:
                # Send servo control command
                command = {
                    "type": "servo_control",
                    "angle": angle
                }
                
                logger.info(f"Sending: {command}")
                await websocket.send(json.dumps(command))
                
                # Wait for response
                response = await websocket.recv()
                data = json.loads(response)
                logger.info(f"Response: {data}")
                
                if data.get("status") == "ok":
                    returned_angle = data.get("angle")
                    logger.info(f"Server reports angle: {returned_angle}°")
                    
                    if abs(returned_angle - angle) > 0.1:
                        logger.warning(f"Angle mismatch! Sent: {angle}°, Got: {returned_angle}°")
                else:
                    logger.error(f"Error response: {data}")
                
                # Wait before next command
                await asyncio.sleep(1)
                
                # Request current angle
                request = {"type": "request_angle"}
                logger.info(f"Requesting angle: {request}")
                await websocket.send(json.dumps(request))
                
                response = await websocket.recv()
                data = json.loads(response)
                logger.info(f"Angle response: {data}")
                
                await asyncio.sleep(2)
    
    except websockets.exceptions.ConnectionRefused:
        logger.error("Could not connect to WebSocket server. Make sure server.py is running.")
    except Exception as e:
        logger.error(f"WebSocket test failed: {e}")

if __name__ == "__main__":
    print("=== WebSocket Servo Test ===")
    print("Make sure server.py is running first!")
    print("Press Ctrl+C to stop")
    
    try:
        asyncio.run(test_servo_websocket())
    except KeyboardInterrupt:
        print("\nTest stopped by user")