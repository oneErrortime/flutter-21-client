/// quic_noise_service.dart
///
/// Alternative P2P transport: QUIC + Noise Protocol Framework (IK pattern).
///
/// This provides a lower-latency alternative to WebRTC:
///   - Noise IK handshake: 1 RTT (vs 4-6 RTT for ICE + DTLS)
///   - QUIC transport: 0-RTT resumption, no head-of-line blocking,
///     seamless network migration (WiFi → LTE keeps the call alive)
///   - ChaCha20-Poly1305 AEAD: encryption equivalent to DTLS-SRTP
///
/// Architecture reference: docs/content/QUIC Noise Architecture.md

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ---------------------------------------------------------------------------
// Transport type selector
// ---------------------------------------------------------------------------

enum TransportType {
  /// Standard WebRTC P2P (existing implementation)
  webrtc,

  /// QUIC + Noise IK — ultra-low latency, best for 2-party calls
  quicNoise,

  /// LiveKit SFU + SFrame — group calls, Zoom-like experience
  livekit,
}

// ---------------------------------------------------------------------------
// Noise static key management
// ---------------------------------------------------------------------------

/// Manages the local Noise static key pair (persistent X25519 identity).
/// The public key is shared with peers via the signaling server so they
/// can use the Noise IK pattern (remote static key is known in advance).
class NoiseKeyManager {
  static const _storage = FlutterSecureStorage();
  static const _privateKeyStorageKey = 'noise_static_private_key';
  static const _publicKeyStorageKey  = 'noise_static_public_key';

  SimpleKeyPair? _keyPair;

  /// Load existing key pair from Keystore, or generate a new one.
  Future<void> init() async {
    final existingPriv = await _storage.read(key: _privateKeyStorageKey);
    final existingPub  = await _storage.read(key: _publicKeyStorageKey);

    if (existingPriv != null && existingPub != null) {
      // Restore from secure storage
      final privBytes = base64.decode(existingPriv);
      final pubBytes  = base64.decode(existingPub);
      _keyPair = await X25519().newKeyPairFromSeed(privBytes);
      // Verify the stored public key matches
      final derived = await _keyPair!.extractPublicKey();
      assert(listEquals(derived.bytes, pubBytes), 'Key pair mismatch in storage');
    } else {
      // Generate fresh identity
      _keyPair = await X25519().newKeyPair();
      final pub = await _keyPair!.extractPublicKey();
      final priv = await _keyPair!.extractPrivateKeyBytes();
      await _storage.write(key: _privateKeyStorageKey, value: base64.encode(priv));
      await _storage.write(key: _publicKeyStorageKey,  value: base64.encode(pub.bytes));
    }
  }

  /// Base64-encoded X25519 public key to share with the signaling server.
  Future<String> get publicKeyBase64 async {
    final pub = await _keyPair!.extractPublicKey();
    return base64.encode(pub.bytes);
  }

  SimpleKeyPair get keyPair {
    assert(_keyPair != null, 'NoiseKeyManager.init() must be called first');
    return _keyPair!;
  }

  bool listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// Noise IK Handshake
// ---------------------------------------------------------------------------
//
// Pattern:
//   <- s                         (Bob's static key known from server)
//   ...
//   -> e, es, s, ss              (Alice sends ephemeral + static)
//   <- e, ee, se                 (Bob responds)
//
// After handshake: ChaCha20-Poly1305 AEAD for all frames.
// ---------------------------------------------------------------------------

class NoiseHandshakeResult {
  final Uint8List sendKey;    // ChaCha20-Poly1305 key for outbound frames
  final Uint8List receiveKey; // ChaCha20-Poly1305 key for inbound frames
  final Uint8List handshakeHash; // Can be displayed for key verification

  const NoiseHandshakeResult({
    required this.sendKey,
    required this.receiveKey,
    required this.handshakeHash,
  });
}

/// Simplified Noise IK handshake using X25519 + HKDF-SHA256.
///
/// This is a pedagogical implementation illustrating the key exchange.
/// In production, use a audited Noise implementation (e.g. noise-rust via FFI,
/// or the `noise_protocol` Dart package once it reaches stability).
class NoiseHandshake {
  final SimpleKeyPair _localStatic;
  final SimplePublicKey _remoteStatic;

  NoiseHandshake({
    required SimpleKeyPair localStatic,
    required SimplePublicKey remoteStatic,
  })  : _localStatic = localStatic,
        _remoteStatic = remoteStatic;

