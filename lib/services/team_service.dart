import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/models.dart';
import 'crypto_service.dart';

/// Service for team management and secure storage
class TeamService {
  static const _storage = FlutterSecureStorage();
  static const _teamKey = 'current_team';
  static const _userNameKey = 'user_name';
  static const _nodeIdKey = 'node_id';

  /// Create a new team with a password
  static Future<TeamInfo> createTeam({
    required String name,
    required String password,
  }) async {
    // Generate random team ID (16-bit for mesh compatibility)
    final random = Random.secure();
    final teamId = random.nextInt(65535);

    // Derive AES key from password
    final aesKey = CryptoService.generateTeamKey(
      password,
      salt: 'team_$teamId',
    );

    final team = TeamInfo(id: teamId, name: name, aesKey: aesKey);

    // Save to secure storage
    await saveTeam(team);

    return team;
  }

  /// Save team to secure storage
  static Future<void> saveTeam(TeamInfo team) async {
    await _storage.write(key: _teamKey, value: jsonEncode(team.toJson()));
  }

  /// Load team from secure storage
  static Future<TeamInfo?> loadTeam() async {
    final json = await _storage.read(key: _teamKey);
    if (json == null) return null;

    try {
      return TeamInfo.fromJson(jsonDecode(json));
    } catch (e) {
      return null;
    }
  }

  /// Delete current team
  static Future<void> deleteTeam() async {
    await _storage.delete(key: _teamKey);
  }

  /// Generate QR code payload for team sharing
  /// [FIX C6] Uses derived key instead of raw password
  static String generateQrPayload(TeamInfo team) {
    final payload = {
      'id': team.id,
      'name': team.name,
      'key': team.aesKey,
      'version': 2,
    };
    return jsonEncode(payload);
  }

  /// Parse QR code payload and create TeamInfo
  /// Supports both v2 (key-based) and v1 legacy (password-based) formats
  static Future<TeamInfo?> parseQrPayload(String qrData) async {
    try {
      final payload = jsonDecode(qrData) as Map<String, dynamic>;
      final version = payload['version'] as int? ?? 1;

      TeamInfo team;

      if (version >= 2) {
        // v2: derived key included directly
        team = TeamInfo(
          id: payload['id'] as int,
          name: payload['name'] as String,
          aesKey: payload['key'] as String,
        );
      } else {
        // v1 legacy: derive key from password
        final teamId = payload['id'] as int;
        final name = payload['name'] as String;
        final password = payload['password'] as String;
        final aesKey = CryptoService.generateTeamKey(
          password,
          salt: 'team_$teamId',
        );
        team = TeamInfo(id: teamId, name: name, aesKey: aesKey);
      }

      await saveTeam(team);
      return team;
    } catch (e) {
      return null;
    }
  }

  /// Save user name
  static Future<void> saveUserName(String name) async {
    await _storage.write(key: _userNameKey, value: name);
  }

  /// Load user name
  static Future<String?> loadUserName() async {
    return await _storage.read(key: _userNameKey);
  }

  /// Generate and save a unique node ID for this device
  static Future<int> getOrCreateNodeId() async {
    final existing = await _storage.read(key: _nodeIdKey);
    if (existing != null) {
      return int.parse(existing);
    }

    // Generate random node ID (16-bit)
    final random = Random.secure();
    final nodeId = random.nextInt(65535);
    await _storage.write(key: _nodeIdKey, value: nodeId.toString());
    return nodeId;
  }

  /// Get node ID (returns 0 if not set)
  static Future<int> getNodeId() async {
    final existing = await _storage.read(key: _nodeIdKey);
    return existing != null ? int.parse(existing) : 0;
  }
}
