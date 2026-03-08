import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';
import '../../services/signaling_service.dart';
import '../../services/webrtc_service.dart';
import '../../core/theme.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends StatefulWidget {
  final String? pendingRoomId;
  const HomeScreen({super.key, this.pendingRoomId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchCtrl = TextEditingController();
  List<UserModel> _searchResults = [];
  bool _searching = false;
  final _api = ApiService();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    // Handle deep link room join
    if (widget.pendingRoomId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleRoomJoin(widget.pendingRoomId!);
      });
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.bluetooth,
      Permission.bluetoothConnect,
    ].request();
  }

  Future<void> _search(String query) async {
    if (query.length < 2) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await _api.searchUsers(query);
      setState(() => _searchResults = results);
    } catch (_) {
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _callUserById(String userId) async {
    try {
      final user = await _api.getUserById(userId);
      await _startCall(user);
    } catch (e) {
      _showSnack('User not found');
    }
  }

  Future<void> _startCall(UserModel user) async {
    final signaling = context.read<SignalingService>();
    if (!signaling.isConnected) {
      _showSnack('Not connected to server');
      return;
    }

    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      await Permission.microphone.request();
      if (!await Permission.microphone.isGranted) {
        _showSnack('Microphone permission required');
        return;
      }
    }

    if (mounted) {
      context.read<WebRTCService>().callUser(user);
      context.push('/call/active');
    }
  }

  Future<void> _createRoomLink() async {
    try {
      final data = await _api.createRoom();
      final link = data['link'] as String;
      if (mounted) {
        _showRoomDialog(link, data['roomId'] as String);
      }
    } catch (e) {
      _showSnack('Failed to create room');
    }
  }

  Future<void> _handleRoomJoin(String roomId) async {
    try {
      final info = await _api.getRoomInfo(roomId);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Join Call'),
          content: Text(
            'Join call created by ${info['createdBy']?['displayName'] ?? 'Unknown'}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                context.read<WebRTCService>().joinRoomCall(roomId);
                context.push('/call/active');
              },
              child: const Text('Join'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showSnack('Room not found or expired');
    }
  }

  void _showRoomDialog(String link, String roomId) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Share Call Link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Share this link to invite someone to call'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(link, style: const TextStyle(fontSize: 12))),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: link));
                      _showSnack('Link copied!');
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<WebRTCService>().hostRoomCall(roomId);
              context.push('/call/active');
            },
            child: const Text('Wait for Caller'),
          ),
        ],
      ),
    );
  }

  void _showCallByIdDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Call by User ID'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'Paste User ID here',
            prefixIcon: Icon(Icons.fingerprint),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              if (ctrl.text.isNotEmpty) _callUserById(ctrl.text.trim());
            },
            child: const Text('Call'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final signaling = context.watch<SignalingService>();
    final user = auth.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VoiceCall'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              context.read<SignalingService>().disconnect();
              await context.read<AuthService>().logout();
              if (mounted) context.go('/auth/login');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // User ID Card
          if (user != null)
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text(
                      user.displayName.isNotEmpty
                          ? user.displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.displayName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('@${user.username}',
                            style: const TextStyle(color: Colors.white54)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: user.userId));
                            _showSnack('User ID copied!');
                          },
                          child: Row(
                            children: [
                              Text(
                                'ID: ${user.userId.substring(0, 8)}...',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 11),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.copy, size: 12, color: Colors.white38),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Connection indicator
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: signaling.isConnected
                          ? AppTheme.callGreen
                          : Colors.orange,
                    ),
                  ),
                ],
              ),
            ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    icon: Icons.link,
                    label: 'Create Link',
                    onTap: _createRoomLink,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.fingerprint,
                    label: 'Call by ID',
                    onTap: _showCallByIdDialog,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: 'Search users...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _searchResults = []);
                  },
                )
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Results
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (_, i) {
                final u = _searchResults[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                    Theme.of(context).colorScheme.primary,
                    child: Text(
                      u.displayName[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  title: Text(u.displayName),
                  subtitle: Text('@${u.username}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.call,
                        color: Colors.green),
                    onPressed: () => _startCall(u),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