  /// Initiator side: returns (message1Bytes, session promise).
  /// message1Bytes are sent to the responder over the signaling channel.
  Future<({Uint8List message1, Future<NoiseHandshakeResult> Function(Uint8List message2) finish})>
      initiate() async {
    final x25519 = X25519();

    // e: generate ephemeral key pair
    final ephemeral = await x25519.newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();

    // es = DH(ephemeral, remoteStatic)
    final es = await x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: _remoteStatic,
    );

    // s = local static public key
    final localPub = await _localStatic.extractPublicKey();

    // ss = DH(localStatic, remoteStatic)
    final ss = await x25519.sharedSecretKey(
      keyPair: _localStatic,
      remotePublicKey: _remoteStatic,
    );

    // Build message1: ephemeral public key + encrypted static public key
    final message1 = Uint8List(64)
      ..setRange(0, 32, ephemeralPub.bytes)
      ..setRange(32, 64, localPub.bytes); // simplified: not yet encrypted

    return (
      message1: message1,
      finish: (Uint8List message2) async {
        // Process responder's message2 (responder ephemeral key)
        final responderEphemeralPub = SimplePublicKey(
          message2.sublist(0, 32),
          type: KeyPairType.x25519,
        );

        // ee = DH(initiatorEphemeral, responderEphemeral)
        final ee = await x25519.sharedSecretKey(
          keyPair: ephemeral,
          remotePublicKey: responderEphemeralPub,
        );

        // se = DH(initiatorEphemeral, responderStatic) — simplified
        // In full Noise: se = DH(initiatorEphemeral, responderStatic)
        final se = await x25519.sharedSecretKey(
          keyPair: ephemeral,
          remotePublicKey: _remoteStatic,
        );

        // Derive final session keys via HKDF
        return await _deriveSessionKeys(
          ikm: Uint8List.fromList([
            ...await es.extractBytes(),
            ...await ss.extractBytes(),
            ...await ee.extractBytes(),
            ...await se.extractBytes(),
          ]),
        );
      },
    );
  }

  static Future<NoiseHandshakeResult> _deriveSessionKeys({
    required Uint8List ikm,
  }) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: Uint8List(32),
      info: utf8.encode('voicecall-noise-v1'),
    );
    final keyBytes = await derived.extractBytes();
    return NoiseHandshakeResult(
      sendKey:    Uint8List.fromList(keyBytes.sublist(0, 32)),
      receiveKey: Uint8List.fromList(keyBytes.sublist(32, 64)),
      handshakeHash: Uint8List.fromList(keyBytes.sublist(0, 32)),
    );
  }
}

// ---------------------------------------------------------------------------
// Noise Cipher Session
// ---------------------------------------------------------------------------
//
// After handshake, all frames use ChaCha20-Poly1305 AEAD.
// Nonce = 96-bit little-endian frame counter (rekey after 2^64 frames).
// ---------------------------------------------------------------------------

class NoiseCipherSession {
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final _chacha = Chacha20.poly1305Aead();

  int _sendNonce = 0;
  int _receiveNonce = 0;

  NoiseCipherSession({
    required Uint8List sendKey,
    required Uint8List receiveKey,
  })  : _sendKey = SecretKey(sendKey),
        _receiveKey = SecretKey(receiveKey);

  /// Encrypt an Opus audio frame (or any payload).
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final nonce = _buildNonce(_sendNonce++);
    final box = await _chacha.encrypt(
      plaintext,
      secretKey: _sendKey,
      nonce: nonce,
    );
    return Uint8List.fromList(box.concatenation());
  }

  /// Decrypt a received frame.
  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    final nonce = _buildNonce(_receiveNonce++);
    final box = SecretBox(
      ciphertext.sublist(0, ciphertext.length - 16),
      nonce: nonce,
      mac: Mac(ciphertext.sublist(ciphertext.length - 16)),
    );
    final plaintext = await _chacha.decrypt(box, secretKey: _receiveKey);
    return Uint8List.fromList(plaintext);
  }

  /// Build 12-byte nonce from 64-bit counter (little-endian, 4-byte zero pad).
  static List<int> _buildNonce(int counter) {
    final nonce = Uint8List(12);
    final view = ByteData.sublistView(nonce);
    view.setUint32(0, counter & 0xFFFFFFFF, Endian.little);
    view.setUint32(4, (counter >> 32) & 0xFFFFFFFF, Endian.little);
    return nonce;
  }
}

// ---------------------------------------------------------------------------
// QuicNoiseCall — high-level API
// ---------------------------------------------------------------------------

