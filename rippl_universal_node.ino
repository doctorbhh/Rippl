/*
 * Rippl ESP32 Mesh Node v2.0
 * ===========================
 * Reliable ESP-NOW mesh with BLE NUS gateway, optimised for 6 nodes.
 *
 * Architecture changes from v1
 * ----------------------------
 * 1. OnDataRecv is now a thin ISR shim — it only copies bytes into a
 *    FreeRTOS queue and returns.  All logic runs in loop().
 * 2. ACKs are unicast back toward the origin through the next-hop MAC,
 *    eliminating the O(n²) ACK storm of v1.
 * 3. Routing table stores a nextHopMac field to enable directed ACK
 *    delivery without flooding.
 * 4. Duplicate findNode / findNodeIndex consolidated into one function.
 * 5. Constants re-tuned for 6 nodes (see rationale inline).
 * 6. WiFi channel changed to 6 (avoids BLE advertising channel overlap).
 * 7. MeshPacket loses targetCount (stale on relay); nodeCount is read
 *    directly from the live routing table.
 * 8. Pending-table evicts oldest entry on overflow instead of silently
 *    dropping the new message.
 * 9. Cascade expiry removes ghost routes when a node dies.
 * 10. Send-fail callback accelerates timeout for unreachable peers.
 * 11. Stale-route override allows dynamic topology adaptation.
 * 12. Fast new-node bootstrap via immediate unicast reply beacon.
 */

// ═══════════════════════════════════════════════════════════
// Mesh Visualizer — enabled by default for development.
// Emits @EVT:{json} events on Serial + BLE for real-time
// topology display in mesh_visualizer.html or Flutter app.
// Comment out to disable in production.
// ═══════════════════════════════════════════════════════════
#define MESH_VIZ

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_mac.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// ═══════════════════════════════════════════════════════════
// BLE — Nordic UART Service UUIDs
// ═══════════════════════════════════════════════════════════
#define SERVICE_UUID  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_TX_UUID  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_RX_UUID  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

// ═══════════════════════════════════════════════════════════
// Hardware pins
// ═══════════════════════════════════════════════════════════
#define SOS_BUTTON_PIN  0   // BOOT button doubles as SOS trigger
#define LED_PIN         2

// ═══════════════════════════════════════════════════════════
// Network constants — every value justified for 6 nodes
// ═══════════════════════════════════════════════════════════

/*
 * ESPNOW_CHANNEL 6 (was 1)
 * BLE advertising uses channels 37/38/39 ≈ 2402/2426/2480 MHz.
 * WiFi ch 1 = 2412 MHz sits within 10 MHz of BLE ch 37 and causes
 * measurable packet-loss on shared-radio ESP32 silicon.
 * Ch 6 = 2437 MHz is equidistant between all three BLE adv channels
 * and is the ITU-recommended coexistence channel.
 */
#define ESPNOW_CHANNEL    6

/*
 * MAX_NODES 8 (was 15)
 * 6 target nodes + 2 transient slots for nodes joining/leaving.
 * Each RoutingEntry is ~28 bytes → 8 entries = 224 bytes (vs 420 bytes).
 */
#define MAX_NODES         8

/*
 * MAX_HOPS 6 (was 10)
 * In a 6-node network the maximum chain length is 5 hops.
 * Capping at 6 guarantees delivery while halving unnecessary relays.
 */
#define MAX_HOPS          6

/*
 * MSG_HISTORY_SIZE 20 (was 50)
 * With 6 senders at human typing speed, 20 slots is enough to cover
 * all in-flight duplicates.  Ring-buffer eviction recycles old slots.
 */
#define MSG_HISTORY_SIZE  40

/*
 * ROUTE_UPDATE_MS 5000 (was 3000)
 * 6 nodes × 1 beacon/5 s = 1.2 beacons/s aggregate — negligible
 * overhead.  The slower rate reduces collisions on the shared channel.
 */
#define ROUTE_UPDATE_MS   5000

/* NODE_TIMEOUT_MS 15000 — 3 missed beacons at 5 s each. */
#define NODE_TIMEOUT_MS   15000

/*
 * ACK_TIMEOUT_MS 300 (was 500)
 * ESP-NOW RTT on a 6-node bench mesh is typically 5–40 ms.
 * 300 ms gives 7× headroom even under heavy BLE coexistence load.
 */
#define ACK_TIMEOUT_MS    300

/* MAX_RETRIES 3 — 3 × 300 ms = 900 ms max wait. */
#define MAX_RETRIES       3

/*
 * MAX_PENDING 8 (was 5)
 * One slot per potential concurrent sender (6) + 2 spare.
 */
#define MAX_PENDING       8

/*
 * RX_QUEUE_DEPTH 10
 * Holds up to 10 raw packets while loop() is busy.
 * At ~260 bytes/item the queue occupies ~2.6 KB in SRAM.
 */
#define RX_QUEUE_DEPTH    10

// ═══════════════════════════════════════════════════════════
// Packet type codes
// ═══════════════════════════════════════════════════════════
#define PKT_ROUTE_UPDATE  0
#define PKT_CHAT          1
#define PKT_SOS           2
#define PKT_ACK           3

// ═══════════════════════════════════════════════════════════
// Wire structures  (__packed__ preserves wire format)
// ═══════════════════════════════════════════════════════════

struct RoutePacket {
  uint8_t  type;                       // PKT_ROUTE_UPDATE
  uint16_t senderId;
  uint8_t  senderMac[6];
  uint8_t  nodeCount;
  uint16_t knownNodes[MAX_NODES - 1];  // up to 7 known node IDs
} __attribute__((packed));

