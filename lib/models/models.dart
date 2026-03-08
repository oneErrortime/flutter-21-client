class UserModel {
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final DateTime? lastSeen;

  const UserModel({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.lastSeen,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      userId: json['userId'] as String,
      username: json['username'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      lastSeen: json['lastSeen'] != null ? DateTime.parse(json['lastSeen']) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'lastSeen': lastSeen?.toIso8601String(),
  };
}

enum CallState {
  idle,
  calling,      // Outgoing: dialing
  ringing,      // Incoming: ringing
  connecting,   // ICE connecting
  connected,    // In call
  ended,
  declined,
  missed,
  failed,
}

enum CallMode {
  p2pStun,   // Direct P2P with STUN (best quality, no relay cost)
  p2pTurn,   // P2P via TURN relay (works everywhere)
}

class CallModel {
  final String callId;
  final UserModel? peer;
  final bool isIncoming;
  final CallState state;
  final CallMode mode;
  final DateTime startedAt;
  DateTime? connectedAt;
  DateTime? endedAt;

  CallModel({
    required this.callId,
    this.peer,
    required this.isIncoming,
    required this.state,
    this.mode = CallMode.p2pTurn,
    required this.startedAt,
    this.connectedAt,
    this.endedAt,
  });

  Duration? get duration =>
      connectedAt != null && endedAt != null
          ? endedAt!.difference(connectedAt!)
          : null;
}
