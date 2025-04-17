import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:logger/logger.dart';

import 'settings_screen.dart';
import '../providers/voice_state.dart';
import '../providers/mascot_state.dart';
import '../providers/lg_connection_state.dart';
import '../services/permission_service.dart';
import '../services/speech_service.dart';
import '../llm.dart'; // Import for VoiceCommandProcessor trigger & ActiveLlmProvider

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final Logger _log = logger; // Use global logger from llm.dart
  final Flutter3DController mascotController = Flutter3DController();
  final PermissionService _permissionService = PermissionService();
  late final SpeechService _speechService;
  String _statusText = 'Tap the microphone to start'; // Updated initial text

  // Define emission color
  final Color _emissionColor = const Color.fromARGB(255, 68, 255, 152).withOpacity(0.6); // Adjust color and opacity
  final Color _processingColor = const Color.fromARGB(255, 64, 99, 255).withOpacity(0.6);

  @override
  void initState() {
    super.initState();

    // Initialize ActiveLlmProvider early
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ActiveLlmProvider>().initialize();
    });

    // --- Initialize Speech Service ---
    _speechService = SpeechService(
      onResult: _handleSpeechResult,
      onError: _handleSpeechError,
      onStatus: _handleSpeechStatus,
    );

    _initializeSpeechRecognizer();
  }

  @override
  void dispose() {
    // Dispose of any controllers if necessary (mascotController doesn't seem to have one)
    super.dispose();
  }


  Future<void> _initializeSpeechRecognizer() async {
    final isAvailable = await _speechService.initialize();
    if (!isAvailable) {
      _updateStatusText("Speech recognizer not available on this device.");
      // Keep state as idle, but update text and notifier
      context.read<VoiceStateNotifier>().setError("Speech recognizer not available.");
    } else {
       _updateStatusText("Tap the microphone to start"); // Ready state text
    }
  }

  // --- Speech Service Callbacks ---
  void _handleSpeechResult(String recognizedText) {
    _log.i("Speech Result Received: '$recognizedText'");
    if (recognizedText.trim().isEmpty) {
       _log.w("Received empty speech result. Going back to idle.");
        context.read<MascotStateNotifier>().setIdle(); // Turn off emission
        context.read<VoiceStateNotifier>().setIdle();
        _updateStatusText("Didn't catch that. Tap microphone to try again.");
        return;
    }

    // Update state to Processing
    context.read<MascotStateNotifier>().setProcessing(); // Or setIdle() if no processing look
    context.read<VoiceStateNotifier>().setProcessing(recognizedText);
    _updateStatusText('Processing: "$recognizedText"');

    // --- Trigger Phase 3: Intent Classification ---
    _triggerIntentClassification(recognizedText);
  }

  void _handleSpeechError(String errorMsg) {
    _log.e("Speech Error Received: $errorMsg");
    context.read<MascotStateNotifier>().setIdle(); // Turn off emission
    context.read<VoiceStateNotifier>().setError(errorMsg);
    _updateStatusText('Error: $errorMsg');
  }

  void _handleSpeechStatus(String status) { // status is String
    _log.d("Speech Status Update: $status");
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();

    // Compare using the status string constants from speech_to_text
    if (status == stt.SpeechToText.listeningStatus) {
      if (!voiceNotifier.isListening) {
        mascotNotifier.setListening(); // Turn on emission visual
        voiceNotifier.setListening();
        _updateStatusText('Listening...');
      }
    } else if (status == stt.SpeechToText.notListeningStatus || status == stt.SpeechToText.doneStatus) {
      // If we are still in 'listening' state (meaning no final result/error yet)
      // go back to idle. This handles cases like timeout without speech.
      if (voiceNotifier.isListening) {
        _log.w("Speech stopped without final result/error. Returning to idle.");
        mascotNotifier.setIdle(); // Turn off emission
        voiceNotifier.setIdle();
        _updateStatusText('Stopped listening. Tap microphone to try again.');
      }
      // Otherwise, the state would have been updated by onResult or onError
    }
  }

  // --- Voice Activation Button Tapped ---
  Future<void> _activateVoiceInput() async {
    _log.d("Voice Activation triggered - _activateVoiceInput entered.");
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();

    // Check 1: Already busy?
    if (voiceNotifier.isListening || voiceNotifier.isProcessing) {
      _log.w("Voice Activation tapped while busy (State: ${voiceNotifier.currentState}). Ignoring.");
      // Optional: Stop listening if tapped while listening?
      if (voiceNotifier.isListening) {
        _speechService.stopListening(); // Stop current listening attempt
        mascotNotifier.setIdle();
        voiceNotifier.setIdle();
        _updateStatusText('Listening stopped. Tap microphone to start.');
      }
      return; // Exit
    }
    _log.d("_activateVoiceInput: Not busy, proceeding.");

    // Check 2: Speech Service Available?
    if (!_speechService.isAvailable) {
      _log.e("Voice Activation tapped but speech service is not available.");
      voiceNotifier.setError("Speech recognizer not available.");
      _updateStatusText("Error: Speech recognizer not available.");
      return; // Exit
    }
    _log.d("_activateVoiceInput: Speech service is available.");

    // Check 3: Request Permission
    _log.d("_activateVoiceInput: Requesting microphone permission...");
    final hasPermission = await _permissionService.requestMicrophonePermission();
    _log.d("_activateVoiceInput: Permission result: hasPermission=$hasPermission");

    if (!hasPermission) {
      _log.w("Microphone permission denied.");
      mascotNotifier.setIdle(); // Ensure idle state visually
      voiceNotifier.setError("Microphone permission required.");
      _updateStatusText("Error: Microphone permission is required.");
      // Consider prompting to open settings
      // await _permissionService.openAppSettingsPage();
      return; // Exit
    }
    _log.d("_activateVoiceInput: Permission granted.");

    // Action: Start Listening
    _log.i("_activateVoiceInput: Calling _speechService.startListening()...");
    _speechService.startListening();
    _log.d("_activateVoiceInput: Call to _speechService.startListening() completed.");
    // State changes (listening, mascot glowing) are handled by the _handleSpeechStatus callback
  }


  // --- Update Bottom Status Text ---
  void _updateStatusText(String text) {
    if (mounted) {
      setState(() { _statusText = text; });
    }
  }

  // --- Phase 3 Trigger (Placeholder for now) ---
  Future<void> _triggerIntentClassification(String transcript) async {
    _log.i("Phase 3: Triggering Intent Classification for: '$transcript'");

    // Ensure states reflect processing START
    context.read<MascotStateNotifier>().setProcessing(); // Show processing visual
    context.read<VoiceStateNotifier>().setProcessing(transcript); // Keep state as processing
    _updateStatusText('Processing...'); // Update UI text

    final llmProvider = context.read<ActiveLlmProvider>();
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();

    if (!llmProvider.isReady) {
      _log.e("Cannot process command: LLM client not ready.");
      mascotNotifier.setIdle(); // Reset visuals
      voiceNotifier.setError("LLM Service not available. Check API Key settings.");
      _updateStatusText("Error: LLM Service not available.");
      return;
    }

    // Instantiate the processor with the active client
    final processor = VoiceCommandProcessor(llm: llmProvider.client!);

    try {
      // --- Call the processor ---
      final result = await processor.processVoiceCommand(transcript);
      _log.i("Phase 3: Voice Processing Result: $result");

      // --- Handle the result ---
      if (result['success'] == true) {
        final action = result['action'];
        _log.i("Phase 3: Successfully processed intent: $action");

        // Prepare for Phase 4 based on action
        if (action == 'GENERATE_KML') {
          final kml = result['kml'] as String?;
          if (kml != null) {
             _log.d("Phase 3: KML Generated (Length: ${kml.length}). Ready for Phase 4 (Send KML).");
             // TODO (Phase 4): Call LGService.sendKmlToLg(kml);
             _updateStatusText("Okay, preparing to display KML...");
          } else {
             // This case shouldn't happen if success is true and action is GENERATE_KML
             // according to VoiceCommandProcessor logic, but handle defensively.
              _log.e("Phase 3: KML Generation reported success but KML was null.");
              throw LlmException("KML generation failed unexpectedly.");
          }
        } else {
          // Handle other direct commands
          final params = result['params'];
          _log.d("Phase 3: Direct Command '$action' ready for Phase 4. Params: $params");
          // TODO (Phase 4): Call appropriate LGService method (e.g., clearKml, playTour)
           _updateStatusText("Okay, understood command: $action");
        }

         // --- Reset state after successful processing (Temporary) ---
         // In full flow, state might remain busy during LG interaction (Phase 4)
         // For now, reset to idle after a short delay to show the status text.
         await Future.delayed(const Duration(seconds: 2));
         mascotNotifier.setIdle();
         voiceNotifier.setIdle();
         _updateStatusText("Ready. Tap microphone to start.");
         // --- End Temporary Reset ---

      } else {
        // Handle processing failure reported by the processor
        final message = result['message'] ?? 'Unknown processing error.';
        final errorAction = result['action'] ?? 'ERROR_UNKNOWN';
        _log.e("Phase 3: Voice command processing failed. Action: $errorAction, Message: $message");
        mascotNotifier.setIdle();
        voiceNotifier.setError("Processing failed: $message"); // Use message from result
         _updateStatusText("Sorry, I couldn't process that request."); // User-friendly message
      }

    } on LlmException catch (e, s) {
      _log.e("Phase 3: LLM Exception during voice processing", error: e, stackTrace: s);
      mascotNotifier.setIdle();
      voiceNotifier.setError("LLM Error: ${e.message}");
       _updateStatusText("Sorry, there was an issue with the AI service.");
    } catch (e, s) {
      // Catch any other unexpected errors
      _log.f("Phase 3: Unexpected error during voice processing", error: e, stackTrace: s);
      mascotNotifier.setIdle();
      voiceNotifier.setError("Unexpected error: ${e.toString()}");
       _updateStatusText("Sorry, an unexpected error occurred.");
    }
    // Note: State reset is handled within success/error blocks or temporarily after success.
  }


  @override
  Widget build(BuildContext context) {
    // Watch necessary states for rebuilds
    final connectionState = context.watch<LgConnectionStateNotifier>().isConnected;
    final mascotAppearance = context.watch<MascotStateNotifier>().appearance;
    final voiceState = context.watch<VoiceStateNotifier>(); // Watch voice state too

    _log.v("MainScreen rebuilding. Mascot Appearance: $mascotAppearance, Voice State: ${voiceState.currentState}");

    return Scaffold(
      // Use SafeArea to avoid status/navigation bar overlap
      body: SafeArea(
        child: Stack(
          children: [
            // --- Connection Status Indicator (Top-Left) ---
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(
                    color: connectionState ? Colors.greenAccent : Colors.redAccent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3), spreadRadius: 1,
                        blurRadius: 3, offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // --- Settings Icon (Top-Right) ---
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: IconButton(
                  icon: const Icon(Icons.settings, size: 30.0),
                  tooltip: 'Settings',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const SettingsScreen()),
                    );
                  },
                ),
              ),
            ),

            // --- Mascot and Emission Effect Layer (Center) ---
            Center(
              child: Stack( // Inner stack for mascot and effect
                alignment: Alignment.center,
                children: [
                  // --- Emission Effect (Behind Mascot) ---
                  AnimatedOpacity(
                    opacity: (mascotAppearance == MascotAppearance.listening || mascotAppearance == MascotAppearance.processing)
                         ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300), // Fade duration
                    child: IgnorePointer( // Prevent effect from blocking model interaction
                      child: Container(
                        width: 350, // Slightly larger than model viewer
                        height: 350,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              mascotAppearance == MascotAppearance.listening
                              ? _emissionColor // Blue for listening
                              : _processingColor, // Orange for processing
                            Colors.transparent,
                            ],
                            stops: const [0.1, 1.0], // Adjust gradient spread
                          ),
                        ),
                      ),
                    ),
                  ),

                  // --- 3D Mascot (In Front of Effect) ---
                  SizedBox(
                    width: 300, height: 400, // Original size
                    child: Flutter3DViewer(
                      controller: mascotController,
                      src: 'assets/models/mascot.glb',
                      // Allow user to interact with model if desired
                      enableTouch: true,
                      activeGestureInterceptor: true,
                      // Key might help if internal state needs resetting, but not essential here
                      // key: ValueKey(mascotAppearance),
                    ),
                  ),
                ],
              ),
            ),


            // --- Status Text Area (Bottom) ---
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20), // Adjust bottom padding if needed
                child: Text(
                  _statusText, // Display dynamic status text
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: voiceState.hasError ? Colors.redAccent : null,
                  ),
                ),
              ),
            ),
          ], // End Outer Stack Children
        ), // End SafeArea Child
      ), // End SafeArea

      // --- Floating Action Button for Voice Activation ---
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
         // Add padding below FAB to avoid overlapping bottom text/nav bar
         padding: const EdgeInsets.only(bottom: 60.0),
         child: FloatingActionButton.large(
           onPressed: _activateVoiceInput, // Trigger voice logic
           tooltip: 'Activate Voice Command',
           // Change appearance when listening
           backgroundColor: voiceState.isListening
                            ? Colors.redAccent.withOpacity(0.8)
                            : Theme.of(context).colorScheme.secondary,
           foregroundColor: Colors.white, // Icon color
           child: voiceState.isListening
               ? const Icon(Icons.stop) // Show stop icon when listening
               : const Icon(Icons.mic), // Show mic icon otherwise
         ),
      ), // End Padding
    ); // End Scaffold
  }
}