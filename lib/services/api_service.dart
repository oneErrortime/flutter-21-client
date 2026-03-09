import 'package:dio/dio.dart';
import '../core/constants.dart';
import '../models/models.dart';
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
}
