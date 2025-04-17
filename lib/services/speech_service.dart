import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:logger/logger.dart';
import '../llm.dart'; // <-- ADD THIS IMPORT for the global logger

class SpeechService {
  // Use the global logger instance from llm.dart
  final Logger _log = logger; // Now 'logger' should be defined
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isAvailable = false;
  bool _isListening = false;

  // Callbacks for state updates - Use String for status
  final Function(String)? onResult;
  final Function(String)? onError;
  final Function(String)? onStatus; // <-- CHANGE Type hint to String

  SpeechService({this.onResult, this.onError, this.onStatus});

  bool get isAvailable => _isAvailable;
  bool get isListening => _isListening;

  Future<bool> initialize() async {
    try {
      _isAvailable = await _speech.initialize(
        onError: _errorListener,
        onStatus: _statusListener,
        // debugLog: true, // <-- REMOVE this parameter
        // finalTimeout: Duration(seconds: 5), // Adjust timeout if needed
      );
      _log.i("Speech recognition initialized. Available: $_isAvailable");
      return _isAvailable;
    } catch (e, s) {
      _log.e("Error initializing speech recognition", error: e, stackTrace: s);
      _isAvailable = false;
      return false;
    }
  }

    void startListening() {
    _log.d("SpeechService: startListening() called."); // Log entry
    if (!_isAvailable) {
      _log.w("SpeechService: Cannot start listening - Service not available.");
      onError?.call("Speech recognizer not available."); // Notify caller
      return;
    }
    if (_isListening) {
        _log.w("SpeechService: Cannot start listening - Already listening.");
        // Maybe call stop/cancel first? Or just ignore.
        return;
    }

    _log.i("SpeechService: Attempting to call _speech.listen()...");
    try {
        _speech.listen(
          onResult: _resultListener,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 10),
          localeId: 'en_US',
        );
        _isListening = true; // Assume listening starts (callback confirms)
        _log.i("SpeechService: _speech.listen() called successfully.");
    } catch (e, s) {
        // Catch potential errors during the listen() call itself
        _log.e("SpeechService: Error calling _speech.listen()", error: e, stackTrace: s);
        _isListening = false;
        onError?.call("Failed to start listener: ${e.toString()}");
    }
  }

  void stopListening() {
    if (!_isListening && !_speech.isListening) return; // Check plugin state too
    _log.i("Stopping speech recognition listening...");
    _speech.stop();
    _isListening = false;
     // Status update will be handled by _statusListener
  }

  void cancelListening() {
    if (!_isListening && !_speech.isListening) return;
    _log.i("Cancelling speech recognition listening...");
    _speech.cancel();
    _isListening = false;
     // Status update will be handled by _statusListener
  }

  // --- Internal Listeners ---

  void _resultListener(SpeechRecognitionResult result) {
    _log.d("Speech result: Final=${result.finalResult}, Recognized='${result.recognizedWords}'");
    if (result.finalResult) {
      _isListening = false; // Update internal state
      onResult?.call(result.recognizedWords);
    }
  }

  void _errorListener(SpeechRecognitionError error) {
    _log.e("Speech recognition error: ${error.errorMsg} (Permanent: ${error.permanent})");
    _isListening = false; // Update internal state
    onError?.call(error.errorMsg); // Pass the string message
  }

  void _statusListener(String status) { // <-- Parameter is String
    _log.i("Speech recognition status changed: $status");
    // Update internal flag based on string status
    _isListening = status == stt.SpeechToText.listeningStatus; // Use constant for comparison
    // Pass the raw string status to the callback
    onStatus?.call(status);
  }
}