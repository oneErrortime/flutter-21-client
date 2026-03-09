import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/constants.dart';
import '../models/models.dart';
import '../services/signaling_service.dart';

class WebRTCService extends ChangeNotifier {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  CallState _callState = CallState.idle;
  CallModel? _currentCall;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _useFullIce = true; // Use TURN by default for reliability

  // DTLS fingerprint for E2E verification (RFC 5764)
  String? _localFingerprint;
  String? _remoteFingerprint;

  CallState get callState => _callState;
  CallModel? get currentCall => _currentCall;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isInCall => _callState == CallState.connected || _callState == CallState.connecting;
  String? get localFingerprint => _localFingerprint;
  String? get remoteFingerprint => _remoteFingerprint;

  final SignalingService _signaling;
  Timer? _ringTimer;

  WebRTCService(this._signaling) {
    _registerSignalingHandlers();
  }

  void _registerSignalingHandlers() {
    _signaling.on('call-incoming', _onCallIncoming);
    _signaling.on('call-answered', _onCallAnswered);
    _signaling.on('call-declined', _onCallDeclined);
    _signaling.on('ice', _onIceCandidate);
    _signaling.on('hangup', _onHangup);
    _signaling.on('user-offline', _onPeerUnavailable);
    _signaling.on('user-busy', _onPeerUnavailable);
    _signaling.on('room-joined', _onRoomJoined);
    _signaling.on('room-answered', _onRoomAnswered);
    _signaling.on('room-ice', _onRoomIce);
    _signaling.on('room-hangup', _onHangup); // reuse same handler — ends the call
  }

