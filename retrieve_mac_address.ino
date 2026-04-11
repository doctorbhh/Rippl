#include <WiFi.h>

void setup() {
  Serial.begin(115200);
  delay(1000);                 // Give serial time
  WiFi.mode(WIFI_STA);
  delay(1000);                 // Give WiFi time to initialize

  Serial.print("MAC Address: ");
  Serial.println(WiFi.macAddress());
}

void loop() {}
