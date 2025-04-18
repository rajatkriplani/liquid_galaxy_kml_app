import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' show min, max;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';

import '../llm.dart'; // Import for logger instance

class Coordinate {
  final double latitude;
  final double longitude;
  Coordinate(this.latitude, this.longitude);
}

// Custom Exception for LG Service errors
class LgException implements Exception {
  final String message;
  final dynamic underlyingError;
  LgException(this.message, {this.underlyingError});

  @override
  String toString() => 'LgException: $message ${underlyingError ?? ''}';
}


class LGService {
  final Logger _log = logger; // Use global logger

  // --- Updated Configuration Placeholders ---
  // Using the values you provided
  String _hostIp = '192.168.29.63';     // UPDATED
  int _sshPort = 6969;                 // UPDATED
  String _sshUser = 'lg';                 // Keep 'lg' or replace if different
  String _sshPassword = 'lg';             // Keep 'lg' or replace if different
  int _screenCount = 3;                  // Keep 3 or replace if different
  // --- End Configuration Placeholders ---

  SSHClient? _sshClient;
  bool _isConnected = false;
  final Duration _connectionTimeout = const Duration(seconds: 15); // Keep timeout

  bool get isConnected => _isConnected && _sshClient != null;

  final String _queryPath = '/tmp/query.txt';
  final String _kmlsFilePath = '/var/www/html/kmls.txt';
  final String _kmlUploadDir = '/var/www/html/';
  final String _logoAssetName = 'assets/logo.png';
  final String _remoteLogoPath = '/var/www/html/logo.png';
  final String _slaveKmlDir = '/var/www/html/kml/';

  // --- URL Base changed back to hostname 'lg1' ---
  String get _kmlBaseUrl => 'http://lg1:81/'; // CHANGED BACK

  // Delay Duration (can be tuned)
  final Duration _shortDelay = const Duration(milliseconds: 500);
  final Duration _mediumDelay = const Duration(seconds: 1);
  final Duration _flyToDelay = const Duration(seconds: 3);

  // --- Core SSH Methods ---

  Future<bool> connect() async {
    if (isConnected) {
      _log.i('Already connected to LG.');
      return true;
    }
    // Removed placeholder check as values are now set directly
    _log.i('Attempting to connect to LG at $_hostIp:$_sshPort as $_sshUser...');
    try {
      _sshClient = SSHClient(
        await SSHSocket.connect(_hostIp, _sshPort, timeout: _connectionTimeout),
        username: _sshUser,
        onPasswordRequest: () => _sshPassword,
      );

      await _sshClient!.run('echo "Connection test successful"');
      _isConnected = true;
      _log.i('Successfully connected to LG.');
      // Automatically set logo upon successful connection
      await setLogo();
      return true;
    } on TimeoutException catch (e) {
      _log.e('Connection timed out.', error: e);
      _isConnected = false;
      _sshClient = null;
      return false;
    } catch (e, s) {
      _log.e('Failed to connect to LG.', error: e, stackTrace: s);
      _isConnected = false;
      _sshClient = null;
      return false;
    }
  }

  Future<void> disconnect() async {
    // ... (no changes needed here) ...
    if (!isConnected) return;
    _log.i('Disconnecting from LG...');
    try {
      _sshClient?.close();
    } catch (e, s) {
      _log.w('Error during SSH disconnect.', error: e, stackTrace: s);
    } finally {
      _sshClient = null;
      _isConnected = false;
       _log.i('Disconnected.');
    }
  }

  Future<String> execute(String command) async {
    // ... (no changes needed here) ...
     if (!isConnected) throw LgException('Not connected to Liquid Galaxy.');
    _log.d('Executing LG command: $command');
    try {
      final result = await _sshClient!.run(command);
      final output = utf8.decode(result);
      _log.v('Command output: $output');
      return output;
    } catch (e, s) {
      _log.e('Failed to execute command: $command', error: e, stackTrace: s);
      throw LgException('Failed to execute command on LG', underlyingError: e);
    }
  }