  // ── OUTGOING CALL ──────────────────────────────────────────────────────────
  Future<void> callUser(UserModel peer) async {
    if (!_callState.isIdle) return;
    _setState(CallState.calling);
    _currentCall = CallModel(
      callId: DateTime.now().millisecondsSinceEpoch.toString(),
      peer: peer,
      isIncoming: false,
      state: CallState.calling,
      startedAt: DateTime.now(),
    );

    try {
      await _initPeerConnection(isCaller: true, peerId: peer.userId);
      await _getLocalAudio();
      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);

      // Extract DTLS fingerprint from SDP for E2E verification
      _localFingerprint = _extractFingerprint(offer.sdp ?? '');

      _signaling.sendCall(peer.userId, {
        'type': offer.type,
        'sdp': offer.sdp,
      });

      // Ring timeout
      _ringTimer = Timer(AppConstants.callRingTimeout, () {
        if (_callState == CallState.calling) {
          _signaling.sendHangup(peer.userId);
          _endCall();
          _setState(CallState.missed);
        }
      });
      notifyListeners();
    } catch (e) {
      debugPrint('Call error: $e');
      _endCall();
      _setState(CallState.failed);
    }
  }

  // ── INCOMING CALL RECEIVED ─────────────────────────────────────────────────
  Future<void> _onCallIncoming(Map<String, dynamic> msg) async {
    if (!_callState.isIdle) {
      // Already in a call — decline automatically
      _signaling.sendDecline(msg['from'] as String, reason: 'busy');
      return;
    }

    final peer = UserModel(
      userId: msg['from'] as String,
      username: msg['from'] as String,
      displayName: msg['callerName'] as String,
    );

    _currentCall = CallModel(
      callId: msg['callId'] as String? ?? '',
      peer: peer,
      isIncoming: true,
      state: CallState.ringing,
      startedAt: DateTime.now(),
    );
    _setState(CallState.ringing);

    // Store offer for when user accepts
    _pendingOffer = msg['offer'] as Map<String, dynamic>?;
    _pendingCallerId = msg['from'] as String;
  }

  Map<String, dynamic>? _pendingOffer;
  String? _pendingCallerId;

  // ── ACCEPT INCOMING CALL ───────────────────────────────────────────────────
  Future<void> acceptCall() async {
    if (_callState != CallState.ringing || _pendingOffer == null) return;
    _setState(CallState.connecting);

    try {
      await _initPeerConnection(isCaller: false, peerId: _pendingCallerId!);
      await _getLocalAudio();

      // Set remote offer (SDP — RFC 4566)
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(_pendingOffer!['sdp'] as String, _pendingOffer!['type'] as String),
      );

      // Extract remote DTLS fingerprint for E2E verification
      _remoteFingerprint = _extractFingerprint(_pendingOffer!['sdp'] as String);

      final answer = await _peerConnection!.createAnswer({});
      await _peerConnection!.setLocalDescription(answer);
      _localFingerprint = _extractFingerprint(answer.sdp ?? '');

      _signaling.sendAnswer(_pendingCallerId!, {
        'type': answer.type,
        'sdp': answer.sdp,
      });

      _pendingOffer = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Accept call error: $e');
      declineCall();
    }
  }

  // ── DECLINE INCOMING CALL ──────────────────────────────────────────────────
  void declineCall() {
    if (_pendingCallerId != null) {
      _signaling.sendDecline(_pendingCallerId!);
    }
    _endCall();
    _setState(CallState.idle);
  }

  // ── ANSWER RECEIVED (callee answered our offer) ────────────────────────────
  Future<void> _onCallAnswered(Map<String, dynamic> msg) async {
    _ringTimer?.cancel();
    final answerData = msg['answer'] as Map<String, dynamic>;
    _remoteFingerprint = _extractFingerprint(answerData['sdp'] as String);

    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(answerData['sdp'] as String, answerData['type'] as String),
    );
    _setState(CallState.connecting);
  }

  void _onCallDeclined(Map<String, dynamic> msg) {
    _ringTimer?.cancel();
    _endCall();
    _setState(CallState.declined);
  }

  void _onPeerUnavailable(Map<String, dynamic> msg) {
    _ringTimer?.cancel();
    _endCall();
    _setState(CallState.failed);
  }

  // ── ICE CANDIDATES (RFC 8445) ──────────────────────────────────────────────
  Future<void> _onIceCandidate(Map<String, dynamic> msg) async {
    final candidateData = msg['candidate'] as Map<String, dynamic>;
    try {
      await _peerConnection?.addCandidate(
        RTCIceCandidate(
          candidateData['candidate'] as String?,
          candidateData['sdpMid'] as String?,
          candidateData['sdpMLineIndex'] as int?,
        ),
      );
    } catch (e) {
      debugPrint('ICE candidate error: $e');
    }
  }

  void _onHangup(Map<String, dynamic> msg) {
    _endCall();
    _setState(CallState.ended);
  }

  // ── ROOM-BASED CALL ────────────────────────────────────────────────────────
  Future<void> hostRoomCall(String roomId) async {
    if (!_callState.isIdle) return;
    _setState(CallState.calling);
    _currentCall = CallModel(
      callId: roomId,
      isIncoming: false,
      state: CallState.calling,
      startedAt: DateTime.now(),
    );

    _signaling.hostRoom(roomId);
    notifyListeners();
  }

  Future<void> joinRoomCall(String roomId) async {
    if (!_callState.isIdle) return;
    _setState(CallState.connecting);

    try {
      await _initPeerConnection(isCaller: true, peerId: roomId);
      await _getLocalAudio();

      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);
      _localFingerprint = _extractFingerprint(offer.sdp ?? '');

      _signaling.joinRoom(roomId, {'type': offer.type, 'sdp': offer.sdp});
      _currentRoomId = roomId;
    } catch (e) {
      debugPrint('Join room error: $e');
      _setState(CallState.failed);
    }
  }

  String? _currentRoomId;

  Future<void> _onRoomJoined(Map<String, dynamic> msg) async {
    final offer = msg['offer'] as Map<String, dynamic>;
    _remoteFingerprint = _extractFingerprint(offer['sdp'] as String);

    // FIX: extract roomId and joinerId from the message — _currentRoomId is null
    // on the host side because hostRoomCall() doesn't set it.
    final roomId = msg['roomId'] as String? ?? _currentCall?.callId ?? '';
    _currentRoomId = roomId;
    final joinerId = msg['joinerId'] as String?;

    await _initPeerConnection(isCaller: false, peerId: roomId);
    await _getLocalAudio();
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
    );

    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    _signaling.sendRoomAnswer(
      roomId,
      {'type': answer.type, 'sdp': answer.sdp},
      joinerId: joinerId,  // FIX: pass joinerId for Rust server routing
    );
  }

  Future<void> _onRoomAnswered(Map<String, dynamic> msg) async {
    final answer = msg['answer'] as Map<String, dynamic>;
    _remoteFingerprint = _extractFingerprint(answer['sdp'] as String);
    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(answer['sdp'] as String, answer['type'] as String),
    );
    _setState(CallState.connecting);
  }

  Future<void> _onRoomIce(Map<String, dynamic> msg) async {
    final candidate = msg['candidate'] as Map<String, dynamic>;
    try {
      await _peerConnection?.addCandidate(
        RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          candidate['sdpMLineIndex'] as int?,
        ),
      );
    } catch (e) {
      debugPrint('Room ICE error: $e');
    }
  }

  // ── HANGUP ─────────────────────────────────────────────────────────────────
  void hangUp() {
    if (_currentRoomId != null) {
      // Room call: notify via room channel, both participants share the roomId
      _signaling.sendRoomHangup(_currentRoomId!);
    } else if (_currentCall?.peer != null) {
      _signaling.sendHangup(_currentCall!.peer!.userId);
    }
    _endCall();
    _setState(CallState.ended);
  }

  // ── AUDIO CONTROLS ─────────────────────────────────────────────────────────
  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !_isMuted;
    });
    notifyListeners();
  }

  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    // Platform-specific speaker routing
    Helper.setSpeakerphoneOn(_isSpeakerOn);
    notifyListeners();
  }

  // ── INTERNAL ───────────────────────────────────────────────────────────────
  Future<void> _initPeerConnection({required bool isCaller, required String peerId}) async {
    final config = AppConstants.rtcConfig(_useFullIce);
    _peerConnection = await createPeerConnection(config);

    // ICE candidate handler — send to remote peer
    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        final candidateMap = {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        };
        if (_currentRoomId != null) {
          _signaling.sendRoomIce(
            _currentRoomId!,
            candidateMap,
            isCaller ? 'callee' : 'caller',
          );
        } else {
          _signaling.sendIceCandidate(peerId, candidateMap);
        }
      }
    };

    // ICE connection state (RFC 8445)
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('ICE state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _currentCall?.connectedAt = DateTime.now();
          _setState(CallState.connected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _endCall();
          _setState(CallState.failed);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          if (_callState == CallState.connected) {
            // Temporary disconnect, try ICE restart
            _peerConnection?.restartIce();
          }
          break;
        default:
          break;
      }
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint('PC state: $state');
    };
  }

  Future<void> _getLocalAudio() async {
    _localStream = await navigator.mediaDevices.getUserMedia(
      AppConstants.audioConstraints,
    );
    for (final track in _localStream!.getAudioTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }
  }

  void _endCall() {
    _ringTimer?.cancel();
    _currentCall?.endedAt = DateTime.now();
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
    _peerConnection?.close();
    _peerConnection = null;
    _pendingOffer = null;
    _pendingCallerId = null;
    _currentRoomId = null;
    _isMuted = false;
    _localFingerprint = null;
    _remoteFingerprint = null;
  }

  void _setState(CallState state) {
    _callState = state;
    notifyListeners();
  }

  /// Extract DTLS fingerprint from SDP for E2E key verification
  /// RFC 5764 — DTLS-SRTP fingerprint
  String? _extractFingerprint(String sdp) {
    final match = RegExp(r'a=fingerprint:(\S+ \S+)').firstMatch(sdp);
    return match?.group(1);
  }

  void setIceMode(bool useFull) {
    _useFullIce = useFull;
  }

  @override
  void dispose() {
    _unregisterHandlers();
    _endCall();
    super.dispose();
  }

  void _unregisterHandlers() {
    _signaling.off('call-incoming', _onCallIncoming);
    _signaling.off('call-answered', _onCallAnswered);
    _signaling.off('call-declined', _onCallDeclined);
    _signaling.off('ice', _onIceCandidate);
    _signaling.off('hangup', _onHangup);
    _signaling.off('user-offline', _onPeerUnavailable);
    _signaling.off('user-busy', _onPeerUnavailable);
    _signaling.off('room-joined', _onRoomJoined);
    _signaling.off('room-answered', _onRoomAnswered);
    _signaling.off('room-ice', _onRoomIce);
    _signaling.off('room-hangup', _onHangup);
  }
}

// CallStateX extension is defined in models/models.dart — do not duplicate here.
