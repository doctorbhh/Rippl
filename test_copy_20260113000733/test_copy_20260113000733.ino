/*
 * Rippl ESP32 Mesh Node (Distance Vector Routing over ESP-NOW)
 * =============================================================
 * Smart routing like painlessMesh, but FAST with ESP-NOW!
 * 
 * Algorithm:
 * 1. Nodes exchange routing tables periodically
 * 2. Each node knows all other nodes and best path to them
 * 3. Messages forwarded only to nodes that haven't seen them
 * 4. Managed flooding prevents loops
 * 
 * Advantages over painlessMesh:
 * ✓ ESP-NOW = Connectionless, instant, low power
 * ✓ Binary structs = Fast, not JSON overhead
 * ✓ No TCP handshakes = Zero lag
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <WiFi.h>

// Forward declarations for Arduino IDE
struct MeshPacket;
struct RoutingEntry;

// ========== BLE UUIDs ==========
#define SERVICE_UUID    "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_TX_UUID    "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_RX_UUID    "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

// ========== Configuration ==========
#define SOS_BUTTON_PIN      0
#define LED_PIN             2
#define ESPNOW_CHANNEL      1
#define MAX_NODES           20      // Max nodes in network
#define MAX_HOPS            15      // Max hops for messages
#define MSG_HISTORY_SIZE    100     // Seen message IDs
#define ROUTE_UPDATE_MS     3000    // Exchange routing every 3s
#define NODE_TIMEOUT_MS     15000   // Node considered dead after 15s

// ========== Message Types ==========
#define PKT_ROUTE_UPDATE    0   // Routing table exchange
#define PKT_CHAT            1   // Chat message
#define PKT_SOS             2   // Emergency

// ========== Routing Table Entry ==========
struct RoutingEntry {
  uint16_t nodeId;          // Node's unique ID
  uint8_t mac[6];           // Node's MAC address
  int8_t rssi;              // Signal strength
  uint8_t hopCount;         // Hops to reach this node
  uint32_t lastSeen;        // millis() when last heard
  bool active;              // Is node reachable?
};

// ========== Routing Table ==========
RoutingEntry routingTable[MAX_NODES];
int nodeCount = 0;

// ========== Packet Structures ==========
// Route Update Packet (sent periodically)
struct RoutePacket {
  uint8_t type;             // PKT_ROUTE_UPDATE
  uint16_t senderId;        // Sender's node ID
  uint8_t senderMac[6];     // Sender's MAC
  uint8_t nodeCount;        // Number of known nodes
  uint16_t knownNodes[10];  // IDs of nodes I know about
} __attribute__((packed));

// Data Packet (chat/SOS)
struct MeshPacket {
  uint8_t type;             // PKT_CHAT or PKT_SOS
  uint32_t msgId;           // Unique message ID
  uint16_t originId;        // Original sender's node ID
  uint8_t hopCount;         // Current hop count
  uint8_t ttl;              // Time to live
  uint8_t visitedCount;     // Number of nodes visited
  uint16_t visitedNodes[10];// Node IDs that have seen this
  char sender[12];          // Sender name
  char message[60];         // Message content
} __attribute__((packed));

// ========== Globals ==========
BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
bool bleConnected = false;

String deviceName;
uint8_t myMac[6];
uint16_t myNodeId;
uint16_t msgCounter = 0;
uint32_t lastRouteUpdate = 0;

uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

// Message history
uint32_t seenMessages[MSG_HISTORY_SIZE];
uint8_t seenIndex = 0;

// ========== Helper Functions ==========
bool hasSeenMessage(uint32_t msgId) {
  for (int i = 0; i < MSG_HISTORY_SIZE; i++) {
    if (seenMessages[i] == msgId) return true;
  }
  return false;
}

void rememberMessage(uint32_t msgId) {
  seenMessages[seenIndex] = msgId;
  seenIndex = (seenIndex + 1) % MSG_HISTORY_SIZE;
}

uint32_t generateMsgId() {
  return ((uint32_t)myNodeId << 16) | (++msgCounter);
}

bool isVisitedNode(uint16_t nodeId, MeshPacket* pkt) {
  for (int i = 0; i < pkt->visitedCount && i < 10; i++) {
    if (pkt->visitedNodes[i] == nodeId) return true;
  }
  return false;
}

void addVisitedNode(uint16_t nodeId, MeshPacket* pkt) {
  if (pkt->visitedCount < 10) {
    pkt->visitedNodes[pkt->visitedCount++] = nodeId;
  }
}

// ========== Routing Table Functions ==========
int findNode(uint16_t nodeId) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (routingTable[i].active && routingTable[i].nodeId == nodeId) {
      return i;
    }
  }
  return -1;
}

int addOrUpdateNode(uint16_t nodeId, const uint8_t* mac, int8_t rssi, uint8_t hops) {
  // Don't add ourselves
  if (nodeId == myNodeId) return -1;
  
  int idx = findNode(nodeId);
  
  if (idx >= 0) {
    // Update existing
    routingTable[idx].rssi = rssi;
    routingTable[idx].lastSeen = millis();
    if (hops < routingTable[idx].hopCount) {
      routingTable[idx].hopCount = hops;  // Better path found
      memcpy(routingTable[idx].mac, mac, 6);
    }
    return idx;
  }
  
  // Find empty slot
  for (int i = 0; i < MAX_NODES; i++) {
    if (!routingTable[i].active) {
      routingTable[i].nodeId = nodeId;
      memcpy(routingTable[i].mac, mac, 6);
      routingTable[i].rssi = rssi;
      routingTable[i].hopCount = hops;
      routingTable[i].lastSeen = millis();
      routingTable[i].active = true;
      nodeCount++;
      
      // Add as ESP-NOW peer
      esp_now_peer_info_t peerInfo = {};
      memcpy(peerInfo.peer_addr, mac, 6);
      peerInfo.channel = ESPNOW_CHANNEL;
      peerInfo.encrypt = false;
      esp_now_add_peer(&peerInfo);
      
      Serial.printf("[ROUTE] New node: %04X (hop:%d, rssi:%d)\n", nodeId, hops, rssi);
      return i;
    }
  }
  return -1;  // Table full
}

void cleanupRoutingTable() {
  uint32_t now = millis();
  for (int i = 0; i < MAX_NODES; i++) {
    if (routingTable[i].active && (now - routingTable[i].lastSeen > NODE_TIMEOUT_MS)) {
      Serial.printf("[ROUTE] Node timeout: %04X\n", routingTable[i].nodeId);
      esp_now_del_peer(routingTable[i].mac);
      routingTable[i].active = false;
      nodeCount--;
    }
  }
}

void printRoutingTable() {
  Serial.printf("\n[ROUTING TABLE] %d nodes:\n", nodeCount);
  for (int i = 0; i < MAX_NODES; i++) {
    if (routingTable[i].active) {
      Serial.printf("  %04X: hop=%d rssi=%d\n", 
        routingTable[i].nodeId, routingTable[i].hopCount, routingTable[i].rssi);
    }
  }
  Serial.println();
}

// ========== Send Route Update ==========
void sendRouteUpdate() {
  RoutePacket pkt = {};
  pkt.type = PKT_ROUTE_UPDATE;
  pkt.senderId = myNodeId;
  memcpy(pkt.senderMac, myMac, 6);
  
  // Add known nodes to packet
  pkt.nodeCount = 0;
  for (int i = 0; i < MAX_NODES && pkt.nodeCount < 10; i++) {
    if (routingTable[i].active) {
      pkt.knownNodes[pkt.nodeCount++] = routingTable[i].nodeId;
    }
  }
  
  esp_now_send(broadcastAddress, (uint8_t*)&pkt, sizeof(pkt));
}

// ========== Send to Phone ==========
void sendToPhone(const char* json) {
  if (bleConnected && pTxCharacteristic) {
    pTxCharacteristic->setValue((uint8_t*)json, strlen(json));
    pTxCharacteristic->notify();
  }
}

// ========== Send New Message ==========
void sendNewMessage(uint8_t type, const char* sender, const char* msg) {
  MeshPacket pkt = {};
  pkt.type = type;
  pkt.msgId = generateMsgId();
  pkt.originId = myNodeId;
  pkt.hopCount = 0;
  pkt.ttl = MAX_HOPS;
  pkt.visitedCount = 0;
  addVisitedNode(myNodeId, &pkt);  // Mark self as visited
  strncpy(pkt.sender, sender, sizeof(pkt.sender) - 1);
  strncpy(pkt.message, msg, sizeof(pkt.message) - 1);
  
  rememberMessage(pkt.msgId);
  
  Serial.printf("[TX] %s: %s (ID:%08X)\n", sender, msg, pkt.msgId);
  
  // Broadcast to all neighbors
  esp_now_send(broadcastAddress, (uint8_t*)&pkt, sizeof(pkt));
}

// ========== Forward Message (Managed Flood) ==========
void forwardMessage(MeshPacket* pkt) {
  pkt->hopCount++;
  pkt->ttl--;
  
  if (pkt->ttl <= 0) {
    Serial.println("[FWD] TTL expired");
    return;
  }
  
  // Count unvisited neighbors
  int unvisited = 0;
  for (int i = 0; i < MAX_NODES; i++) {
    if (routingTable[i].active && !isVisitedNode(routingTable[i].nodeId, pkt)) {
      unvisited++;
    }
  }
  
  if (unvisited == 0) {
    Serial.println("[FWD] All neighbors visited, stopping flood");
    return;
  }
  
  // Small random delay to prevent collision
  delay(random(5, 30));
  
  // Broadcast (ESP-NOW handles delivery to all in range)
  esp_now_send(broadcastAddress, (uint8_t*)pkt, sizeof(MeshPacket));
  
  Serial.printf("[FWD] Hop %d, TTL %d, unvisited neighbors: %d\n", 
    pkt->hopCount, pkt->ttl, unvisited);
}

// ========== ESP-NOW Receive Callback ==========
void OnDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  int8_t rssi = info->rx_ctrl->rssi;
  
  // Check packet type from first byte
  uint8_t pktType = data[0];
  
  // ===== Route Update Packet =====
  if (pktType == PKT_ROUTE_UPDATE && len == sizeof(RoutePacket)) {
    RoutePacket* rpkt = (RoutePacket*)data;
    
    // Add/update direct neighbor
    addOrUpdateNode(rpkt->senderId, rpkt->senderMac, rssi, 1);
    
    // Learn about nodes this neighbor knows (2+ hops away)
    for (int i = 0; i < rpkt->nodeCount; i++) {
      if (rpkt->knownNodes[i] != myNodeId) {
        // We can reach this node via the sender (2 hops)
        int idx = findNode(rpkt->knownNodes[i]);
        if (idx < 0) {
          // New node we didn't know about
          addOrUpdateNode(rpkt->knownNodes[i], rpkt->senderMac, rssi, 2);
        }
      }
    }
    return;
  }
  
  // ===== Data Packet =====
  if ((pktType == PKT_CHAT || pktType == PKT_SOS) && len == sizeof(MeshPacket)) {
    MeshPacket* pkt = (MeshPacket*)data;
    
    // Check if already seen
    if (hasSeenMessage(pkt->msgId)) {
      return;
    }
    rememberMessage(pkt->msgId);
    
    // Check if we already visited (shouldn't happen, but safety check)
    if (isVisitedNode(myNodeId, pkt)) {
      return;
    }
    
    Serial.printf("[RX] %s: %s (ID:%08X, hop:%d, rssi:%d)\n", 
      pkt->sender, pkt->message, pkt->msgId, pkt->hopCount, rssi);
    
    // Flash LED
    digitalWrite(LED_PIN, HIGH);
    
    // Handle SOS
    if (pkt->type == PKT_SOS) {
      Serial.println("!!! SOS RECEIVED !!!");
    }
    
    // Send to phone
    if (bleConnected) {
      char json[200];
      snprintf(json, sizeof(json), 
        "{\"type\":%d,\"from\":\"%s\",\"msg\":\"%s\",\"hops\":%d,\"rssi\":%d}",
        pkt->type, pkt->sender, pkt->message, pkt->hopCount, rssi);
      sendToPhone(json);
    }
    
    // Mark self as visited
    addVisitedNode(myNodeId, pkt);
    
    // Forward to other nodes (managed flood)
    forwardMessage(pkt);
    
    digitalWrite(LED_PIN, LOW);
  }
}

void OnDataSent(const wifi_tx_info_t *info, esp_now_send_status_t status) {
  // Optional tracking
}

// ========== BLE Callbacks ==========
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    bleConnected = true;
    Serial.println("[BLE] Connected");
  }
  void onDisconnect(BLEServer* pServer) {
    bleConnected = false;
    Serial.println("[BLE] Disconnected");
    BLEDevice::startAdvertising();
  }
};

class MyRxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue();
    if (value.length() == 0) return;
    
    Serial.printf("[BLE RX] %s\n", value.c_str());
    
    String sender = deviceName;
    String message = value;
    int type = PKT_CHAT;
    
    if (value.indexOf("SOS") >= 0) {
      type = PKT_SOS;
      message = "EMERGENCY!";
    } else {
      int fs = value.indexOf("\"from\":\"");
      if (fs >= 0) {
        fs += 8;
        int fe = value.indexOf("\"", fs);
        if (fe > fs) sender = value.substring(fs, fe);
      }
      int ms = value.indexOf("\"msg\":\"");
      if (ms >= 0) {
        ms += 7;
        int me = value.indexOf("\"", ms);
        if (me > ms) message = value.substring(ms, me);
      }
    }
    
    sendNewMessage(type, sender.c_str(), message.c_str());
  }
};

// ========== SOS Button ==========
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
  attachInterrupt(digitalPinToInterrupt(SOS_BUTTON_PIN), sosButtonISR, FALLING);
  
  // Init WiFi for ESP-NOW
  WiFi.mode(WIFI_STA);
  delay(100);
  esp_wifi_get_mac(WIFI_IF_STA, myMac);
  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);
  
  // Create unique node ID from MAC
  myNodeId = (myMac[4] << 8) | myMac[5];
  
  deviceName = "Rippl-";
  deviceName += String(myNodeId, HEX);
  deviceName.toUpperCase();
  
  Serial.println("\n========================================");
  Serial.println("  Rippl Mesh (Distance Vector + ESP-NOW)");
  Serial.println("========================================");
  Serial.printf("Node ID: %04X\n", myNodeId);
  Serial.printf("MAC: %02X:%02X:%02X:%02X:%02X:%02X\n",
    myMac[0], myMac[1], myMac[2], myMac[3], myMac[4], myMac[5]);
  
  // Clear tables
  memset(routingTable, 0, sizeof(routingTable));
  memset(seenMessages, 0, sizeof(seenMessages));
  
  // Init ESP-NOW
  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW init failed!");
    return;
  }
  esp_now_register_recv_cb(OnDataRecv);
  esp_now_register_send_cb(OnDataSent);
  
  // Add broadcast peer
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, broadcastAddress, 6);
  peerInfo.channel = ESPNOW_CHANNEL;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);
  
  // Init BLE
  BLEDevice::init(deviceName.c_str());
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  
  BLEService* pService = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pService->createCharacteristic(CHAR_TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pTxCharacteristic->addDescriptor(new BLE2902());
  
  BLECharacteristic* pRxCharacteristic = pService->createCharacteristic(
    CHAR_RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pRxCharacteristic->setCallbacks(new MyRxCallbacks());
  
  pService->start();
  BLEDevice::getAdvertising()->addServiceUUID(SERVICE_UUID);
  BLEDevice::startAdvertising();
  
  Serial.println("BLE: " + deviceName);
  Serial.println("\n✓ Distance Vector routing enabled!");
  Serial.println("✓ Route updates every 3 seconds");
  Serial.println("✓ Type 'routes' to see routing table");
  Serial.println("========================================\n");
  
  // Initial route broadcast
  sendRouteUpdate();
}

// ========== Loop ==========
void loop() {
  uint32_t now = millis();
  
  // Periodic route updates
  if (now - lastRouteUpdate > ROUTE_UPDATE_MS) {
    lastRouteUpdate = now;
    sendRouteUpdate();
    cleanupRoutingTable();
  }
  
  // SOS button
  if (sosTriggered) {
    sosTriggered = false;
    Serial.println("!!! SOS !!!");
    sendNewMessage(PKT_SOS, deviceName.c_str(), "EMERGENCY!");
  }
  
  // Serial commands
  if (Serial.available()) {
    String input = Serial.readStringUntil('\n');
    input.trim();
    if (input.length() > 0) {
      if (input.equalsIgnoreCase("SOS")) {
        sendNewMessage(PKT_SOS, deviceName.c_str(), "EMERGENCY!");
      } else if (input == "routes" || input == "nodes") {
        printRoutingTable();
      } else if (input == "clear") {
        memset(seenMessages, 0, sizeof(seenMessages));
        Serial.println("Message history cleared");
      } else {
        sendNewMessage(PKT_CHAT, deviceName.c_str(), input.c_str());
      }
    }
  }
  
  delay(1);
}