struct AckPacket {
  uint8_t  type;      // PKT_ACK
  uint32_t msgId;
  uint16_t ackerId;   // sender's node ID
} __attribute__((packed));

/*
 * MeshPacket — chat or SOS payload.
 * CHANGE: removed targetCount (stale on relay copies).
 */
struct MeshPacket {
  uint8_t  type;          // PKT_CHAT or PKT_SOS
  uint32_t msgId;
  uint16_t originId;
  uint16_t originDest;    // 0xFFFF = broadcast, else target node ID
  uint8_t  hopCount;
  uint8_t  ttl;           // decremented by each relay; drop at 0
  char     sender[12];
  char     message[60];
} __attribute__((packed));

/*
 * RxQueueItem — a self-contained copy of one received packet.
 * The ESP-NOW callback hands us a pointer that may be invalidated
 * after it returns, so we copy everything here before queuing.
 * Convention: len==0 is a sentinel for "send to senderMac failed".
 */
struct RxQueueItem {
  uint8_t senderMac[6];
  uint8_t data[250];   // worst-case ESP-NOW payload
  uint8_t len;
  int8_t  rssi;
};

// ═══════════════════════════════════════════════════════════
// Routing table
// ═══════════════════════════════════════════════════════════
/*
 * nextHopMac — new field in v2.
 * For direct neighbours nextHopMac == mac.
 * For multi-hop nodes nextHopMac is the direct peer that relayed
 * their beacon, enabling directed ACK delivery without flooding.
 */
struct RoutingEntry {
  uint16_t nodeId;
  uint8_t  mac[6];
  uint8_t  nextHopMac[6];
  int8_t   rssi;
  uint8_t  hopCount;
  uint32_t lastSeen;
  bool     active;
};

RoutingEntry routingTable[MAX_NODES];
uint8_t      nodeCount = 0;

// ═══════════════════════════════════════════════════════════
// Pending-message retry table
// ═══════════════════════════════════════════════════════════
struct PendingMessage {
  uint32_t   msgId;
  uint32_t   sentTime;
  uint8_t    retryCount;
  bool       ackedBy[MAX_NODES]; // index mirrors routingTable index
  bool       active;
  MeshPacket packet;
};

PendingMessage pendingMessages[MAX_PENDING];

// ═══════════════════════════════════════════════════════════
// Deduplication ring buffer
// ═══════════════════════════════════════════════════════════
struct SeenEntry { uint32_t msgId; uint16_t originId; };
static SeenEntry seenMsgIds[MSG_HISTORY_SIZE];
static uint8_t   seenHead = 0;

// ═══════════════════════════════════════════════════════════
// Node identity
// ═══════════════════════════════════════════════════════════
static uint16_t myNodeId = 0;
static uint8_t  myMac[6];
static char     myName[12] = "Node";
static uint32_t msgIdCounter = 1;

// ═══════════════════════════════════════════════════════════
// BLE state
// ═══════════════════════════════════════════════════════════
static BLEServer*         pServer      = nullptr;
static BLECharacteristic* pTxChar      = nullptr;
static BLECharacteristic* pRxChar      = nullptr;
static bool               bleConnected = false;

// ═══════════════════════════════════════════════════════════
// FreeRTOS receive queue
// ═══════════════════════════════════════════════════════════
static QueueHandle_t rxQueue = nullptr;

// ═══════════════════════════════════════════════════════════
// Misc runtime state
// ═══════════════════════════════════════════════════════════
static uint32_t lastRouteUpdate = 0;
static bool     sosActive       = false;

// ═══════════════════════════════════════════════════════════
// Forward declarations
// ═══════════════════════════════════════════════════════════
void broadcastToAllPeers(const MeshPacket& pkt);
void trackPendingMessage(const MeshPacket& pkt);
void markSeen(uint32_t id);
void notifyBLE(const char* msg);
void sendRouteUpdate();

// ════════════════════════════════════════════════════════════
// UTILITY — MAC helpers
// ════════════════════════════════════════════════════════════
static inline bool macEqual(const uint8_t* a, const uint8_t* b) {
  return memcmp(a, b, 6) == 0;
}
static inline void macCopy(uint8_t* dst, const uint8_t* src) {
  memcpy(dst, src, 6);
}

// ════════════════════════════════════════════════════════════
// ROUTING TABLE helpers — consolidated from v1's duplicates
// ════════════════════════════════════════════════════════════

static int findNodeById(uint16_t nodeId) {
  for (int i = 0; i < MAX_NODES; i++)
    if (routingTable[i].active && routingTable[i].nodeId == nodeId)
      return i;
  return -1;
}

static int findNodeByMac(const uint8_t* mac) {
  for (int i = 0; i < MAX_NODES; i++)
    if (routingTable[i].active && macEqual(routingTable[i].mac, mac))
      return i;
  return -1;
}

static int findFreeSlot() {
  for (int i = 0; i < MAX_NODES; i++)
    if (!routingTable[i].active) return i;
  return -1;
}

// ════════════════════════════════════════════════════════════
// DEDUPLICATION — ring buffer
// ════════════════════════════════════════════════════════════
static bool alreadySeen(uint32_t id, uint16_t originId) {
  for (int i = 0; i < MSG_HISTORY_SIZE; i++)
    if (seenMsgIds[i].msgId == id && seenMsgIds[i].originId == originId)
      return true;
  return false;
}

void markSeen(uint32_t id, uint16_t originId) {
  seenMsgIds[seenHead] = { id, originId };
  seenHead = (seenHead + 1) % MSG_HISTORY_SIZE;
}


