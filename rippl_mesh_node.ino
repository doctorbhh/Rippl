/*
 * Rippl ESP32 Mesh Node (Lag-Free BLE Edition)
NEW SKETCH

 * =============================================
 * Upload this SAME code to ALL your ESP32 devices!
 * 
 * INSTANT MESSAGING ARCHITECTURE:
 * ✓ Event-driven (callbacks only, empty loop)
 * ✓ BLE Notifications (push, not poll)
 * ✓ No encryption on ESP32 (app handles it)
 * ✓ RSSI signal strength included
 * 
 * How it works:
 * - Phone connects via BLE
 * - Messages pushed instantly via notify()
 * - ESP-NOW handles mesh communication
 * - RSSI included for signal strength display
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <WiFi.h>

// ========== BLE UUIDs ==========
#define SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_TX_UUID        "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // ESP32 -> Phone (notify)
#define CHAR_RX_UUID        "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // Phone -> ESP32 (write)

// ========== Configuration ==========
#define SOS_BUTTON_PIN    0
#define LED_PIN           2
#define MAX_HOPS          5
#define ESPNOW_CHANNEL    1

// ========== Globals ==========
BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
bool deviceConnected = false;
bool oldDeviceConnected = false;

String deviceName;
String deviceMac;
uint16_t msgCounter = 0;

// Broadcast address for ESP-NOW
uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

// Message types
#define MSG_CHAT    1
#define MSG_SOS     2

// Mesh packet structure
typedef struct __attribute__((packed)) {
  uint8_t type;
  uint8_t hopCount;
  uint16_t msgId;
  int8_t rssi;           // Signal strength
  char sender[12];
  char message[100];
} MeshPacket;

MeshPacket outPacket;
MeshPacket inPacket;

// Message history (prevent duplicates)
#define MSG_HISTORY_SIZE 30
uint16_t messageHistory[MSG_HISTORY_SIZE];
uint8_t historyIndex = 0;

bool isMessageSeen(uint16_t msgId) {
  for (int i = 0; i < MSG_HISTORY_SIZE; i++) {
    if (messageHistory[i] == msgId) return true;
  }
  return false;
}

void addToHistory(uint16_t msgId) {
  messageHistory[historyIndex] = msgId;
  historyIndex = (historyIndex + 1) % MSG_HISTORY_SIZE;
}

// ========== Send to Phone (BLE Notify - INSTANT) ==========
void sendToPhone(const char* json) {
  if (deviceConnected && pTxCharacteristic) {
    pTxCharacteristic->setValue((uint8_t*)json, strlen(json));
    pTxCharacteristic->notify();
    // NO DELAY - instant push!
  }
}

// ========== Send to Mesh ==========
void sendToMesh(uint8_t type, const char* sender, const char* msg) {
  memset(&outPacket, 0, sizeof(outPacket));
  outPacket.type = type;
  outPacket.hopCount = 0;
  outPacket.msgId = ++msgCounter;
  outPacket.rssi = 0;
  strncpy(outPacket.sender, sender, sizeof(outPacket.sender) - 1);
  strncpy(outPacket.message, msg, sizeof(outPacket.message) - 1);
  
  addToHistory(outPacket.msgId);
  
  esp_now_send(broadcastAddress, (uint8_t*)&outPacket, sizeof(outPacket));
  
  Serial.print("[TX] ");
  Serial.print(sender);
  Serial.print(": ");
  Serial.println(msg);
}

// ========== ESP-NOW Receive Callback (EVENT-DRIVEN) ==========
void OnDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  if (len != sizeof(MeshPacket)) return;
  
  memcpy(&inPacket, data, sizeof(inPacket));
  
  if (isMessageSeen(inPacket.msgId)) return;
  addToHistory(inPacket.msgId);
  
  // Get RSSI from the received packet info
  int8_t rxRssi = info->rx_ctrl->rssi;
  
  Serial.print("[RX] ");
  Serial.print(inPacket.sender);
  Serial.print(": ");
  Serial.print(inPacket.message);
  Serial.print(" (RSSI:");
  Serial.print(rxRssi);
  Serial.println(")");
  
  // INSTANT push to phone via BLE notify
  if (deviceConnected) {
    char json[200];
    snprintf(json, sizeof(json), 
      "{\"type\":%d,\"from\":\"%s\",\"msg\":\"%s\",\"hops\":%d,\"rssi\":%d}",
      inPacket.type, inPacket.sender, inPacket.message, inPacket.hopCount, rxRssi);
    sendToPhone(json);
  }
  
  // Forward to mesh
  if (inPacket.hopCount < MAX_HOPS) {
    inPacket.hopCount++;
    inPacket.rssi = rxRssi;
    esp_now_send(broadcastAddress, (uint8_t*)&inPacket, sizeof(inPacket));
  }
  
  // Flash LED
  digitalWrite(LED_PIN, HIGH);
  digitalWrite(LED_PIN, LOW);
}

void OnDataSent(const wifi_tx_info_t *info, esp_now_send_status_t status) {
  // Silent
}

// ========== BLE Callbacks (EVENT-DRIVEN) ==========
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("[BLE] Phone connected!");
    digitalWrite(LED_PIN, HIGH);
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("[BLE] Phone disconnected");
    digitalWrite(LED_PIN, LOW);
    // Restart advertising
    pServer->startAdvertising();
  }
};

class MyRxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue();
    
    if (value.length() > 0) {
      Serial.print("[BLE RX] ");
      Serial.println(value.c_str());
      
      // Check for SOS
      if (value.indexOf("SOS") >= 0) {
        Serial.println("!!! SOS !!!");
        sendToMesh(MSG_SOS, deviceName.c_str(), "EMERGENCY!");
        return;
      }
      
      // Parse JSON: {"from":"name","msg":"content"}
      String sender = deviceName;
      String message = value;
      
      int fromStart = value.indexOf("\"from\":\"");
      if (fromStart > 0) {
        fromStart += 8;
        int fromEnd = value.indexOf("\"", fromStart);
        if (fromEnd > fromStart) {
          sender = value.substring(fromStart, fromEnd);
        }
      }
      
      int msgStart = value.indexOf("\"msg\":\"");
      if (msgStart > 0) {
        msgStart += 7;
        int msgEnd = value.indexOf("\"", msgStart);
        if (msgEnd > msgStart) {
          message = value.substring(msgStart, msgEnd);
        }
      }
      
      sendToMesh(MSG_CHAT, sender.c_str(), message.c_str());
    }
  }
};

// ========== SOS Button ISR (EVENT-DRIVEN) ==========
volatile bool sosTriggered = false;
unsigned long lastSosTime = 0;

void IRAM_ATTR sosButtonISR() {
  if (millis() - lastSosTime > 2000) {
    sosTriggered = true;
    lastSosTime = millis();
  }
}

// ========== Setup ==========
void setup() {
  Serial.begin(115200);
  delay(500);
  
  pinMode(SOS_BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  
  // Attach interrupt for SOS button (event-driven!)
  attachInterrupt(digitalPinToInterrupt(SOS_BUTTON_PIN), sosButtonISR, FALLING);
  
  // WiFi for ESP-NOW
  WiFi.mode(WIFI_STA);
  delay(100);
  deviceMac = WiFi.macAddress();
  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);
  
  // Device name from MAC
  String macSuffix = deviceMac.substring(deviceMac.length() - 5);
  macSuffix.replace(":", "");
  deviceName = "Rippl-" + macSuffix;
  
  Serial.println("\n========================================");
  Serial.println("  Rippl Mesh (Lag-Free BLE Edition)");
  Serial.println("========================================");
  Serial.println("Device: " + deviceName);
  Serial.println("MAC: " + deviceMac);
  
  // Initialize BLE
  BLEDevice::init(deviceName.c_str());
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  
  BLEService* pService = pServer->createService(SERVICE_UUID);
  
  // TX characteristic (ESP32 -> Phone, with notify)
  pTxCharacteristic = pService->createCharacteristic(
    CHAR_TX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());
  
  // RX characteristic (Phone -> ESP32, with write)
  BLECharacteristic* pRxCharacteristic = pService->createCharacteristic(
    CHAR_RX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pRxCharacteristic->setCallbacks(new MyRxCallbacks());
  
  pService->start();
  
  // Start advertising
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  
  Serial.println("BLE advertising: " + deviceName);
  
  // Initialize ESP-NOW
  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW init failed!");
    return;
  }
  
  esp_now_register_recv_cb(OnDataRecv);
  esp_now_register_send_cb(OnDataSent);
  
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, broadcastAddress, 6);
  peerInfo.channel = ESPNOW_CHANNEL;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);
  
  msgCounter = random(1, 1000);
  
  Serial.println("\nReady! Connect via BLE to: " + deviceName);
  Serial.println("Press BOOT button for SOS");
  Serial.println("========================================\n");
}

// ========== Loop (MINIMAL - Event Driven) ==========
void loop() {
  // Only check SOS flag (set by interrupt)
  if (sosTriggered) {
    sosTriggered = false;
    Serial.println("!!! SOS TRIGGERED !!!");
    digitalWrite(LED_PIN, HIGH);
    sendToMesh(MSG_SOS, deviceName.c_str(), "EMERGENCY!");
    
    // Notify phone
    if (deviceConnected) {
      char json[100];
      snprintf(json, sizeof(json), "{\"type\":2,\"from\":\"%s\",\"msg\":\"EMERGENCY!\",\"sos\":true}", deviceName.c_str());
      sendToPhone(json);
    }
    digitalWrite(LED_PIN, LOW);
  }
  
  // Serial monitor testing (optional)
  if (Serial.available()) {
    String input = Serial.readStringUntil('\n');
    input.trim();
    if (input.length() > 0) {
      if (input.equalsIgnoreCase("SOS")) {
        sendToMesh(MSG_SOS, deviceName.c_str(), "EMERGENCY!");
      } else {
        sendToMesh(MSG_CHAT, deviceName.c_str(), input.c_str());
      }
    }
  }
  
  // Minimal delay just to yield
  delay(1);
}
