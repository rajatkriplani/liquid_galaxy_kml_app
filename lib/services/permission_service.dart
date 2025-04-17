import 'package:permission_handler/permission_handler.dart';
import 'package:logger/logger.dart';
import '../llm.dart'; // <-- ADD THIS IMPORT for the global logger

class PermissionService {
  // Use the global logger instance from llm.dart
  final Logger _log = logger; // Now 'logger' should be defined

  Future<bool> requestMicrophonePermission() async {
    var status = await Permission.microphone.status;
    _log.d("Microphone permission status: $status");

    if (status.isGranted) {
      return true;
    }

    // isDenied means we can still request. isPermanentlyDenied means we cannot.
    // Asking when denied is the standard flow.
    if (status.isDenied || status.isPermanentlyDenied) {
       if (status.isPermanentlyDenied) {
           _log.w("Microphone permission is permanently denied. Cannot request.");
           // Consider prompting user to go to settings here before returning false
           // await openAppSettings(); // Optionally open settings directly
           return false;
       } else {
           // Request permission if simply denied
           status = await Permission.microphone.request();
           _log.d("Microphone permission requested. New status: $status");
           if (status.isPermanentlyDenied) {
               _log.w("Microphone permission became permanently denied after request.");
               // Consider prompting user to go to settings
           }
           return status.isGranted;
       }
    }

    // Handle other potential statuses if needed (e.g., restricted on iOS)
    _log.w("Unhandled microphone permission status: $status");
    return false;
  }

  // Helper to open app settings (optional)
  Future<void> openAppSettingsPage() async {
     _log.i("Attempting to open app settings.");
     await openAppSettings();
  }
}