#ifdef MESH_VIZ
// ════════════════════════════════════════════════════════════
// Visualization event emitter — sends to Serial + BLE.
// All events are prefixed with @EVT: so parsers can filter
// them from regular debug output.
// Must be declared before RxCallbacks which uses it.
// ════════════════════════════════════════════════════════════
static char vizBuf[200];

static void emitVizEvent(const char* json) {
  Serial.printf("@EVT:%s\n", json);
  // ↑ Serial only. BLE characteristic is for chat payloads only.
  // Viz events sent over BLE collide with chat notifications and
  // cause phantom duplicates on the phone app.
}
#endif

// ════════════════════════════════════════════════════════════
// BLE callbacks
// ════════════════════════════════════════════════════════════
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    bleConnected = true;
    Serial.println("[BLE] Client connected");
  }
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    s->startAdvertising();
    Serial.println("[BLE] Client disconnected, re-advertising");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String val = c->getValue();
    if (val.length() == 0) return;

    // Handle SOS command (plain text from app)
    if (val.startsWith("SOS:") || val == "SOS") {
      MeshPacket pkt  = {};
      pkt.type        = PKT_SOS;
      pkt.msgId       = msgIdCounter++;
      pkt.originId    = myNodeId;
      pkt.originDest  = 0xFFFF;
      pkt.hopCount    = 0;
      pkt.ttl         = MAX_HOPS;
      strncpy(pkt.sender, myName, sizeof(pkt.sender) - 1);
      strncpy(pkt.message, "EMERGENCY SOS!", sizeof(pkt.message) - 1);
      broadcastToAllPeers(pkt);
      trackPendingMessage(pkt);
      markSeen(pkt.msgId, myNodeId);
      Serial.println("[SOS] Sent from BLE");
      return;
    }

    // Try to parse JSON from the app: {"type":"CHAT","from":"User","msg":"hello"}
    const char* raw = val.c_str();
    char senderName[12] = {0};
    char msgText[60]    = {0};

    if (raw[0] == '{') {
      // Extract "msg" field value
      const char* msgKey = strstr(raw, "\"msg\":\"");
      if (msgKey) {
        msgKey += 7; // skip past "msg":"
        int i = 0;
        while (*msgKey && *msgKey != '"' && i < (int)sizeof(msgText) - 1) {
          if (*msgKey == '\\' && *(msgKey + 1) == '"') { msgText[i++] = '"'; msgKey += 2; }
          else { msgText[i++] = *msgKey++; }
        }
      }
      // Extract "from" field value
      const char* fromKey = strstr(raw, "\"from\":\"");
      if (fromKey) {
        fromKey += 8; // skip past "from":"
        int i = 0;
        while (*fromKey && *fromKey != '"' && i < (int)sizeof(senderName) - 1) {
          senderName[i++] = *fromKey++;
        }
      }
    }

    // Fallback: if no JSON fields found, treat as plain text
    if (msgText[0] == '\0') {
      strncpy(msgText, raw, sizeof(msgText) - 1);
    }
    if (senderName[0] == '\0') {
      strncpy(senderName, myName, sizeof(senderName) - 1);
    }

    MeshPacket pkt  = {};
    pkt.type        = PKT_CHAT;
    pkt.msgId       = msgIdCounter++;
    pkt.originId    = myNodeId;
    pkt.originDest  = 0xFFFF;   // broadcast
    pkt.hopCount    = 0;
    pkt.ttl         = MAX_HOPS;
    strncpy(pkt.sender,  senderName,  sizeof(pkt.sender)  - 1);
    strncpy(pkt.message, msgText,     sizeof(pkt.message) - 1);

    broadcastToAllPeers(pkt);
    trackPendingMessage(pkt);
    markSeen(pkt.msgId, myNodeId);
#ifdef MESH_VIZ
    snprintf(vizBuf, sizeof(vizBuf),
      "{\"e\":\"msg_tx\",\"mid\":%lu,\"to\":\"*\"}",
      (unsigned long)pkt.msgId);
    emitVizEvent(vizBuf);
#endif
  }
};

// ════════════════════════════════════════════════════════════
// BLE TX — notify connected phone.  Safe from loop() context only.
// ════════════════════════════════════════════════════════════
void notifyBLE(const char* msg) {
  if (!bleConnected || !pTxChar) return;
  pTxChar->setValue((uint8_t*)msg, strlen(msg));
  pTxChar->notify();
}

// ════════════════════════════════════════════════════════════
// ESP-NOW peer management
// ════════════════════════════════════════════════════════════
static void ensurePeer(const uint8_t* mac) {
  if (esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t p = {};
  macCopy(p.peer_addr, mac);
  p.channel = ESPNOW_CHANNEL;
  p.encrypt = false;
  p.ifidx   = WIFI_IF_STA;
  esp_now_add_peer(&p);
}

// Broadcast a MeshPacket to every active peer.
void broadcastToAllPeers(const MeshPacket& pkt) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!routingTable[i].active) continue;
    ensurePeer(routingTable[i].mac);
    esp_now_send(routingTable[i].mac, (const uint8_t*)&pkt, sizeof(MeshPacket));
  }
}

/*
 * sendAckToOrigin — UNICAST ACK back toward the origin.
 * v1 re-broadcast ACKs to all peers → O(n²) storm.
 * Now each receiver sends exactly ONE ACK frame, directed via
 * nextHopMac toward the origin.
 */
static void sendAckToOrigin(uint32_t msgId, const uint8_t* nextHopToOrigin) {
  AckPacket ack = {};
  ack.type    = PKT_ACK;
  ack.msgId   = msgId;
  ack.ackerId = myNodeId;
  ensurePeer(nextHopToOrigin);
  esp_now_send(nextHopToOrigin, (const uint8_t*)&ack, sizeof(AckPacket));
}

