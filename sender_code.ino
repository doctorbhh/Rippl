#include <WiFi.h>
#include <esp_now.h>
#include "BluetoothSerial.h"

BluetoothSerial SerialBT;

// ===== NODE MAC ADDRESSES =====
uint8_t node1[] = {0x00,0x4B,0x12,0xEE,0x67,0xA4};
uint8_t node2[] = {0xCC,0x7B,0x5C,0xF1,0xEC,0x28};
uint8_t broadcastMAC[] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};

// =============================

typedef struct {
  char msg[100];
} Packet;

Packet data;
bool lastBtState = false;

void addPeer(uint8_t *mac) {
  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, mac, 6);
  peer.channel = 0;
  peer.encrypt = false;

  if (!esp_now_is_peer_exist(mac)) {
    esp_now_add_peer(&peer);
  }
}

void setup() {
  Serial.begin(115200);
  delay(1500);

  // ---------- Bluetooth ----------
  SerialBT.begin("ESP32-Gateway");
  Serial.println("📱 Bluetooth Ready. Connect from phone.");

  // ---------- ESP-NOW ----------
  WiFi.mode(WIFI_STA);

  if (esp_now_init() != ESP_OK) {
    Serial.println("❌ ESP-NOW Init Failed");
    return;
  }

  // Register peers
  addPeer(node1);
  addPeer(node2);
  addPeer(broadcastMAC);

  Serial.println("📡 ESP-NOW Ready");
  Serial.println("Use commands:");
  Serial.println("ALL:message");
  Serial.println("N1:message");
  Serial.println("N2:message");
}

void loop() {

  // ---- Bluetooth connection status ----
  bool connected = SerialBT.hasClient();
  if (connected != lastBtState) {
    Serial.println(connected ? "✅ Phone Connected" : "❌ Phone Disconnected");
    lastBtState = connected;
  }

  // ---- Read message from phone ----
  if (SerialBT.available()) {
    String raw = SerialBT.readStringUntil('\n');
    raw.trim();
    if (raw.length() == 0) return;

    uint8_t *targetMAC = nullptr;
    String message;

    if (raw.startsWith("ALL:")) {
      targetMAC = broadcastMAC;
      message = raw.substring(4);
    }
    else if (raw.startsWith("N1:")) {
      targetMAC = node1;
      message = raw.substring(3);
    }
    else if (raw.startsWith("N2:")) {
      targetMAC = node2;
      message = raw.substring(3);
    }
    else {
      Serial.println("⚠️ Invalid format. Use ALL:, N1:, N2:");
      return;
    }

    message.trim();
    message.toCharArray(data.msg, sizeof(data.msg));

    esp_err_t result = esp_now_send(targetMAC,
                                    (uint8_t *)&data,
                                    sizeof(data));

    // ---- Confirmation ----
    if (result == ESP_OK) {
      if (targetMAC == broadcastMAC) {
        Serial.println("📤 Sent to ALL nodes → " + message);
      }
      else if (targetMAC == node1) {
        Serial.println("📤 Sent to Node 1 → " + message);
      }
      else if (targetMAC == node2) {
        Serial.println("📤 Sent to Node 2 → " + message);
      }
    } else {
      Serial.println("❌ Send Failed");
    }
  }
}



in teammates its not showing anything update that to when the team member is on range it should show 