  Future<void> uploadFile(String localPath, String remotePath) async {
    // ... (Keep the corrected chunked upload logic from the previous response) ...
    if (!isConnected) throw LgException('Not connected to Liquid Galaxy.');
    _log.i('Uploading file from $localPath to $remotePath...');
    SftpClient? sftp;
    RandomAccessFile? localFileHandle;
    SftpFile? remoteHandle;
    try {
      sftp = await _sshClient!.sftp();
      final localFile = File(localPath);
      localFileHandle = await localFile.open(mode: FileMode.read);
      final fileSize = await localFile.length();
      _log.d('Local file size: $fileSize bytes');
      remoteHandle = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
      );
      _log.d('Opened remote file for writing: $remotePath');
      const int chunkSize = 32 * 1024;
      int bytesUploaded = 0;
      int lastLoggedPercent = -1;
      while (true) {
        final Uint8List chunk = await localFileHandle.read(chunkSize);
        if (chunk.isEmpty) break;
        await remoteHandle.write(Stream.value(chunk));
        bytesUploaded += chunk.length;
        if (fileSize > 0) {
          final percent = (bytesUploaded * 100 ~/ fileSize);
          if (percent % 5 == 0 && percent != lastLoggedPercent) {
             _log.v('Upload progress: $percent% ($bytesUploaded / $fileSize bytes)');
             lastLoggedPercent = percent;
          }
        } else if (bytesUploaded > 0) {
            if (bytesUploaded % (10 * chunkSize) == 0) {
               _log.v('Upload progress: $bytesUploaded bytes');
            }
        }
      }
      _log.i('File upload completed successfully ($bytesUploaded bytes written).');
    } catch (e, s) {
      _log.e('Failed to upload file $localPath to $remotePath', error: e, stackTrace: s);
      throw LgException('Failed to upload file to LG', underlyingError: e);
    } finally {
      try { await remoteHandle?.close(); _log.d('Closed remote file handle.'); } catch (e) { _log.w('Error closing remote SFTP handle.', error: e); }
      try { await localFileHandle?.close(); _log.d('Closed local file handle.'); } catch (e) { _log.w('Error closing local file handle.', error: e); }
    }
  }


  List<Coordinate> _extractCoordinates(String kmlContent) {
    List<Coordinate> coordinates = [];
    _log.d("Extracting coordinates from KML...");
    try {
      // Look for <Point> coordinates
      final pointMatches = RegExp(r'<Point>\s*<coordinates>([^<]+)</coordinates>', dotAll: true)
          .allMatches(kmlContent);
      for (var match in pointMatches) {
        if (match.group(1) != null) {
          final parts = match.group(1)!.trim().split(',');
          if (parts.length >= 2) {
            try {
              final longitude = double.parse(parts[0].trim());
              final latitude = double.parse(parts[1].trim());
              coordinates.add(Coordinate(latitude, longitude));
            } catch (e) { _log.w('Error parsing point coordinate: $e'); }
          }
        }
      }

      // If no Point coordinates found, look for Polygon coordinates
      if (coordinates.isEmpty) {
        _log.d("No <Point> coordinates found, looking for Polygon coordinates...");
        final polygonMatches = RegExp(r'<coordinates>([^<]+)</coordinates>', dotAll: true)
            .allMatches(kmlContent);
        for (var match in polygonMatches) {
          if (match.group(1) != null) {
            final coordList = match.group(1)!.trim().split(RegExp(r'\s+')); // Split by whitespace
            for (var coord in coordList) {
              final parts = coord.split(',');
              if (parts.length >= 2) {
                try {
                  final longitude = double.parse(parts[0].trim());
                  final latitude = double.parse(parts[1].trim());
                  coordinates.add(Coordinate(latitude, longitude));
                } catch (e) { _log.w('Error parsing polygon coordinate: $e'); }
              }
            }
          }
        }
      }
    } catch (e, s) {
       _log.e("Error during coordinate extraction regex", error: e, stackTrace: s);
       // Don't throw, just return empty list or potentially partial list
    }
    _log.i('Extracted ${coordinates.length} coordinates');
    return coordinates;
  }

  Coordinate _calculateCenter(List<Coordinate> coordinates) {
    if (coordinates.isEmpty) {
      _log.w("Cannot calculate center: No coordinates provided.");
      return Coordinate(0, 0); // Default or throw error?
    }
    // Ensure min/max start correctly
    double minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude;
    double minLng = coordinates[0].longitude, maxLng = coordinates[0].longitude;

    for (var coord in coordinates) {
      minLat = min(minLat, coord.latitude);
      maxLat = max(maxLat, coord.latitude);
      minLng = min(minLng, coord.longitude);
      maxLng = max(maxLng, coord.longitude);
    }
    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;
    _log.d("Calculated center: Lat=$centerLat, Lng=$centerLng");
    return Coordinate(centerLat, centerLng);
  }

  double _calculateRange(List<Coordinate> coordinates) {
     if (coordinates.length < 2) {
        _log.d("Cannot calculate range: Need at least 2 coordinates. Using default.");
        return 500000; // Default range if only 0 or 1 point
     }
     double minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude;
     double minLng = coordinates[0].longitude, maxLng = coordinates[0].longitude;
     for (var coord in coordinates) {
       minLat = min(minLat, coord.latitude);
       maxLat = max(maxLat, coord.latitude);
       minLng = min(minLng, coord.longitude);
       maxLng = max(maxLng, coord.longitude);
     }
     double latSpread = maxLat - minLat;
     double lngSpread = maxLng - minLng;
     // Estimate range based on diagonal distance (rough approximation)
     // Use larger spread, convert degrees to meters (approx 111km/deg at equator)
     // Multiply by a factor (e.g., 1.5-2) to ensure view encompasses area
     double range = max(latSpread, lngSpread) * 111320.0 * 1.8; // Factor 1.8
     // Ensure minimum range for points or small areas, max range for safety
     range = min(max(range, 5000.0), 20000000.0); // Min 5km, Max 20,000km
     _log.d("Calculated range: ${range.toStringAsFixed(0)} meters");
     return range;
  }


  int _getLeftmostScreen() {
    // ... (no changes needed here) ...
    int leftmostScreen = 3; // Defaulting to 2 as per typical LG setups
    _log.d('Calculated leftmost screen for logo: screen $leftmostScreen (Total screens: $_screenCount)');
    return leftmostScreen;
  }

  // --- LG Specific Methods ---

  Future<void> setLogo() async {
    _log.i('Attempting to set LG logo.');
    if (!isConnected) throw LgException('Cannot set logo: Not connected.');

    try {
      final tempDir = await getTemporaryDirectory();
      final localLogoPath = '${tempDir.path}/logo.png';
      final logoFile = File(localLogoPath);
      _log.d('Loading logo asset: $_logoAssetName');
      final logoBytes = await rootBundle.load(_logoAssetName);
      await logoFile.writeAsBytes(logoBytes.buffer.asUint8List(), flush: true);
      _log.d('Logo asset saved locally to $localLogoPath');
      await uploadFile(localLogoPath, _remoteLogoPath);
      final leftmostScreen = _getLeftmostScreen();
      // Using _kmlBaseUrl which now points to lg1:81
      final logoKml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2" xmlns:atom="http://www.w3.org/2005/Atom">
<Document>
  <ScreenOverlay id="logo_overlay">
    <name>Logo</name>
    <Icon>
      <href>${_kmlBaseUrl}logo.png</href> <!-- Now uses lg1:81 -->
    </Icon>
    <overlayXY x="0" y="1" xunits="fraction" yunits="fraction"/>
    <screenXY x="0.01" y="0.99" xunits="fraction" yunits="fraction"/>
    <rotationXY x="0" y="0" xunits="fraction" yunits="fraction"/>
    <size x="0.1" y="0.1" xunits="fraction" yunits="fraction"/>
  </ScreenOverlay>
</Document>
</kml>''';
      final remoteSlaveKmlPath = '${_slaveKmlDir}slave_$leftmostScreen.kml';
      await execute('echo \'$logoKml\' > $remoteSlaveKmlPath');
      _log.i('Logo set successfully on screen $leftmostScreen.');
    } catch (e, s) {
       _log.e('Failed to set logo.', error: e, stackTrace: s);
       if (e is LgException) rethrow;
       throw LgException('Failed to set logo', underlyingError: e);
    }
  }

  Future<void> clearLogo() async {
    // ... (no changes needed here, already writes blank KML) ...
    _log.i('Attempting to clear LG logo.');
    if (!isConnected) throw LgException('Cannot clear logo: Not connected.');
    try {
      final leftmostScreen = _getLeftmostScreen();
      final blankKml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
</Document>
</kml>''';
      final remoteSlaveKmlPath = '${_slaveKmlDir}slave_$leftmostScreen.kml';
      await execute('echo \'$blankKml\' > $remoteSlaveKmlPath');
       _log.i('Logo cleared successfully from screen $leftmostScreen.');
    } catch (e, s) {
       _log.e('Failed to clear logo.', error: e, stackTrace: s);
       if (e is LgException) rethrow;
       throw LgException('Failed to clear logo', underlyingError: e);
    }
  }


  /// Sends KML content to be displayed on Liquid Galaxy using the sequence from the working app.
  Future<void> sendKmlToLg(String kmlContent, String kmlFileName) async {
    _log.i('Sending KML ($kmlFileName) with internal FlyTo calculation.');
    if (!isConnected) throw LgException('Cannot send KML: Not connected.');

    try {
      // 1. Extract coordinates and calculate center/range *first*
      final coordinates = _extractCoordinates(kmlContent);
      Coordinate center = Coordinate(0, 0); // Default
      double range = 500000; // Default
      bool hasCoordinates = coordinates.isNotEmpty;

      if (hasCoordinates) {
        center = _calculateCenter(coordinates);
        range = _calculateRange(coordinates);
      } else {
         _log.w("No coordinates found in KML for FlyTo calculation. KML will load without initial FlyTo.");
         // Optionally try to parse <Document><LookAt> as a fallback here?
         // final lookAt = _extractLookAtFromKml(kmlContent); // (Need helper from main_screen)
         // if (lookAt != null) { ... send explicit flyToLookAt ... }
      }

      // --- Start Command Sequence (Matching working app) ---
      _log.d('Starting KML loading sequence...');

      // 2. Clear the existing KML list file
      _log.d('Clearing remote KML list file: $_kmlsFilePath');
      await execute('> $_kmlsFilePath');

      // 3. Exit any currently running tour
      await execute('echo "exittour=true" > $_queryPath');
      await Future.delayed(_mediumDelay);

      // 4. Send the flyto command *IF* coordinates were found
      if (hasCoordinates) {
         final flyToCmd = 'echo "flytoview=<LookAt><longitude>${center.longitude}</longitude><latitude>${center.latitude}</latitude><range>$range</range><tilt>60</tilt><heading>0</heading><altitudeMode>relativeToGround</altitudeMode></LookAt>" > $_queryPath';
         _log.i('Sending calculated FlyTo command.');
         await execute(flyToCmd);
         await Future.delayed(_flyToDelay); // Wait longer after flyto
      }
      // --- End FlyTo Command ---

      // 5. Save KML content locally (needed for upload)
      final tempDir = await getTemporaryDirectory();
      final localKmlPath = '${tempDir.path}/$kmlFileName';
      final kmlFile = File(localKmlPath);
      await kmlFile.writeAsString(kmlContent, encoding: utf8, flush: true);
      _log.d('KML content saved locally to $localKmlPath');

      // 6. Upload the KML file
      final remoteKmlPath = '$_kmlUploadDir$kmlFileName';
      await uploadFile(localKmlPath, remoteKmlPath);

      // 7. Add the URL of the new KML to the list file
      final kmlUrl = '$_kmlBaseUrl$kmlFileName'; // Uses lg1:81
      _log.d('Adding KML URL to list file: $kmlUrl');
      await execute('echo "$kmlUrl" > $_kmlsFilePath');
      await Future.delayed(_shortDelay);

      // 8. Refresh Google Earth to load the new KML
      _log.d('Sending Refresh command...');
      await execute('echo "playtour=Refresh" > $_queryPath');
      await Future.delayed(_mediumDelay);

      // 9. Exit tour again
      _log.d('Sending final Exit Tour command...');
      await execute('echo "exittour=true" > $_queryPath');
      // --- End Command Sequence ---

      _log.i('KML send sequence executed successfully: $kmlFileName');

    } catch (e, s) {
       _log.e('Failed during sendKML sequence for $kmlFileName.', error: e, stackTrace: s);
       if (e is LgException) rethrow;
       throw LgException('Failed to send KML to LG', underlyingError: e);
    }
  }


  Future<void> clearKmlOnLg() async {
     _log.i('Attempting to clear KML on LG.');
     if (!isConnected) throw LgException('Cannot clear KML: Not connected.');
     try {
        // Exit tour first, then clear, then refresh
        await execute('echo "exittour=true" > $_queryPath');
        await Future.delayed(_shortDelay); // ADDED DELAY
        await execute('> $_kmlsFilePath');
        await execute('echo "playtour=Refresh" > $_queryPath');
        await Future.delayed(_shortDelay);
        _log.i('KML cleared successfully.');
     } catch (e, s) {
        _log.e('Failed to clear KML.', error: e, stackTrace: s);
        if (e is LgException) rethrow;
        throw LgException('Failed to clear KML on LG', underlyingError: e);
     }
  }

  Future<void> playTour() async {
     _log.i('Attempting to play tour (using PlayTour command).'); // Updated log msg
     if (!isConnected) throw LgException('Cannot play tour: Not connected.');
     try {
        // Use "PlayTour=main" or a specific tour name if known,
        // but "Refresh" is often used to start the default tour in kmls.txt
        await execute('echo "playtour=Refresh" > $_queryPath'); // Keep Refresh based on previous examples
        _log.i('Play tour command sent.');
     } catch (e, s) {
        _log.e('Failed to send play tour command.', error: e, stackTrace: s);
        if (e is LgException) rethrow;
        throw LgException('Failed to play tour', underlyingError: e);
     }
  }

  Future<void> exitTour() async {
    // ... (no changes needed here, already correct) ...
    _log.i('Attempting to exit tour.');
    if (!isConnected) throw LgException('Cannot exit tour: Not connected.');
    try {
       await execute('echo "exittour=true" > $_queryPath');
        _log.i('Exit tour command sent.');
    } catch (e, s) {
        _log.e('Failed to send exit tour command.', error: e, stackTrace: s);
        if (e is LgException) rethrow;
        throw LgException('Failed to exit tour', underlyingError: e);
    }
  }

  /// Flies Google Earth using the specific flytoview=<LookAt> command.
  /// This method now expects coordinates etc. directly.
  Future<void> flyToCoordinates({
      required double latitude,
      required double longitude,
      double range = 50000, // Default range, adjust as needed
      double tilt = 60,
      double heading = 0,
      String altitudeMode = 'relativeToGround', // Or clampToGround etc.
  }) async {
     _log.i('Attempting to fly to Coordinates: $latitude, $longitude');
     if (!isConnected) throw LgException('Cannot fly to Coordinates: Not connected.');

     // Construct the specific LookAt KML string
     final lookAtKml = '<LookAt>'
                       '<longitude>$longitude</longitude>'
                       '<latitude>$latitude</latitude>'
                       '<range>$range</range>'
                       '<tilt>$tilt</tilt>'
                       '<heading>$heading</heading>'
                       '<altitudeMode>$altitudeMode</altitudeMode>'
                       '</LookAt>';

     try {
       // Exit tour first
       await execute('echo "exittour=true" > $_queryPath');
       await Future.delayed(_shortDelay);
       // Send the command
       // Write the command to query.txt
       await execute('echo "flytoview=$lookAtKml" > $_queryPath');
       _log.i('Fly to Coordinates command sent.');
     } catch (e, s) {
        _log.e('Failed to send fly to Coordinates command.', error: e, stackTrace: s);
        if (e is LgException) rethrow;
        throw LgException('Failed to fly to Coordinates', underlyingError: e);
     }
  }

  // Keep the LookAt version for cases where the LLM *does* provide it
  Future<void> flyToLookAt(String lookAtKml) async {
    // ... (No changes needed to the existing flyToLookAt method) ...
     _log.i('Attempting to fly to LookAt KML string.');
    if (!isConnected) throw LgException('Cannot fly to LookAt: Not connected.');
    if (!lookAtKml.trim().startsWith('<LookAt>') || !lookAtKml.trim().endsWith('</LookAt>')) {
       _log.e('Invalid LookAt KML format provided: $lookAtKml');
       throw LgException('Invalid LookAt KML format.');
    }
    try {
       // Exit tour before flying is often good practice
       await execute('echo "exittour=true" > $_queryPath');
       await Future.delayed(_shortDelay);
       // Send the command
       await execute('echo "flytoview=$lookAtKml" > $_queryPath');
       _log.i('Fly to LookAt command sent.');
    } catch (e, s) {
        _log.e('Failed to send fly to LookAt command.', error: e, stackTrace: s);
        if (e is LgException) rethrow;
        throw LgException('Failed to fly to LookAt', underlyingError: e);
    }
  }

  // --- Reboot placeholder remains omitted ---
  // Future<void> rebootLG() async { ... }

  // --- Configuration Update Method (Called from Phase 5) ---
  void updateConnectionDetails({
    required String ip,
    required int port,
    required String username,
    required String password,
    required int screenCount,
  }) {
    // ... (no changes needed here) ...
     _log.i("Updating LG connection details.");
     bool changed = _hostIp != ip || _sshPort != port || _sshUser != username || _sshPassword != password || _screenCount != screenCount;
     _hostIp = ip;
     _sshPort = port;
     _sshUser = username;
     _sshPassword = password;
     _screenCount = screenCount;
     if (changed && isConnected) {
        _log.w("Connection details updated while connected. Disconnecting.");
        disconnect();
     } else if (changed) {
        _log.i("Connection details updated. Will use new details on next connect.");
     }
  }
}