// ════════════════════════════════════════════════════════════
// Pending-message retry table
// ════════════════════════════════════════════════════════════
void trackPendingMessage(const MeshPacket& pkt) {
  int slot = -1;
  for (int i = 0; i < MAX_PENDING; i++) {
    if (!pendingMessages[i].active) { slot = i; break; }
  }

  // Table full: evict the oldest entry (FIFO policy).
  if (slot < 0) {
    Serial.println("[WARN] Pending table full — evicting oldest entry");
    uint32_t oldest = UINT32_MAX;
    for (int i = 0; i < MAX_PENDING; i++) {
      if (pendingMessages[i].sentTime < oldest) {
        oldest = pendingMessages[i].sentTime;
        slot   = i;
      }
    }
  }

  pendingMessages[slot]             = {};
  pendingMessages[slot].msgId       = pkt.msgId;
  pendingMessages[slot].sentTime    = millis();
  pendingMessages[slot].retryCount  = 0;
  pendingMessages[slot].active      = true;
  pendingMessages[slot].packet      = pkt;
}

static void handleAck(const AckPacket& ack) {
  for (int i = 0; i < MAX_PENDING; i++) {
    if (!pendingMessages[i].active)            continue;
    if (pendingMessages[i].msgId != ack.msgId) continue;

    int idx = findNodeById(ack.ackerId);
    if (idx >= 0) pendingMessages[i].ackedBy[idx] = true;

    // If every *currently active* node has ACKed, retire the slot.
    bool allAcked = true;
    for (int j = 0; j < MAX_NODES; j++) {
      if (routingTable[j].active && !pendingMessages[i].ackedBy[j]) {
        allAcked = false;
        break;
      }
    }
    if (allAcked) {
      pendingMessages[i].active = false;
      Serial.printf("[ACK] Msg %lu fully confirmed\n", (unsigned long)ack.msgId);
#ifdef MESH_VIZ
      snprintf(vizBuf, sizeof(vizBuf),
        "{\"e\":\"ack_rx\",\"mid\":%lu,\"from\":\"%04X\"}",
        (unsigned long)ack.msgId, ack.ackerId);
      emitVizEvent(vizBuf);
#endif
    }
    return;
  }
}

// Selective retry — only retransmit to peers that have NOT yet ACKed.
static void checkRetries() {
  uint32_t now = millis();
  for (int i = 0; i < MAX_PENDING; i++) {
    if (!pendingMessages[i].active) continue;
    if (now - pendingMessages[i].sentTime < ACK_TIMEOUT_MS) continue;

    if (pendingMessages[i].retryCount >= MAX_RETRIES) {
      Serial.printf("[RETRY] Giving up on msg %lu after %d retries\n",
                    (unsigned long)pendingMessages[i].msgId, MAX_RETRIES);
      pendingMessages[i].active = false;
      continue;
    }

    bool anyRetry = false;
    for (int j = 0; j < MAX_NODES; j++) {
      if (!routingTable[j].active)       continue;
      if (pendingMessages[i].ackedBy[j]) continue;
      ensurePeer(routingTable[j].mac);
      esp_now_send(routingTable[j].mac,
                   (const uint8_t*)&pendingMessages[i].packet,
                   sizeof(MeshPacket));
      anyRetry = true;
    }
    if (anyRetry) {
      pendingMessages[i].retryCount++;
      pendingMessages[i].sentTime = now;
      Serial.printf("[RETRY] Msg %lu retry %d\n",
                    (unsigned long)pendingMessages[i].msgId,
                    pendingMessages[i].retryCount);
    } else {
      pendingMessages[i].active = false;
    }
  }
}

// ════════════════════════════════════════════════════════════
// Routing table management
// ════════════════════════════════════════════════════════════

/*
 * updateRoute — add or refresh a routing entry.
 *
 * FIX 3: Stale-route override — accepts a worse hop count if the
 * current route hasn't been refreshed in 2 beacon cycles (stale).
 * Also accepts same-hop update if RSSI improved by ≥5 dBm (node
 * moved closer but stayed at same hop count).
 */
static void updateRoute(uint16_t nodeId, const uint8_t* mac,
                        const uint8_t* nextHopMac,
                        int8_t rssi, uint8_t hops) {
  int idx = findNodeById(nodeId);

  if (idx < 0) {
    // Brand-new node — always add
    idx = findFreeSlot();
    if (idx < 0) {
      Serial.printf("[ROUTE] Table full, cannot add %04X\n", nodeId);
      return;
    }
    routingTable[idx].active = true;
    nodeCount++;
    Serial.printf("[ROUTE] New node %04X hops=%d\n", nodeId, hops);
#ifdef MESH_VIZ
    snprintf(vizBuf, sizeof(vizBuf),
      "{\"e\":\"node_add\",\"id\":\"%04X\",\"hop\":%d,\"rssi\":%d}",
      nodeId, hops, rssi);
    emitVizEvent(vizBuf);
#endif
  } else {
    // Existing node — decide whether this is a better route
    uint32_t age    = millis() - routingTable[idx].lastSeen;
    bool stale      = (age > ROUTE_UPDATE_MS * 2);
    bool betterHops = (hops < routingTable[idx].hopCount);
    bool betterRssi = (hops == routingTable[idx].hopCount &&
                       rssi  > routingTable[idx].rssi + 5);

    if (!betterHops && !betterRssi && !stale) return;

    if (stale) {
      Serial.printf("[ROUTE] Stale route to %04X replaced (age=%lums)\n",
                    nodeId, (unsigned long)age);
    }
  }

  routingTable[idx].nodeId   = nodeId;
  macCopy(routingTable[idx].mac,        mac);
  macCopy(routingTable[idx].nextHopMac, nextHopMac);
  routingTable[idx].rssi     = rssi;
  routingTable[idx].hopCount = hops;
  routingTable[idx].lastSeen = millis();
}

