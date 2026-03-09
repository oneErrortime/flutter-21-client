/// services/contacts_service.dart
///
/// Contact discovery & management.
///
/// The problem: "How does Вася find Галя and call her, without accidentally
/// calling Петя or exposing Галя's account to random strangers?"
///
/// Solution: A mutual-contact model (like Signal/Telegram), not open search:
///
/// 1. IDENTITY — every user has a permanent short @handle + numeric user ID.
///    Галя shares her handle (e.g. @galya_ivanova) with Васей out-of-band
///    (in person, in another chat, via QR code, or via invite link).
///
/// 2. ADD REQUEST — Вася sends a contact request to @galya_ivanova.
///    Галя sees a notification and accepts or ignores.
///    Only after mutual acceptance can either side call the other.
///
/// 3. PRIVACY — the search endpoint only returns users who have their
///    "discoverable" flag ON, OR users who are already in your contacts.
///    If Галя wants privacy, she turns off discoverability and only
///    accepts calls from people she added first.
///
/// 4. INVITE LINK — generates a one-time or permanent deep link:
///    voicecall://add/USER_ID/TOKEN
///    Clicking it pre-fills the add-contact form for the other party.
///
/// 5. QR CODE — encodes the invite link; scannable for in-person sharing.
///
/// Wire protocol (REST):
///   POST   /api/contacts/request       { targetUserId }
///   POST   /api/contacts/accept        { requesterId }
///   POST   /api/contacts/decline       { requesterId }
///   DELETE /api/contacts/:userId       remove contact
///   POST   /api/contacts/block         { userId }
///   GET    /api/contacts               list accepted contacts
///   GET    /api/contacts/pending       list incoming pending requests
///   GET    /api/contacts/sent          list outgoing pending requests
///   POST   /api/contacts/invite-link   generate invite link
///   GET    /api/users/by-handle/:handle

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/models.dart';
import 'api_service.dart';

// ── Contact status ────────────────────────────────────────────────────────────

enum ContactStatus {
  /// Mutual contact — can call each other
  accepted,
  /// We sent them a request, they haven't responded
  pendingOutgoing,
  /// They sent us a request, we haven't responded
  pendingIncoming,
  /// We blocked this user
  blocked,
  /// Not a contact
  none,
}

// ── Contact model ─────────────────────────────────────────────────────────────

class Contact {
  final String contactId;      // their userId
  final String handle;         // @handle
  final String displayName;
  final String? avatarUrl;
  final ContactStatus status;
  final DateTime createdAt;
  final DateTime? lastSeen;
  final bool isOnline;

  const Contact({
    required this.contactId,
    required this.handle,
    required this.displayName,
    this.avatarUrl,
    required this.status,
    required this.createdAt,
    this.lastSeen,
    this.isOnline = false,
  });

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        contactId: j['userId'] as String,
        handle: j['username'] as String,
        displayName: j['displayName'] as String,
        avatarUrl: j['avatarUrl'] as String?,
        status: _statusFromString(j['status'] as String? ?? 'accepted'),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        lastSeen: j['lastSeen'] != null
            ? DateTime.tryParse(j['lastSeen'] as String)
            : null,
        isOnline: j['isOnline'] as bool? ?? false,
      );

  UserModel toUserModel() => UserModel(
        userId: contactId,
        username: handle,
        displayName: displayName,
        avatarUrl: avatarUrl,
        lastSeen: lastSeen,
      );

  static ContactStatus _statusFromString(String s) => switch (s) {
        'accepted' => ContactStatus.accepted,
        'pending_outgoing' => ContactStatus.pendingOutgoing,
        'pending_incoming' => ContactStatus.pendingIncoming,
        'blocked' => ContactStatus.blocked,
        _ => ContactStatus.none,
      };
}

// ── ContactsService ───────────────────────────────────────────────────────────

class ContactsService extends ChangeNotifier {
  final ApiService _api;

  List<Contact> _contacts = [];
  List<Contact> _pendingIncoming = [];
  List<Contact> _pendingSent = [];
  bool _isLoading = false;
  String? _error;

  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<Contact> get pendingIncoming => List.unmodifiable(_pendingIncoming);
  List<Contact> get pendingSent => List.unmodifiable(_pendingSent);
  bool get isLoading => _isLoading;
  String? get error => _error;
  int get pendingCount => _pendingIncoming.length;

  ContactsService(this._api);

  // ── Load all contacts ─────────────────────────────────────────────────────

