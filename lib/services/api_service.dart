import 'package:dio/dio.dart';
import '../core/constants.dart';
import '../models/models.dart';
import 'contacts_service.dart';
import 'secure_storage_service.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() { _init(); }

  late final Dio _dio;
  bool _isRefreshing = false;
  final List<Function> _retryQueue = [];

  void _init() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConstants.baseUrl,
      connectTimeout: AppConstants.connectTimeout,
      receiveTimeout: AppConstants.receiveTimeout,
      headers: {'Content-Type': 'application/json'},
    ));

    // Request interceptor: attach access token
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await SecureStorageService.getAccessToken();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401) {
            final code = error.response?.data['code'];
            if (code == 'TOKEN_EXPIRED') {
              if (_isRefreshing) {
                // Queue the request for retry after token refresh completes
                _retryQueue.add(() async {
                  try {
                    final opts = error.requestOptions;
                    final token = await SecureStorageService.getAccessToken();
                    opts.headers['Authorization'] = 'Bearer $token';
                    final response = await _dio.fetch(opts);
                    handler.resolve(response);
                  } catch (e) {
                    handler.reject(error);
                  }
                });
                return;
              }
              _isRefreshing = true;
              try {
                await _refreshTokens();
                _isRefreshing = false;
                // Retry original request
                final opts = error.requestOptions;
                final token = await SecureStorageService.getAccessToken();
                opts.headers['Authorization'] = 'Bearer $token';
                final response = await _dio.fetch(opts);
                handler.resolve(response);
                // Drain queued requests that piled up during refresh
                for (final retry in _retryQueue) {
                  retry();
                }
                _retryQueue.clear();
              } catch (e) {
                // Refresh failed, force logout
                await SecureStorageService.clearAll();
                _retryQueue.clear();
                handler.reject(error);
              } finally {
                _isRefreshing = false;
              }
              return;
            }
          }
          handler.next(error);
        },
      ),
    );
  }

  Future<void> _refreshTokens() async {
    final refreshToken = await SecureStorageService.getRefreshToken();
    if (refreshToken == null) throw Exception('No refresh token');

    final response = await Dio().post(
      '${AppConstants.baseUrl}/api/auth/refresh',
      data: {'refreshToken': refreshToken},
    );
    await SecureStorageService.saveTokens(
      accessToken: response.data['accessToken'],
      refreshToken: response.data['refreshToken'],
    );
  }

  // ── Auth ───────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async {
    final response = await _dio.post('/api/auth/register', data: {
      'username': username,
      'email': email,
      'password': password,
      'displayName': displayName,
    });
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login({
    required String identifier,
    required String password,
  }) async {
    final response = await _dio.post('/api/auth/login', data: {
      'identifier': identifier,
      'password': password,
    });
    return response.data as Map<String, dynamic>;
  }

  Future<void> logout(String refreshToken) async {
    try {
      await _dio.post('/api/auth/logout', data: {'refreshToken': refreshToken});
    } catch (_) {}
  }

  Future<Map<String, dynamic>> getMe() async {
    final response = await _dio.get('/api/auth/me');
    return response.data as Map<String, dynamic>;
  }

  // ── Users ──────────────────────────────────────────────────────────────────
  Future<UserModel> getUserById(String userId) async {
    final response = await _dio.get('/api/users/$userId');
    return UserModel.fromJson(response.data['user'] as Map<String, dynamic>);
  }

  Future<List<UserModel>> searchUsers(String query) async {
    final response = await _dio.get('/api/users/search', queryParameters: {'q': query});
    final users = response.data['users'] as List;
    return users.map((u) => UserModel.fromJson(u as Map<String, dynamic>)).toList();
  }

  // ── Rooms ──────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> createRoom() async {
    final response = await _dio.post('/api/rooms');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getRoomInfo(String roomId) async {
    final response = await _dio.get('/api/rooms/$roomId');
    return response.data as Map<String, dynamic>;
  }

  // ── Users ──────────────────────────────────────────────────────────────────

  /// Find user by exact @handle.
  /// Server only returns a result if the user is discoverable or already a contact.
  Future<Contact?> getUserByHandle(String handle) async {
    try {
      final response = await _dio.get('/api/users/by-handle/$handle');
      final json = response.data['user'] as Map<String, dynamic>?;
      if (json == null) return null;
      return Contact.fromJson({...json, 'status': 'none'});
    } catch (_) {
      return null;
    }
  }

  // ── Contacts ───────────────────────────────────────────────────────────────

  Future<List<Contact>> getContacts() async {
    final response = await _dio.get('/api/contacts');
    final list = response.data['contacts'] as List;
    return list.map((j) => Contact.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<List<Contact>> getPendingContacts() async {
    final response = await _dio.get('/api/contacts/pending');
    final list = response.data['requests'] as List;
    return list.map((j) => Contact.fromJson({...j as Map<String, dynamic>, 'status': 'pending_incoming'})).toList();
  }

  Future<List<Contact>> getSentContactRequests() async {
    final response = await _dio.get('/api/contacts/sent');
    final list = response.data['requests'] as List;
    return list.map((j) => Contact.fromJson({...j as Map<String, dynamic>, 'status': 'pending_outgoing'})).toList();
  }

  Future<void> sendContactRequest(String targetUserId) async {
    await _dio.post('/api/contacts/request', data: {'targetUserId': targetUserId});
  }

  Future<void> acceptContactRequest(String requesterId) async {
    await _dio.post('/api/contacts/accept', data: {'requesterId': requesterId});
  }

  Future<void> declineContactRequest(String requesterId) async {
    await _dio.post('/api/contacts/decline', data: {'requesterId': requesterId});
  }

  Future<void> removeContact(String userId) async {
    await _dio.delete('/api/contacts/$userId');
  }

  Future<void> blockUser(String userId) async {
    await _dio.post('/api/contacts/block', data: {'userId': userId});
  }

  Future<String?> generateInviteLink() async {
    final response = await _dio.post('/api/contacts/invite-link');
    return response.data['link'] as String?;
  }
}