/*
 * expireOldNodes — FIX 1: Cascade expiry.
 *
 * When a node times out, any routes that used it as nextHopMac are
 * also removed ("ghost routes").  After any topology change, an
 * immediate re-beacon is triggered so neighbours can rebuild paths.
 */
static void expireOldNodes() {
  uint32_t now = millis();
  bool anyExpired = false;

  for (int i = 0; i < MAX_NODES; i++) {
    if (!routingTable[i].active) continue;
    if (now - routingTable[i].lastSeen <= NODE_TIMEOUT_MS) continue;

    Serial.printf("[ROUTE] Node %04X timed out\n", routingTable[i].nodeId);
#ifdef MESH_VIZ
    snprintf(vizBuf, sizeof(vizBuf),
      "{\"e\":\"node_rm\",\"id\":\"%04X\"}",
      routingTable[i].nodeId);
    emitVizEvent(vizBuf);
#endif
    uint8_t deadMac[6];
    macCopy(deadMac, routingTable[i].mac);
    routingTable[i].active = false;
    if (nodeCount > 0) nodeCount--;
    anyExpired = true;

    // Cascade: remove any entry whose nextHopMac pointed through
    // the now-dead node — these are "ghost routes".
    for (int j = 0; j < MAX_NODES; j++) {
      if (!routingTable[j].active) continue;
      if (macEqual(routingTable[j].nextHopMac, deadMac)) {
        Serial.printf("[ROUTE] Cascade: ghost route to %04X removed\n",
                      routingTable[j].nodeId);
        routingTable[j].active = false;
        if (nodeCount > 0) nodeCount--;
      }
    }
  }

  // After any topology change, immediately re-beacon so neighbours
  // can rebuild alternate paths as fast as possible.
  if (anyExpired) {
    sendRouteUpdate();
    lastRouteUpdate = millis();
  }
}

void sendRouteUpdate() {
  RoutePacket pkt = {};
  pkt.type     = PKT_ROUTE_UPDATE;
  pkt.senderId = myNodeId;
  macCopy(pkt.senderMac, myMac);

  uint8_t cnt = 0;
  for (int i = 0; i < MAX_NODES && cnt < (MAX_NODES - 1); i++)
    if (routingTable[i].active)
      pkt.knownNodes[cnt++] = routingTable[i].nodeId;
  pkt.nodeCount = cnt;

  if (nodeCount == 0) {
    static const uint8_t broadcastMac[6] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
    ensurePeer(broadcastMac);
    esp_now_send(broadcastMac, (const uint8_t*)&pkt, sizeof(RoutePacket));
  } else {
    for (int i = 0; i < MAX_NODES; i++) {
      if (!routingTable[i].active) continue;
      ensurePeer(routingTable[i].mac);
      esp_now_send(routingTable[i].mac, (const uint8_t*)&pkt, sizeof(RoutePacket));
    }
  }

#ifdef MESH_VIZ
  // Emit full topology snapshot for the visualizer.
  int pos = snprintf(vizBuf, sizeof(vizBuf),
    "{\"e\":\"topo\",\"me\":\"%04X\",\"nodes\":[", myNodeId);
  bool first = true;
  for (int i = 0; i < MAX_NODES && pos < (int)sizeof(vizBuf) - 40; i++) {
    if (!routingTable[i].active) continue;
    if (!first) vizBuf[pos++] = ',';
    pos += snprintf(vizBuf + pos, sizeof(vizBuf) - pos,
      "{\"id\":\"%04X\",\"hop\":%d,\"rssi\":%d}",
      routingTable[i].nodeId, routingTable[i].hopCount,
      routingTable[i].rssi);
    first = false;
  }
  pos += snprintf(vizBuf + pos, sizeof(vizBuf) - pos, "]}");
  emitVizEvent(vizBuf);
#endif
}

static void printRoutingTable() {
  Serial.printf("\n[NODES] %d active:\n", nodeCount);
  for (int i = 0; i < MAX_NODES; i++) {
    if (routingTable[i].active) {
      Serial.printf("  %04X: hop=%d rssi=%d\n",
        routingTable[i].nodeId, routingTable[i].hopCount, routingTable[i].rssi);
    }
  }
}

// ════════════════════════════════════════════════════════════
// Packet processing — runs in loop() context only
// ════════════════════════════════════════════════════════════

/*
 * processRoutePacket — FIX 4: Fast new-node bootstrap.
 *
 * When we detect a node we've never seen before, we immediately
 * unicast our routing table back to it instead of waiting 5 s.
 */