/// Manages the lifecycle of a QUIC + Noise encrypted call.
///
/// Usage:
/// ```dart
/// final call = QuicNoiseCall(
///   localKeys: noiseKeyManager,
///   remotePublicKeyBase64: peerPublicKey,
///   onAudioFrame: (frame) => audioOutput.play(frame),
/// );
///
/// await call.connect(peerIp, peerPort);
/// await call.sendAudio(opusFrame);
/// await call.close();
/// ```
class QuicNoiseCall {
  final NoiseKeyManager _localKeys;
  final String _remotePublicKeyBase64;
  final void Function(Uint8List opusFrame) onAudioFrame;
  final void Function(String reason)? onDisconnected;

  NoiseCipherSession? _session;
  bool _connected = false;

  // TODO: Replace with actual QUIC connection when quic_dart stabilises.
  // For now this is the interface contract; integration requires either:
  //   a) quic_dart package (tracks quinn-rs)
  //   b) Platform channel to native QUIC (Android: Cronet / Quiche)
  dynamic _quicConnection; // QuicConnection placeholder

  QuicNoiseCall({
    required NoiseKeyManager localKeys,
    required String remotePublicKeyBase64,
    required this.onAudioFrame,
    this.onDisconnected,
  })  : _localKeys = localKeys,
        _remotePublicKeyBase64 = remotePublicKeyBase64;

  /// Initiate a QUIC connection and perform the Noise IK handshake.
  Future<void> connect(String peerIp, int peerPort) async {
    assert(!_connected, 'Already connected');

    final remoteKeyBytes = base64.decode(_remotePublicKeyBase64);
    final remotePublicKey = SimplePublicKey(remoteKeyBytes, type: KeyPairType.x25519);

    final handshake = NoiseHandshake(
      localStatic: _localKeys.keyPair,
      remoteStatic: remotePublicKey,
    );

    // 1. Perform Noise IK handshake (1 RTT)
    final (:message1, :finish) = await handshake.initiate();

    // 2. Send message1 to peer via QUIC stream 0
    //    (actual QUIC send would go here)
    //    final message2 = await _quicConnection.sendAndReceive(message1);

    // 3. Placeholder: in a real implementation receive message2 from peer
    //    and call finish(message2)
    //    _session = NoiseCipherSession(
    //      sendKey:    result.sendKey,
    //      receiveKey: result.receiveKey,
    //    );

    _connected = true;
    // Start audio receive loop
    // _startReceiveLoop();
  }

  /// Send an Opus audio frame to the peer.
  Future<void> sendAudio(Uint8List opusFrame) async {
    assert(_connected && _session != null, 'Not connected');
    final encrypted = await _session!.encrypt(opusFrame);

    // Frame format: [2-byte length BE][encrypted payload]
    final frame = ByteData(2 + encrypted.length);
    frame.setUint16(0, encrypted.length, Endian.big);
    frame.buffer.asUint8List(2).setAll(0, encrypted);

    // TODO: _quicConnection.audioStream.write(frame.buffer.asUint8List())
  }

  Future<void> close() async {
    _connected = false;
    _session = null;
    // TODO: _quicConnection.close()
  }

  bool get isConnected => _connected;
}

// ---------------------------------------------------------------------------
// Signaling extensions for QUIC/Noise
// ---------------------------------------------------------------------------
//
// These message types extend the existing WebSocket signaling protocol.
// Add to SignalingService alongside the existing WebRTC messages.
// ---------------------------------------------------------------------------

class QuicNoiseSignaling {
  /// Message sent to announce QUIC/Noise capability during auth.
  static Map<String, dynamic> authMessage({
    required String jwtToken,
    required String noisePublicKeyBase64,
  }) => {
    'type': 'auth',
    'token': jwtToken,
    'noisePublicKey': noisePublicKeyBase64,
    'capabilities': ['webrtc', 'quic-noise'],
  };

  /// Initiate a QUIC/Noise call to a peer.
  static Map<String, dynamic> callMessage({
    required String targetUserId,
    required String noisePublicKeyBase64,
    required String localQuicEndpoint, // "ip:port"
  }) => {
    'type': 'call-quic',
    'targetUserId': targetUserId,
    'noisePublicKey': noisePublicKeyBase64,
    'quicEndpoint': localQuicEndpoint,
  };

  /// Answer a QUIC/Noise incoming call.
  static Map<String, dynamic> answerMessage({
    required String callerId,
    required String noisePublicKeyBase64,
    required String localQuicEndpoint,
  }) => {
    'type': 'answer-quic',
    'callerId': callerId,
    'noisePublicKey': noisePublicKeyBase64,
    'quicEndpoint': localQuicEndpoint,
  };
}
