/// livekit_service.dart
///
/// Zoom-like group call implementation using LiveKit SFU + SFrame E2E encryption.
///
/// Architecture:
///   - LiveKit SFU handles media forwarding at scale (1–100+ participants)
///   - SFrame (RFC 9605) provides E2E encryption through the SFU
///   - The SFU cannot decrypt media — only participants hold the keys
///
/// Architecture reference: docs/content/QUIC Noise Architecture.md

import 'dart:async';

// ---------------------------------------------------------------------------
// LiveKit call service
// ---------------------------------------------------------------------------
//
// Add to pubspec.yaml:
//   livekit_client: ^2.1.0
//
// This file uses the LiveKit Flutter SDK API. The import is commented out
// so the project compiles without the dependency being added yet.
// Uncomment when adding livekit_client to pubspec.yaml.
//
// import 'package:livekit_client/livekit_client.dart';
// ---------------------------------------------------------------------------

/// Manages a LiveKit room with SFrame E2E encryption.
///
/// This enables Zoom-like group calls where:
///   - The server (SFU) forwards encrypted media frames
///   - The SFU cannot decrypt audio or video
///   - All participants hold a shared epoch key (rotated when someone leaves)
class LiveKitCallService {
  // Room? _room;  // uncomment with livekit_client
  // ignore: unused_field
  dynamic _room; // placeholder until livekit_client is added to pubspec

  final StreamController<List<RemoteParticipantInfo>> _participantsController =
      StreamController.broadcast();
  final StreamController<bool> _micController = StreamController.broadcast();
  final StreamController<bool> _cameraController = StreamController.broadcast();

  bool _micEnabled = false;
  bool _cameraEnabled = false;

  /// Connect to a LiveKit room with E2E encryption.
  ///
  /// [serverUrl] — LiveKit server WebSocket URL, e.g. `wss://livekit.yourapp.com`
  /// [token]     — Room token (generated server-side with LiveKit Server SDK)
  /// [roomKey]   — Shared encryption key for SFrame E2E (all participants need the same key)
  Future<void> joinRoom({
    required String serverUrl,
    required String token,
    required String roomKey,
    bool enableVideo = false,
    int audioBitrate = 32000,
  }) async {
    // With livekit_client, this becomes:
    //
    // _room = Room();
    //
    // await _room!.connect(
    //   serverUrl,
    //   token,
    //   roomOptions: RoomOptions(
    //     // SFrame E2E encryption — SFU cannot decrypt media
    //     e2eeOptions: E2EEOptions(
    //       keyProvider: SharedKeyKeyProvider(sharedKey: roomKey),
    //     ),
    //     defaultAudioPublishOptions: AudioPublishOptions(
    //       audioBitrate: audioBitrate, // 32kbps Opus = Zoom-quality voice
    //       dtx: true,                  // Silence suppression
    //       noiseSuppression: true,
    //       echoCancellation: true,
    //       autoGainControl: true,
    //     ),
    //     defaultVideoPublishOptions: enableVideo
    //       ? VideoPublishOptions(
    //           simulcast: true,          // Multiple quality layers
    //           videoEncoding: VideoEncoding(
    //             maxBitrate: 1200000,    // 1.2 Mbps @ 720p
    //             maxFramerate: 30,
    //           ),
    //         )
    //       : null,
    //   ),
    // );
    //
    // // Publish microphone
    // await _room!.localParticipant?.setMicrophoneEnabled(true);
    // _micEnabled = true;
    // _micController.add(true);
    //
    // // Set up participant listener
    // _room!.addListener(_onRoomUpdate);

    throw UnimplementedError(
      'Add livekit_client to pubspec.yaml to enable LiveKit calls. '
      'See docs/content/QUIC Noise Architecture.md for setup instructions.',
    );
  }

  /// Toggle microphone.
  Future<void> setMicrophoneEnabled(bool enabled) async {
    // await _room?.localParticipant?.setMicrophoneEnabled(enabled);
    _micEnabled = enabled;
    _micController.add(enabled);
  }

  /// Toggle camera.
  Future<void> setCameraEnabled(bool enabled) async {
    // await _room?.localParticipant?.setCameraEnabled(enabled);
    _cameraEnabled = enabled;
    _cameraController.add(enabled);
  }

  /// Screen share (for presentations / Zoom-style screen sharing).
  Future<void> setScreenShareEnabled(bool enabled) async {
    // await _room?.localParticipant?.setScreenShareEnabled(enabled);
  }

  /// Leave the room and clean up.
  Future<void> leaveRoom() async {
    // await _room?.disconnect();
    _room = null;
    _micEnabled = false;
    _cameraEnabled = false;
  }

  // ── Streams ───────────────────────────────────────────────────────────────

  Stream<List<RemoteParticipantInfo>> get participants =>
      _participantsController.stream;

  Stream<bool> get micState => _micController.stream;
  Stream<bool> get cameraState => _cameraController.stream;

  bool get isMicEnabled => _micEnabled;
  bool get isCameraEnabled => _cameraEnabled;

  void dispose() {
    _participantsController.close();
    _micController.close();
    _cameraController.close();
  }
}

/// Info about a remote participant displayed in the call UI.
class RemoteParticipantInfo {
  final String identity;
  final String displayName;
  final bool isAudioEnabled;
  final bool isVideoEnabled;
  final bool isSpeaking;

  const RemoteParticipantInfo({
    required this.identity,
    required this.displayName,
    required this.isAudioEnabled,
    required this.isVideoEnabled,
    required this.isSpeaking,
  });
}

// ---------------------------------------------------------------------------
// LiveKit token generation (server-side reference)
// ---------------------------------------------------------------------------
//
// The room token must be generated on your server using the LiveKit Server SDK.
// Add to server/src/routes/rooms.js:
//
// const { AccessToken } = require('livekit-server-sdk');
//
// router.post('/api/rooms/livekit-token', auth, async (req, res) => {
//   const { roomName } = req.body;
//   const token = new AccessToken(
//     process.env.LIVEKIT_API_KEY,
//     process.env.LIVEKIT_API_SECRET,
//     { identity: req.user.userId }
//   );
//   token.addGrant({
//     roomJoin: true,
//     room: roomName,
//     canPublish: true,
//     canSubscribe: true,
//   });
//   res.json({ token: await token.toJwt() });
// });
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Transport selector
// ---------------------------------------------------------------------------

/// Decides which transport to use based on participant count and capabilities.
///
/// This allows the app to seamlessly use the optimal transport:
///   - 2 parties  → QUIC + Noise (ultra-low latency)
///   - 3+ parties → LiveKit SFU (scalable, E2E via SFrame)
///   - Fallback   → WebRTC (always available)
class TransportSelector {
  static TransportMode select({
    required int participantCount,
    required bool peerSupportsQuicNoise,
    required bool livekitAvailable,
  }) {
    if (participantCount >= 3 && livekitAvailable) {
      return TransportMode.livekit;
    }
    if (participantCount == 2 && peerSupportsQuicNoise) {
      return TransportMode.quicNoise;
    }
    return TransportMode.webrtc;
  }
}

enum TransportMode {
  /// Existing WebRTC P2P implementation
  webrtc,

  /// QUIC + Noise IK — ultra-low latency 2-party calls
  quicNoise,

  /// LiveKit SFU + SFrame — Zoom-like group calls
  livekit,
}