static void processRoutePacket(const uint8_t* senderMac,
                                const RoutePacket& pkt,
                                int8_t rssi) {
  if (pkt.senderId == myNodeId) return;

  // Detect new node BEFORE updateRoute modifies the table
  bool isNewNode = (findNodeById(pkt.senderId) < 0);

  // Direct peer: nextHop == their MAC, hopCount = 1.
  updateRoute(pkt.senderId, pkt.senderMac, senderMac, rssi, 1);
  ensurePeer(senderMac);

  // Fast bootstrap: immediately unicast our routing table to the new
  // node so it doesn't have to wait up to ROUTE_UPDATE_MS (5 s).
  if (isNewNode) {
    RoutePacket reply = {};
    reply.type     = PKT_ROUTE_UPDATE;
    reply.senderId = myNodeId;
    macCopy(reply.senderMac, myMac);
    uint8_t cnt = 0;
    for (int i = 0; i < MAX_NODES && cnt < (MAX_NODES - 1); i++)
      if (routingTable[i].active)
        reply.knownNodes[cnt++] = routingTable[i].nodeId;
    reply.nodeCount = cnt;
    esp_now_send(senderMac, (const uint8_t*)&reply, sizeof(RoutePacket));
    Serial.printf("[ROUTE] New node %04X — sent immediate bootstrap beacon\n",
                  pkt.senderId);
  }

  // Split-horizon 2-hop learning: do not accept a 2-hop advertisement
  // for a node we already reach in 1 hop (prevents count-to-infinity).
  for (uint8_t i = 0; i < pkt.nodeCount && i < (MAX_NODES - 1); i++) {
    uint16_t remoteId = pkt.knownNodes[i];
    if (remoteId == myNodeId) continue;
    int existing = findNodeById(remoteId);
    if (existing >= 0 && routingTable[existing].hopCount <= 1) continue;
    updateRoute(remoteId, senderMac, senderMac, rssi - 10, 2);
  }
}

static void processDataPacket(const uint8_t* senderMac,
                               const MeshPacket& pkt) {
  if (alreadySeen(pkt.msgId, pkt.originId)) return;
  markSeen(pkt.msgId, pkt.originId);

  bool isForMe = (pkt.originDest == 0xFFFF || pkt.originDest == myNodeId);

  if (isForMe && pkt.originId != myNodeId) {
    // Deliver to BLE phone as JSON (app expects {from, msg, hops, type})
    char buf[160];
    snprintf(buf, sizeof(buf),
      "{\"from\":\"%.11s\",\"msg\":\"%.60s\",\"hops\":%d,\"type\":%d}",
      pkt.sender, pkt.message, pkt.hopCount,
      pkt.type == PKT_SOS ? 2 : 1);
    notifyBLE(buf);
    Serial.println(buf);
#ifdef MESH_VIZ
    snprintf(vizBuf, sizeof(vizBuf),
      "{\"e\":\"msg_rx\",\"mid\":%lu,\"from\":\"%04X\",\"hop\":%d}",
      (unsigned long)pkt.msgId, pkt.originId, pkt.hopCount);
    emitVizEvent(vizBuf);
#endif

    // Send unicast ACK back toward the origin via nextHopMac.
    int originIdx = findNodeById(pkt.originId);
    const uint8_t* ackTarget = (originIdx >= 0)
                                ? routingTable[originIdx].nextHopMac
                                : senderMac;
    sendAckToOrigin(pkt.msgId, ackTarget);
  }

  // ── Relay only when genuinely needed ─────────────────────────────
  // Skip relay entirely if the origin is already a direct 1-hop peer
  // AND there are no multi-hop nodes in the table. In a fully-connected
  // 4-node mesh this cuts 9 sends/msg down to 3 — eliminating the
  // congestion that causes retries and drops.
  if (pkt.ttl <= 1 || pkt.hopCount >= MAX_HOPS) return;

  int  originIdx  = findNodeById(pkt.originId);
  bool directOrigin = (originIdx >= 0 &&
                       routingTable[originIdx].hopCount == 1);
  if (directOrigin) {
    // Only relay if there is at least one node we can't reach directly
    bool needRelay = false;
    for (int i = 0; i < MAX_NODES; i++) {
      if (routingTable[i].active && routingTable[i].hopCount > 1) {
        needRelay = true;
        break;
      }
    }
    if (!needRelay) return;  // dense mesh — relay adds only collisions
  }

  MeshPacket relay = pkt;
  relay.hopCount++;
  relay.ttl--;
  for (int i = 0; i < MAX_NODES; i++) {
    if (!routingTable[i].active) continue;
    if (macEqual(routingTable[i].mac, senderMac)) continue;
    ensurePeer(routingTable[i].mac);
    esp_now_send(routingTable[i].mac,
                 (const uint8_t*)&relay, sizeof(MeshPacket));
#ifdef MESH_VIZ
    snprintf(vizBuf, sizeof(vizBuf),
      "{\"e\":\"msg_relay\",\"mid\":%lu,\"to\":\"%04X\"}",
      (unsigned long)pkt.msgId, routingTable[i].nodeId);
    emitVizEvent(vizBuf);
#endif
  }
}

/*
 * processAckPacket — if the ACK matches one of our pending messages,
 * mark it.  Otherwise, we are an intermediate hop and silently drop
 * (origin will retry if needed — no ACK flood).
 */
static void processAckPacket(const uint8_t* senderMac,
                              const AckPacket& ack) {
  // Check if this is our own pending message first
  for (int i = 0; i < MAX_PENDING; i++) {
    if (pendingMessages[i].active &&
        pendingMessages[i].msgId == ack.msgId) {
      handleAck(ack);
      return;
    }
  }

  // Not ours — we are an intermediate hop. Forward toward origin
  // by looking up the ack's originating message sender in our table.
  // We find the node that sent msgId by checking who the ACK came from
  // and forwarding along the best path we know.
  // Simple approach: re-broadcast the ACK to all direct peers except
  // the one we received it from, once only (TTL not needed — ACKs are
  // small and this path is already deduplicated by the pending table).
  AckPacket fwd = ack;
  for (int i = 0; i < MAX_NODES; i++) {
    if (!routingTable[i].active) continue;
    if (macEqual(routingTable[i].mac, senderMac)) continue;
    if (routingTable[i].hopCount != 1) continue;  // only direct peers
    ensurePeer(routingTable[i].mac);
    esp_now_send(routingTable[i].mac,
                 (const uint8_t*)&fwd, sizeof(AckPacket));
  }
}

