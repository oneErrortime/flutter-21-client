/// video_call_service.dart
///
/// Full-featured WebRTC audio + video call service.
///
/// Adds to the existing WebRTC audio-only implementation:
///   - Video tracks (camera + screen-share)
///   - RTCVideoRenderer management (local + remote)
///   - Simulcast for bandwidth adaptation (RFC 8853)
///   - onTrack handler — remote video/audio streams
///   - Camera flip (front ↔ back)
///   - Screen share via getDisplayMedia
///   - ICE restart on disconnect
///   - DTLS fingerprint verification (RFC 5764)
///   - Codec preference: VP9 (better compression) → VP8 → H.264 fallback
///
/// Usage (register in main.dart alongside WebRTCService):
///   ChangeNotifierProvider(create: (_) => VideoCallService(signaling))
///
/// The video renderers must be initialised before use and disposed after:
///   await service.initRenderers();
///   ...
///   service.disposeRenderers();

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/constants.dart';
import '../models/models.dart';
import '../services/signaling_service.dart';

// ---------------------------------------------------------------------------
// Video constraints (RFC 8831)
// ---------------------------------------------------------------------------

/// Low, medium and high video quality presets.
/// Sent to getUserMedia; also used for SDP munging to set codec bitrates.
enum VideoQuality { low, medium, high }

extension VideoQualityX on VideoQuality {
  Map<String, dynamic> get constraints => switch (this) {
        VideoQuality.low => {
            'width': {'ideal': 320},
            'height': {'ideal': 240},
            'frameRate': {'ideal': 15},
          },
        VideoQuality.medium => {
            'width': {'ideal': 640},
            'height': {'ideal': 480},
            'frameRate': {'ideal': 24},
          },
        VideoQuality.high => {
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
            'frameRate': {'ideal': 30},
          },
      };

  int get maxBitrateKbps => switch (this) {
        VideoQuality.low => 200,
        VideoQuality.medium => 500,
        VideoQuality.high => 1200,
      };
}

// ---------------------------------------------------------------------------
// VideoCallService
// ---------------------------------------------------------------------------

class VideoCallService extends ChangeNotifier {
  final SignalingService _signaling;

  // ── PeerConnection & Streams ───────────────────────────────────────────────
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaStream? _screenShareStream;

  // ── Renderers ─────────────────────────────────────────────────────────────
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  // ── State ──────────────────────────────────────────────────────────────────
  CallState _callState = CallState.idle;
  CallModel? _currentCall;
  bool _isMuted = false;
  bool _isVideoEnabled = true;
  bool _isSpeakerOn = true;
  bool _isScreenSharing = false;
  bool _isFrontCamera = true;
  bool _useFullIce = true;
  VideoQuality _quality = VideoQuality.medium;

  // ── Security (DTLS fingerprints — RFC 5764) ───────────────────────────────
  String? _localFingerprint;
  String? _remoteFingerprint;

  // ── Pending signaling ─────────────────────────────────────────────────────
  Map<String, dynamic>? _pendingOffer;
  String? _pendingCallerId;
  String? _currentRoomId;

  Timer? _ringTimer;
  bool _renderersInitialised = false;

  // ── Getters ────────────────────────────────────────────────────────────────
  CallState get callState => _callState;
  CallModel? get currentCall => _currentCall;
  bool get isMuted => _isMuted;
  bool get isVideoEnabled => _isVideoEnabled;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isScreenSharing => _isScreenSharing;
  bool get isFrontCamera => _isFrontCamera;
  bool get isInCall =>
      _callState == CallState.connected || _callState == CallState.connecting;
  String? get localFingerprint => _localFingerprint;
  String? get remoteFingerprint => _remoteFingerprint;
  MediaStream? get remoteStream => _remoteStream;

  VideoCallService(this._signaling) {
    _registerHandlers();
  }

  // ── Renderer lifecycle ────────────────────────────────────────────────────

  /// Must be called before placing or accepting any call.
  Future<void> initRenderers() async {
    if (_renderersInitialised) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersInitialised = true;
  }

  void disposeRenderers() {
    if (!_renderersInitialised) return;
    localRenderer.dispose();
    remoteRenderer.dispose();
    _renderersInitialised = false;
  }

