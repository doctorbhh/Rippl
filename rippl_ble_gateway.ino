/*
 * Rippl ESP32 BLE Gateway (Simplified)
 * 
 * BLE-only version for phone connection.
 * ESP-NOW mesh can be added later once BLE works.
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ========== BLE UUIDs (must match Flutter app) ==========
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define TX_CHARACTERISTIC   "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define RX_CHARACTERISTIC   "beb5483e-36e1-4688-b7f5-ea07361b26a9"

// ========== Global Variables ==========
BLEServer* pServer = NULL;
BLECharacteristic* pTxCharacteristic = NULL;
BLECharacteristic* pRxCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// ========== BLE Callbacks ==========
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("Phone Connected via BLE");
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("Phone Disconnected");
  }
};

class TxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue();
    if (value.length() > 0) {
      Serial.print("Received from phone: ");
      Serial.println(value.c_str());
      
      // Echo back for testing
      if (pRxCharacteristic != NULL && deviceConnected) {
        String response = "Echo: " + value;
        pRxCharacteristic->setValue(response.c_str());
        pRxCharacteristic->notify();
        Serial.println("Sent echo back to phone");
      }
    }
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println();
  Serial.println("========================================");
  Serial.println("   Rippl ESP32 BLE Gateway");
  Serial.println("========================================");
  Serial.println();
  
  // Initialize BLE
  BLEDevice::init("Rippl-Gateway");
  
  // Create BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  
  // Create BLE Service
  BLEService* pService = pServer->createService(SERVICE_UUID);
  
  // TX Characteristic - Phone writes here
  pTxCharacteristic = pService->createCharacteristic(
    TX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pTxCharacteristic->setCallbacks(new TxCallbacks());
  
  // RX Characteristic - Phone reads/gets notified here
  pRxCharacteristic = pService->createCharacteristic(
    RX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pRxCharacteristic->addDescriptor(new BLE2902());
  
  // Start service
  pService->start();
  
  // Start advertising
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  BLEDevice::startAdvertising();
  
  Serial.println("BLE Server started!");
  Serial.println("Device name: Rippl-Gateway");
  Serial.println("Waiting for phone connection...");
  Serial.println();
}

void loop() {
  // Handle reconnection
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("Restarting advertising...");
    oldDeviceConnected = deviceConnected;
  }
  
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
  
  delay(20);
}