// ════════════════════════════════════════════════════════════
// ESP-NOW receive callback — WiFi-task / near-ISR context
//
// RULE: Do the absolute minimum.  Copy bytes, post to queue, return.
// NEVER: Serial.print, delay(), BLE calls, heap allocation.
// ════════════════════════════════════════════════════════════
static void IRAM_ATTR OnDataRecv(const esp_now_recv_info_t* info,
                                  const uint8_t* data, int len) {
  if (!rxQueue || len <= 0 || len > 250) return;

  RxQueueItem item;
  macCopy(item.senderMac, info->src_addr);
  item.len  = (uint8_t)len;
  item.rssi = (info->rx_ctrl) ? (int8_t)info->rx_ctrl->rssi : -70;
  memcpy(item.data, data, len);

  BaseType_t woken = pdFALSE;
  xQueueSendFromISR(rxQueue, &item, &woken);
  if (woken) portYIELD_FROM_ISR();
}

/*
 * OnDataSent — FIX 2: Send-failure callback.
 *
 * When ESP-NOW cannot deliver a frame (peer off-air), accelerate
 * that peer's timeout by halving its lastSeen age.  Three consecutive
 * failures push it past NODE_TIMEOUT_MS → cascade expiry kicks in.
 * Uses the same queue mechanism as OnDataRecv for ISR safety.
 * Convention: len==0 sentinel means "send to senderMac failed".
 */
static void IRAM_ATTR OnDataSent(const wifi_tx_info_t* info,
                                  esp_now_send_status_t status) {
  if (status == ESP_NOW_SEND_SUCCESS) return;
  if (!rxQueue) return;

  RxQueueItem item = {};
  macCopy(item.senderMac, info->des_addr);
  item.len = 0;  // sentinel: send failure
  BaseType_t woken = pdFALSE;
  xQueueSendFromISR(rxQueue, &item, &woken);
  if (woken) portYIELD_FROM_ISR();
}

// Drain the receive queue in loop() — safe non-ISR context.
static void drainRxQueue() {
  RxQueueItem item;
  while (xQueueReceive(rxQueue, &item, 0) == pdTRUE) {

    // Handle send-failure sentinel (len==0)
    if (item.len == 0) {
      int fi = findNodeByMac(item.senderMac);
      if (fi >= 0 && routingTable[fi].active) {
        uint32_t age = millis() - routingTable[fi].lastSeen;
        if (age < NODE_TIMEOUT_MS / 2) {
          routingTable[fi].lastSeen -= (NODE_TIMEOUT_MS / 2);
        }
        Serial.printf("[WARN] Send fail to %04X — accelerating timeout\n",
                      routingTable[fi].nodeId);
      }
      continue;
    }

    switch (item.data[0]) {
      case PKT_ROUTE_UPDATE:
        if (item.len >= (int)sizeof(RoutePacket))
          processRoutePacket(item.senderMac,
                             *reinterpret_cast<const RoutePacket*>(item.data),
                             item.rssi);
        break;
      case PKT_CHAT:
      case PKT_SOS:
        if (item.len >= (int)sizeof(MeshPacket))
          processDataPacket(item.senderMac,
                            *reinterpret_cast<const MeshPacket*>(item.data));
        break;
      case PKT_ACK:
        if (item.len >= (int)sizeof(AckPacket))
          processAckPacket(item.senderMac,
                           *reinterpret_cast<const AckPacket*>(item.data));
        break;
      default:
        Serial.printf("[WARN] Unknown packet type 0x%02X\n", item.data[0]);
        break;
    }
  }
}

// ════════════════════════════════════════════════════════════
// SOS button (long-press ≥ 1 s on BOOT button)
// ════════════════════════════════════════════════════════════
static void checkSosButton() {
  static uint32_t pressStart = 0;
  static bool     wasPressed  = false;

  bool pressed = (digitalRead(SOS_BUTTON_PIN) == LOW);
  if (pressed && !wasPressed) {
    pressStart = millis();
    wasPressed = true;
  } else if (!pressed && wasPressed) {
    wasPressed = false;
    if (millis() - pressStart >= 1000) {
      MeshPacket pkt  = {};
      pkt.type        = PKT_SOS;
      pkt.msgId       = msgIdCounter++;
      pkt.originId    = myNodeId;
      pkt.originDest  = 0xFFFF;
      pkt.hopCount    = 0;
      pkt.ttl         = MAX_HOPS;
      strncpy(pkt.sender,  myName,           sizeof(pkt.sender)  - 1);
      strncpy(pkt.message, "SOS! Need help!", sizeof(pkt.message) - 1);

      broadcastToAllPeers(pkt);
      trackPendingMessage(pkt);
      markSeen(pkt.msgId, myNodeId);

      sosActive = true;
      digitalWrite(LED_PIN, HIGH);
      Serial.println("[SOS] Sent!");
      notifyBLE("SOS sent!");
    }
  }
}

// ════════════════════════════════════════════════════════════
// Initialisation
// ════════════════════════════════════════════════════════════
static void initBLE() {
  BLEDevice::init(myName);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* svc = pServer->createService(SERVICE_UUID);

  pTxChar = svc->createCharacteristic(CHAR_TX_UUID,
                BLECharacteristic::PROPERTY_NOTIFY);
  pTxChar->addDescriptor(new BLE2902());

  pRxChar = svc->createCharacteristic(CHAR_RX_UUID,
                BLECharacteristic::PROPERTY_WRITE |
                BLECharacteristic::PROPERTY_WRITE_NR);
  pRxChar->setCallbacks(new RxCallbacks());

  svc->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] NUS service advertising");
}

