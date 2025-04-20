import 'dart:async';
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
import '../services/lg_service.dart'; // Keep Import
import '../llm.dart';

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

  String _statusText = 'Initializing...'; // Update initial status

  final Color _emissionColor = const Color.fromARGB(255, 68, 255, 152).withOpacity(0.6);
  final Color _processingColor = const Color.fromARGB(255, 64, 99, 255).withOpacity(0.6);

  @override
  void initState() {
    super.initState();

    // Use addPostFrameCallback to safely interact with Providers after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Check if the widget is still mounted before proceeding
      if (!mounted) return;
      _initializeServicesAndConnection();
    });

    // Initialize SpeechService (can be done synchronously if initialize is light)
    _speechService = SpeechService(
      onResult: _handleSpeechResult,
      onError: _handleSpeechError,
      onStatus: _handleSpeechStatus,
    );
    _initializeSpeechRecognizer(); // Start STT initialization
  }

  Future<void> _initializeServicesAndConnection() async {
    _log.i("MainScreen: Initializing services and checking LG connection...");

    // Initialize LLM Provider (triggers loading keys/prefs)
    try {
      // Use context.read inside async methods/callbacks
      final llmProvider = context.read<ActiveLlmProvider>();
      await llmProvider.initialize();
      if (llmProvider.isReady) {
        _log.i("LLM Provider initialized and ready.");
      } else {
         // Error state is handled within the provider, maybe update status text?
         _updateStatusText(llmProvider.error ?? "LLM not configured.");
         // No return here, app should still function for settings access
      }
    } catch (e, s) {
       // This catch is less likely now as initialize handles errors internally
       _log.e("Unexpected error during LLM initialization", error: e, stackTrace: s);
       _updateStatusText("Error initializing AI Service.");
    }


    // Attempt initial LG Connection if configured
    try {
      final lgService = context.read<LGService>();
      final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();

      if (lgService.isConfigured) {
        _log.i("LG Service is configured. Attempting initial connection...");
        _updateStatusText("Connecting to Liquid Galaxy..."); // Update UI
        final bool connected = await lgService.connect();
        if (!mounted) return; // Check mounted status after await

        if (connected) {
          _log.i("Initial connection to LG successful.");
          lgConnectionNotifier.setConnected();
          _updateStatusText("Connected. Tap microphone to start."); // Update UI
        } else {
          // connect() now throws on failure, so this 'else' might not be reached often
          _log.w("Initial connection to LG failed (returned false).");
          lgConnectionNotifier.setDisconnected("Initial connection failed");
          _updateStatusText("Connection failed. Check Settings."); // Update UI
        }
      } else {
        _log.w("LG Service is not configured. Skipping initial connection attempt.");
        _updateStatusText("LG not configured. Go to Settings."); // Update UI
        lgConnectionNotifier.setDisconnected("Not Configured"); // Set state to disconnected
      }
    } on LgException catch (e, s) {
       _log.e("LG Connection/Configuration Error during initialization", error: e.underlyingError ?? e, stackTrace: s);
       if (!mounted) return;
       final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();
       lgConnectionNotifier.setDisconnected(e.message); // Use error message from exception
       _updateStatusText("LG Error: ${e.message}"); // Update UI
    } catch (e, s) {
      // Catch other unexpected errors
      _log.e("Unexpected error during initial LG connection attempt", error: e, stackTrace: s);
       if (!mounted) return;
       final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();
       lgConnectionNotifier.setDisconnected("Connection Error");
       _updateStatusText("Error connecting to LG."); // Update UI
    }
  }


  @override
  void dispose() {
    try {
      final lgService = context.read<LGService>();
      if (lgService.isConnected) {
          lgService.disconnect(); // Disconnect if connected
      }
    } catch (e) {
      _log.w("Error accessing LGService or disconnecting during dispose: $e");
      // Don't crash if provider is unavailable during dispose
    }
    // Cancel speech listener if active
    if (_speechService.isListening) {
        _speechService.cancelListening();
    }
    super.dispose();
  }

  Future<void> _initializeSpeechRecognizer() async {
    // Keep this initialization logic
    final isAvailable = await _speechService.initialize();
    if (!mounted) return;
    if (!isAvailable) {
      _updateStatusText("Speech recognizer not available.");
      context.read<VoiceStateNotifier>().setError("Speech recognizer not available.");
    } else {
       // Only set ready text if LG didn't set an error/connection message
       if (context.read<LgConnectionStateNotifier>().connectionError == null &&
           !context.read<LgConnectionStateNotifier>().isConnected) {
          _updateStatusText("Ready. Tap microphone to start.");
       }
    }
  }

  // ... _handleSpeechResult, _handleSpeechError, _handleSpeechStatus remain the same ...
   void _handleSpeechResult(String recognizedText) {
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
    _log.e("Speech Error Received: $errorMsg");
    context.read<MascotStateNotifier>().setIdle();
    context.read<VoiceStateNotifier>().setError(errorMsg);
    _updateStatusText('Error: $errorMsg');
  }

  void _handleSpeechStatus(String status) {
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
      // Added check: Only reset to idle if we were actually listening and didn't get a result/error yet
      if (voiceNotifier.isListening && !voiceNotifier.isProcessing && !voiceNotifier.hasError) {
        _log.w("Speech stopped without final result/error while listening. Returning to idle.");
        mascotNotifier.setIdle();
        voiceNotifier.setIdle();
        _updateStatusText('Stopped listening. Tap microphone to try again.');
      }
    }
  }

  Future<void> _activateVoiceInput() async {
    _log.d("Voice Activation triggered.");
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();

    if (voiceNotifier.isListening || voiceNotifier.isProcessing) {
      _log.w("Tapped while busy.");
      if (voiceNotifier.isListening) {
        _speechService.stopListening(); // Use stop instead of just setting state
        // Let the status callback handle state changes
      }
      return;
    }

    if (!_speechService.isAvailable) {
      _handleError("Speech recognizer not available.", "Speech Error");
      return;
    }

    final llmProvider = context.read<ActiveLlmProvider>();
    final lgService = context.read<LGService>();

    if (!llmProvider.isReady) {
        _handleError(llmProvider.error ?? "LLM not configured.", "AI Service Error");
        return;
    }
    if (!lgService.isConfigured) {
        _handleError("Liquid Galaxy not configured.", "LG Error");
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
    // Use mounted check for safety
    if (mounted) {
      setState(() { _statusText = text; });
    } else {
      _log.w("Attempted to update status text when widget not mounted: $text");
    }
  }

  // _handleError remains mostly the same
  void _handleError(String message, String title, {dynamic error, StackTrace? stackTrace}) {
    _log.e('$title: $message', error: error, stackTrace: stackTrace);
    // Update state notifiers ONLY IF mounted
    if (mounted) {
      context.read<VoiceStateNotifier>().setError(message);
      context.read<MascotStateNotifier>().setIdle();
      _updateStatusText('Error: $message'); // Update bottom text

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title: $message', style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }


  Future<void> _triggerIntentClassification(String transcript) async {
    _log.i("Phase 3/4: Starting process for transcript: '$transcript'");
    // Access services via context.read inside the method
    final llmProvider = context.read<ActiveLlmProvider>();
    final lgService = context.read<LGService>(); // <-- Use Provider
    final voiceNotifier = context.read<VoiceStateNotifier>();
    final mascotNotifier = context.read<MascotStateNotifier>();
    final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();

    // Ensure states reflect processing START
    mascotNotifier.setProcessing();
    voiceNotifier.setProcessing(transcript); // Keep this
    _updateStatusText('Understanding command...');

    // Check LLM availability (already done in _activateVoiceInput, but good defense)
    if (!llmProvider.isReady || llmProvider.client == null) {
      _handleError(llmProvider.error ?? "LLM Service not available.", "LLM Error");
      return;
    }

    // Instantiate the processor using the provided client
    final processor = VoiceCommandProcessor(llm: llmProvider.client!);
    Map<String, dynamic> classificationResult;

    try {
      // === Step 1: Classify Intent ===
      classificationResult = await processor.processVoiceCommand(transcript);
      _log.i("Phase 3: Voice Processing Result: $classificationResult");

      if (classificationResult['success'] != true) {
         final message = classificationResult['message'] ?? 'Unknown processing error.';
         _handleError(message, "Command Error");
         return;
      }

      final action = classificationResult['action'] as String?;
      final params = classificationResult['params'] as Map<String, dynamic>? ?? {};
      final originalIntent = classificationResult['original_intent'] as Map<String, dynamic>?;

      // === Step 2: Check LG Connection (if needed for action) ===
      // Actions that REQUIRE a live connection check *before* executing
      bool needsConnectionCheck = action != 'GENERATE_KML' && action != 'UNKNOWN';
      bool connectionSuccessful = lgService.isConnected; // Check current state

      if (needsConnectionCheck && !connectionSuccessful) {
          // Configuration check (should be configured if we reached here, but good practice)
          if (!lgService.isConfigured) {
              _handleError("Liquid Galaxy not configured.", "LG Error");
              return;
          }
          _updateStatusText('Connecting to Liquid Galaxy...');
          try {
             connectionSuccessful = await lgService.connect(); // Attempt connection
          } on LgException catch (e) { // Catch specific connection errors
             _handleError(e.message, "Connection Failed", error: e.underlyingError ?? e);
             lgConnectionNotifier.setDisconnected(e.message);
             return; // Stop if connection failed
          }

          if (!mounted) return; // Check mounted after await
          if (connectionSuccessful) {
             lgConnectionNotifier.setConnected();
             _updateStatusText('Connected. Executing command...');
          } else {
             // Should be caught by exception now, but handle just in case
             _handleError("Failed to connect to Liquid Galaxy.", "Connection Failed");
             lgConnectionNotifier.setDisconnected("Connection Failed");
             return;
          }
      } else if (action == 'GENERATE_KML' && !lgService.isConnected) {
          // Special case: Connect specifically for KML generation if not already connected
          if (!lgService.isConfigured) {
              _handleError("Liquid Galaxy not configured.", "LG Error");
              return;
          }
          _updateStatusText('Connecting to send KML...');
          try {
             connectionSuccessful = await lgService.connect();
          } on LgException catch (e) {
             _handleError(e.message, "Connection Failed", error: e.underlyingError ?? e);
             lgConnectionNotifier.setDisconnected(e.message);
             return;
          }
          if (!mounted) return;
          if (!connectionSuccessful) {
             _handleError("Failed to connect to Liquid Galaxy to send KML.", "Connection Failed");
             lgConnectionNotifier.setDisconnected("Connection Failed");
             return;
          }
          lgConnectionNotifier.setConnected();
      }


      // === Step 3: Execute Action via LGService ===
      _updateStatusText('Executing: $action...');

      switch (action) {
        case 'GENERATE_KML':
          final kml = classificationResult['kml'] as String?;
          if (kml != null) {
             _log.d("Phase 4: Sending KML to LG...");
             _log.i("=== GENERATED KML START ===\n$kml\n=== GENERATED KML END ===");
             // Connection ensured above
             final kmlFileName = 'voice_cmd_${DateTime.now().millisecondsSinceEpoch}.kml';
             await lgService.sendKmlToLg(kml, kmlFileName); // Use lgService instance
             _updateStatusText("KML Displayed on Liquid Galaxy.");
          } else {
             throw LlmException("KML generation reported success but KML was null.");
          }
          break;

        case 'CLEAR_KML':
          await lgService.clearKmlOnLg(); // Use lgService instance
          _updateStatusText("KML cleared from Liquid Galaxy.");
          break;

        case 'CLEAR_LOGO':
           await lgService.clearLogo(); // Use lgService instance
           _updateStatusText("Logo cleared from Liquid Galaxy.");
           break;

        case 'PLAY_TOUR':
           await lgService.playTour(); // Use lgService instance
           _updateStatusText("Tour started on Liquid Galaxy.");
           break;

        case 'EXIT_TOUR':
           await lgService.exitTour(); // Use lgService instance
           _updateStatusText("Tour stopped on Liquid Galaxy.");
           break;

        case 'FLY_TO':
           final lookAt = params['lookAt'] as String? ?? originalIntent?['lookAt'] as String?;
           final locationName = params['location_name'] as String? ?? originalIntent?['location_name'] as String?;

           if (lookAt != null && lookAt.isNotEmpty) {
              _log.i("Executing direct FlyTo LookAt: $lookAt");
              await lgService.flyToLookAt(lookAt); // Use lgService instance
              _updateStatusText("Flying to view on Liquid Galaxy.");
           }
           else if (locationName != null && locationName.isNotEmpty) {
              _log.i("FLY_TO: Generating KML for location: '$locationName'");
              _updateStatusText("Generating KML for $locationName...");

              // Re-use the LLM client from the provider
              final kmlProcessor = KmlGeneratorService(llm: llmProvider.client!);
              final kml = await kmlProcessor.generateKml("Show $locationName");
               if (!mounted) return; // Check after await
              _updateStatusText("Sending KML for $locationName...");

              _log.i("=== FLY_TO FALLBACK KML START ===\n$kml\n=== FLY_TO FALLBACK KML END ===");
               // Connection ensured above
              final kmlFileName = 'flyto_${locationName.replaceAll(' ','_')}_${DateTime.now().millisecondsSinceEpoch}.kml';
              await lgService.sendKmlToLg(kml, kmlFileName); // Use lgService instance
               if (!mounted) return;
               _updateStatusText("Flying to $locationName on Liquid Galaxy.");
           } else {
              _log.e("FLY_TO intent received but missing LookAt KML and location name.");
              throw LgException("Could not determine where to fly to for FLY_TO command.");
           }
           break;

        case 'REBOOT_LG':
          // Show confirmation dialog first
          final confirm = await showDialog<bool>(
             context: context,
             builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('Confirm Reboot'),
                  content: const Text('Are you sure you want to reboot the Liquid Galaxy rig?'),
                  actions: <Widget>[
                    TextButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Reboot'),
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ],
                );
             },
          );

          if (confirm == true) {
             _updateStatusText("Sending Reboot command...");
             await lgService.rebootLG(); // Use lgService instance
              if (!mounted) return; // Check after await
             // Update state to disconnected as connection will be lost
             lgConnectionNotifier.setDisconnected("Rebooting");
             _updateStatusText("Reboot command sent. Connection lost.");
          } else {
             _updateStatusText("Reboot cancelled.");
          }
          break;

        case 'UNKNOWN':
        default:
          _log.w("Unhandled or UNKNOWN action received: $action");
           final message = classificationResult['message'] ?? "I'm not sure how to handle that request for Liquid Galaxy.";
           _handleError(message, "Unknown Command");
           break;
      }

      // === Step 4: Reset State (on success, unless rebooting) ===
      if (action != 'REBOOT_LG') {
          await Future.delayed(const Duration(milliseconds: 1500));
          if (!mounted) return;
          mascotNotifier.setIdle();
          voiceNotifier.setIdle();
          // Reset status text based on connection state
          final currentConnectionState = context.read<LgConnectionStateNotifier>();
          if (currentConnectionState.isConnected) {
             _updateStatusText("Ready. Tap microphone to start.");
          } else {
              _updateStatusText(currentConnectionState.connectionError ?? "Disconnected. Check Settings.");
          }
      }

    } on LgException catch (e, s) {
       _log.e("LG Error during command execution", error: e.underlyingError ?? e, stackTrace: s);
        if (!mounted) return;
       _handleError(e.message, "Liquid Galaxy Error", error: e.underlyingError ?? e, stackTrace: s);
       // Update connection state if it was a connection error potentially missed earlier
       if (e.message.toLowerCase().contains('connect') || e.message.toLowerCase().contains('config')) {
          lgConnectionNotifier.setDisconnected(e.message);
       }
    } on LlmException catch (e, s) {
       _log.e("LLM Error during command execution", error: e.underlyingError ?? e, stackTrace: s);
       if (!mounted) return;
       _handleError(e.message, "AI Service Error", error: e.underlyingError ?? e, stackTrace: s);
    } catch (e, s) {
       _log.e("Unexpected error during command execution", error: e, stackTrace: s);
        if (!mounted) return;
       _handleError("An unexpected error occurred: ${e.toString()}", "Error", error: e, stackTrace: s);
    } finally {
       // Ensure mascot/voice state is reset even if an error occurred (handled in _handleError)
       // but double check here if needed.
       if (mounted && (voiceNotifier.isProcessing || mascotNotifier.appearance == MascotAppearance.processing)) {
           // If _handleError wasn't called or didn't reset state fully
           context.read<MascotStateNotifier>().setIdle();
           // Keep error message if voice state is error, otherwise idle
           if (!context.read<VoiceStateNotifier>().hasError) {
              context.read<VoiceStateNotifier>().setIdle();
           }
       }
    }
  }

  // --- Build Method remains the same ---
  @override
  Widget build(BuildContext context) {
    final connectionState = context.watch<LgConnectionStateNotifier>();
    final mascotAppearance = context.watch<MascotStateNotifier>().appearance;
    final voiceState = context.watch<VoiceStateNotifier>();
    
    _log.v("MainScreen rebuilding. Mascot: $mascotAppearance, Voice: ${voiceState.currentState}, LG Connected: ${connectionState.isConnected}, LG Error: ${connectionState.connectionError}");

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Connection Status Indicator (Top-Left)
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Tooltip( // Added tooltip for clarity
                  message: connectionState.isConnected
                      ? 'Connected to Liquid Galaxy'
                      : connectionState.connectionError != null
                          ? 'LG Error: ${connectionState.connectionError}'
                          : 'Disconnected from Liquid Galaxy',
                  child: Container(
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                      color: connectionState.isConnected
                          ? Colors.greenAccent // Green when connected
                          : connectionState.connectionError != null
                              ? Colors.orangeAccent // Orange on error (e.g., config needed, connection fail)
                              : Colors.redAccent, // Red when disconnected cleanly or not configured initially
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
            ),

            // Settings Icon (Top-Right)
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
                    ).then((_) {
                       _log.d("Returned from Settings screen.");
                       // Example: Maybe just update status text based on current known state
                       final currentConnectionState = context.read<LgConnectionStateNotifier>();
                       final currentLlmState = context.read<ActiveLlmProvider>();
                        if (currentConnectionState.isConnected) {
                           _updateStatusText("Ready. Tap microphone to start.");
                         } else if (!context.read<LGService>().isConfigured) {
                            _updateStatusText("LG not configured. Go to Settings.");
                         } else if (currentConnectionState.connectionError != null) {
                            _updateStatusText("LG Error: ${currentConnectionState.connectionError}");
                         } else if (!currentLlmState.isReady) {
                           _updateStatusText(currentLlmState.error ?? "LLM not configured.");
                         }
                         else {
                           _updateStatusText("Disconnected. Check Settings.");
                         }
                    });
                  },
                ),
              ),
            ),

            // Mascot and Emission Effect Layer (Center)
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Emission Effect (Behind Mascot)
                  AnimatedOpacity(
                    opacity: (mascotAppearance == MascotAppearance.listening || mascotAppearance == MascotAppearance.processing)
                         ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      child: Container(
                        width: 350, height: 350,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              mascotAppearance == MascotAppearance.listening
                               ? _emissionColor
                               : _processingColor,
                              Colors.transparent,
                            ],
                            stops: const [0.1, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 3D Mascot (In Front of Effect)
                  SizedBox(
                    width: 300, height: 400,
                    child: Flutter3DViewer(
                      controller: mascotController,
                      src: 'assets/models/mascot.glb',
                      enableTouch: true,
                      activeGestureInterceptor: true,
                    ),
                  ),
                ],
              ),
            ),

            // Status Text Area (Bottom)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 180), // Increased bottom padding
                child: Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    // Use connection error or voice error for red text
                    color: voiceState.hasError || (connectionState.connectionError != null && !connectionState.isConnected)
                           ? Colors.redAccent
                           : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),

      // Floating Action Button
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
         padding: const EdgeInsets.only(bottom: 20.0), // Adjusted FAB padding
         child: FloatingActionButton.large(
           onPressed: _activateVoiceInput,
           tooltip: 'Activate Voice Command',
           backgroundColor: voiceState.isListening
                            ? Colors.redAccent.withOpacity(0.8)
                            : Theme.of(context).colorScheme.secondary,
           foregroundColor: Colors.white,
           child: voiceState.isListening
               ? const Icon(Icons.stop)
               : const Icon(Icons.mic),
         ),
      ),
    );
  }
}