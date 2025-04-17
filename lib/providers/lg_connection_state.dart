import 'package:flutter/foundation.dart';

// Basic placeholder for now
class LgConnectionStateNotifier extends ChangeNotifier {
  bool _isConnected = false;
  String? _connectionError;
  // Add connection details later (IP, user, pass, port, screenCount)

  bool get isConnected => _isConnected;
  String? get connectionError => _connectionError;

  // Placeholder methods - will be implemented in later phases
  void setConnected() {
    if (!_isConnected) {
      _isConnected = true;
      _connectionError = null;
      notifyListeners();
      // TODO: Trigger logo display via LG Service later
    }
  }

  void setDisconnected([String? error]) {
     if (_isConnected || _connectionError != error) {
       _isConnected = false;
       _connectionError = error;
       notifyListeners();
       // TODO: Potentially trigger logo clear via LG Service later
     }
  }

  void loadConnectionDetails() {
     // TODO: Load from secure storage in Phase 5
  }
}