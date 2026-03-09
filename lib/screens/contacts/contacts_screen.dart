/// screens/contacts/contacts_screen.dart
///
/// User discovery & contacts management screen.
///
/// Tabs:
///   1. My Contacts  — accepted contacts, call button per row
///   2. Requests     — incoming + sent pending requests
///   3. Add Contact  — search by @handle or scan QR / share invite link

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/contacts_service.dart';
import '../../services/webrtc_service.dart';
import '../../core/theme.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContactsService>().loadAll();
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            const Tab(icon: Icon(Icons.people), text: 'Contacts'),
            Consumer<ContactsService>(
              builder: (_, svc, __) => Tab(
                icon: Badge(
                  isLabelVisible: svc.pendingCount > 0,
                  label: Text('${svc.pendingCount}'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                text: 'Requests',
              ),
            ),
            const Tab(icon: Icon(Icons.person_add_outlined), text: 'Add'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _ContactListTab(),
          _RequestsTab(),
          _AddContactTab(),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Tab 1: Contact list
// ════════════════════════════════════════════════════════════════════════════

class _ContactListTab extends StatelessWidget {
  const _ContactListTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<ContactsService>(
      builder: (context, svc, _) {
        if (svc.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (svc.contacts.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.people_outline, size: 64, color: Colors.white24),
                const SizedBox(height: 16),
                Text(
                  'No contacts yet',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Colors.white54),
                ),
                const SizedBox(height: 8),
                Text(
                  'Go to Add tab to find people by @handle',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white38),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          itemCount: svc.contacts.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
          itemBuilder: (context, i) => _ContactTile(contact: svc.contacts[i]),
        );
      },
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final webrtc = context.read<WebRTCService>();

    return ListTile(
      leading: _Avatar(
        name: contact.displayName,
        isOnline: contact.isOnline,
      ),
      title: Text(contact.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '@${contact.handle}',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.8),
          fontSize: 12,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Audio call button
          IconButton(
            icon: const Icon(Icons.call_outlined),
            color: AppTheme.callGreen,
            tooltip: 'Voice call',
            onPressed: contact.isOnline
                ? () => webrtc.callUser(contact.toUserModel())
                : null,
          ),
          // Video call button
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            color: Colors.blue,
            tooltip: 'Video call',
            onPressed: contact.isOnline
                ? () => webrtc.callUser(contact.toUserModel())
                : null,
          ),
          // More options
          PopupMenuButton<_ContactAction>(
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _ContactAction.remove,
                child: ListTile(
                  leading: Icon(Icons.person_remove_outlined),
                  title: Text('Remove contact'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: _ContactAction.block,
                child: ListTile(
                  leading: Icon(Icons.block, color: Colors.red),
                  title: Text('Block', style: TextStyle(color: Colors.red)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
            onSelected: (action) => _onAction(context, action),
          ),
        ],
      ),
    );
  }

  Future<void> _onAction(BuildContext context, _ContactAction action) async {
    final svc = context.read<ContactsService>();
    switch (action) {
      case _ContactAction.remove:
        final ok = await svc.removeContact(contact.contactId);
        if (context.mounted) {
          _showSnack(context, ok ? 'Contact removed' : 'Failed to remove contact');
        }
      case _ContactAction.block:
        final confirm = await _confirmDialog(
          context,
          title: 'Block ${contact.displayName}?',
          body: 'They won\'t be able to call you or see your status. You can unblock from settings.',
          confirmLabel: 'Block',
          isDestructive: true,
        );
        if (confirm == true) {
          final ok = await svc.blockUser(contact.contactId);
          if (context.mounted) {
            _showSnack(context, ok ? 'User blocked' : 'Failed to block user');
          }
        }
    }
  }
}

enum _ContactAction { remove, block }

// ════════════════════════════════════════════════════════════════════════════
// Tab 2: Pending requests
// ════════════════════════════════════════════════════════════════════════════

class _RequestsTab extends StatelessWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<ContactsService>(
      builder: (context, svc, _) {
        if (svc.isLoading) return const Center(child: CircularProgressIndicator());

        final incoming = svc.pendingIncoming;
        final sent = svc.pendingSent;

        if (incoming.isEmpty && sent.isEmpty) {
          return const Center(
            child: Text(
              'No pending requests',
              style: TextStyle(color: Colors.white38),
            ),
          );
        }

        return ListView(
          children: [
            if (incoming.isNotEmpty) ...[
              const _SectionHeader('Incoming requests'),
              ...incoming.map((c) => _IncomingRequestTile(contact: c)),
            ],
            if (sent.isNotEmpty) ...[
              const _SectionHeader('Sent requests'),
              ...sent.map((c) => _SentRequestTile(contact: c)),
            ],
          ],
        );
      },
    );
  }
}

class _IncomingRequestTile extends StatelessWidget {
  const _IncomingRequestTile({required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _Avatar(name: contact.displayName, isOnline: false),
      title: Text(contact.displayName,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('@${contact.handle}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.8),
            fontSize: 12,
          )),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Accept
          IconButton(
            icon: const Icon(Icons.check_circle_outline),
            color: AppTheme.callGreen,
            tooltip: 'Accept',
            onPressed: () async {
              final ok = await context
                  .read<ContactsService>()
                  .acceptRequest(contact.contactId);
              if (context.mounted) {
                _showSnack(
                  context,
                  ok ? '${contact.displayName} added!' : 'Failed to accept',
                );
              }
            },
          ),
          // Decline
          IconButton(
            icon: const Icon(Icons.cancel_outlined),
            color: AppTheme.callRed,
            tooltip: 'Decline',
            onPressed: () async {
              await context
                  .read<ContactsService>()
                  .declineRequest(contact.contactId);
            },
          ),
        ],
      ),
    );
  }
}

