import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/team_service.dart';
import '../theme/app_theme.dart';

/// Screen for creating or joining a team
class TeamSetupScreen extends ConsumerStatefulWidget {
  const TeamSetupScreen({super.key});

  @override
  ConsumerState<TeamSetupScreen> createState() => _TeamSetupScreenState();
}

class _TeamSetupScreenState extends ConsumerState<TeamSetupScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _teamNameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isCreating = false;
  bool _isScanning = false;
  String? _qrPayload;
  String? _createdPassword;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _teamNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _createTeam() async {
    final name = _teamNameController.text.trim();
    final password = _passwordController.text.trim();

    if (name.isEmpty) {
      _showError('Please enter a team name');
      return;
    }

    if (password.length < 4) {
      _showError('Password must be at least 4 characters');
      return;
    }

    setState(() => _isCreating = true);

    try {
      final team = await TeamService.createTeam(name: name, password: password);

      ref.read(currentTeamProvider.notifier).setTeam(team);



      setState(() {
        _qrPayload = TeamService.generateQrPayload(team);
        _isCreating = false;
      });
    } catch (e) {
      setState(() => _isCreating = false);
      _showError('Failed to create team: $e');
    }
  }

  void _startScanning() {
    setState(() => _isScanning = true);
  }

  Future<void> _handleQrScanned(String data) async {
    setState(() => _isScanning = false);

    final team = await TeamService.parseQrPayload(data);

    if (team != null) {
      ref.read(currentTeamProvider.notifier).setTeam(team);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Joined team: ${team.name}'),
            backgroundColor: AppColors.connected,
          ),
        );
        Navigator.pop(context);
      }
    } else {
      _showError('Invalid QR code');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.disconnected),
    );
  }

  Future<void> _leaveTeam() async {
    await ref.read(currentTeamProvider.notifier).clearTeam();
    ref.read(messagesProvider.notifier).clear();
    ref.read(teammatesProvider.notifier).clear();

    if (mounted) {
      setState(() {
        _qrPayload = null;
        _createdPassword = null;
        _teamNameController.clear();
        _passwordController.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Left team'),
          backgroundColor: AppColors.warning,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTeam = ref.watch(currentTeamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Setup'),
        bottom: currentTeam == null
            ? TabBar(
                controller: _tabController,
                indicatorColor: AppColors.safetyOrange,
                labelColor: AppColors.safetyOrange,
                unselectedLabelColor: AppColors.textSecondary,
                tabs: const [
                  Tab(text: 'Create Team'),
                  Tab(text: 'Join Team'),
                ],
              )
            : null,
      ),
      body: currentTeam != null
          ? _CurrentTeamView(
              team: currentTeam,
              qrPayload: _qrPayload,
              password: _createdPassword,
              onLeave: _leaveTeam,
              onShowQr: () {
                // [FIX H4] No password needed — QR uses stored derived key
                final team = ref.read(currentTeamProvider);
                if (team != null) {
                  setState(() {
                    _qrPayload = TeamService.generateQrPayload(team);
                  });
                }
              },
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _CreateTeamTab(
                  nameController: _teamNameController,
                  passwordController: _passwordController,
                  isCreating: _isCreating,
                  onCreate: _createTeam,
                ),
                _JoinTeamTab(
                  isScanning: _isScanning,
                  onStartScan: _startScanning,
                  onStopScan: () => setState(() => _isScanning = false),
                  onQrScanned: _handleQrScanned,
                ),
              ],
            ),
    );
  }

  // [FIX H4] Password dialog removed — QR now uses stored derived key directly
  // Backward-compatible: old v1 QR codes with passwords still work for scanning
}

class _CreateTeamTab extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController passwordController;
  final bool isCreating;
  final VoidCallback onCreate;

  const _CreateTeamTab({
    required this.nameController,
    required this.passwordController,
    required this.isCreating,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Icon
          Container(
            width: 80,
            height: 80,
            margin: const EdgeInsets.only(bottom: AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppColors.deepForestGreen.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.group_add,
              size: 40,
              color: AppColors.lightForest,
            ),
          ),

          Text(
            'Create a New Team',
            style: AppTextStyles.headline2,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Share the QR code with your teammates\nto let them join securely',
            style: AppTextStyles.body2,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.xl),

          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Team Name',
              hintText: 'e.g., Summit Squad',
              prefixIcon: Icon(Icons.group),
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Team Password',
              hintText: 'Shared secret for encryption',
              prefixIcon: Icon(Icons.lock),
            ),
          ),

          const SizedBox(height: AppSpacing.lg),

          ElevatedButton(
            onPressed: isCreating ? null : onCreate,
            child: isCreating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.darkSlate,
                    ),
                  )
                : const Text('Create Team'),
          ),
        ],
      ),
    );
  }
}

class _JoinTeamTab extends StatelessWidget {
  final bool isScanning;
  final VoidCallback onStartScan;
  final VoidCallback onStopScan;
  final Function(String) onQrScanned;

  const _JoinTeamTab({
    required this.isScanning,
    required this.onStartScan,
    required this.onStopScan,
    required this.onQrScanned,
  });

  @override
  Widget build(BuildContext context) {
    if (isScanning) {
      return Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              final barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                onQrScanned(barcodes.first.rawValue!);
              }
            },
          ),
          Positioned(
            top: 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Scan team QR code',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                onPressed: onStopScan,
                child: const Text('Cancel'),
              ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.safetyOrange.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.qr_code_scanner,
                size: 40,
                color: AppColors.safetyOrange,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Join an Existing Team',
              style: AppTextStyles.headline2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Scan the QR code shared by\nyour team leader',
              style: AppTextStyles.body2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            ElevatedButton.icon(
              onPressed: onStartScan,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Scan QR Code'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentTeamView extends StatelessWidget {
  final TeamInfo team;
  final String? qrPayload;
  final String? password;
  final VoidCallback onLeave;
  final VoidCallback onShowQr;

  const _CurrentTeamView({
    required this.team,
    this.qrPayload,
    this.password,
    required this.onLeave,
    required this.onShowQr,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          // Team badge
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.deepForestGreen, AppColors.lightForest],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.group, size: 40, color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(team.name, style: AppTextStyles.headline1),
          Text('Team ID: ${team.id}', style: AppTextStyles.caption),

          const SizedBox(height: AppSpacing.xl),

          // QR Code
          if (qrPayload != null) ...[
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: qrPayload!,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Share this QR code with teammates',
              style: AppTextStyles.body2,
              textAlign: TextAlign.center,
            ),
          ] else ...[
            OutlinedButton.icon(
              onPressed: onShowQr,
              icon: const Icon(Icons.qr_code),
              label: const Text('Show QR Code'),
            ),
          ],

          const SizedBox(height: AppSpacing.xl),

          // Leave team button
          TextButton.icon(
            onPressed: onLeave,
            icon: const Icon(Icons.exit_to_app, color: AppColors.disconnected),
            label: const Text(
              'Leave Team',
              style: TextStyle(color: AppColors.disconnected),
            ),
          ),
        ],
      ),
    );
  }
}
