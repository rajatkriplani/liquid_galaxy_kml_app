import 'dart:async'; // Import for Timer if needed for delays
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:logger/logger.dart';
// For temporary KML file names
// For File
// Import for XML parsing

import 'settings_screen.dart';
import '../providers/voice_state.dart';
import '../providers/mascot_state.dart';
import '../providers/lg_connection_state.dart';
import '../services/permission_service.dart';
import '../services/speech_service.dart';
import '../services/lg_service.dart'; // Import LG Service
import '../llm.dart'; // Import LLM services

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final Logger _log = logger;
  final Flutter3DController mascotController = Flutter3DController();
  final PermissionService _permissionService = PermissionService();
  late final SpeechService _speechService;
  final LGService _lgService = LGService(); // Instantiate LG Service
  String _statusText = 'Tap the microphone to start';

  final Color _emissionColor = const Color.fromARGB(255, 68, 255, 152).withOpacity(0.6);
  final Color _processingColor = const Color.fromARGB(255, 64, 99, 255).withOpacity(0.6);


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ActiveLlmProvider>().initialize();
      // Optionally try to connect automatically based on saved settings later
    });
    _speechService = SpeechService(
      onResult: _handleSpeechResult,
      onError: _handleSpeechError,
      onStatus: _handleSpeechStatus,
    );
    _initializeSpeechRecognizer();
  }

  @override
  void dispose() {
    _lgService.disconnect(); // Ensure disconnection on screen disposal
    super.dispose();
  }

  Future<void> _initializeSpeechRecognizer() async {
    // ... (no changes needed here) ...
    final isAvailable = await _speechService.initialize();
    if (!isAvailable) {
      _updateStatusText("Speech recognizer not available on this device.");
      context.read<VoiceStateNotifier>().setError("Speech recognizer not available.");
    } else {
       _updateStatusText("Tap the microphone to start");
    }
  }

  void _handleSpeechResult(String recognizedText) {
    // ... (no changes needed here) ...
    _log.i("Speech Result Received: '$recognizedText'");
    if (recognizedText.trim().isEmpty) {
       _log.w("Received empty speech result. Going back to idle.");
        context.read<MascotStateNotifier>().setIdle();
        context.read<VoiceStateNotifier>().setIdle();
        _updateStatusText("Didn't catch that. Tap microphone to try again.");
        return;
    }
    context.read<MascotStateNotifier>().setProcessing();
    context.read<VoiceStateNotifier>().setProcessing(recognizedText);
    _updateStatusText('Processing: "$recognizedText"');
    _triggerIntentClassification(recognizedText);
  }

  void _handleSpeechError(String errorMsg) {
    // ... (no changes needed here) ...
    _log.e("Speech Error Received: $errorMsg");
    context.read<MascotStateNotifier>().setIdle();
    context.read<VoiceStateNotifier>().setError(errorMsg);
    _updateStatusText('Error: $errorMsg');
  }

  void _handleSpeechStatus(String status) {
    // ... (no changes needed here) ...
    _log.d("Speech Status Update: $status");
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();
    if (status == stt.SpeechToText.listeningStatus) {
      if (!voiceNotifier.isListening) {
        mascotNotifier.setListening();
        voiceNotifier.setListening();
        _updateStatusText('Listening...');
      }
    } else if (status == stt.SpeechToText.notListeningStatus || status == stt.SpeechToText.doneStatus) {
      if (voiceNotifier.isListening) {
        _log.w("Speech stopped without final result/error. Returning to idle.");
        mascotNotifier.setIdle();
        voiceNotifier.setIdle();
        _updateStatusText('Stopped listening. Tap microphone to try again.');
      }
    }
  }

  Future<void> _activateVoiceInput() async {
    // ... (no changes needed here) ...
    _log.d("Voice Activation triggered.");
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();

    if (voiceNotifier.isListening || voiceNotifier.isProcessing) {
      _log.w("Tapped while busy.");
      if (voiceNotifier.isListening) {
        _speechService.stopListening();
        mascotNotifier.setIdle();
        voiceNotifier.setIdle();
        _updateStatusText('Listening stopped.');
      }
      return;
    }

    if (!_speechService.isAvailable) {
      _handleError("Speech recognizer not available.", "Speech Error");
      return;
    }

    final hasPermission = await _permissionService.requestMicrophonePermission();
    if (!hasPermission) {
      _handleError("Microphone permission is required.", "Permission Denied");
      return;
    }

    _log.i("Starting listening...");
    _speechService.startListening();
  }

  void _updateStatusText(String text) {
    // ... (no changes needed here) ...
    if (mounted) {
      setState(() { _statusText = text; });
    }
  }

  /// Helper to show SnackBar errors and log them
  void _handleError(String message, String title, {dynamic error, StackTrace? stackTrace}) {
    _log.e('$title: $message', error: error, stackTrace: stackTrace);
    // Update state notifiers to reflect error
    context.read<VoiceStateNotifier>().setError(message);
    context.read<MascotStateNotifier>().setIdle();
    _updateStatusText('Error: $message'); // Update bottom text

    // Show SnackBar
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title: $message', style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4), // Show longer for errors
        ),
      );
    }
  }


  /// --- Phase 3 & 4: Intent Classification & LG Interaction ---
  Future<void> _triggerIntentClassification(String transcript) async {
    _log.i("Phase 3/4: Starting process for transcript: '$transcript'");
    // Ensure states reflect processing START
    context.read<MascotStateNotifier>().setProcessing();
    context.read<VoiceStateNotifier>().setProcessing(transcript);
    _updateStatusText('Understanding command...'); // Initial processing text

    final llmProvider = context.read<ActiveLlmProvider>();
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();
    final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();

    // Check LLM availability first
    if (!llmProvider.isReady) {
      _handleError("LLM Service not available.", "LLM Error");
      return;
    }

    // Instantiate the processor
    final processor = VoiceCommandProcessor(llm: llmProvider.client!);
    Map<String, dynamic> classificationResult;

    try {
      // === Step 1: Classify Intent ===
      classificationResult = await processor.processVoiceCommand(transcript);
      _log.i("Phase 3: Voice Processing Result: $classificationResult");

      if (classificationResult['success'] != true) {
         final message = classificationResult['message'] ?? 'Unknown processing error.';
         _handleError(message, "Command Error");
         return; // Stop if classification failed
      }

      final action = classificationResult['action'] as String?;
      final params = classificationResult['params'] as Map<String, dynamic>? ?? {};
      final originalIntent = classificationResult['original_intent'] as Map<String, dynamic>?;

      // === Step 2: Check LG Connection (if needed for action) ===
      bool needsConnection = action != 'GENERATE_KML' && action != 'UNKNOWN'; // KML generation connects just before sending
      bool connectionSuccessful = _lgService.isConnected;

      if (needsConnection && !connectionSuccessful) {
          _updateStatusText('Connecting to Liquid Galaxy...');
          connectionSuccessful = await _lgService.connect();
          if (connectionSuccessful) {
             lgConnectionNotifier.setConnected(); // Update provider state
             _updateStatusText('Connected. Executing command...');
          } else {
             _handleError("Failed to connect to Liquid Galaxy.", "Connection Failed");
             lgConnectionNotifier.setDisconnected("Connection Failed");
             return; // Stop if connection failed
          }
      }

      // === Step 3: Execute Action via LGService ===
      _updateStatusText('Executing: $action...'); // Update status text

      switch (action) {
        case 'GENERATE_KML':
          final kml = classificationResult['kml'] as String?;
          if (kml != null) {
             _log.d("Phase 4: Sending KML to LG...");
             // Ensure connection before sending KML
             _log.i("=== GENERATED KML START ===\n$kml\n=== GENERATED KML END ===");
             if (!_lgService.isConnected) {
                 _updateStatusText('Connecting to send KML...');
                 connectionSuccessful = await _lgService.connect();
                 if (!connectionSuccessful) {
                    _handleError("Failed to connect to Liquid Galaxy to send KML.", "Connection Failed");
                    lgConnectionNotifier.setDisconnected("Connection Failed");
                    return;
                 }
                 lgConnectionNotifier.setConnected();
             }
             final kmlFileName = 'voice_cmd_${DateTime.now().millisecondsSinceEpoch}.kml';
             await _lgService.sendKmlToLg(kml, kmlFileName);

             _updateStatusText("KML Displayed on Liquid Galaxy.");
          } else {
             throw LlmException("KML generation reported success but KML was null."); // Should be caught below
          }
          break;

        case 'CLEAR_KML':
          await _lgService.clearKmlOnLg();
          _updateStatusText("KML cleared from Liquid Galaxy.");
          break;

        case 'CLEAR_LOGO':
           await _lgService.clearLogo();
           _updateStatusText("Logo cleared from Liquid Galaxy.");
           break;

        case 'PLAY_TOUR':
           await _lgService.playTour();
           _updateStatusText("Tour started on Liquid Galaxy.");
           break;

        case 'EXIT_TOUR':
           await _lgService.exitTour();
           _updateStatusText("Tour stopped on Liquid Galaxy.");
           break;

        case 'FLY_TO':
           // Attempt to use LookAt string if provided directly by LLM (less likely now)
           final lookAt = params['lookAt'] as String? ?? originalIntent?['lookAt'] as String?;
           final locationName = params['location_name'] as String? ?? originalIntent?['location_name'] as String?;

           if (lookAt != null && lookAt.isNotEmpty) {
              _log.i("FLY_TO: Using direct LookAt KML provided.");
              _log.i("Executing direct FlyTo LookAt: $lookAt");
              await _lgService.flyToLookAt(lookAt);
              _updateStatusText("Flying to view on Liquid Galaxy.");
           }
           // **Primary Path: Use location name to generate KML**
           else if (locationName != null && locationName.isNotEmpty) {
              _log.i("FLY_TO: No direct LookAt KML. Generating KML for location: '$locationName'");
              _updateStatusText("Generating KML for $locationName..."); // Update status

              // Generate KML specifically for flying to the location
              final kmlProcessor = KmlGeneratorService(llm: llmProvider.client!);
              // Use a simple prompt focused on just viewing the location
              final kml = await kmlProcessor.generateKml("Show $locationName");
              _updateStatusText("Sending KML for $locationName..."); // Update status

              _log.i("=== FLY_TO FALLBACK KML START ===\n$kml\n=== FLY_TO FALLBACK KML END ===");
               // Ensure connection before sending
              if (!_lgService.isConnected) { /* connect */ } // Simplified connection check

              final kmlFileName = 'flyto_${locationName.replaceAll(' ','_')}_${DateTime.now().millisecondsSinceEpoch}.kml';
              await _lgService.sendKmlToLg(kml, kmlFileName);

               _updateStatusText("Flying to $locationName on Liquid Galaxy."); // Final status
           } else {
              _log.e("FLY_TO intent received but missing LookAt KML and location name.");
              throw LgException("Could not determine where to fly to for FLY_TO command.");
           }
           break;

        case 'UNKNOWN':
        default:
          _log.w("Unhandled or UNKNOWN action received: $action");
           // Use the message from the classification result if available
           final message = classificationResult['message'] ?? "I'm not sure how to handle that request for Liquid Galaxy.";
           _handleError(message, "Unknown Command");
           break;
      }

      // === Step 4: Reset State (on success) ===
      // Short delay to allow user to read final status message
      await Future.delayed(const Duration(milliseconds: 2000));
      mascotNotifier.setIdle();
      voiceNotifier.setIdle();
      _updateStatusText("Ready. Tap microphone to start.");


    } on LgException catch (e, s) { // Catch specific LG connection/command errors
       _handleError(e.message, "Liquid Galaxy Error", error: e.underlyingError ?? e, stackTrace: s);
       // Optionally update LG connection state if it was a connection error
       if (e.message.toLowerCase().contains('connect')) {
          lgConnectionNotifier.setDisconnected(e.message);
       }
    } on LlmException catch (e, s) { // Catch LLM errors (classification or KML gen)
       _handleError(e.message, "AI Service Error", error: e.underlyingError ?? e, stackTrace: s);
    } catch (e, s) { // Catch any other unexpected errors
       _handleError("An unexpected error occurred.", "Error", error: e, stackTrace: s);
    }
    // Note: State reset on error is handled within _handleError
  }


  @override
  Widget build(BuildContext context) {
    // ... (rest of the build method - no changes needed from your provided code) ...
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