  Future<void> loadAll() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final results = await Future.wait([
        _api.getContacts(),
        _api.getPendingContacts(),
        _api.getSentContactRequests(),
      ]);
      _contacts = results[0];
      _pendingIncoming = results[1];
      _pendingSent = results[2];
    } catch (e) {
      _error = e.toString();
      debugPrint('[ContactsService] loadAll error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Find user by @handle (privacy-safe) ──────────────────────────────────
  //
  // The server only returns a result if:
  //   a) the handle exactly matches a discoverable user, OR
  //   b) the handle matches someone already in your contacts
  //
  // This prevents enumeration of the entire user base.

  Future<Contact?> findByHandle(String handle) async {
    try {
      // Strip leading @ if user typed it
      final clean = handle.startsWith('@') ? handle.substring(1) : handle;
      final user = await _api.getUserByHandle(clean);
      return user;
    } catch (e) {
      debugPrint('[ContactsService] findByHandle error: $e');
      return null;
    }
  }

  // ── Send contact request ──────────────────────────────────────────────────

  Future<ContactRequestResult> sendRequest(String targetUserId) async {
    try {
      await _api.sendContactRequest(targetUserId);
      await loadAll();
      return ContactRequestResult.sent;
    } on ApiException catch (e) {
      if (e.code == 'ALREADY_CONTACTS') return ContactRequestResult.alreadyContacts;
      if (e.code == 'REQUEST_EXISTS') return ContactRequestResult.alreadySent;
      if (e.code == 'BLOCKED') return ContactRequestResult.blocked;
      return ContactRequestResult.error;
    } catch (e) {
      debugPrint('[ContactsService] sendRequest error: $e');
      return ContactRequestResult.error;
    }
  }

  // ── Accept incoming request ───────────────────────────────────────────────

  Future<bool> acceptRequest(String requesterId) async {
    try {
      await _api.acceptContactRequest(requesterId);
      await loadAll();
      return true;
    } catch (e) {
      debugPrint('[ContactsService] acceptRequest error: $e');
      return false;
    }
  }

  // ── Decline incoming request ──────────────────────────────────────────────

  Future<bool> declineRequest(String requesterId) async {
    try {
      await _api.declineContactRequest(requesterId);
      _pendingIncoming.removeWhere((c) => c.contactId == requesterId);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[ContactsService] declineRequest error: $e');
      return false;
    }
  }

  // ── Remove contact ────────────────────────────────────────────────────────

  Future<bool> removeContact(String userId) async {
    try {
      await _api.removeContact(userId);
      _contacts.removeWhere((c) => c.contactId == userId);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[ContactsService] removeContact error: $e');
      return false;
    }
  }

  // ── Block user ────────────────────────────────────────────────────────────
  //
  // Blocked users cannot send contact requests, cannot see your online status,
  // and cannot call you. Blocks are one-sided (the other party is not notified).

  Future<bool> blockUser(String userId) async {
    try {
      await _api.blockUser(userId);
      _contacts.removeWhere((c) => c.contactId == userId);
      _pendingIncoming.removeWhere((c) => c.contactId == userId);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[ContactsService] blockUser error: $e');
      return false;
    }
  }

  // ── Generate invite link ──────────────────────────────────────────────────
  //
  // Returns a deep link that the other party can tap to jump straight to
  // the "add contact" flow pre-filled with your handle.
  //
  // Format: voicecall://add/{userId}/{shortToken}
  // Short token is a server-generated 8-char code (expires in 24h by default).

  Future<String?> generateInviteLink() async {
    try {
      return await _api.generateInviteLink();
    } catch (e) {
      debugPrint('[ContactsService] generateInviteLink error: $e');
      return null;
    }
  }

  // ── Check if a user is callable ───────────────────────────────────────────

  bool canCall(String userId) {
    return _contacts.any(
      (c) => c.contactId == userId && c.status == ContactStatus.accepted,
    );
  }

  // ── Get contact by userId ─────────────────────────────────────────────────

  Contact? getContact(String userId) =>
      _contacts.where((c) => c.contactId == userId).firstOrNull;
}

// ── Request result enum ───────────────────────────────────────────────────────

enum ContactRequestResult {
  sent,
  alreadyContacts,
  alreadySent,
  blocked,
  error,
}

// ── ApiException ──────────────────────────────────────────────────────────────

class ApiException implements Exception {
  final String code;
  final String message;
  const ApiException(this.code, this.message);
  @override
  String toString() => 'ApiException($code): $message';
}