class _SentRequestTile extends StatelessWidget {
  const _SentRequestTile({required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _Avatar(name: contact.displayName, isOnline: false),
      title: Text(contact.displayName),
      subtitle: Text('@${contact.handle}',
          style: const TextStyle(fontSize: 12)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text('Pending',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Tab 3: Add Contact
// ════════════════════════════════════════════════════════════════════════════

class _AddContactTab extends StatefulWidget {
  const _AddContactTab();

  @override
  State<_AddContactTab> createState() => _AddContactTabState();
}

class _AddContactTabState extends State<_AddContactTab> {
  final _handleCtrl = TextEditingController();
  bool _searching = false;
  Contact? _foundUser;
  String? _searchError;
  Timer? _debounce;

  @override
  void dispose() {
    _handleCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onHandleChanged(String value) {
    _debounce?.cancel();
    if (value.length < 2) {
      setState(() { _foundUser = null; _searchError = null; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () => _search(value));
  }

  Future<void> _search(String handle) async {
    setState(() { _searching = true; _foundUser = null; _searchError = null; });
    final svc = context.read<ContactsService>();
    final result = await svc.findByHandle(handle);
    if (mounted) {
      setState(() {
        _searching = false;
        _foundUser = result;
        if (result == null) _searchError = 'No user found with that handle.\nThey may not be discoverable.';
      });
    }
  }

  Future<void> _sendRequest() async {
    if (_foundUser == null) return;
    final svc = context.read<ContactsService>();
    final result = await svc.sendRequest(_foundUser!.contactId);
    if (!mounted) return;
    switch (result) {
      case ContactRequestResult.sent:
        _showSnack(context, 'Request sent to ${_foundUser!.displayName} ✓');
        setState(() { _foundUser = null; _handleCtrl.clear(); });
      case ContactRequestResult.alreadyContacts:
        _showSnack(context, 'Already contacts!');
      case ContactRequestResult.alreadySent:
        _showSnack(context, 'Request already sent');
      case ContactRequestResult.blocked:
        _showSnack(context, 'Cannot send request to this user');
      case ContactRequestResult.error:
        _showSnack(context, 'Failed to send request');
    }
  }

  Future<void> _shareInviteLink() async {
    final svc = context.read<ContactsService>();
    final link = await svc.generateInviteLink();
    if (!mounted) return;
    if (link == null) {
      _showSnack(context, 'Could not generate link');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link));
    _showSnack(context, 'Invite link copied to clipboard!');
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── How it works ─────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('🔒 Privacy-first contacts',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text(
                  'You can only call people who are in your contacts. '
                  'To find someone, you need their exact @handle — '
                  'there is no public directory.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // ── Search by handle ─────────────────────────────────────────────
          Text('Find by @handle',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
          const SizedBox(height: 12),

          TextField(
            controller: _handleCtrl,
            onChanged: _onHandleChanged,
            onSubmitted: _search,
            decoration: InputDecoration(
              hintText: '@username or username',
              prefixIcon: const Icon(Icons.alternate_email),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ),

          // ── Search result ─────────────────────────────────────────────────
          if (_foundUser != null) ...[
            const SizedBox(height: 16),
            _FoundUserCard(
              user: _foundUser!,
              onAdd: _sendRequest,
            ),
          ],

          if (_searchError != null && _handleCtrl.text.length >= 2) ...[
            const SizedBox(height: 16),
            Text(
              _searchError!,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],

          const SizedBox(height: 36),
          const Divider(),
          const SizedBox(height: 24),

          // ── Share invite link ─────────────────────────────────────────────
          Text('Share invite link',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
          const SizedBox(height: 8),
          Text(
            'Generate a one-time link and share it with someone. '
            'When they tap it, they\'ll be taken straight to adding you as a contact.',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _shareInviteLink,
              icon: const Icon(Icons.link),
              label: const Text('Generate & copy invite link'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),

          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Links expire after 24 hours.\nYou can generate as many as you need.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Found user card ────────────────────────────────────────────────────────

class _FoundUserCard extends StatelessWidget {
  const _FoundUserCard({required this.user, required this.onAdd});
  final Contact user;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          _Avatar(name: user.displayName, isOnline: false, radius: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.displayName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                Text(
                  '@${user.handle}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.person_add, size: 18),
            label: const Text('Add'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(80, 40),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.name,
    required this.isOnline,
    this.radius = 22,
  });
  final String name;
  final bool isOnline;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(' ').map((w) => w[0]).take(2).join().toUpperCase();

    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor:
              Theme.of(context).colorScheme.primary.withOpacity(0.25),
          child: Text(
            initials,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: radius * 0.6,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: radius * 0.55,
              height: radius * 0.55,
              decoration: BoxDecoration(
                color: AppTheme.callGreen,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
          ),
        ),
      );
}

// ── Helpers ────────────────────────────────────────────────────────────────────

void _showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2)));
}

Future<bool?> _confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool isDestructive = false,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor:
                  isDestructive ? Theme.of(context).colorScheme.error : null,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
