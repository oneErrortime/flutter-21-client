/// screens/call/video_call_screen.dart
///
/// Zoom-like video call UI.
///
/// Layout:
///   - Full-screen remote video (background)
///   - Local video preview (draggable PiP, bottom-right corner)
///   - Transparent control overlay (auto-hide after 3 s)
///   - Status bar: call duration + transport mode badge
///   - Control row: mute / video on-off / flip camera / screen share / hang up
///   - Security row: DTLS fingerprint verification button (RFC 5764)
///
/// Works in both portrait and landscape.
/// Screen keeps on during call (wakelock_plus).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../models/models.dart';
import '../../services/video_call_service.dart';
import '../../core/theme.dart';

class VideoCallScreen extends StatefulWidget {
  const VideoCallScreen({super.key});

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen>
    with WidgetsBindingObserver {
  // ── Timer & overlay ───────────────────────────────────────────────────────
  late Timer _durationTimer;
  Duration _callDuration = Duration.zero;
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // ── Local PiP drag ────────────────────────────────────────────────────────
  double _pipRight = 16;
  double _pipBottom = 120;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();

    // Hide status bar for immersive video
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final svc = context.read<VideoCallService>();
      final start = svc.currentCall?.connectedAt;
      if (start != null && mounted) {
        setState(() => _callDuration = DateTime.now().difference(start));
      }
    });

    _scheduleHideControls();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _durationTimer.cancel();
    _hideControlsTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Disable camera when app is backgrounded (privacy)
    if (state == AppLifecycleState.paused) {
      context.read<VideoCallService>().toggleVideo();
    }
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _onTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoCallService>(
      builder: (context, svc, _) {
        // Auto-navigate away when call ends
        if (svc.callState.isTerminal) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) context.go('/');
          });
        }

        return Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            onTap: _onTap,
            behavior: HitTestBehavior.opaque,
            child: Stack(
              children: [
                // ── Remote video (full screen) ─────────────────────────────
                _RemoteVideoBackground(renderer: svc.remoteRenderer),

                // ── Local PiP video ────────────────────────────────────────
                if (svc.isVideoEnabled)
                  _DraggablePip(
                    renderer: svc.localRenderer,
                    right: _pipRight,
                    bottom: _pipBottom,
                    isMirrored: svc.isFrontCamera && !svc.isScreenSharing,
                    onDragEnd: (r, b) => setState(() {
                      _pipRight = r;
                      _pipBottom = b;
                    }),
                  ),

                // ── Control overlay ────────────────────────────────────────
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: Column(
                      children: [
                        // Status bar
                        _StatusBar(
                          duration: _callDuration,
                          transport: svc.currentCall?.transport,
                          peerName: svc.currentCall?.peerDisplayName ?? '',
                          callState: svc.callState,
                        ),
                        const Spacer(),
                        // Controls
                        _ControlBar(
                          svc: svc,
                          onHangUp: () => svc.hangUp(),
                          onFingerprint: () =>
                              _showFingerprintSheet(context, svc),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),

                // ── Connecting indicator ───────────────────────────────────
                if (svc.callState == CallState.connecting)
                  const Center(child: _ConnectingOverlay()),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFingerprintSheet(BuildContext context, VideoCallService svc) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🔒 Security Verification',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'DTLS-SRTP fingerprints (RFC 5764).\n'
              'Read these aloud to verify your call is not intercepted.',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 20),
            _FingerprintRow(
                label: 'Your fingerprint',
                value: svc.localFingerprint ?? 'Negotiating…'),
            const SizedBox(height: 12),
            _FingerprintRow(
                label: "Peer's fingerprint",
                value: svc.remoteFingerprint ?? 'Negotiating…'),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Remote video background
// ---------------------------------------------------------------------------

class _RemoteVideoBackground extends StatelessWidget {
  const _RemoteVideoBackground({required this.renderer});
  final RTCVideoRenderer renderer;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: renderer.srcObject != null
          ? RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: false,
            )
          : const ColoredBox(
              color: Color(0xFF1A1A2E),
              child: Center(
                child: Icon(
                  Icons.person_rounded,
                  size: 120,
                  color: Colors.white24,
                ),
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Draggable local PiP
// ---------------------------------------------------------------------------

class _DraggablePip extends StatelessWidget {
  const _DraggablePip({
    required this.renderer,
    required this.right,
    required this.bottom,
    required this.isMirrored,
    required this.onDragEnd,
  });

  final RTCVideoRenderer renderer;
  final double right;
  final double bottom;
  final bool isMirrored;
  final void Function(double right, double bottom) onDragEnd;

  @override
  Widget build(BuildContext context) {
    const width = 96.0;
    const height = 128.0;

    return Positioned(
      right: right,
      bottom: bottom,
      child: GestureDetector(
        onPanUpdate: (details) {
          final size = MediaQuery.of(context).size;
          final newRight =
              (right - details.delta.dx).clamp(0.0, size.width - width);
          final newBottom =
              (bottom - details.delta.dy).clamp(0.0, size.height - height);
          onDragEnd(newRight, newBottom);
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: width,
            height: height,
            child: RTCVideoView(
              renderer,
              mirror: isMirrored,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.duration,
    required this.transport,
    required this.peerName,
    required this.callState,
  });

  final Duration duration;
  final TransportMode? transport;
  final String peerName;
  final CallState callState;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding:
          const EdgeInsets.fromLTRB(16, 48, 16, 16), // account for status bar
      child: Row(
        children: [
          // Peer name + state
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  peerName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  callState == CallState.connected
                      ? _formatDuration(duration)
                      : callState.name.toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          // Transport badge
          if (transport != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                transport!.displayName,
                style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    letterSpacing: 0.5),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ---------------------------------------------------------------------------
// Control bar
// ---------------------------------------------------------------------------

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.svc,
    required this.onHangUp,
    required this.onFingerprint,
  });

  final VideoCallService svc;
  final VoidCallback onHangUp;
  final VoidCallback onFingerprint;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute
          _CircleBtn(
            icon: svc.isMuted ? Icons.mic_off : Icons.mic,
            label: svc.isMuted ? 'Unmute' : 'Mute',
            onTap: svc.toggleMute,
            active: svc.isMuted,
          ),

          // Video on/off
          _CircleBtn(
            icon: svc.isVideoEnabled
                ? Icons.videocam
                : Icons.videocam_off,
            label: svc.isVideoEnabled ? 'Video' : 'No Video',
            onTap: svc.toggleVideo,
            active: !svc.isVideoEnabled,
          ),

          // Hang up (centre, prominent)
          _CircleBtn(
            icon: Icons.call_end,
            label: 'End',
            onTap: onHangUp,
            backgroundColor: Colors.red,
            size: 64,
          ),

          // Flip camera
          _CircleBtn(
            icon: Icons.flip_camera_android,
            label: 'Flip',
            onTap: svc.flipCamera,
          ),

          // Screen share / security
          _CircleBtn(
            icon: svc.isScreenSharing
                ? Icons.stop_screen_share
                : Icons.screen_share,
            label: svc.isScreenSharing ? 'Stop Share' : 'Share',
            onTap: svc.isScreenSharing
                ? svc.stopScreenShare
                : svc.startScreenShare,
            active: svc.isScreenSharing,
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.backgroundColor,
    this.size = 52,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? backgroundColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ??
        (active ? Colors.white24 : Colors.white.withOpacity(0.12));

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: size * 0.44),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style:
                const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connecting overlay
// ---------------------------------------------------------------------------

class _ConnectingOverlay extends StatelessWidget {
  const _ConnectingOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text(
              'Connecting…',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fingerprint display widget
// ---------------------------------------------------------------------------

class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
              color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.greenAccent,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}
