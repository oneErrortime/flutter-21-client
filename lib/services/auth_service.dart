import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/secure_storage_service.dart';

class AuthService extends ChangeNotifier {
  UserModel? _currentUser;
  bool _isLoading = false;
  String? _error;

  UserModel? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _currentUser != null;
  String? get error => _error;

  final _api = ApiService();

  Future<void> tryAutoLogin() async {
    final userData = await SecureStorageService.getUserData();
    final accessToken = await SecureStorageService.getAccessToken();

    if (accessToken != null && userData['userId'] != null) {
      try {
        // Verify token is still valid
        final data = await _api.getMe();
        _currentUser = UserModel.fromJson(data['user'] as Map<String, dynamic>);
        notifyListeners();
      } catch (e) {
        await SecureStorageService.clearAll();
      }
    }
  }

  Future<bool> register({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async {
    _setLoading(true);
    try {
      final data = await _api.register(
        username: username,
        email: email,
        password: password,
        displayName: displayName,
      );
      await _handleAuthResponse(data);
      return true;
    } catch (e) {
      _setError(_extractError(e));
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> login({required String identifier, required String password}) async {
    _setLoading(true);
    try {
      final data = await _api.login(identifier: identifier, password: password);
      await _handleAuthResponse(data);
      return true;
    } catch (e) {
      _setError(_extractError(e));
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> logout() async {
    final refreshToken = await SecureStorageService.getRefreshToken();
    if (refreshToken != null) {
      await _api.logout(refreshToken);
    }
    await SecureStorageService.clearAll();
    _currentUser = null;
    notifyListeners();
  }

  Future<void> _handleAuthResponse(Map<String, dynamic> data) async {
    final user = UserModel.fromJson(data['user'] as Map<String, dynamic>);
    await SecureStorageService.saveTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
    await SecureStorageService.saveUser(user);
    _currentUser = user;
    _error = null;
    notifyListeners();
  }

  void _setLoading(bool val) {
    _isLoading = val;
    notifyListeners();
  }

  void _setError(String? msg) {
    _error = msg;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  String _extractError(dynamic e) {
    // Dio wraps server responses — access .response.data directly
    try {
      final data = (e as dynamic).response?.data;
      if (data is Map && data['error'] != null) {
        return data['error'] as String;
      }
    } catch (_) {}
    if (e is Exception) {
      final str = e.toString();
      final match = RegExp(r'"error":"([^"]+)"').firstMatch(str);
      if (match != null) return match.group(1)!;
    }
    return 'An unexpected error occurred';
  }
}