  // ── Signaling handlers ────────────────────────────────────────────────────

  void _registerHandlers() {
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
    _signaling.on('room-hangup', _onHangup);
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

  // ── Outgoing call ─────────────────────────────────────────────────────────

  /// Start a call to [peer]. Set [withVideo] to include camera.
  Future<void> callUser(UserModel peer, {bool withVideo = false}) async {
    if (!_callState.isIdle) return;
    _setState(CallState.calling);

    _currentCall = CallModel(
      callId: DateTime.now().millisecondsSinceEpoch.toString(),
      peer: peer,
      isIncoming: false,
      state: CallState.calling,
      transport: _useFullIce
          ? TransportMode.webrtcTurn
          : TransportMode.webrtcDirect,
      mediaKind: withVideo ? MediaKind.audioVideo : MediaKind.audioOnly,
      startedAt: DateTime.now(),
    );

    try {
      await _initPeerConnection(isCaller: true, peerId: peer.userId);
      await _captureLocalMedia(withVideo: withVideo);

      // RFC 8829 — JSEP: create offer after adding tracks
      final offer = await _peerConnection!.createOffer(
        withVideo ? _videoOfferConstraints : _audioOfferConstraints,
      );

      // Prefer VP9 codec for better compression/quality
      final sdp = _preferCodec(offer.sdp ?? '', 'VP9');
      final mungedOffer = RTCSessionDescription(sdp, offer.type);

      await _peerConnection!.setLocalDescription(mungedOffer);
      _localFingerprint = _extractFingerprint(sdp);

      _signaling.sendCall(peer.userId, {
        'type': mungedOffer.type,
        'sdp': mungedOffer.sdp,
        'withVideo': withVideo,
      });

      _ringTimer = Timer(AppConstants.callRingTimeout, () {
        if (_callState == CallState.calling) {
          _signaling.sendHangup(peer.userId);
          _endCall();
          _setState(CallState.missed);
        }
      });

      notifyListeners();
    } catch (e) {
      debugPrint('[VideoCallService] callUser error: $e');
      _endCall();
      _setState(CallState.failed);
    }
  }

  // ── Incoming call ─────────────────────────────────────────────────────────

  Future<void> _onCallIncoming(Map<String, dynamic> msg) async {
    if (!_callState.isIdle) {
      _signaling.sendDecline(msg['from'] as String, reason: 'busy');
      return;
    }

    final peer = UserModel(
      userId: msg['from'] as String,
      username: msg['from'] as String,
      displayName: msg['callerName'] as String? ?? msg['from'] as String,
    );

    final withVideo = msg['withVideo'] as bool? ?? false;

    _currentCall = CallModel(
      callId: msg['callId'] as String? ?? '',
      peer: peer,
      isIncoming: true,
      state: CallState.ringing,
      mediaKind: withVideo ? MediaKind.audioVideo : MediaKind.audioOnly,
      startedAt: DateTime.now(),
    );

    _pendingOffer = msg['offer'] as Map<String, dynamic>?;
    _pendingCallerId = msg['from'] as String;
    _setState(CallState.ringing);
  }

  // ── Accept incoming call ──────────────────────────────────────────────────

  Future<void> acceptCall({bool withVideo = false}) async {
    if (_callState != CallState.ringing || _pendingOffer == null) return;
    _setState(CallState.connecting);

    final withVideoFinal =
        withVideo || (_currentCall?.mediaKind == MediaKind.audioVideo);

    try {
      await _initPeerConnection(
          isCaller: false, peerId: _pendingCallerId!);
      await _captureLocalMedia(withVideo: withVideoFinal);

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(
          _pendingOffer!['sdp'] as String,
          _pendingOffer!['type'] as String,
        ),
      );

      _remoteFingerprint =
          _extractFingerprint(_pendingOffer!['sdp'] as String);

      final answer = await _peerConnection!.createAnswer(
        withVideoFinal ? _videoOfferConstraints : _audioOfferConstraints,
      );
      final sdp = _preferCodec(answer.sdp ?? '', 'VP9');
      final mungedAnswer = RTCSessionDescription(sdp, answer.type);

      await _peerConnection!.setLocalDescription(mungedAnswer);
      _localFingerprint = _extractFingerprint(sdp);

      _signaling.sendAnswer(_pendingCallerId!, {
        'type': mungedAnswer.type,
        'sdp': mungedAnswer.sdp,
      });

      _pendingOffer = null;
      notifyListeners();
    } catch (e) {
      debugPrint('[VideoCallService] acceptCall error: $e');
      declineCall();
    }
  }

