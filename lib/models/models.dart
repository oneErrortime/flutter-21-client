// models/models.dart
//
// Core domain models for the VoiceCall application.
//
// RFC / standards tracked:
//   RFC 4566 — SDP
//   RFC 8825 / 8829 — WebRTC overview & JSEP
//   RFC 8445 — ICE
//   RFC 5764 — DTLS-SRTP (fingerprints)
//   RFC 9605 — SFrame (E2E encryption through SFU)

// ── User ────────────────────────────────────────────────────────────────────

class UserModel {
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final DateTime? lastSeen;

  // Noise public key for QUIC-Noise transport (X25519, base64-encoded)
  final String? noisePublicKey;

  // Capabilities advertised by this user during auth
  final Set<String> capabilities; // e.g. {'webrtc', 'quic-noise', 'livekit'}

  const UserModel({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.lastSeen,
    this.noisePublicKey,
    this.capabilities = const {'webrtc'},
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      userId: json['userId'] as String,
      username: json['username'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      lastSeen: json['lastSeen'] != null
          ? DateTime.tryParse(json['lastSeen'] as String)
          : null,
      noisePublicKey: json['noisePublicKey'] as String?,
      capabilities: (json['capabilities'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          const {'webrtc'},
    );
  }

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'displayName': displayName,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        if (lastSeen != null) 'lastSeen': lastSeen!.toIso8601String(),
        if (noisePublicKey != null) 'noisePublicKey': noisePublicKey,
        'capabilities': capabilities.toList(),
      };

  bool get supportsQuicNoise => capabilities.contains('quic-noise');
  bool get supportsLiveKit => capabilities.contains('livekit');

  UserModel copyWith({
    String? displayName,
    String? avatarUrl,
    DateTime? lastSeen,
    String? noisePublicKey,
    Set<String>? capabilities,
  }) =>
      UserModel(
        userId: userId,
        username: username,
        displayName: displayName ?? this.displayName,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        lastSeen: lastSeen ?? this.lastSeen,
        noisePublicKey: noisePublicKey ?? this.noisePublicKey,
        capabilities: capabilities ?? this.capabilities,
      );
}

// ── Call State ───────────────────────────────────────────────────────────────

enum CallState {
  idle,
  calling,     // Outgoing: dialling, waiting for peer
  ringing,     // Incoming: ringing (user sees incoming screen)
  connecting,  // ICE / media negotiation in progress
  connected,   // Media flowing
  ended,
  declined,
  missed,
  failed,
}

extension CallStateX on CallState {
  bool get isIdle =>
      this == CallState.idle ||
      this == CallState.ended ||
      this == CallState.declined ||
      this == CallState.failed ||
      this == CallState.missed;

  bool get isActive =>
      this == CallState.connecting || this == CallState.connected;

  bool get isTerminal =>
      this == CallState.ended ||
      this == CallState.declined ||
      this == CallState.failed ||
      this == CallState.missed;
}

// ── Transport Mode ───────────────────────────────────────────────────────────

enum TransportMode {
  /// Standard WebRTC P2P (STUN-only, same-network / simple NAT).
  webrtcDirect,

  /// WebRTC P2P via TURN relay — works through symmetric NAT / strict firewalls.
  webrtcTurn,

  /// WebRTC SFU relay — media flows through the Rust signaling server.
  /// Enables server-side recording; no E2E unless SFrame is enabled.
  webrtcSfu,

  /// QUIC + Noise IK — ultra-low latency, 1-RTT handshake, network migration.
  quicNoise,

  /// LiveKit SFU + SFrame (RFC 9605) — Zoom-like group calls with E2E.
  livekit,
}

extension TransportModeX on TransportMode {
  String get displayName => switch (this) {
        TransportMode.webrtcDirect => 'WebRTC Direct',
        TransportMode.webrtcTurn => 'WebRTC (TURN)',
        TransportMode.webrtcSfu => 'Server Relay (SFU)',
        TransportMode.quicNoise => 'QUIC+Noise',
        TransportMode.livekit => 'LiveKit (group)',
      };

  bool get isP2P =>
      this == TransportMode.webrtcDirect ||
      this == TransportMode.webrtcTurn ||
      this == TransportMode.quicNoise;

  bool get isE2E => this != TransportMode.webrtcSfu;
}

// ── Media Kind ───────────────────────────────────────────────────────────────

enum MediaKind { audioOnly, audioVideo }

// ── Video Track Info ─────────────────────────────────────────────────────────

class VideoTrackInfo {
  final String participantId;
  final String displayName;
  final bool isLocal;
  final bool isEnabled;

  const VideoTrackInfo({
    required this.participantId,
    required this.displayName,
    required this.isLocal,
    required this.isEnabled,
  });

  VideoTrackInfo copyWith({bool? isEnabled}) => VideoTrackInfo(
        participantId: participantId,
        displayName: displayName,
        isLocal: isLocal,
        isEnabled: isEnabled ?? this.isEnabled,
      );
}

// ── Call Model ───────────────────────────────────────────────────────────────

class CallModel {
  final String callId;
  final UserModel? peer;
  final bool isIncoming;
  final CallState state;
  final TransportMode transport;
  final MediaKind mediaKind;
  final DateTime startedAt;
  DateTime? connectedAt;
  DateTime? endedAt;

  CallModel({
    required this.callId,
    this.peer,
    required this.isIncoming,
    required this.state,
    this.transport = TransportMode.webrtcTurn,
    this.mediaKind = MediaKind.audioOnly,
    required this.startedAt,
    this.connectedAt,
    this.endedAt,
  });

  Duration? get duration => connectedAt != null && endedAt != null
      ? endedAt!.difference(connectedAt!)
      : null;

  String get peerDisplayName =>
      peer?.displayName ?? peer?.username ?? 'Unknown';
}

// ── ICE / TURN credential model ──────────────────────────────────────────────

class IceServerConfig {
  final List<IceServer> servers;

  const IceServerConfig({required this.servers});

  factory IceServerConfig.fromJson(Map<String, dynamic> json) {
    final list = json['iceServers'] as List<dynamic>? ?? [];
    return IceServerConfig(
      servers: list
          .map((e) => IceServer.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  List<Map<String, dynamic>> toRtcConfig() =>
      servers.map((s) => s.toMap()).toList();
}

class IceServer {
  final String urls;
  final String? username;
  final String? credential;

  const IceServer({required this.urls, this.username, this.credential});

  factory IceServer.fromJson(Map<String, dynamic> json) => IceServer(
        urls: json['urls'] as String,
        username: json['username'] as String?,
        credential: json['credential'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'urls': urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };
}
