import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rippl/services/team_service.dart';
import 'package:rippl/models/models.dart';
import 'dart:convert';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Mock the platform channels for flutter_secure_storage
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TeamService Test', () {
    test('createTeam generates valid team with derived key and saves it', () async {
      final team = await TeamService.createTeam(name: 'Alpha Team', password: 'secure_password');
      
      expect(team.name, 'Alpha Team');
      expect(team.id, isA<int>());
      expect(team.aesKey.isNotEmpty, true);
      
      // Verify it was saved
      final loadedTeam = await TeamService.loadTeam();
      expect(loadedTeam, isNotNull);
      expect(loadedTeam!.id, team.id);
      expect(loadedTeam.name, team.name);
      expect(loadedTeam.aesKey, team.aesKey);
    });

    test('deleteTeam removes the team', () async {
      await TeamService.createTeam(name: 'Beta Team', password: 'pass');
      expect(await TeamService.loadTeam(), isNotNull);
      
      await TeamService.deleteTeam();
      expect(await TeamService.loadTeam(), isNull);
    });

    test('generateQrPayload produces v2 format with derived key', () async {
      final team = TeamInfo(id: 12345, name: 'Gamma Team', aesKey: 'base64_encoded_key_here');
      final payloadStr = TeamService.generateQrPayload(team);
      
      final payload = jsonDecode(payloadStr);
      expect(payload['id'], 12345);
      expect(payload['name'], 'Gamma Team');
      expect(payload['key'], 'base64_encoded_key_here');
      expect(payload['version'], 2);
      expect(payload.containsKey('password'), false); // Should NOT contain raw password (Fix C6)
    });

    test('parseQrPayload parses v2 (key-based) format correctly', () async {
      final payloadStr = jsonEncode({
        'id': 54321,
        'name': 'Delta Team',
        'key': 'some_derived_key',
        'version': 2,
      });

      final team = await TeamService.parseQrPayload(payloadStr);
      
      expect(team, isNotNull);
      expect(team!.id, 54321);
      expect(team.name, 'Delta Team');
      expect(team.aesKey, 'some_derived_key');
      
      // Verify it was saved securely
      final loadedTeam = await TeamService.loadTeam();
      expect(loadedTeam?.id, 54321);
    });

    test('parseQrPayload supports backward compatibility with v1 (password-based) format', () async {
      final payloadStr = jsonEncode({
        'id': 11111,
        'name': 'Legacy Team',
        'password': 'shared_legacy_password',
        // version 1 is implicit if absent
      });

      final team = await TeamService.parseQrPayload(payloadStr);
      
      expect(team, isNotNull);
      expect(team!.id, 11111);
      expect(team.name, 'Legacy Team');
      expect(team.aesKey.isNotEmpty, true); // Should derive a key, not store password
      
      // Verify key is derived correctly
      // (Using the logic from the service to cross-check conceptually)
      // Salt in service is 'team_11111'
      expect(team.aesKey.length, 44); // Base64 encoding of 32 bytes
    });

    test('getOrCreateNodeId generates and persists node ID', () async {
      final nodeId1 = await TeamService.getOrCreateNodeId();
      expect(nodeId1, greaterThan(0));
      expect(nodeId1, lessThan(65536)); // 16-bit

      // Fetching again should return the same
      final nodeId2 = await TeamService.getOrCreateNodeId();
      expect(nodeId2, nodeId1);
    });
  });
}
