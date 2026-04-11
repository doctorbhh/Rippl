#include <esp_now.h>
#include <WiFi.h>

typedef struct {
  char msg[100];
} Packet;

void OnReceive(const esp_now_recv_info *info,
               const uint8_t *incomingData,
               int len) {

  Packet data;
  memcpy(&data, incomingData, sizeof(data));

  Serial.print("Received: ");
  Serial.println(data.msg);
}

void setup() {
  Serial.begin(115200);
  delay(1500);

  WiFi.mode(WIFI_STA);

  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW Init Failed");
    return;
  }

  esp_now_register_recv_cb(OnReceive);
  Serial.println("Receiver Ready");
}

void loop() {}
