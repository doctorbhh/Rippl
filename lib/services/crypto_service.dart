import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

/// Service for AES-256-CBC encryption/decryption
class CryptoService {
  /// Generate a 256-bit AES key from a password using PBKDF2
  static String generateTeamKey(String password, {String? salt}) {
    final saltBytes = salt != null
        ? utf8.encode(salt)
        : utf8.encode('rippl_mountain_salt_${password.length}');

    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
        Uint8List.fromList(saltBytes),
        10000, // iterations
        32, // 256 bits = 32 bytes
      ));

    final key = derivator.process(Uint8List.fromList(utf8.encode(password)));
    return base64.encode(key);
  }

  /// Generate a random 16-byte IV
  static IV generateIV() {
    return IV.fromSecureRandom(16);
  }

  /// Encrypt a message using AES-256-CBC
  /// Returns base64 encoded string: IV + encrypted data
  static String encryptMessage(String plainText, String teamKeyBase64) {
    try {
      final key = Key.fromBase64(teamKeyBase64);
      final iv = generateIV();
      final encrypter = Encrypter(AES(key, mode: AESMode.cbc));

      final encrypted = encrypter.encrypt(plainText, iv: iv);

      // Combine IV + encrypted data for transmission
      final combined = iv.bytes + encrypted.bytes;
      return base64.encode(combined);
    } catch (e) {
      throw CryptoException('Encryption failed: $e');
    }
  }

  /// Decrypt a message using AES-256-CBC
  /// Expects base64 encoded string: IV (16 bytes) + encrypted data
  static String decryptMessage(String cipherText, String teamKeyBase64) {
    try {
      final combined = base64.decode(cipherText);

      if (combined.length < 17) {
        throw CryptoException('Invalid cipher text: too short');
      }

      // Extract IV (first 16 bytes) and encrypted data
      final ivBytes = combined.sublist(0, 16);
      final encryptedBytes = combined.sublist(16);

      final key = Key.fromBase64(teamKeyBase64);
      final iv = IV(Uint8List.fromList(ivBytes));
      final encrypter = Encrypter(AES(key, mode: AESMode.cbc));

      final encrypted = Encrypted(Uint8List.fromList(encryptedBytes));
      return encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      if (e is CryptoException) rethrow;
      throw CryptoException('Decryption failed: $e');
    }
  }

  /// Hash a string using SHA-256
  static String sha256Hash(String input) {
    final digest = SHA256Digest();
    final hash = digest.process(Uint8List.fromList(utf8.encode(input)));
    return base64.encode(hash);
  }
}

/// Exception for crypto operations
class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);

  @override
  String toString() => 'CryptoException: $message';
}
