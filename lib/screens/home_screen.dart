import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../navigation/app_router.dart';
import '../providers/app_state.dart';
import '../services/bluetooth_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_status_card.dart';
import '../widgets/team_info_card.dart';

/// Main dashboard screen with centralized SOS listener via provider
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late final BluetoothManager _bluetoothManager;

  @override
  void initState() {
    super.initState();
    _bluetoothManager = ref.read(bluetoothManagerProvider);
  }

  // [FIX C5] SOS alert shown via centralized latestSosAlertProvider
  void _showSosAlert(SosAlert alert) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        title: const Row(
          children: [
            Icon(Icons.warning_rounded, color: Colors.white, size: 32),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '🚨 SOS ALERT',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From: ${alert.sender}',
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade800,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                alert.message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
            onPressed: () {
              ref.read(latestSosAlertProvider.notifier).state = null;
              Navigator.pop(ctx);
            },
            child: const Text(
              'ACKNOWLEDGE',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connectionStatus = ref.watch(connectionStatusProvider);
    final currentTeam = ref.watch(currentTeamProvider);
    final userName = ref.watch(userNameProvider);

    // [FIX C5] Listen for SOS alerts from centralized provider
    ref.listen(latestSosAlertProvider, (prev, next) {
      if (next != null && next != prev) {
        _showSosAlert(next);
      }
    });

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // App header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                AppColors.deepForestGreen,
                                AppColors.lightForest,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.terrain,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Rippl', style: AppTextStyles.headline1),
                            Text(
                              userName.isEmpty
                                  ? 'Tap to set your name'
                                  : userName,
                              style: AppTextStyles.body2,
                            ),
                          ],
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () => _showSettingsDialog(context, ref),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Connection status card
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: ConnectionStatusCard(
                  status: connectionStatus,
                  onTap: () => context.push(AppRoutes.deviceScan),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),

            // Team info card
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: TeamInfoCard(
                  team: currentTeam,
                  onTap: () => context.push(AppRoutes.teamSetup),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),

            // Quick actions
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Text(
                  'QUICK ACTIONS',
                  style: AppTextStyles.caption.copyWith(
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),

            // Action grid
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: AppSpacing.md,
                  mainAxisSpacing: AppSpacing.md,
                  childAspectRatio: 1.1,
                ),
                delegate: SliverChildListDelegate([
                  _ActionCard(
                    icon: Icons.chat_bubble_rounded,
                    label: 'Chat',
                    sublabel: 'Team messages',
                    color: AppColors.forestGreen,
                    onTap: () => context.push(AppRoutes.chat),
                  ),
                  _ActionCard(
                    icon: Icons.people_rounded,
                    label: 'Teammates',
                    sublabel: 'Signal radar',
                    color: AppColors.safetyOrange,
                    onTap: () => context.push(AppRoutes.teammates),
                  ),
                  _ActionCard(
                    icon: Icons.bluetooth_searching,
                    label: 'Scan',
                    sublabel: 'Find ESP32',
                    color: Colors.blueAccent,
                    onTap: () => context.push(AppRoutes.deviceScan),
                  ),
                  _ActionCard(
                    icon: Icons.qr_code_rounded,
                    label: 'Team Setup',
                    sublabel: 'Join or create',
                    color: Colors.purpleAccent,
                    onTap: () => context.push(AppRoutes.teamSetup),
                  ),
                  _ActionCard(
                    icon: Icons.hub_rounded,
                    label: 'Mesh',
                    sublabel: 'Live visualizer',
                    color: Colors.tealAccent,
                    onTap: () => context.push(AppRoutes.meshViz),
                  ),
                ]),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
          ],
        ),
      ),
      // SOS Emergency Button
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showSosConfirmation(context, ref),
        backgroundColor: Colors.red,
        icon: const Icon(Icons.warning_rounded, color: Colors.white),
        label: const Text(
          'SOS',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  void _showSosConfirmation(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        title: const Row(
          children: [
            Icon(Icons.warning_rounded, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text('Send SOS?', style: TextStyle(color: Colors.red)),
          ],
        ),
        content: const Text(
          'This will send an EMERGENCY alert to ALL members in the mesh network.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              _sendSos(context, ref);
            },
            child: const Text(
              'SEND SOS',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _sendSos(BuildContext context, WidgetRef ref) {
    final userName = ref.read(userNameProvider);

    if (_bluetoothManager.isConnected) {
      _bluetoothManager.sendData('SOS:$userName');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.warning_rounded, color: Colors.white),
              SizedBox(width: 8),
              Text('SOS SENT to all devices!'),
            ],
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not connected! Please connect to ESP32 first.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  // [FIX L3] TextEditingController properly scoped & disposed via dialog lifecycle
  void _showSettingsDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) {
        // Controller is created and disposed with the dialog's lifecycle
        final controller = TextEditingController(
          text: ref.read(userNameProvider),
        );
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.cardBackground,
              title: const Text('Settings'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Your Name',
                      hintText: 'Enter your display name',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    controller.dispose();
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    ref
                        .read(userNameProvider.notifier)
                        .setName(controller.text.trim());
                    controller.dispose();
                    Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const Spacer(),
              Text(
                label,
                style: AppTextStyles.headline3,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                sublabel,
                style: AppTextStyles.caption,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
