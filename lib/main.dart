import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/main_screen.dart';
import 'providers/voice_state.dart';
import 'providers/mascot_state.dart';
import 'providers/lg_connection_state.dart';
import 'llm.dart'; // Import your LLM file

// Make main async to use await
Future<void> main() async {
  // Ensure Flutter bindings are initialized FIRST
  WidgetsFlutterBinding.ensureInitialized();

  // --- TEMPORARY API KEY SETUP FOR TESTING ---
  // IMPORTANT: Replace with your actual key and choose the correct provider.
  // Remove this section once the Settings screen (Phase 5) is implemented.
  try {
    final apiKeyManager = ApiKeyManager();
    const providerToSet = LlmProvider.groq; // Or .nvidia, .gemini
    const apiKeyToSet = ''; // <--- PASTE YOUR KEY HERE

    // Optional: Check if a key already exists before overwriting
    final existingKey = await apiKeyManager.getApiKey(providerToSet);
    if (existingKey == null || existingKey.isEmpty) {
       logger.i("Setting temporary API key for $providerToSet for testing...");
       await apiKeyManager.saveApiKey(providerToSet, apiKeyToSet);
       // Optional: Set this provider as the default active one for the test
       await apiKeyManager.setActiveProvider(providerToSet);
       logger.i("Temporary API key set successfully.");
    } else {
        logger.i("API Key for $providerToSet already exists. Skipping temporary set.");
        // Ensure the active provider is correct if needed
        await apiKeyManager.setActiveProvider(providerToSet);
    }
  } catch (e, s) {
     logger.e("Failed to set temporary API key", error: e, stackTrace: s);
     // Handle error - maybe show a dialog or prevent app start?
     // For now, just log it. The ActiveLlmProvider will likely fail later.
  }
  // --- END TEMPORARY API KEY SETUP ---


  // Initialize other global services if needed here (logger is already global)

  runApp(const MyApp());
}

// MyApp class remains the same
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Initialize provider - it will now load the key set above (if successful)
        ChangeNotifierProvider(create: (_) => ActiveLlmProvider()),
        ChangeNotifierProvider(create: (_) => VoiceStateNotifier()),
        ChangeNotifierProvider(create: (_) => MascotStateNotifier()),
        ChangeNotifierProvider(create: (_) => LgConnectionStateNotifier()),
      ],
      child: MaterialApp(
        title: 'LG KML Voice Assistant',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
          snackBarTheme: const SnackBarThemeData(
             behavior: SnackBarBehavior.floating,
          )
        ),
        debugShowCheckedModeBanner: false,
        home: const MainScreen(),
      ),
    );
  }
}
