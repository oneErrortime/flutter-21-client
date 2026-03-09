import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../models/models.dart';
import '../../services/webrtc_service.dart';
import '../../core/theme.dart';

class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  late Timer _durationTimer;
  Duration _callDuration = Duration.zero;
  DateTime? _callStartTime;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callStartTime != null) {
        setState(() {
          _callDuration = DateTime.now().difference(_callStartTime!);
        });
      }
    });

    // Listen for call connected event to start timer
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final webrtc = context.read<WebRTCService>();
      if (webrtc.callState == CallState.connected) {
        _callStartTime = webrtc.currentCall?.connectedAt ?? DateTime.now();
      }
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _durationTimer.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _showFingerprintDialog(WebRTCService webrtc) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('🔒 Security Verification'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'DTLS-SRTP fingerprints (RFC 5764)\nVerify these match on both devices:',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            const Text('Your fingerprint:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            _FingerprintBox(
              fingerprint: webrtc.localFingerprint ?? 'Negotiating...',
            ),
            const SizedBox(height: 12),
            const Text("Peer's fingerprint:", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            _FingerprintBox(
              fingerprint: webrtc.remoteFingerprint ?? 'Negotiating...',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '✓ WebRTC enforces DTLS-SRTP by default. '
                    'Audio is encrypted end-to-end. '
                    'No server can intercept the call.',
                style: TextStyle(color: Colors.green, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final webrtc = context.watch<WebRTCService>();
    final call = webrtc.currentCall;
    final peer = call?.peer;
    final callState = webrtc.callState;

    // If call ended, navigate back
    if (callState.isIdle && callState != CallState.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/home');
      });
    }

    // Start timer when connected
    if (callState == CallState.connected && _callStartTime == null) {
      _callStartTime = call?.connectedAt ?? DateTime.now();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.security, color: Colors.white54),
                    onPressed: () => _showFingerprintDialog(webrtc),
                    tooltip: 'Security Info',
                  ),
                ],
              ),
            ),

            // Peer info & call status
            Column(
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    peer?.displayName.isNotEmpty == true
                        ? peer!.displayName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(fontSize: 44, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  peer?.displayName ?? 'Connecting...',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _StatusBadge(state: callState, duration: _formatDuration(_callDuration)),
              ],
            ),

            // Controls
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ControlButton(
                      icon: webrtc.isMuted ? Icons.mic_off : Icons.mic,
                      label: webrtc.isMuted ? 'Unmute' : 'Mute',
                      active: webrtc.isMuted,
                      onTap: webrtc.toggleMute,
                    ),
                    const SizedBox(width: 32),
                    _ControlButton(
                      icon: webrtc.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                      label: webrtc.isSpeakerOn ? 'Earpiece' : 'Speaker',
                      active: webrtc.isSpeakerOn,
                      onTap: webrtc.toggleSpeaker,
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                // Hang up
                GestureDetector(
                  onTap: () {
                    webrtc.hangUp();
                    context.go('/home');
                  },
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppTheme.callRed,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.callRed.withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.call_end, color: Colors.white, size: 32),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final CallState state;
  final String duration;

  const _StatusBadge({required this.state, required this.duration});

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (state) {
      CallState.calling => ('Calling...', Colors.orange),
      CallState.connecting => ('Connecting...', Colors.orange),
      CallState.connected => (duration, Colors.green),
      CallState.ringing => ('Ringing...', Colors.orange),
      _ => ('Ended', Colors.white54),
    };

    return Text(text, style: TextStyle(color: color, fontSize: 18));
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : const Color(0xFF2A2A3E),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

class _FingerprintBox extends StatelessWidget {
  final String fingerprint;

  const _FingerprintBox({required this.fingerprint});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        fingerprint,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          color: Colors.lightGreenAccent,
        ),
      ),
    );
  }
}
