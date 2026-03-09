import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants.dart';
import '../services/secure_storage_service.dart';

enum SignalingState { disconnected, connecting, connected, authenticated }

typedef MessageCallback = void Function(Map<String, dynamic> message);

class SignalingService extends ChangeNotifier {
  WebSocketChannel? _channel;
  SignalingState _state = SignalingState.disconnected;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  // Event callbacks
  final Map<String, List<MessageCallback>> _handlers = {};

  SignalingState get state => _state;
  bool get isConnected => _state == SignalingState.authenticated;

  // ── Connect ────────────────────────────────────────────────────────────────
  Future<void> connect() async {
    if (_state != SignalingState.disconnected) return;
    _reconnectAttempts = 0; // reset so reconnect works after intentional disconnect+reconnect
    _setState(SignalingState.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(AppConstants.wsUrl));
      _setState(SignalingState.connected);

      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDisconnected,
        cancelOnError: false,
      );

      // Authenticate immediately after connecting
      await _authenticate();
    } catch (e) {
      debugPrint('WS connect error: $e');
      _onDisconnected();
    }
  }

  Future<void> _authenticate() async {
    final token = await SecureStorageService.getAccessToken();
    if (token == null) {
      debugPrint('No token for WS auth');
      return;
    }
    _send({'type': 'auth', 'token': token});
  }

  // ── Disconnect ─────────────────────────────────────────────────────────────
  void disconnect() {
    _reconnectAttempts = _maxReconnectAttempts; // Prevent auto-reconnect
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setState(SignalingState.disconnected);
  }

  // ── Send ───────────────────────────────────────────────────────────────────
  void _send(Map<String, dynamic> data) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(data));
    }
  }

  // ── Message Routing ────────────────────────────────────────────────────────
  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      if (type == null) return;

      if (type == 'auth-success') {
        _setState(SignalingState.authenticated);
        _reconnectAttempts = 0;
        _startHeartbeat();
      } else if (type == 'heartbeat-ack') {
        // All good
      } else if (type == 'session-replaced') {
        debugPrint('Session replaced by new connection');
      } else {
        // Dispatch to registered handlers
        _handlers[type]?.forEach((cb) => cb(msg));
        _handlers['*']?.forEach((cb) => cb(msg)); // Wildcard handlers
      }
    } catch (e) {
      debugPrint('WS message parse error: $e');
    }
  }

  void _onError(dynamic error) {
    debugPrint('WS error: $error');
    _onDisconnected();
  }

  void _onDisconnected() {
    _heartbeatTimer?.cancel();
    _setState(SignalingState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _reconnectAttempts++;
    final delay = Duration(
      seconds: (_reconnectAttempts * 2).clamp(2, 30),
    );
    debugPrint('Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, connect);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(AppConstants.heartbeatInterval, (_) {
      _send({'type': 'heartbeat'});
    });
  }

  void _setState(SignalingState state) {
    _state = state;
    notifyListeners();
  }

  // ── Event Subscription ─────────────────────────────────────────────────────
  void on(String type, MessageCallback callback) {
    _handlers.putIfAbsent(type, () => []).add(callback);
  }

  void off(String type, MessageCallback callback) {
    _handlers[type]?.remove(callback);
  }

  // ── Signaling Actions ──────────────────────────────────────────────────────
  void sendCall(String toUserId, Map<String, dynamic> offer) {
    _send({'type': 'call', 'to': toUserId, 'offer': offer});
  }

  void sendAnswer(String toUserId, Map<String, dynamic> answer) {
    _send({'type': 'answer', 'to': toUserId, 'answer': answer});
  }

  void sendIceCandidate(String toUserId, Map<String, dynamic> candidate) {
    _send({'type': 'ice', 'to': toUserId, 'candidate': candidate});
  }

  void sendHangup(String toUserId) {
    _send({'type': 'hangup', 'to': toUserId});
  }

  void sendDecline(String toUserId, {String reason = 'declined'}) {
    _send({'type': 'decline', 'to': toUserId, 'reason': reason});
  }

  void createRoom() {
    _send({'type': 'create-room'});
  }

  void joinRoom(String roomId, Map<String, dynamic> offer) {
    _send({'type': 'join-room', 'roomId': roomId, 'offer': offer});
  }

  void hostRoom(String roomId) {
    _send({'type': 'room-host', 'roomId': roomId});
  }

  void sendRoomAnswer(String roomId, Map<String, dynamic> answer, {String? joinerId}) {
    _send({
      'type': 'room-answer',
      'roomId': roomId,
      'answer': answer,
      if (joinerId != null) 'joinerId': joinerId, // required by Rust server
    });
  }

  void sendRoomHangup(String roomId) {
    _send({'type': 'room-hangup', 'roomId': roomId});
  }

  void sendRoomIce(String roomId, Map<String, dynamic> candidate, String role) {
    _send({'type': 'room-ice', 'roomId': roomId, 'candidate': candidate, 'role': role});
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
