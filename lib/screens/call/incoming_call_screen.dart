import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:vibration/vibration.dart';
import '../../services/webrtc_service.dart';
import '../../core/theme.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _startVibration();
  }

  void _startVibration() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 500, 1000, 500], repeat: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    Vibration.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webrtc = context.watch<WebRTCService>();
    final peer = webrtc.currentCall?.peer;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Caller info
            Column(
              children: [
                const Text('Incoming Call',
                    style: TextStyle(color: Colors.white54, fontSize: 16)),
                const SizedBox(height: 24),
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: CircleAvatar(
                    radius: 60,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text(
                      peer?.displayName.isNotEmpty == true
                          ? peer!.displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(fontSize: 48, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  peer?.displayName ?? 'Unknown',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (peer?.username != null)
                  Text(
                    '@${peer!.username}',
                    style: const TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 12, color: Colors.green),
                      SizedBox(width: 4),
                      Text('End-to-End Encrypted',
                          style: TextStyle(color: Colors.green, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Decline
                _CallActionButton(
                  icon: Icons.call_end,
                  color: AppTheme.callRed,
                  label: 'Decline',
                  onTap: () {
                    webrtc.declineCall();
                    context.go('/home');
                  },
                ),
                // Accept
                _CallActionButton(
                  icon: Icons.call,
                  color: AppTheme.callGreen,
                  label: 'Accept',
                  onTap: () async {
                    await webrtc.acceptCall();
                    if (mounted) context.go('/call/active');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withOpacity(0.4), blurRadius: 20, spreadRadius: 4),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}