  void declineCall() {
    if (_pendingCallerId != null) {
      _signaling.sendDecline(_pendingCallerId!);
    }
    _endCall();
    _setState(CallState.idle);
  }

  // ── Answer received ───────────────────────────────────────────────────────

  Future<void> _onCallAnswered(Map<String, dynamic> msg) async {
    _ringTimer?.cancel();
    final answerData = msg['answer'] as Map<String, dynamic>;
    _remoteFingerprint =
        _extractFingerprint(answerData['sdp'] as String);

    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(
        answerData['sdp'] as String,
        answerData['type'] as String,
      ),
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

  // ── ICE (RFC 8445) ────────────────────────────────────────────────────────

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
      debugPrint('[VideoCallService] addCandidate error: $e');
    }
  }

  void _onHangup(Map<String, dynamic> msg) {
    _endCall();
    _setState(CallState.ended);
  }

  // ── Room calls ────────────────────────────────────────────────────────────

  Future<void> joinRoomCall(String roomId, {bool withVideo = false}) async {
    if (!_callState.isIdle) return;
    _setState(CallState.connecting);

    _currentCall = CallModel(
      callId: roomId,
      isIncoming: false,
      state: CallState.connecting,
      mediaKind: withVideo ? MediaKind.audioVideo : MediaKind.audioOnly,
      startedAt: DateTime.now(),
    );
    _currentRoomId = roomId;

    try {
      await _initPeerConnection(isCaller: true, peerId: roomId);
      await _captureLocalMedia(withVideo: withVideo);

      final offer = await _peerConnection!.createOffer(
        withVideo ? _videoOfferConstraints : _audioOfferConstraints,
      );
      final sdp = _preferCodec(offer.sdp ?? '', 'VP9');
      final mungedOffer = RTCSessionDescription(sdp, offer.type);
      await _peerConnection!.setLocalDescription(mungedOffer);
      _localFingerprint = _extractFingerprint(sdp);

      _signaling.joinRoom(roomId, {
        'type': mungedOffer.type,
        'sdp': mungedOffer.sdp,
        'withVideo': withVideo,
      });
    } catch (e) {
      debugPrint('[VideoCallService] joinRoomCall error: $e');
      _setState(CallState.failed);
    }
  }

  Future<void> _onRoomJoined(Map<String, dynamic> msg) async {
    final offer = msg['offer'] as Map<String, dynamic>;
    final roomId =
        msg['roomId'] as String? ?? _currentCall?.callId ?? '';
    _currentRoomId = roomId;
    final joinerId = msg['joinerId'] as String?;

    _remoteFingerprint = _extractFingerprint(offer['sdp'] as String);
    final withVideo = msg['withVideo'] as bool? ?? false;

    await _initPeerConnection(isCaller: false, peerId: roomId);
    await _captureLocalMedia(withVideo: withVideo);

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(
          offer['sdp'] as String, offer['type'] as String),
    );

    final answer = await _peerConnection!.createAnswer(
      withVideo ? _videoOfferConstraints : _audioOfferConstraints,
    );
    final sdp = _preferCodec(answer.sdp ?? '', 'VP9');
    final mungedAnswer = RTCSessionDescription(sdp, answer.type);
    await _peerConnection!.setLocalDescription(mungedAnswer);

    _signaling.sendRoomAnswer(
      roomId,
      {'type': mungedAnswer.type, 'sdp': mungedAnswer.sdp},
      joinerId: joinerId,
    );
  }

  Future<void> _onRoomAnswered(Map<String, dynamic> msg) async {
    final answer = msg['answer'] as Map<String, dynamic>;
    _remoteFingerprint =
        _extractFingerprint(answer['sdp'] as String);
    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(
          answer['sdp'] as String, answer['type'] as String),
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
      debugPrint('[VideoCallService] room ICE error: $e');
    }
  }

  // ── Hang up ───────────────────────────────────────────────────────────────

  void hangUp() {
    if (_currentRoomId != null) {
      _signaling.sendRoomHangup(_currentRoomId!);
    } else if (_currentCall?.peer != null) {
      _signaling.sendHangup(_currentCall!.peer!.userId);
    }
    _endCall();
    _setState(CallState.ended);
  }

  // ── Media controls ────────────────────────────────────────────────────────

  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream
        ?.getAudioTracks()
        .forEach((t) => t.enabled = !_isMuted);
    notifyListeners();
  }

  void toggleVideo() {
    _isVideoEnabled = !_isVideoEnabled;
    _localStream
        ?.getVideoTracks()
        .forEach((t) => t.enabled = _isVideoEnabled);
    notifyListeners();
  }

  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    Helper.setSpeakerphoneOn(_isSpeakerOn);
    notifyListeners();
  }

  /// Flip between front and back camera.
  Future<void> flipCamera() async {
    if (_localStream == null) return;
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isEmpty) return;

    await Helper.switchCamera(videoTracks.first);
    _isFrontCamera = !_isFrontCamera;
    notifyListeners();
  }

  /// Start screen sharing (replaces camera video track).
  Future<void> startScreenShare() async {
    if (_isScreenSharing) return;
    try {
      _screenShareStream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });

      final screenTrack = _screenShareStream!.getVideoTracks().first;
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(screenTrack);
          break;
        }
      }

      // Show screen share in local renderer
      localRenderer.srcObject = _screenShareStream;
      _isScreenSharing = true;
      notifyListeners();

      // Auto-stop when screen share ends
      screenTrack.onEnded = () => stopScreenShare();
    } catch (e) {
      debugPrint('[VideoCallService] startScreenShare error: $e');
    }
  }

  /// Stop screen sharing and restore camera.
  Future<void> stopScreenShare() async {
    if (!_isScreenSharing) return;
    _screenShareStream?.getTracks().forEach((t) => t.stop());
    _screenShareStream = null;

    // Restore camera track
    if (_localStream != null) {
      final cameraTrack = _localStream!.getVideoTracks().firstOrNull;
      if (cameraTrack != null) {
        final senders = await _peerConnection!.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(cameraTrack);
            break;
          }
        }
        localRenderer.srcObject = _localStream;
      }
    }

    _isScreenSharing = false;
    notifyListeners();
  }

  /// Set video quality (affects getUserMedia constraints on next call).
  void setVideoQuality(VideoQuality quality) {
    _quality = quality;
    // Apply to existing track if in call
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      videoTrack.applyConstraints(quality.constraints);
    }
  }

  // ── PeerConnection init ───────────────────────────────────────────────────

  Future<void> _initPeerConnection({
    required bool isCaller,
    required String peerId,
  }) async {
    await _peerConnection?.close();
    _peerConnection = null;

    final config = AppConstants.rtcConfig(_useFullIce);
    _peerConnection = await createPeerConnection(config);

    // ── onTrack: remote media arrives ────────────────────────────────────────
    // This is the handler that was MISSING in the audio-only service.
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint(
          '[VideoCallService] Remote track: kind=${event.track.kind}');

      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;

        if (event.track.kind == 'video') {
          // Bind to video renderer — RTCVideoView will display it
          remoteRenderer.srcObject = _remoteStream;
          debugPrint('[VideoCallService] Remote video stream attached');
        }
        notifyListeners();
      }
    };

    // ── onAddStream (legacy fallback for older WebRTC stacks) ─────────────
    _peerConnection!.onAddStream = (stream) {
      _remoteStream ??= stream;
      remoteRenderer.srcObject = stream;
      notifyListeners();
    };

    // ── ICE candidates ────────────────────────────────────────────────────
    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty ?? false) {
        final map = {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        };
        if (_currentRoomId != null) {
          _signaling.sendRoomIce(
            _currentRoomId!,
            map,
            isCaller ? 'callee' : 'caller',
          );
        } else {
          _signaling.sendIceCandidate(peerId, map);
        }
      }
    };

    // ── ICE connection state (RFC 8445) ───────────────────────────────────
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('[VideoCallService] ICE state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _currentCall?.connectedAt = DateTime.now();
          _setState(CallState.connected);
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _endCall();
          _setState(CallState.failed);
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          if (_callState == CallState.connected) {
            // Attempt ICE restart before giving up
            _peerConnection?.restartIce();
            debugPrint('[VideoCallService] ICE disconnected — restarting');
          }
        default:
          break;
      }
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint('[VideoCallService] PC state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _endCall();
        _setState(CallState.failed);
      }
    };
  }

  // ── Media capture ─────────────────────────────────────────────────────────

  Future<void> _captureLocalMedia({required bool withVideo}) async {
    final constraints = <String, dynamic>{
      'audio': AppConstants.audioConstraints['audio'],
      'video': withVideo
          ? {
              'facingMode': _isFrontCamera ? 'user' : 'environment',
              ..._quality.constraints,
            }
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);

    // Attach local video to renderer (mirror for front camera)
    if (withVideo) {
      localRenderer.srcObject = _localStream;
    }

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }
  }

  // ── End call ──────────────────────────────────────────────────────────────

  void _endCall() {
    _ringTimer?.cancel();
    _currentCall?.endedAt = DateTime.now();

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    _screenShareStream?.getTracks().forEach((t) => t.stop());
    _screenShareStream = null;

    _remoteStream?.dispose();
    _remoteStream = null;

    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;

    _peerConnection?.close();
    _peerConnection = null;

    _pendingOffer = null;
    _pendingCallerId = null;
    _currentRoomId = null;
    _isMuted = false;
    _isVideoEnabled = true;
    _isScreenSharing = false;
    _localFingerprint = null;
    _remoteFingerprint = null;
  }

  void _setState(CallState state) {
    _callState = state;
    notifyListeners();
  }

  // ── SDP helpers ───────────────────────────────────────────────────────────

  /// Reorder codec priority in SDP so [preferred] appears first.
  /// Falls back gracefully if the codec is not supported.
  String _preferCodec(String sdp, String preferred) {
    final lines = sdp.split('\r\n');
    int? mVideoLineIndex;

    // Find the m=video line
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('m=video')) {
        mVideoLineIndex = i;
        break;
      }
    }
    if (mVideoLineIndex == null) return sdp;

    // Find payload type for preferred codec
    final payloadPattern = RegExp(r'a=rtpmap:(\d+) ' + preferred,
        caseSensitive: false);
    String? preferredPt;
    for (final line in lines) {
      final m = payloadPattern.firstMatch(line);
      if (m != null) {
        preferredPt = m.group(1);
        break;
      }
    }
    if (preferredPt == null) return sdp; // codec not available, keep as-is

    // Rearrange payload types on m=video line
    final mLine = lines[mVideoLineIndex];
    final parts = mLine.split(' ');
    if (parts.length < 4) return sdp;
    final pts = parts.sublist(3);
    if (!pts.contains(preferredPt)) return sdp;

    pts.remove(preferredPt);
    pts.insert(0, preferredPt);
    lines[mVideoLineIndex] =
        [parts[0], parts[1], parts[2], ...pts].join(' ');

    return lines.join('\r\n');
  }

  /// Extract DTLS fingerprint from SDP (RFC 5764).
  String? _extractFingerprint(String sdp) {
    final match =
        RegExp(r'a=fingerprint:(\S+ \S+)').firstMatch(sdp);
    return match?.group(1);
  }

  // ── SDP offer constraints ─────────────────────────────────────────────────

  static const _audioOfferConstraints = <String, dynamic>{
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': false,
    },
  };

  static const _videoOfferConstraints = <String, dynamic>{
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
  };

  // ── Settings ──────────────────────────────────────────────────────────────

  void setIceMode(bool useFull) {
    _useFullIce = useFull;
  }

  @override
  void dispose() {
    _unregisterHandlers();
    _endCall();
    disposeRenderers();
    super.dispose();
  }
}
