import 'package:flutter/material.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// Card showing BLE connection status
class ConnectionStatusCard extends StatelessWidget {
  final ConnectionStatus status;
  final VoidCallback onTap;

  const ConnectionStatusCard({
    super.key,
    required this.status,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, label, sublabel, color) = switch (status) {
      ConnectionStatus.connected => (
        Icons.bluetooth_connected,
        'Connected',
        'ESP32 device linked',
        AppColors.connected,
      ),
      ConnectionStatus.connecting => (
        Icons.bluetooth_searching,
        'Connecting...',
        'Please wait',
        AppColors.warning,
      ),
      ConnectionStatus.scanning => (
        Icons.bluetooth_searching,
        'Scanning...',
        'Looking for devices',
        AppColors.warning,
      ),
      ConnectionStatus.error => (
        Icons.bluetooth_disabled,
        'Connection Error',
        'Tap to retry',
        AppColors.disconnected,
      ),
      ConnectionStatus.disconnected => (
        Icons.bluetooth,
        'Not Connected',
        'Tap to scan for ESP32',
        AppColors.textMuted,
      ),
    };

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppTextStyles.headline3),
                    Text(sublabel, style: AppTextStyles.caption),
                  ],
                ),
              ),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
