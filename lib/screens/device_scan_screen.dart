import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/bluetooth_manager.dart';
import '../theme/app_theme.dart';

/// Screen for scanning and connecting to ESP32 devices via BLE
class DeviceScanScreen extends ConsumerStatefulWidget {
  const DeviceScanScreen({super.key});

  @override
  ConsumerState<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends ConsumerState<DeviceScanScreen> {
  List<ScanResult> _scanResults = [];
  StreamSubscription? _scanSubscription;
  bool _isScanning = false;
  String? _error;
  late final BluetoothManager _bluetoothManager;

  @override
  void initState() {
    super.initState();
    _bluetoothManager = ref.read(bluetoothManagerProvider);
    _checkBluetoothAndScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _checkBluetoothAndScan() async {
    // Check if Bluetooth is available
    if (!await _bluetoothManager.isAvailable) {
      setState(() => _error = 'Bluetooth is not available on this device');
      return;
    }

    // Check if Bluetooth is on
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      setState(() => _error = 'Please turn on Bluetooth');
      return;
    }

    _startScan();
  }

  void _startScan() {
    setState(() {
      _isScanning = true;
      _error = null;
      _scanResults = [];
    });

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          // Filter for Rippl devices
          _scanResults = results.where((r) {
            final name = r.device.platformName.toLowerCase();
            return name.contains('rippl') || name.contains('esp');
          }).toList();
        });
      }
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    // Auto-stop after timeout
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    ref.read(connectionStatusProvider.notifier).state =
        ConnectionStatus.connecting;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.safetyOrange),
                SizedBox(height: 16),
                Text('Connecting...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await FlutterBluePlus.stopScan();
      final success = await _bluetoothManager.connect(device);

      if (mounted) {
        Navigator.pop(context); // Close dialog

        if (success) {
          ref.read(connectionStatusProvider.notifier).state =
              ConnectionStatus.connected;
          ref.read(connectedDeviceProvider.notifier).state = DiscoveredDevice(
            id: device.remoteId.str,
            name: device.platformName.isNotEmpty
                ? device.platformName
                : 'Rippl Device',
            rssi: 0,
          );

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Connected to ${device.platformName}'),
              backgroundColor: AppColors.connected,
            ),
          );

          Navigator.pop(context); // Return home
        } else {
          ref.read(connectionStatusProvider.notifier).state =
              ConnectionStatus.error;
          _showError('Connection failed - make sure device is nearby');
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ref.read(connectionStatusProvider.notifier).state =
            ConnectionStatus.error;
        _showError('Connection failed: $e');
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.disconnected),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find Rippl Devices'),
        actions: [
          if (_isScanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.safetyOrange,
                ),
              ),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), onPressed: _startScan),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.bluetooth_disabled,
                size: 64,
                color: AppColors.disconnected,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(
                onPressed: _checkBluetoothAndScan,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_scanResults.isEmpty && !_isScanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.bluetooth_searching,
              size: 64,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text('No Rippl devices found'),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Make sure ESP32 is powered on',
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton(
              onPressed: _startScan,
              child: const Text('Scan Again'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: _scanResults.length,
      itemBuilder: (context, index) {
        final result = _scanResults[index];
        final device = result.device;
        final rssi = result.rssi;

        return Card(
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: ListTile(
            onTap: () => _connectToDevice(device),
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.forestGreen.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.bluetooth, color: AppColors.forestGreen),
            ),
            title: Text(
              device.platformName.isNotEmpty
                  ? device.platformName
                  : 'Unknown Device',
              style: AppTextStyles.headline3,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.remoteId.str, style: AppTextStyles.caption),
                Row(
                  children: [
                    Icon(
                      rssi > -60
                          ? Icons.signal_cellular_4_bar
                          : rssi > -70
                          ? Icons.signal_cellular_alt
                          : Icons.signal_cellular_alt_1_bar,
                      size: 16,
                      color: rssi > -60
                          ? AppColors.connected
                          : AppColors.warning,
                    ),
                    const SizedBox(width: 4),
                    Text('$rssi dBm', style: AppTextStyles.caption),
                  ],
                ),
              ],
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppColors.textMuted,
            ),
          ),
        );
      },
    );
  }
}
