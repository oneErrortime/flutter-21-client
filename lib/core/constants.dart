class AppConstants {
  // ── Server ─────────────────────────────────────────────────────────────────
  // Change these to your actual server URL before building
  static const String baseUrl = 'https://yourapp.com';
  static const String wsUrl = 'wss://yourapp.com/ws';

  // For local emulator development:
  // Android emulator: 10.0.2.2 points to host machine localhost
  // static const String baseUrl = 'http://10.0.2.2:3000';
  // static const String wsUrl = 'ws://10.0.2.2:3000/ws';

  // ── Timeouts ───────────────────────────────────────────────────────────────
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 15);
  static const Duration wsReconnectDelay = Duration(seconds: 3);
  static const Duration callRingTimeout = Duration(seconds: 45);
  static const Duration heartbeatInterval = Duration(seconds: 25);

  // ── Secure Storage Keys ────────────────────────────────────────────────────
  static const String kAccessToken = 'access_token';
  static const String kRefreshToken = 'refresh_token';
  static const String kUserId = 'user_id';
  static const String kUsername = 'username';
  static const String kDisplayName = 'display_name';

  // ── ICE Servers (RFC 8445) ─────────────────────────────────────────────────
  // Mode 1: STUN only — works on same network / simple NAT
  // Mode 2: STUN + TURN — works through symmetric NAT and strict firewalls
  static const List<Map<String, dynamic>> iceServersStunOnly = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'},
  ];

  // Full ICE config with TURN for production
  // Replace with your Coturn / Metered.ca credentials
  static const List<Map<String, dynamic>> iceServersFull = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {
      'urls': 'turn:yourapp.com:3478',
      'username': 'your_turn_user',
      'credential': 'your_turn_password'
    },
    {
      'urls': 'turn:yourapp.com:5349', // TURN over TLS
      'username': 'your_turn_user',
      'credential': 'your_turn_password'
    },
  ];

  // ── WebRTC Media Constraints (RFC 8831) ───────────────────────────────────
  static const Map<String, dynamic> audioConstraints = {
    'audio': {
      'mandatory': {
        'googEchoCancellation': 'true',
        'googAutoGainControl': 'true',
        'googNoiseSuppression': 'true',
        'googHighpassFilter': 'true',
      },
      'optional': [],
    },
    'video': false,
  };

  // ── RTCPeerConnection Config ───────────────────────────────────────────────
  static Map<String, dynamic> rtcConfig(bool useFullIce) => {
    'iceServers': useFullIce ? iceServersFull : iceServersStunOnly,
    'iceTransportPolicy': 'all', // 'relay' to force TURN
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'sdpSemantics': 'unified-plan', // RFC 8829
  };

  // ── Deep Link Scheme ───────────────────────────────────────────────────────
  static const String appScheme = 'voicecall';
  static const String joinRoomPath = '/join/';

  // ── App Info ───────────────────────────────────────────────────────────────
  static const String appName = 'VoiceCall';
  static const String appVersion = '1.0.0';
}
