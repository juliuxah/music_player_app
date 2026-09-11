import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

class DebugLogger {
  static File? _logFile;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      final directory = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      _logFile = File('${directory.path}/bin_music_debug.log');
      
      if (await _logFile!.exists()) {
        await _logFile!.delete();
      }
      await _logFile!.create();
      
      _initialized = true;
      log('🚀 ═══════════════════════════════════════');
      log('Sesión de Debug Iniciada');
      log('Sistema: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      log('═══════════════════════════════════════');
    } catch (e) {
      debugPrint('Error inicializando DebugLogger: $e');
    }
  }

  static void log(String message) {
    _write('INFO', 'General', message);
  }

  static void logInfo(String tag, String message) {
    _write('INFO', tag, message);
  }

  static void logSuccess(String tag, String message) {
    _write('SUCCESS', tag, '✅ $message');
  }

  static void logWarning(String tag, String message) {
    _write('WARNING', tag, '⚠️ $message');
  }

  static void logError(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    String fullMessage = '❌ $message';
    if (error != null) fullMessage += '\nError: $error';
    if (stackTrace != null) fullMessage += '\nStackTrace: $stackTrace';
    _write('ERROR', tag, fullMessage);
  }

  static void logData(String tag, String label, dynamic data) {
    _write('DATA', tag, '$label: $data');
  }

  static void _write(String level, String tag, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final logMessage = '[$timestamp] [$level] [$tag] $message\n';
    
    debugPrint(logMessage);
    
    if (_initialized && _logFile != null) {
      try {
        _logFile!.writeAsStringSync(logMessage, mode: FileMode.append, flush: true);
      } catch (e) {
        debugPrint('Error escribiendo en log: $e');
      }
    }
  }

  static Future<String> getLogPath() async {
    if (_logFile == null) return 'No inicializado';
    return _logFile!.path;
  }
}
