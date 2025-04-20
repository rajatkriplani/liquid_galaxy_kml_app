import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/main_screen.dart';
import 'providers/voice_state.dart';
import 'providers/mascot_state.dart';
import 'providers/lg_connection_state.dart';
import 'services/lg_service.dart'; // Import LG Service
import 'services/lg_config_manager.dart'; // Import LG Config Manager
import 'llm.dart'; // Import your LLM file (includes ApiKeyManager, ActiveLlmProvider, logger)

// Make main async to use await
Future<void> main() async {
  // Ensure Flutter bindings are initialized FIRST
  WidgetsFlutterBinding.ensureInitialized();
  logger.i("App starting..."); // Use the logger from llm.dart

  final lgConfigManager = LgConfigManager();
  // ApiKeyManager is used internally by ActiveLlmProvider, no need for separate instance here

  // Load initial LG configuration details
  Map<String, dynamic>? initialLgConfig;
  try {
    initialLgConfig = await lgConfigManager.loadConnectionDetails();
    if (initialLgConfig != null) {
      logger.i("Loaded initial LG configuration from storage.");
    } else {
      logger.w("No initial LG configuration found in storage. Needs setup in Settings.");
    }
  } catch (e, s) {
    logger.e("Error loading initial LG configuration", error: e, stackTrace: s);
    // Continue execution, the app should still load but LG features won't work until configured
  }

  // Create LGService instance - it starts unconfigured
  final lgService = LGService();

  // If config was loaded, update the LGService instance immediately
  if (initialLgConfig != null) {
    try {
      lgService.updateConnectionDetails(
        ip: initialLgConfig['ip'],
        port: initialLgConfig['port'],
        username: initialLgConfig['user'], // Use 'username:' parameter with map key 'user'
        password: initialLgConfig['password'],
        screenCount: initialLgConfig['screens'],
      );
      logger.i("LGService instance updated with loaded configuration.");
    } catch (e, s) {
      logger.e("Error updating LGService with loaded configuration", error: e, stackTrace: s);
      // LG Service remains unconfigured
    }
  }
  

  runApp(MyApp(
    lgService: lgService,
  ));
}

class MyApp extends StatelessWidget {
  final LGService lgService; // Receive the LGService instance

  const MyApp({
    super.key,
    required this.lgService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        
        ChangeNotifierProvider(create: (_) => ActiveLlmProvider()),

        Provider<LGService>(create: (_) => lgService),

        // --- UI State Notifiers ---
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
          ),
        ),
        debugShowCheckedModeBanner: false,
        home: const MainScreen(), // MainScreen will access providers via context
      ),
    );
  }
}