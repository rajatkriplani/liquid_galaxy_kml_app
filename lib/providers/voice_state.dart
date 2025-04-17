import 'package:flutter/foundation.dart';

// Enum to represent the different states of voice processing
enum VoiceActivityState {
  idle, // Waiting for user input
  listening, // Microphone is active
  processing, // STT finished, sending to LLM (or preparing to)
  error // An error occurred
}

class VoiceStateNotifier extends ChangeNotifier {
  VoiceActivityState _currentState = VoiceActivityState.idle;
  String _spokenText = '';
  String? _errorMessage;

  VoiceActivityState get currentState => _currentState;
  String get spokenText => _spokenText;
  String? get errorMessage => _errorMessage;
  // Helper getter for UI logic
  bool get isIdle => _currentState == VoiceActivityState.idle;
  bool get isListening => _currentState == VoiceActivityState.listening;
  bool get isProcessing => _currentState == VoiceActivityState.processing;
  bool get hasError => _currentState == VoiceActivityState.error;

  void setIdle() {
    _updateState(VoiceActivityState.idle);
    _spokenText = ''; // Clear text when going idle
    _errorMessage = null; // Clear error
  }

  void setListening() {
    _updateState(VoiceActivityState.listening);
    _errorMessage = null; // Clear error when starting to listen
  }

  void setProcessing(String recognizedText) {
    _updateState(VoiceActivityState.processing);
    _spokenText = recognizedText;
     _errorMessage = null;
  }

  void setError(String message) {
    _updateState(VoiceActivityState.error);
    _errorMessage = message;
  }

  // Internal helper to reduce boilerplate
  void _updateState(VoiceActivityState newState) {
    if (_currentState != newState) {
      _currentState = newState;
      notifyListeners();
    }
  }
}