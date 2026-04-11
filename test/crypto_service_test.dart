import 'package:flutter_test/flutter_test.dart';
import 'package:rippl/services/crypto_service.dart';
import 'dart:convert';

void main() {
  group('CryptoService Test', () {
    test('generateTeamKey creates valid base64 key of correct length', () {
      final key = CryptoService.generateTeamKey('mypassword123', salt: 'test_salt');
      expect(key.isNotEmpty, true);
      
      final keyBytes = base64.decode(key);
      expect(keyBytes.length, 32); // 256 bits = 32 bytes
    });

    test('generateTeamKey is deterministic', () {
      final key1 = CryptoService.generateTeamKey('password', salt: 'salt1');
      final key2 = CryptoService.generateTeamKey('password', salt: 'salt1');
      expect(key1, key2);
    });

    test('generateTeamKey produces different keys for different salts', () {
      final key1 = CryptoService.generateTeamKey('password', salt: 'salt1');
      final key2 = CryptoService.generateTeamKey('password', salt: 'salt2');
      expect(key1, isNot(equals(key2)));
    });

    test('generateTeamKey produces different keys for different passwords', () {
      final key1 = CryptoService.generateTeamKey('pass1', salt: 'salt');
      final key2 = CryptoService.generateTeamKey('pass2', salt: 'salt');
      expect(key1, isNot(equals(key2)));
    });

    test('encrypt and decrypt message round-trip', () {
      final plainText = 'Hello, Rippl Mesh!';
      final teamKey = CryptoService.generateTeamKey('secret_password', salt: 'salt');

      final cipherText = CryptoService.encryptMessage(plainText, teamKey);
      expect(cipherText, isNot(equals(plainText)));

      final decrypted = CryptoService.decryptMessage(cipherText, teamKey);
      expect(decrypted, equals(plainText));
    });

    test('decrypting with wrong key throws CryptoException', () {
      final plainText = 'Secret Message';
      final trueKey = CryptoService.generateTeamKey('true_pass', salt: 'salt');
      final wrongKey = CryptoService.generateTeamKey('wrong_pass', salt: 'salt');

      final cipherText = CryptoService.encryptMessage(plainText, trueKey);

      expect(
        () => CryptoService.decryptMessage(cipherText, wrongKey),
        throwsA(isA<CryptoException>()),
      );
    });

    test('decrypting malformed cipher text throws CryptoException', () {
      final key = CryptoService.generateTeamKey('pass', salt: 'salt');
      
      // Too short
      expect(
        () => CryptoService.decryptMessage(base64.encode([1, 2, 3]), key),
        throwsA(isA<CryptoException>()),
      );

      // Not base64
      expect(
        () => CryptoService.decryptMessage('not_base64_string!!!!', key),
        throwsA(isA<CryptoException>()), // base64 decode will throw FormatException but CryptoService wraps it
      );
    });

    test('sha256Hash produces valid base64 hash', () {
      final hash = CryptoService.sha256Hash('test');
      expect(hash.isNotEmpty, true);
      
      final hashBytes = base64.decode(hash);
      expect(hashBytes.length, 32); // 256 bits = 32 bytes
    });

    test('sha256Hash is deterministic', () {
      final hash1 = CryptoService.sha256Hash('message');
      final hash2 = CryptoService.sha256Hash('message');
      expect(hash1, equals(hash2));
    });
  });
}
