import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';
import '../llm.dart'; // Import for the global logger instance

class LgConfigManager {
  final Logger _log = logger; // Use the global logger
  final _secureStorage = const FlutterSecureStorage();
  static const String _prefPrefix = 'lg_config_'; // Prefix for shared_prefs keys
  static const String _keyIp = '${_prefPrefix}ip';
  static const String _keyPort = '${_prefPrefix}port';
  static const String _keyUser = '${_prefPrefix}user';
  static const String _keyScreens = '${_prefPrefix}screens';
  static const String _secureKeyPassword = 'lg_ssh_password'; // Key for secure storage

  /// Saves the LG connection details.
  ///
  /// Non-sensitive data (IP, Port, User, Screen Count) is saved to SharedPreferences.
  /// The password is saved securely using FlutterSecureStorage.
  Future<void> saveConnectionDetails({
    required String ip,
    required int port,
    required String user,
    required String password,
    required int screenCount,
  }) async {
    _log.i("Attempting to save LG connection details...");
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyIp, ip);
      await prefs.setInt(_keyPort, port); // Use setInt for port
      await prefs.setString(_keyUser, user);
      await prefs.setInt(_keyScreens, screenCount); // Use setInt for screenCount

      await _secureStorage.write(key: _secureKeyPassword, value: password);

      _log.i("LG connection details saved successfully.");
    } catch (e, s) {
      _log.e("Failed to save LG connection details", error: e, stackTrace: s);
      // Rethrow or handle as needed, maybe return a bool success indicator?
      // For now, just log the error. The calling function should handle UI feedback.
      throw Exception("Failed to save connection settings: $e");
    }
  }

  /// Loads the LG connection details from storage.
  ///
  /// Returns a Map containing the details if *all* required fields are found.
  /// Returns `null` if any required detail is missing, indicating incomplete configuration.
  Future<Map<String, dynamic>?> loadConnectionDetails() async {
    _log.d("Attempting to load LG connection details...");
    try {
      final prefs = await SharedPreferences.getInstance();

      // Read non-sensitive data
      final ip = prefs.getString(_keyIp);
      final port = prefs.getInt(_keyPort); // Use getInt
      final user = prefs.getString(_keyUser);
      final screenCount = prefs.getInt(_keyScreens); // Use getInt

      // Read sensitive data
      final password = await _secureStorage.read(key: _secureKeyPassword);

      // --- Crucial Check: Ensure ALL details exist ---
      if (ip == null || ip.isEmpty ||
          port == null ||
          user == null || user.isEmpty ||
          screenCount == null ||
          password == null || password.isEmpty) {
        _log.w("LG connection details are incomplete or not found in storage.");
        return null; // Return null if any part is missing
      }

      _log.i("LG connection details loaded successfully.");
      return {
        'ip': ip,
        'port': port,
        'user': user,
        'password': password,
        'screens': screenCount,
      };
    } catch (e, s) {
      _log.e("Failed to load LG connection details", error: e, stackTrace: s);
      return null; // Return null on error
    }
  }

  /// Clears all saved LG connection details from both SharedPreferences and SecureStorage.
  Future<void> clearConnectionDetails() async {
    _log.i("Attempting to clear all LG connection details...");
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyIp);
      await prefs.remove(_keyPort);
      await prefs.remove(_keyUser);
      await prefs.remove(_keyScreens);

      await _secureStorage.delete(key: _secureKeyPassword);

      _log.i("All LG connection details cleared.");
    } catch (e, s) {
      _log.e("Failed to clear LG connection details", error: e, stackTrace: s);
      // Decide how to handle errors, maybe rethrow
      throw Exception("Failed to clear connection settings: $e");
    }
  }
}