/// Data models for Rippl mesh communication app
library;

enum PacketType { chat, heartbeat, sos }

/// Represents a packet transmitted over the mesh network
class MeshPacket {
  final int msgId;
  final int originNode;
  final int teamId;
  final String senderName;
  final String payload; // Encrypted content
  final int rssi;
  final int hopCount;
  final PacketType type;
  final DateTime timestamp;

  MeshPacket({
    required this.msgId,
    required this.originNode,
    required this.teamId,
    required this.senderName,
    required this.payload,
    required this.rssi,
    required this.hopCount,
    required this.type,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory MeshPacket.fromJson(Map<String, dynamic> json) {
    return MeshPacket(
      msgId: json['msg_id'] as int,
      originNode: json['origin_node'] as int,
      teamId: json['team_id'] as int,
      senderName: json['sender_name'] as String,
      payload: json['payload'] as String,
      rssi: json['rssi'] as int? ?? 0,
      hopCount: json['hop_count'] as int? ?? 0,
      type: PacketType.values.firstWhere(
        (e) => e.name.toUpperCase() == (json['type'] as String?)?.toUpperCase(),
        orElse: () => PacketType.chat,
      ),
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'msg_id': msgId,
        'origin_node': originNode,
        'team_id': teamId,
        'sender_name': senderName,
        'payload': payload,
        'rssi': rssi,
        'hop_count': hopCount,
        'type': type.name.toUpperCase(),
        'timestamp': timestamp.millisecondsSinceEpoch,
      };
}

/// Decrypted chat message for display
class ChatMessage {
  final int id;
  final String senderName;
  final String content;
  final DateTime timestamp;
  final bool isMe;
  final int rssi;
  final int hopCount;

  ChatMessage({
    required this.id,
    required this.senderName,
    required this.content,
    required this.timestamp,
    required this.isMe,
    this.rssi = 0,
    this.hopCount = 0,
  });
}

/// Team information including encryption key
class TeamInfo {
  final int id;
  final String name;
  final String aesKey; // Base64 encoded AES-256 key

  TeamInfo({
    required this.id,
    required this.name,
    required this.aesKey,
  });

  factory TeamInfo.fromJson(Map<String, dynamic> json) {
    return TeamInfo(
      id: json['id'] as int,
      name: json['name'] as String,
      aesKey: json['aes_key'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'aes_key': aesKey,
      };
}

/// Team member with signal information
class Teammate {
  final String name;
  final int nodeId;
  final int rssi;
  final DateTime lastSeen;

  Teammate({
    required this.name,
    required this.nodeId,
    required this.rssi,
    required this.lastSeen,
  });

  /// Calculate signal strength percentage from RSSI
  /// RSSI typically ranges from -30 (excellent) to -100 (poor)
  int get signalPercent {
    if (rssi >= -30) return 100;
    if (rssi <= -100) return 0;
    return ((rssi + 100) * 100 / 70).round().clamp(0, 100);
  }

  Teammate copyWith({
    String? name,
    int? nodeId,
    int? rssi,
    DateTime? lastSeen,
  }) {
    return Teammate(
      name: name ?? this.name,
      nodeId: nodeId ?? this.nodeId,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

/// BLE connection states
enum ConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

/// Discovered BLE device for display
class DiscoveredDevice {
  final String id;
  final String name;
  final int rssi;

  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });
}
