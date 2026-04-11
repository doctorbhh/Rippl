import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// BLE UUIDs matching ESP32
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String charTxUuid =
    '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // ESP32 -> Phone (notify)
const String charRxUuid =
    '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // Phone -> ESP32 (write)

/// Bluetooth Manager for ESP32 BLE communication
/// Uses notifications for instant message reception (no polling!)
class BluetoothManager {
  static final BluetoothManager _instance = BluetoothManager._internal();
  factory BluetoothManager() => _instance;
  BluetoothManager._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription? _notifySubscription;
  StreamSubscription? _connectionSubscription;

  final _receivedDataController = StreamController<String>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  /// Stream of received data from ESP32 (INSTANT via notifications)
  Stream<String> get receivedData => _receivedDataController.stream;

  /// Stream of connection state changes
  Stream<bool> get connectionState => _connectionStateController.stream;

  /// Check if Bluetooth is available
  Future<bool> get isAvailable async {
    try {
      return await FlutterBluePlus.isSupported;
    } catch (e) {
      return false;
    }
  }

  /// Check if Bluetooth is on
  Future<bool> get isOn async {
    try {
      return await FlutterBluePlus.adapterState.first ==
          BluetoothAdapterState.on;
    } catch (e) {
      return false;
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  /// Connect to a device
  Future<bool> connect(BluetoothDevice device) async {
    try {
      _connectionStateController.add(false);

      await device.connect(timeout: const Duration(seconds: 10));
      _connectedDevice = device;

      // Discover services
      List<BluetoothService> services = await device.discoverServices();

      // Find our service
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUuid) {
          for (var char in service.characteristics) {
            final uuid = char.uuid.toString().toLowerCase();

            if (uuid == charTxUuid) {
              _txCharacteristic = char;
              // Subscribe to notifications - INSTANT message reception!
              await char.setNotifyValue(true);
              _notifySubscription = char.onValueReceived.listen((value) {
                final data = utf8.decode(value).trim();
                if (data.isNotEmpty) {
                  _receivedDataController.add(data);
                }
              });
            } else if (uuid == charRxUuid) {
              _rxCharacteristic = char;
            }
          }
        }
      }

      if (_txCharacteristic != null && _rxCharacteristic != null) {
        // [FIX H8] Listen for unexpected BLE disconnections
        _connectionSubscription = device.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            _handleDisconnection();
          }
        });

        _connectionStateController.add(true);
        return true;
      }

      // Couldn't find characteristics
      await disconnect();
      return false;
    } catch (e) {
      _connectionStateController.add(false);
      return false;
    }
  }

  /// [FIX H8] Handle unexpected BLE disconnection
  void _handleDisconnection() {
    _notifySubscription?.cancel();
    _notifySubscription = null;
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _connectedDevice = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _connectionStateController.add(false);
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    try {
      await _notifySubscription?.cancel();
      _notifySubscription = null;
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      await _connectedDevice?.disconnect();
    } catch (e) {
      // Ignore disconnect errors
    }
    _connectedDevice = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _connectionStateController.add(false);
  }

  /// [FIX H2/H3] Send data to ESP32 — returns true on success, false on failure
  Future<bool> sendData(String data) async {
    if (_rxCharacteristic == null) return false;
    try {
      await _rxCharacteristic!.write(
        utf8.encode('$data\n'),
        withoutResponse: true,
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if connected
  bool get isConnected => _connectedDevice != null && _rxCharacteristic != null;

  /// Get connected device
  BluetoothDevice? get connectedDevice => _connectedDevice;

  /// Dispose resources
  void dispose() {
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    _connectedDevice?.disconnect();
    _receivedDataController.close();
    _connectionStateController.close();
  }
}
