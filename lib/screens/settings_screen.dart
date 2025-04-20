import 'dart:convert'; // For jsonDecode
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For TextInputFormatters
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart'; // Corrected import
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart'; // <<< ADDED IMPORT

import '../llm.dart'; // Access LlmProvider, ApiKeyManager, logger
import '../services/lg_config_manager.dart';
import '../services/lg_service.dart';
import '../providers/lg_connection_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Logger _log = logger;
  final _lgConfigManager = LgConfigManager();
  final _apiKeyManager = ApiKeyManager();

  // Form Keys
  final _lgConnectionFormKey = GlobalKey<FormState>();

  // Text Editing Controllers
  final _ipController = TextEditingController();
  final _portController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  final _screensController = TextEditingController();
  final _apiKeyController = TextEditingController();

  // State Variables
  bool _isLoading = true;
  bool _isSavingLg = false;
  bool _isSavingApi = false;
  LlmProvider? _selectedProvider;
  bool _isPasswordVisible = false;
  bool _isApiKeyVisible = false;

  // QR Scanner Controller
  final MobileScannerController _scannerController = MobileScannerController(
     detectionSpeed: DetectionSpeed.normal,
     facing: CameraFacing.back,
     // >>> REMOVED TORCH STATE from constructor if not needed/available <<<
     // torchEnabled: false, // Start with torch off
  );
  bool _isScanningQr = false;
  // >>> ADDED state variable for torch icon if needed <<<
  // TorchState _currentTorchState = TorchState.off; // To manually track state

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // >>> Optional: Listener for torch state if available <<<
    // _scannerController.torchState.addListener(_torchStateListener);
  }

  @override
  void dispose() {
    // >>> Optional: Remove listener <<<
    // _scannerController.torchState.removeListener(_torchStateListener);
    _ipController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _screensController.dispose();
    _apiKeyController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  // >>> Optional: Listener implementation <<<
  // void _torchStateListener() {
  //   if (mounted) {
  //     setState(() {
  //       _currentTorchState = _scannerController.torchState.value;
  //     });
  //   }
  // }


  // --- Loading ---
  Future<void> _loadSettings() async {
    // ... (loading logic remains the same) ...
    setState(() { _isLoading = true; });
    _log.d("Settings: Loading settings...");

    // Load LG Settings
    try {
      final lgDetails = await _lgConfigManager.loadConnectionDetails();
      if (lgDetails != null) {
        _ipController.text = lgDetails['ip'];
        _portController.text = lgDetails['port'].toString();
        _userController.text = lgDetails['user'];
        _passwordController.text = lgDetails['password'];
        _screensController.text = lgDetails['screens'].toString();
        _log.d("Settings: Loaded LG details.");
      } else {
          _log.d("Settings: No saved LG details found.");
          // Clear fields if no details are loaded
          _ipController.clear();
          _portController.clear();
          _userController.clear();
          _passwordController.clear();
          _screensController.clear();
      }
    } catch (e, s) {
      _log.e("Settings: Error loading LG details", error: e, stackTrace: s);
      _showErrorSnackBar("Error loading LG settings: ${e.toString()}");
    }

    // Load API Settings
    try {
      _selectedProvider = await _apiKeyManager.getActiveProvider();
      _log.d("Settings: Loaded active provider: $_selectedProvider");
      if (_selectedProvider != null) {
        final apiKey = await _apiKeyManager.getApiKey(_selectedProvider!);
        _apiKeyController.text = apiKey ?? '';
        _log.d("Settings: Loaded API key for $_selectedProvider: ${apiKey != null ? 'Exists' : 'Not Found'}");
      } else {
          _apiKeyController.clear(); // Clear key if no provider selected
      }
    } catch (e, s) {
      _log.e("Settings: Error loading API settings", error: e, stackTrace: s);
       _showErrorSnackBar("Error loading API settings: ${e.toString()}");
    }

    if (mounted) {
       setState(() { _isLoading = false; });
    }
     _log.d("Settings: Loading complete.");
  }

  // --- Saving LG Connection ---
  Future<void> _saveAndConnectLg() async {
    // ... (logic remains the same) ...
    if (_lgConnectionFormKey.currentState?.validate() ?? false) {
      setState(() { _isSavingLg = true; });
      _log.i("Settings: Saving LG connection details...");

      try {
        final ip = _ipController.text.trim();
        final port = int.parse(_portController.text.trim());
        final user = _userController.text.trim();
        final password = _passwordController.text; // Don't trim password
        final screens = int.parse(_screensController.text.trim());

        // 1. Save details using ConfigManager
        await _lgConfigManager.saveConnectionDetails(
          ip: ip,
          port: port,
          user: user,
          password: password,
          screenCount: screens,
        );

        // 2. Update the LGService instance (use context.read outside build)
        final lgService = context.read<LGService>();
        lgService.updateConnectionDetails(
          ip: ip,
          port: port,
          username: user, // Use 'username' parameter here
          password: password,
          screenCount: screens,
        );

        // 3. Attempt to connect
        _log.i("Settings: Attempting connection with new details...");
        final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();
        // Set state to disconnected first to show attempt
        lgConnectionNotifier.setDisconnected("Connecting...");
        final bool connected = await lgService.connect(); // connect() handles exceptions

        if (!mounted) return; // Check mounted after await

        if (connected) {
          lgConnectionNotifier.setConnected();
          _showSuccessSnackBar("LG settings saved and connected successfully!");
        } else {
           lgConnectionNotifier.setDisconnected("Connection Failed");
           _showErrorSnackBar("LG settings saved, but connection failed. Please check details.");
        }
      } on LgException catch (e) {
         _log.e("Settings: LG Error during save/connect", error: e.underlyingError ?? e);
         if (!mounted) return;
         context.read<LgConnectionStateNotifier>().setDisconnected(e.message);
         _showErrorSnackBar("Error: ${e.message}");
      } catch (e, s) {
        _log.e("Settings: Failed to save or connect LG", error: e, stackTrace: s);
        if (!mounted) return;
        context.read<LgConnectionStateNotifier>().setDisconnected("Save/Connect Error");
        _showErrorSnackBar("Failed to save/connect: ${e.toString()}");
      } finally {
         if (mounted) {
           setState(() { _isSavingLg = false; });
         }
      }
    } else {
        _log.w("Settings: LG connection form validation failed.");
    }
  }

   // --- Saving API Key ---
  Future<void> _saveApiKey() async {
    // ... (logic remains the same) ...
     if (_selectedProvider == null) {
      _showErrorSnackBar("Please select an LLM provider first.");
      return;
    }
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
       _showErrorSnackBar("API Key cannot be empty for the selected provider.");
       return;
    }

    setState(() { _isSavingApi = true; });
    _log.i("Settings: Saving API key for $_selectedProvider...");

    try {
      await _apiKeyManager.saveApiKey(_selectedProvider!, apiKey);
      await _apiKeyManager.setActiveProvider(_selectedProvider!);
      await context.read<ActiveLlmProvider>().initialize();

       if (!mounted) return; // Check mounted after await
       _showSuccessSnackBar("API Key for $_selectedProvider saved successfully!");

    } on ApiKeyException catch (e) {
        _log.e("Settings: API Key Error during save", error: e.underlyingError ?? e);
        if (!mounted) return;
        _showErrorSnackBar("API Key Error: ${e.message}");
        context.read<ActiveLlmProvider>().initialize();
    } catch (e, s) {
      _log.e("Settings: Failed to save API key", error: e, stackTrace: s);
       if (!mounted) return;
      _showErrorSnackBar("Failed to save API key: ${e.toString()}");
       context.read<ActiveLlmProvider>().initialize();
    } finally {
       if (mounted) {
         setState(() { _isSavingApi = false; });
       }
    }
  }

  // --- QR Code Scanning ---
  void _startScanning() {
    // Use the Permission class from the imported package
    Permission.camera.request().then((status) {
         if (status.isGranted) {
             if (mounted) {
                 setState(() { _isScanningQr = true; });
             }
         } else {
             _log.w("Camera permission denied.");
             _showErrorSnackBar("Camera permission is required to scan QR codes.");
         }
     });
  }

  void _onDetectQrCode(BarcodeCapture capture) {
     // ... (logic remains the same) ...
     final List<Barcode> barcodes = capture.barcodes;
     if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
        final String rawValue = barcodes.first.rawValue!;
        _log.i("QR Code Detected: $rawValue");

        // Debounce or ensure single processing if needed
        if (!_isScanningQr) return; // Avoid processing if already stopped

        _scannerController.stop(); // Stop scanning after detection
        setState(() { _isScanningQr = false; });
        _processQrCodeData(rawValue);
     }
  }

  Future<void> _processQrCodeData(String data) async {
    // ... (logic remains the same) ...
     setState(() { _isSavingLg = true; }); // Use the LG saving indicator
     _log.i("Settings: Processing QR code data...");
     try {
        final Map<String, dynamic> qrData = jsonDecode(data);

        // Validate required fields
        final ip = qrData['lg_ip'] as String?;
        final portRaw = qrData['lg_port']; // Can be int or String
        final user = qrData['lg_user'] as String?;
        final password = qrData['lg_pass'] as String?;
        final screensRaw = qrData['lg_screens']; // Can be int or String

        if (ip == null || ip.isEmpty ||
            portRaw == null ||
            user == null || user.isEmpty ||
            password == null || password.isEmpty ||
            screensRaw == null) {
           throw const FormatException("QR code data is missing required fields (lg_ip, lg_port, lg_user, lg_pass, lg_screens).");
        }

        // Parse port and screens safely
        final port = int.tryParse(portRaw.toString());
        final screens = int.tryParse(screensRaw.toString());

        if (port == null || screens == null || screens <= 0) {
           throw const FormatException("Invalid format for port or number of screens in QR code.");
        }

        _log.d("QR Data Parsed: IP=$ip, Port=$port, User=$user, Pass=****, Screens=$screens");

        // --- Save and Connect Logic ---
        await _lgConfigManager.saveConnectionDetails(
          ip: ip, port: port, user: user, password: password, screenCount: screens,
        );
        final lgService = context.read<LGService>();
        lgService.updateConnectionDetails(
          ip: ip, port: port, username: user, password: password, screenCount: screens,
        );
        _log.i("Settings: Attempting connection with QR details...");
        final lgConnectionNotifier = context.read<LgConnectionStateNotifier>();
        lgConnectionNotifier.setDisconnected("Connecting...");
        final bool connected = await lgService.connect();

        if (!mounted) return;

        if (connected) {
          lgConnectionNotifier.setConnected();
          _showSuccessSnackBar("Connected successfully using QR Code!");
        } else {
           lgConnectionNotifier.setDisconnected("QR Connect Failed");
           _showErrorSnackBar("Connection failed using QR code details. Please check the rig.");
        }
        // --- End Save and Connect Logic ---

     } on FormatException catch (e) {
         _log.e("Settings: Invalid QR code format", error: e);
         if (!mounted) return;
         _showErrorSnackBar("Invalid QR code format: ${e.message}");
     } catch (e, s) {
         _log.e("Settings: Failed to process QR code", error: e, stackTrace: s);
          if (!mounted) return;
         _showErrorSnackBar("Failed to process QR code: ${e.toString()}");
         if (context.read<LGService>().isConnected == false) {
            context.read<LgConnectionStateNotifier>().setDisconnected("QR Process Error");
         }
     } finally {
         if (mounted) {
           setState(() { _isSavingLg = false; });
         }
     }
  }

  // --- UI Helpers ---
  void _showErrorSnackBar(String message) {
    // ... (logic remains the same) ...
     if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar(); // Remove previous snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 3),
      ),
    );
  }

   void _showSuccessSnackBar(String message) {
    // ... (logic remains the same) ...
    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
         duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _buildTextFormField({
    // ... (helper remains the same) ...
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    bool obscureText = false,
    required String? Function(String?) validator,
    Widget? suffixIcon,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
          suffixIcon: suffixIcon,
        ),
        keyboardType: keyboardType,
        obscureText: obscureText,
        validator: validator,
        inputFormatters: inputFormatters,
        autovalidateMode: AutovalidateMode.onUserInteraction,
      ),
    );
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    // ... (logic remains the same) ...
     final bool buttonsDisabled = _isLoading || _isSavingLg || _isSavingApi || _isScanningQr;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
           if (_isLoading || _isSavingLg || _isSavingApi) // Show for any background activity
              const Padding(
                padding: EdgeInsets.only(right: 16.0),
                child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isScanningQr
              ? _buildQrScannerView() // Show scanner if active
              : _buildSettingsList(buttonsDisabled), // Show settings list
    );
  }

  Widget _buildSettingsList(bool buttonsDisabled) {
     return ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          ExpansionTile(
            title: const Text('Liquid Galaxy Connection', style: TextStyle(fontWeight: FontWeight.bold)),
            initiallyExpanded: true, // Start expanded
            childrenPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR Code'),
                  onPressed: buttonsDisabled ? null : _startScanning,
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16.0),
                child: Row(children: [ Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 8.0), child: Text('OR')), Expanded(child: Divider()), ],),
              ),
              Form(
                key: _lgConnectionFormKey,
                child: Column(
                  children: [
                    _buildTextFormField( controller: _ipController, label: 'LG Master IP Address', icon: Icons.computer, validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter IP Address' : null, ),
                    Row( crossAxisAlignment: CrossAxisAlignment.start, children: [
                           Expanded( child: _buildTextFormField( controller: _portController, label: 'SSH Port', icon: Icons.lan_outlined, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], validator: (v) { if (v==null||v.trim().isEmpty) return 'Enter Port'; final p = int.tryParse(v.trim()); if (p==null||p<=0||p>65535) return 'Invalid Port'; return null; }, ), ),
                           const SizedBox(width: 16),
                           Expanded( child: _buildTextFormField( controller: _screensController, label: 'No. of Screens', icon: Icons.screenshot_monitor, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], validator: (v) { if (v==null||v.trim().isEmpty) return 'Enter Screens'; final s = int.tryParse(v.trim()); if (s==null||s<=0) return 'Invalid'; return null; }, ), ),
                       ], ),
                    _buildTextFormField( controller: _userController, label: 'SSH Username', icon: Icons.person_outline, validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter Username' : null, ),
                    _buildTextFormField( controller: _passwordController, label: 'SSH Password', icon: Icons.lock_outline, obscureText: !_isPasswordVisible, validator: (v) => (v == null || v.isEmpty) ? 'Please enter Password' : null, suffixIcon: IconButton( icon: Icon( _isPasswordVisible ? Icons.visibility_off : Icons.visibility, ), onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible), ), ),
                    const SizedBox(height: 16),
                    SizedBox( width: double.infinity, child: ElevatedButton.icon( icon: _isSavingLg ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_alt), label: Text(_isSavingLg ? 'Connecting...' : 'Save & Connect'), onPressed: buttonsDisabled ? null : _saveAndConnectLg, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)), ), ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 32),
          ExpansionTile(
             title: const Text('AI Service (LLM) Settings', style: TextStyle(fontWeight: FontWeight.bold)),
             childrenPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
             children: [
               DropdownButtonFormField<LlmProvider>( value: _selectedProvider, decoration: const InputDecoration( labelText: 'Select LLM Provider', border: OutlineInputBorder(), prefixIcon: Icon(Icons.cloud_queue), ), items: LlmProvider.values.map((LlmProvider p) { String n = p.toString().split('.').last; n = n[0].toUpperCase() + n.substring(1); return DropdownMenuItem<LlmProvider>( value: p, child: Text(n), ); }).toList(), onChanged: buttonsDisabled ? null : (LlmProvider? nv) { if (nv != null) { setState(() => _selectedProvider = nv); _apiKeyManager.getApiKey(nv).then((key) { if (mounted) _apiKeyController.text = key ?? ''; }); } }, validator: (v) => v == null ? 'Please select a provider' : null, autovalidateMode: AutovalidateMode.onUserInteraction, ),
               const SizedBox(height: 16),
               if (_selectedProvider != null)
                 _buildTextFormField( controller: _apiKeyController, label: 'API Key for ${_selectedProvider.toString().split('.').last}', icon: Icons.key_outlined, obscureText: !_isApiKeyVisible, validator: (v) => (_selectedProvider != null && (v == null || v.trim().isEmpty)) ? 'Please enter API Key' : null, suffixIcon: IconButton( icon: Icon( _isApiKeyVisible ? Icons.visibility_off : Icons.visibility, ), onPressed: () => setState(() => _isApiKeyVisible = !_isApiKeyVisible), ), ),
                const SizedBox(height: 16),
                SizedBox( width: double.infinity, child: ElevatedButton.icon( icon: _isSavingApi ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save), label: Text(_isSavingApi ? 'Saving...' : 'Save API Key'), onPressed: buttonsDisabled || _selectedProvider == null ? null : _saveApiKey, style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)), ), ),
             ],
           ),
        ],
      );
  }

  // --- UPDATED: _buildQrScannerView ---
  Widget _buildQrScannerView() {
    return Stack(
      alignment: Alignment.center, // Center content
      children: [
        MobileScanner(
          controller: _scannerController,
          onDetect: _onDetectQrCode,
        ),
        Positioned( // Cancel Button
          top: 40, // Adjust position as needed
          left: 20,
          child: IconButton(
            icon: const Icon(Icons.cancel, color: Colors.white, size: 35),
            tooltip: 'Cancel Scan',
            onPressed: () {
              _scannerController.stop();
              setState(() { _isScanningQr = false; });
            },
          ),
        ),
        Positioned(
          top: 40, // Adjust position
          right: 20,
          child: IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white, size: 35), // Always show flash_on icon
            tooltip: 'Toggle Torch',
            onPressed: () => _scannerController.toggleTorch(),
          ),
        ),
      ],
    );
  }

} // End of _SettingsScreenState
class QrScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final Color overlayColor;
  final double borderRadius;
  final double cutOutSize; // Square cutout size

  const QrScannerOverlayShape({
    this.borderColor = Colors.red,
    this.borderWidth = 3.0,
    this.overlayColor = const Color.fromRGBO(0, 0, 0, 80),
    this.borderRadius = 0,
    required this.cutOutSize,
  });

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(0);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(getOuterPath(rect), Offset.zero);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    Path getLeftTopPath(Rect rect) {
      return Path()
        ..moveTo(rect.left, rect.bottom)
        ..lineTo(rect.left, rect.top)
        ..lineTo(rect.right, rect.top);
    }

    return getLeftTopPath(rect)
      ..lineTo(
        rect.right,
        rect.bottom,
      )
      ..lineTo(
        rect.left,
        rect.bottom,
      )
      ..lineTo(
        rect.left,
        rect.top,
      );
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
     final width = rect.width;
     final height = rect.height;
     final top = (height - cutOutSize) / 2;
     final left = (width - cutOutSize) / 2;
     final right = left + cutOutSize;
     final bottom = top + cutOutSize;

     // Draw overlay color
     canvas.drawRect(
       Rect.fromLTRB(rect.left, rect.top, rect.right, top),
       Paint()..color = overlayColor,
     );
     canvas.drawRect(
       Rect.fromLTRB(rect.left, bottom, rect.right, rect.bottom),
       Paint()..color = overlayColor,
     );
      canvas.drawRect(
       Rect.fromLTRB(rect.left, top, left, bottom),
       Paint()..color = overlayColor,
     );
      canvas.drawRect(
       Rect.fromLTRB(right, top, rect.right, bottom),
       Paint()..color = overlayColor,
     );

     // Draw border
     final borderPaint = Paint()
       ..color = borderColor
       ..style = PaintingStyle.stroke
       ..strokeWidth = borderWidth;
     canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), borderPaint);
  }

  @override
  ShapeBorder scale(double t) {
     return this; // Scaling not implemented
  }
}