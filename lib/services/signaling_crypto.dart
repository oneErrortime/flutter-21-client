/// Client-side AES-256-GCM decryption for signaling payloads.
/// Mirrors server-rust/src/crypto/mod.rs encryption scheme.
///
/// The Rust server encrypts SDP offers/answers and ICE candidates before
/// forwarding them over the WebSocket. This prevents a compromised TLS
/// termination proxy from reading call metadata in plaintext.
///
/// Wire format (from server): `<nonce_hex>:<ciphertext_hex>`
/// where ciphertext_hex includes the 16-byte GCM auth tag appended.
///
/// Requires in pubspec.yaml:
///   cryptography: ^2.7.0

import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';

class SignalingCrypto {
  final Uint8List _key;
  final AesGcm _algorithm = AesGcm.with256bits();

  SignalingCrypto(this._key);

  /// Decrypt a server-encrypted signaling payload.
  ///
  /// Format: `nonce_hex:ciphertext_with_tag_hex`
  /// Returns the original plaintext string.
  /// Returns [encrypted] unchanged if it doesn't match the expected format,
  /// so that plain-text messages (Node.js server path) work transparently.
  Future<String> decrypt(String encrypted) async {
    final colonIdx = encrypted.indexOf(':');
    if (colonIdx < 0) return encrypted; // Not encrypted, pass through

    try {
      final nonceHex = encrypted.substring(0, colonIdx);
      final ciphertextHex = encrypted.substring(colonIdx + 1);

      final nonceBytes = Uint8List.fromList(hex.decode(nonceHex));
      final ciphertextWithTag = Uint8List.fromList(hex.decode(ciphertextHex));

      // GCM tag is the last 16 bytes
      final ciphertext = ciphertextWithTag.sublist(0, ciphertextWithTag.length - 16);
      final tag = ciphertextWithTag.sublist(ciphertextWithTag.length - 16);

      final secretKey = await _algorithm.newSecretKeyFromBytes(_key);
      final secretBox = SecretBox(
        ciphertext,
        nonce: nonceBytes,
        mac: Mac(tag),
      );

      final cleartext = await _algorithm.decrypt(secretBox, secretKey: secretKey);
      return utf8.decode(cleartext);
    } catch (e) {
      // Decryption failed (wrong key, corrupted payload, or not encrypted).
      // Return as-is so the call can proceed with whatever data arrived.
      return encrypted;
    }
  }

  /// Encrypt a payload (useful if client→server E2E encryption is needed).
  Future<String> encrypt(String plaintext) async {
    final secretKey = await _algorithm.newSecretKeyFromBytes(_key);
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
    );

    final nonce = secretBox.nonce;
    final ciphertextWithTag = Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return '${hex.encode(nonce)}:${hex.encode(ciphertextWithTag)}';
  }
}
