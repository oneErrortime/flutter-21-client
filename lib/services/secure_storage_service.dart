import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/constants.dart';
import '../models/models.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true, // Uses Android Keystore
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await Future.wait([
      _storage.write(key: AppConstants.kAccessToken, value: accessToken),
      _storage.write(key: AppConstants.kRefreshToken, value: refreshToken),
    ]);
  }

  static Future<String?> getAccessToken() =>
      _storage.read(key: AppConstants.kAccessToken);

  static Future<String?> getRefreshToken() =>
      _storage.read(key: AppConstants.kRefreshToken);

  static Future<void> saveUser(UserModel user) async {
    await Future.wait([
      _storage.write(key: AppConstants.kUserId, value: user.userId),
      _storage.write(key: AppConstants.kUsername, value: user.username),
      _storage.write(key: AppConstants.kDisplayName, value: user.displayName),
    ]);
  }

  static Future<Map<String, String?>> getUserData() async {
    final results = await Future.wait([
      _storage.read(key: AppConstants.kUserId),
      _storage.read(key: AppConstants.kUsername),
      _storage.read(key: AppConstants.kDisplayName),
    ]);
    return {
      'userId': results[0],
      'username': results[1],
      'displayName': results[2],
    };
  }

  static Future<void> clearAll() => _storage.deleteAll();
}
