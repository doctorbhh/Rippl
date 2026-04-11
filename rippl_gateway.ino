/*
 * Rippl ESP32 Gateway
 * ====================
 * Upload this to ONE ESP32 that connects to your phone.
 * Uses Classic Bluetooth Serial (more stable than BLE with ESP-NOW).
 * 
 * Features:
 * - Connects to phone via Bluetooth Serial
 * - Bridges phone messages to ESP-NOW mesh
 * - Receives mesh messages and sends to phone
 * 
 * In Flutter app: Use bluetooth_serial package to connect
 */

#include <esp_now.h>
#include <WiFi.h>
#include "BluetoothSerial.h"

BluetoothSerial SerialBT;

// Broadcast address
uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

// Message types
#define MSG_CHAT    1
#define MSG_SOS     2

// Packet structure (must match mesh nodes)
typedef struct {
  uint8_t type;
  char sender[16];
  char message[180];
  uint8_t hopCount;
} MeshPacket;

MeshPacket outPacket;
MeshPacket inPacket;

bool btConnected = false;

// ========== ESP-NOW Callback ==========
void OnDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  memcpy(&inPacket, data, sizeof(inPacket));
  
  // Create JSON to send to phone
  String json = "{\"type\":";
  json += inPacket.type;
  json += ",\"sender\":\"";
  json += inPacket.sender;
  json += "\",\"message\":\"";
  json += inPacket.message;
  json += "\"}";
  
  Serial.print("Mesh->Phone: ");
  Serial.println(json);
  
  // Send to phone via Bluetooth
  if (SerialBT.hasClient()) {
    SerialBT.println(json);
  }
}

void OnDataSent(const uint8_t *mac_addr, esp_now_send_status_t status) {
  Serial.print("Mesh send: ");
  Serial.println(status == ESP_NOW_SEND_SUCCESS ? "OK" : "FAIL");
}

// ========== Send to Mesh ==========
void sendToMesh(uint8_t type, const char* sender, const char* msg) {
  outPacket.type = type;
  strncpy(outPacket.sender, sender, sizeof(outPacket.sender));
  strncpy(outPacket.message, msg, sizeof(outPacket.message));
  outPacket.hopCount = 0;
  
  esp_now_send(broadcastAddress, (uint8_t*)&outPacket, sizeof(outPacket));
  Serial.print("Phone->Mesh: ");
  Serial.println(msg);
}

// ========== Setup ==========
void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println();
  Serial.println("========================================");
  Serial.println("   Rippl Gateway (BT Serial + ESP-NOW)");
  Serial.println("========================================");
  
  // Initialize Bluetooth Serial
  SerialBT.begin("Rippl-Gateway");
  Serial.println("Bluetooth: Rippl-Gateway");
  
  // Initialize WiFi for ESP-NOW
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  
  Serial.print("MAC: ");
  Serial.println(WiFi.macAddress());
  
  // Initialize ESP-NOW
  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW failed!");
    return;
  }
  
  esp_now_register_recv_cb(OnDataRecv);
  esp_now_register_send_cb(OnDataSent);
  
  // Add broadcast peer
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, broadcastAddress, 6);
  peerInfo.channel = 0;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);
  
  Serial.println();
  Serial.println("Gateway ready!");
  Serial.println("- Pair phone with 'Rippl-Gateway' in Bluetooth settings");
  Serial.println("- Messages from phone go to mesh");
  Serial.println("- Messages from mesh go to phone");
  Serial.println();
}

// ========== Main Loop ==========
void loop() {
  // Check Bluetooth connection
  bool connected = SerialBT.hasClient();
  if (connected != btConnected) {
    btConnected = connected;
    Serial.println(connected ? "Phone connected!" : "Phone disconnected");
  }
  
  // Read from phone (Bluetooth)
  if (SerialBT.available()) {
    String input = SerialBT.readStringUntil('\n');
    input.trim();
    
    if (input.length() > 0) {
      // Check for SOS command
      if (input.startsWith("SOS:")) {
        String sender = input.substring(4, input.indexOf(':', 4));
        sendToMesh(MSG_SOS, sender.c_str(), "EMERGENCY! Need help!");
      } 
      // Check for chat message: CHAT:sender:message
      else if (input.startsWith("CHAT:")) {
        int firstColon = input.indexOf(':', 5);
        String sender = input.substring(5, firstColon);
        String message = input.substring(firstColon + 1);
        sendToMesh(MSG_CHAT, sender.c_str(), message.c_str());
      }
      else {
        // Plain message
        sendToMesh(MSG_CHAT, "Phone", input.c_str());
      }
    }
  }
  
  // Echo Serial to Bluetooth for debugging
  if (Serial.available()) {
    String input = Serial.readStringUntil('\n');
    sendToMesh(MSG_CHAT, "Gateway", input.c_str());
  }
  
  delay(10);
}