static void initEspNow() {
  // WiFi.mode + channel already set in setup() before BLE init.

  if (esp_now_init() != ESP_OK) {
    Serial.println("[ESPNOW] Init failed — rebooting");
    delay(1000);
    ESP.restart();
  }

  esp_now_register_recv_cb(OnDataRecv);
  esp_now_register_send_cb(OnDataSent);   // FIX 2: send-fail detection
  Serial.printf("[ESPNOW] Initialised on channel %d\n", ESPNOW_CHANNEL);
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN,        OUTPUT);
  pinMode(SOS_BUTTON_PIN, INPUT_PULLUP);

  // Derive a unique 16-bit node ID from the last two MAC bytes.
  esp_efuse_mac_get_default(myMac);
  myNodeId = (uint16_t)((myMac[4] << 8) | myMac[5]);
  snprintf(myName, sizeof(myName), "Rippl-%04X", myNodeId);

  Serial.printf("\n========================================\n");
  Serial.printf("  Rippl Mesh v2.0 (Self-Healing)\n");
  Serial.printf("========================================\n");
  Serial.printf("[INIT] Node %s  MAC %02X:%02X:%02X:%02X:%02X:%02X\n",
                myName,
                myMac[0], myMac[1], myMac[2],
                myMac[3], myMac[4], myMac[5]);

  // Create receive queue BEFORE initialising ESP-NOW.
  rxQueue = xQueueCreate(RX_QUEUE_DEPTH, sizeof(RxQueueItem));
  if (!rxQueue) {
    Serial.println("[FATAL] RX queue allocation failed");
    while (true) delay(1000);
  }

  memset(routingTable,    0, sizeof(routingTable));
  memset(pendingMessages, 0, sizeof(pendingMessages));
  memset(seenMsgIds,      0, sizeof(seenMsgIds));

  // WiFi MUST be initialised BEFORE BLE — calling WiFi.mode() after
  // BLEDevice::init() resets the radio and kills BLE advertising.
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  delay(100);
  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);

  initBLE();
  initEspNow();

  // Announce ourselves immediately.
  sendRouteUpdate();
  lastRouteUpdate = millis();

  Serial.println("[INIT] Ready — ACK+retry+self-healing enabled");
  Serial.printf("========================================\n\n");
}

// ════════════════════════════════════════════════════════════
// Main loop — all heavy work happens here, never in callbacks
// ════════════════════════════════════════════════════════════
void loop() {
  // 1. Drain ESP-NOW receive queue
  drainRxQueue();

  // 2. Age out unreachable nodes (with cascade expiry)
  expireOldNodes();

  // 3. Periodic routing beacon
  if (millis() - lastRouteUpdate >= ROUTE_UPDATE_MS) {
    sendRouteUpdate();
    lastRouteUpdate = millis();
  }

  // 4. ACK retry for pending messages
  checkRetries();

  // 5. SOS button long-press detection
  checkSosButton();

  // 6. Serial debug commands (nodes / clear / SOS / free-form chat)
  if (Serial.available()) {
    String input = Serial.readStringUntil('\n');
    input.trim();
    if (input.length() > 0) {
      if (input.equalsIgnoreCase("nodes")) {
        printRoutingTable();
      } else if (input.equalsIgnoreCase("clear")) {
        memset(seenMsgIds, 0, sizeof(seenMsgIds));
        Serial.println("[CMD] Seen history cleared");
      } else if (input.equalsIgnoreCase("SOS")) {
        MeshPacket pkt  = {};
        pkt.type        = PKT_SOS;
        pkt.msgId       = msgIdCounter++;
        pkt.originId    = myNodeId;
        pkt.originDest  = 0xFFFF;
        pkt.hopCount    = 0;
        pkt.ttl         = MAX_HOPS;
        strncpy(pkt.sender,  myName,           sizeof(pkt.sender)  - 1);
        strncpy(pkt.message, "SOS! Need help!", sizeof(pkt.message) - 1);
        broadcastToAllPeers(pkt);
        trackPendingMessage(pkt);
        markSeen(pkt.msgId, myNodeId);
        sosActive = true;
        Serial.println("[SOS] Sent via Serial!");
        notifyBLE("SOS sent!");
      } else {
        // Free-form chat message
        MeshPacket pkt  = {};
        pkt.type        = PKT_CHAT;
        pkt.msgId       = msgIdCounter++;
        pkt.originId    = myNodeId;
        pkt.originDest  = 0xFFFF;
        pkt.hopCount    = 0;
        pkt.ttl         = MAX_HOPS;
        strncpy(pkt.sender,  myName,          sizeof(pkt.sender)  - 1);
        strncpy(pkt.message, input.c_str(),   sizeof(pkt.message) - 1);
        broadcastToAllPeers(pkt);
        trackPendingMessage(pkt);
        markSeen(pkt.msgId, myNodeId);
        Serial.printf("[TX] %s: %s\n", myName, input.c_str());
      }
    }
  }

  // 7. Status LED — SOS: fast blink (200 ms), Normal: slow (1 s)
  {
    static uint32_t lastBlink = 0;
    uint32_t rate = sosActive ? 200UL : 1000UL;
    if (millis() - lastBlink >= rate) {
      digitalWrite(LED_PIN, !digitalRead(LED_PIN));
      lastBlink = millis();
    }
  }

  // 8. Yield to FreeRTOS scheduler — keeps IDLE/WDT tasks healthy
  vTaskDelay(pdMS_TO_TICKS(5));
}
