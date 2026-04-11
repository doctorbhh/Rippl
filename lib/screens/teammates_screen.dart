import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';

/// Screen showing team members and their signal strength
class TeammatesScreen extends ConsumerStatefulWidget {
  const TeammatesScreen({super.key});

  @override
  ConsumerState<TeammatesScreen> createState() => _TeammatesScreenState();
}

class _TeammatesScreenState extends ConsumerState<TeammatesScreen> {
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    // Remove stale teammates every 30 seconds
    _staleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref
          .read(teammatesProvider.notifier)
          .removeStale(const Duration(minutes: 5));
    });
  }

  @override
  void dispose() {
    _staleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final teammates = ref.watch(teammatesProvider);
    final currentTeam = ref.watch(currentTeamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Teammates'),
        actions: [
          if (teammates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.deepForestGreen.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${teammates.length} online',
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.connected,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: currentTeam == null
          ? _NoTeamState()
          : teammates.isEmpty
          ? _EmptyState()
          : _TeammatesList(teammates: teammates),
    );
  }
}

class _NoTeamState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.group_off,
              size: 64,
              color: AppColors.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppSpacing.md),
            const Text('No team joined', style: AppTextStyles.body1),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Join or create a team to see\nyour teammates',
              style: AppTextStyles.body2,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Radar animation placeholder
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.deepForestGreen.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.deepForestGreen.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.deepForestGreen.withValues(alpha: 0.2),
                      ),
                      child: const Icon(
                        Icons.person,
                        color: AppColors.lightForest,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text('Scanning for teammates...', style: AppTextStyles.body1),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'When your teammates send messages,\nthey\'ll appear here with signal strength',
              style: AppTextStyles.body2,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _TeammatesList extends StatelessWidget {
  final List<Teammate> teammates;

  const _TeammatesList({required this.teammates});

  @override
  Widget build(BuildContext context) {
    // Sort by signal strength (strongest first)
    final sorted = [...teammates]..sort((a, b) => b.rssi.compareTo(a.rssi));

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        return _TeammateCard(teammate: sorted[index]);
      },
    );
  }
}

class _TeammateCard extends StatelessWidget {
  final Teammate teammate;

  const _TeammateCard({required this.teammate});

  @override
  Widget build(BuildContext context) {
    final signalPercent = teammate.signalPercent;
    final signalColor = _getSignalColor(signalPercent);
    final timeSinceLastSeen = DateTime.now().difference(teammate.lastSeen);

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            // Avatar with signal ring
            Stack(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: signalColor, width: 3),
                  ),
                  child: Center(
                    child: Text(
                      teammate.name.isNotEmpty
                          ? teammate.name[0].toUpperCase()
                          : '?',
                      style: AppTextStyles.headline2.copyWith(
                        color: signalColor,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: signalColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.cardBackground,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: AppSpacing.md),

            // Name and last seen
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(teammate.name, style: AppTextStyles.headline3),
                  const SizedBox(height: 2),
                  Text(
                    _formatLastSeen(timeSinceLastSeen),
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ),

            // Signal strength bar
            _SignalStrengthBar(percent: signalPercent, rssi: teammate.rssi),
          ],
        ),
      ),
    );
  }

  Color _getSignalColor(int percent) {
    if (percent >= 75) return AppColors.signalExcellent;
    if (percent >= 50) return AppColors.signalGood;
    if (percent >= 25) return AppColors.signalFair;
    return AppColors.signalPoor;
  }

  String _formatLastSeen(Duration duration) {
    if (duration.inSeconds < 60) {
      return 'Just now';
    } else if (duration.inMinutes < 60) {
      return '${duration.inMinutes}m ago';
    } else {
      return '${duration.inHours}h ago';
    }
  }
}

class _SignalStrengthBar extends StatelessWidget {
  final int percent;
  final int rssi;

  const _SignalStrengthBar({required this.percent, required this.rssi});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (index) {
            final barPercent = (index + 1) * 20;
            final isActive = percent >= barPercent;
            final height = 8.0 + (index * 4);

            return Container(
              width: 6,
              height: height,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                color: isActive ? _getBarColor(percent) : AppColors.slateGray,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
        const SizedBox(height: 4),
        Text('$rssi dBm', style: AppTextStyles.caption),
      ],
    );
  }

  Color _getBarColor(int percent) {
    if (percent >= 75) return AppColors.signalExcellent;
    if (percent >= 50) return AppColors.signalGood;
    if (percent >= 25) return AppColors.signalFair;
    return AppColors.signalPoor;
  }
}
