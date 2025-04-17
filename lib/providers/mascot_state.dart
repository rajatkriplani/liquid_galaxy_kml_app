import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'; // For Color

// Enum to represent the desired visual state of the mascot
enum MascotAppearance {
  idle, // Normal appearance
  listening, // Glowing/Emissive appearance
  processing // Thinking/Slightly different appearance (optional)
}

class MascotStateNotifier extends ChangeNotifier {
  MascotAppearance _appearance = MascotAppearance.idle;
  // You might add properties like emissionColor, intensity later if needed
  // Color _emissionColor = Colors.transparent;
  // double _emissionIntensity = 0.0;

  MascotAppearance get appearance => _appearance;

  void setIdle() {
    _updateAppearance(MascotAppearance.idle);
  }

  void setListening() {
    _updateAppearance(MascotAppearance.listening);
  }

  void setProcessing() {
     // Could reuse idle or have a distinct look
    _updateAppearance(MascotAppearance.processing);
  }

  void _updateAppearance(MascotAppearance newAppearance) {
    if (_appearance != newAppearance) {
      _appearance = newAppearance;
      notifyListeners();
    }
  }
}