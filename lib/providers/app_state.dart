import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../services/bluetooth_manager.dart';
import '../services/team_service.dart';

// ═══════════════════════════════════════════════════
// SINGLETON PROVIDERS
// ═══════════════════════════════════════════════════

/// Bluetooth Manager singleton provider
final bluetoothManagerProvider = Provider<BluetoothManager>(
  (ref) => BluetoothManager(),
);

/// Connection status provider
final connectionStatusProvider = StateProvider<ConnectionStatus>(
  (ref) => ConnectionStatus.disconnected,
);

/// Connected device provider
final connectedDeviceProvider = StateProvider<DiscoveredDevice?>((ref) => null);

/// Scan results provider
final scanResultsProvider = StateProvider<List<DiscoveredDevice>>((ref) => []);

/// Is scanning provider
final isScanningProvider = StateProvider<bool>((ref) => false);

// ═══════════════════════════════════════════════════
// SOS ALERT (FIX C5 — centralized, no duplicates)
// ═══════════════════════════════════════════════════

/// SOS Alert data model
class SosAlert {
  final String sender;
  final String message;
  final DateTime timestamp;

  SosAlert({required this.sender, required this.message, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

/// Latest SOS alert — screens watch this to show alerts
final latestSosAlertProvider = StateProvider<SosAlert?>((ref) => null);

// ═══════════════════════════════════════════════════
// TEAM PROVIDERS
// ═══════════════════════════════════════════════════

/// Current team provider
final currentTeamProvider = StateNotifierProvider<TeamNotifier, TeamInfo?>((
  ref,
) {
  return TeamNotifier();
});

class TeamNotifier extends StateNotifier<TeamInfo?> {
  TeamNotifier() : super(null) {
    _loadTeam();
  }

  Future<void> _loadTeam() async {
    state = await TeamService.loadTeam();
  }

  Future<void> setTeam(TeamInfo team) async {
    await TeamService.saveTeam(team);
    state = team;
  }

  Future<void> clearTeam() async {
    await TeamService.deleteTeam();
    state = null;
  }
}

/// User name provider
final userNameProvider = StateNotifierProvider<UserNameNotifier, String>((ref) {
  return UserNameNotifier();
});

class UserNameNotifier extends StateNotifier<String> {
  UserNameNotifier() : super('') {
    _loadName();
  }

  Future<void> _loadName() async {
    state = await TeamService.loadUserName() ?? '';
  }

  Future<void> setName(String name) async {
    await TeamService.saveUserName(name);
    state = name;
  }
}

/// Node ID provider
final nodeIdProvider = FutureProvider<int>((ref) async {
  return TeamService.getOrCreateNodeId();
});

// ═══════════════════════════════════════════════════
// CHAT MESSAGES (FIX C1, C2, H1, H2 — cleaned up)
// ═══════════════════════════════════════════════════

/// Chat messages provider
final messagesProvider =
    StateNotifierProvider<MessagesNotifier, List<ChatMessage>>((ref) {
      return MessagesNotifier(ref);
    });

class MessagesNotifier extends StateNotifier<List<ChatMessage>> {
  final Ref _ref;

  MessagesNotifier(this._ref) : super([]);

  void addMessage(ChatMessage message) {
    state = [...state, message];
  }

  /// [FIX C1/H2] Send a plain-text JSON message matching ESP32 firmware format.
  /// Returns true on success, false on BLE failure.
  Future<bool> sendMessage(String content) async {
    final userName = _ref.read(userNameProvider);
    final bluetoothManager = _ref.read(bluetoothManagerProvider);

    if (!bluetoothManager.isConnected) return false;

    try {
      final message = {
        'type': 'CHAT',
        'from': userName,
        'msg': content,
        'time': DateTime.now().millisecondsSinceEpoch,
      };

      // [FIX H2] Check send result before adding to local chat
      final success = await bluetoothManager.sendData(jsonEncode(message));
      if (!success) return false;

      // Only add to local messages after confirmed sent
      addMessage(
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch,
          senderName: userName,
          content: content,
          timestamp: DateTime.now(),
          isMe: true,
        ),
      );

      return true;
    } catch (e) {
      return false;
    }
  }

  void clear() {
    state = [];
  }
}

// ═══════════════════════════════════════════════════
// TEAMMATES (added updateFromData helper)
// ═══════════════════════════════════════════════════

/// Teammates provider
final teammatesProvider =
    StateNotifierProvider<TeammatesNotifier, List<Teammate>>((ref) {
      return TeammatesNotifier();
    });

class TeammatesNotifier extends StateNotifier<List<Teammate>> {
  TeammatesNotifier() : super([]);

  void updateFromPacket(MeshPacket packet) {
    updateFromData(
      name: packet.senderName,
      nodeId: packet.originNode,
      rssi: packet.rssi,
    );
  }

  /// Update or add a teammate from parsed BLE data
  void updateFromData({
    required String name,
    required int nodeId,
    required int rssi,
  }) {
    final existingIndex = state.indexWhere((t) => t.nodeId == nodeId);

    final teammate = Teammate(
      name: name,
      nodeId: nodeId,
      rssi: rssi,
      lastSeen: DateTime.now(),
    );

    if (existingIndex >= 0) {
      final updated = [...state];
      updated[existingIndex] = teammate;
      state = updated;
    } else {
      state = [...state, teammate];
    }
  }

  void removeStale(Duration timeout) {
    final cutoff = DateTime.now().subtract(timeout);
    state = state.where((t) => t.lastSeen.isAfter(cutoff)).toList();
  }

  void clear() {
    state = [];
  }
}

// ═══════════════════════════════════════════════════
// CENTRALIZED BLE MESSAGE ROUTER
// (FIX C5, H1, H7 — single listener, no duplicates)
// ═══════════════════════════════════════════════════

/// Centralized BLE Message Router
/// Single listener that parses all BLE data and dispatches to appropriate providers.
/// Eliminates duplicate listeners in HomeScreen/ChatScreen.
class BleMessageRouter {
  final Ref _ref;
  StreamSubscription? _dataSubscription;
  StreamSubscription? _connectionSubscription;

  BleMessageRouter(this._ref) {
    _start();
  }

  void _start() {
    final bm = _ref.read(bluetoothManagerProvider);

    // Listen for BLE data
    _dataSubscription = bm.receivedData.listen(_handleData);

    // [FIX H8] Listen for connection state changes to update provider
    _connectionSubscription = bm.connectionState.listen((connected) {
      if (!connected) {
        final currentStatus = _ref.read(connectionStatusProvider);
        if (currentStatus == ConnectionStatus.connected ||
            currentStatus == ConnectionStatus.connecting) {
          _ref.read(connectionStatusProvider.notifier).state =
              ConnectionStatus.disconnected;
        }
      }
    });
  }

  void _handleData(String data) {
    if (data.isEmpty) return;

    // Skip mesh visualizer events (handled by MeshVisualizerScreen)
    if (data.startsWith('@EVT:')) return;

    // Try JSON parsing first
    if (data.startsWith('{')) {
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        _handleJsonMessage(json);
      } catch (_) {}
      return;
    }

    // Fallback: plain text format "[SenderName]: message text"
    final match = RegExp(r'^\[(.+?)\]:\s*(.+)$').firstMatch(data);
    if (match != null) {
      final sender = match.group(1) ?? 'Unknown';
      final message = match.group(2) ?? '';
      _addChatIfNotMe(sender, message, 0);
    }

    // Check for plain text SOS
    if (data.toUpperCase().contains('SOS')) {
      _ref.read(latestSosAlertProvider.notifier).state =
          SosAlert(sender: 'Mesh', message: data);
    }
  }

  void _handleJsonMessage(Map<String, dynamic> json) {
    String sender = 'Unknown';
    String message = '';
    bool isSos = false;
    int hops = 0;
    int rssi = -70;

    // ESP32 format: {type, from, msg, hops}
    if (json.containsKey('from') && json.containsKey('msg')) {
      sender = json['from'] as String? ?? 'Unknown';
      message = json['msg'] as String? ?? '';
      hops = json['hops'] as int? ?? 0;
      rssi = json['rssi'] as int? ?? -70;

      final type = json['type'];
      isSos = type == 2 ||
          type == 'SOS' ||
          (type is String && type.toUpperCase() == 'SOS');
    }
    // MeshPacket format: {sender_name, payload, ...}
    else if (json.containsKey('sender_name')) {
      sender = json['sender_name'] as String? ?? 'Unknown';
      message = json['payload'] as String? ?? '';
      hops = json['hop_count'] as int? ?? 0;
      rssi = json['rssi'] as int? ?? -70;

      final type = json['type'];
      isSos = type == 'SOS' || type == 2;
    } else {
      return; // Unknown format
    }

    // Handle SOS centrally (FIX C5)
    if (isSos) {
      _ref.read(latestSosAlertProvider.notifier).state =
          SosAlert(sender: sender, message: message.isEmpty ? 'EMERGENCY!' : message);
    }

    // Update teammates from any message
    if (sender.isNotEmpty) {
      _ref.read(teammatesProvider.notifier).updateFromData(
        name: sender,
        nodeId: json['origin_node'] as int? ?? sender.hashCode,
        rssi: rssi,
      );
    }

    // Add chat message if not from me
    if (message.isNotEmpty) {
      _addChatIfNotMe(sender, message, hops);
    }
  }

  void _addChatIfNotMe(String sender, String message, int hops) {
    final userName = _ref.read(userNameProvider);
    if (sender.toLowerCase() == userName.toLowerCase()) return;

    _ref.read(messagesProvider.notifier).addMessage(ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch,
      senderName: sender,
      content: message,
      timestamp: DateTime.now(),
      isMe: false,
      hopCount: hops,
    ));
  }

  void dispose() {
    _dataSubscription?.cancel();
    _connectionSubscription?.cancel();
  }
}

/// Provider for the centralized router — eagerly initialized in RipplApp
final bleMessageRouterProvider = Provider<BleMessageRouter>((ref) {
  final router = BleMessageRouter(ref);
  ref.onDispose(() => router.dispose());
  return router;
});
