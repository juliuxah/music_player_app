import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watcher/watcher.dart';

class MusicFolderService {
  static const String _folderPathKey = 'music_folder_path';
  static const List<String> _supportedFormats = ['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'wma', 'alac'];

  late SharedPreferences _prefs;
  DirectoryWatcher? _folderWatcher;
  StreamSubscription<WatchEvent>? _watcherSubscription;
  String? _currentFolderPath;
  String? _previousFolderPath;

  Function(List<String> addedFiles, List<String> removedFiles)? onFolderChanged;
  Function(String message)? onStatusChanged;
  Function()? onFolderCleared;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _currentFolderPath = _prefs.getString(_folderPathKey);

    if (_currentFolderPath != null && await Directory(_currentFolderPath!).exists()) {
      _startMonitoringFolder(_currentFolderPath!);
    }
  }

  Future<bool> requestStoragePermissions() async {
    if (Platform.isAndroid) {
      return await _requestAndroidPermissions();
    } else if (Platform.isIOS) {
      return await _requestIOSPermissions();
    }
    return false;
  }

  Future<bool> _requestAndroidPermissions() async {
    debugPrint('═══════ SOLICITANDO PERMISOS ═══════');

    // En Android 13+ (API 33), necesitamos permisos específicos de audio
    // Pero para escribir en carpetas personalizadas fuera del sandbox, MANAGE_EXTERNAL_STORAGE es lo más seguro
    
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;

    // Intentar pedir MANAGE_EXTERNAL_STORAGE directamente si no está concedido
    // Esto abrirá la pantalla de ajustes del sistema
    final newManageStatus = await Permission.manageExternalStorage.request();
    if (newManageStatus.isGranted) return true;

    // Fallback para versiones anteriores o si no se concedió el anterior
    final audioStatus = await Permission.audio.request();
    final storageStatus = await Permission.storage.request();

    return audioStatus.isGranted || storageStatus.isGranted;
  }

  Future<void> openSettings() async {
    await openAppSettings();
  }

  Future<bool> _requestIOSPermissions() async {
    // En iOS, el acceso a carpetas externas se gestiona a través del FilePicker 
    // y no requiere un permiso global de almacenamiento como en Android.
    // MediaLibrary es opcional para la música del sistema.
    try {
      final status = await Permission.mediaLibrary.status;
      if (status.isDenied) {
        await Permission.mediaLibrary.request();
      }
    } catch (e) {
      debugPrint('Aviso iOS: MediaLibrary no disponible o no requerida');
    }
    return true; // Permitimos continuar ya que el Picker maneja su propio permiso
  }


  /// Selecciona y configura una carpeta de música
  Future<String?> selectMusicFolder() async {
    try {
      onStatusChanged?.call('📁 Abriendo selector...');
      debugPrint('═══════ SELECCIONAR CARPETA ═══════');
      debugPrint('Plataforma: ${Platform.isAndroid ? 'Android' : 'iOS'}');

      String? selectedPath;

      if (Platform.isAndroid) {
        selectedPath = await FilePicker.getDirectoryPath();
      } else if (Platform.isIOS) {
        selectedPath = await _selectFolderOnIOS();
      } else {
        selectedPath = await FilePicker.getDirectoryPath();
      }

      if (selectedPath != null) {
        final dir = Directory(selectedPath);
        if (!await dir.exists()) {
          onStatusChanged?.call('❌ Carpeta no existe');
          return null;
        }

        // LIMPIAR SIEMPRE PARA ASEGURAR ESTADO FRESCO
        await stopMonitoring();
        onFolderCleared?.call();

        await _prefs.setString(_folderPathKey, selectedPath);
        _currentFolderPath = selectedPath;
        onStatusChanged?.call('✅ Carpeta: ${p.basename(selectedPath)}');
        debugPrint('✅ Carpeta configurada: $selectedPath');

        await _startMonitoringFolder(selectedPath);
        return selectedPath;
      }
    } catch (e) {
      onStatusChanged?.call('❌ Error: $e');
      debugPrint('❌ Error en selectMusicFolder: $e');
    }
    return null;
  }

  /// Seleccionar carpeta en iOS (con fallback a Documentos)
  Future<String?> _selectFolderOnIOS() async {
    try {
      debugPrint('📱 Intentando abrir selector de carpetas en iOS...');
      
      // Intentar usar FilePicker para obtener una ruta de directorio
      // Nota: En iOS esto suele abrir el selector de iCloud/Archivos
      String? result = await FilePicker.getDirectoryPath();

      if (result != null) {
        debugPrint('✅ Carpeta iOS seleccionada: $result');
        return result;
      }

      // Si el usuario cancela o falla, podemos sugerir la carpeta de documentos de la app
      // como un lugar donde pueden mover su música mediante iTunes/Finder
      final appDocDir = await getApplicationDocumentsDirectory();
      debugPrint('ℹ️ Usando carpeta de documentos como alternativa: ${appDocDir.path}');
      return appDocDir.path;
      
    } catch (e) {
      debugPrint('⚠️ Error en _selectFolderOnIOS: $e');
      // Fallback final
      final appDocDir = await getApplicationDocumentsDirectory();
      return appDocDir.path;
    }
  }

  /// Cambia a nueva carpeta y LIMPIA la anterior
  Future<String?> selectNewMusicFolder() async => selectMusicFolder();

  String? getCurrentMusicFolder() => _currentFolderPath;

  Future<List<String>> scanMusicFolder() async {
    if (_currentFolderPath == null) return [];

    final dir = Directory(_currentFolderPath!);
    if (!await dir.exists()) {
      onStatusChanged?.call('❌ Carpeta no existe');
      return [];
    }

    try {
      final files = <String>[];
      // Usar list() asíncrono para evitar bloquear el hilo principal (UI thread)
      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final extension = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (_supportedFormats.contains(extension)) {
            files.add(entity.path);
          }
        }
      }

      onStatusChanged?.call('✅ ${files.length} canciones');
      return files;
    } catch (e) {
      onStatusChanged?.call('❌ Error: $e');
      return [];
    }
  }

  Future<void> _startMonitoringFolder(String folderPath) async {
    try {
      await _watcherSubscription?.cancel();

      final dir = Directory(folderPath);
      _folderWatcher = DirectoryWatcher(dir.path);
      onStatusChanged?.call('👁️ Monitoreando');

      _watcherSubscription = _folderWatcher!.events.listen(
            (event) async {
          await Future.delayed(const Duration(milliseconds: 500));

          final path = event.path;
          final extension = p.extension(path).toLowerCase().replaceFirst('.', '');

          if (_supportedFormats.contains(extension)) {
            if (event.type == ChangeType.ADD) {
              onStatusChanged?.call('✨ ${p.basename(path)}');
              onFolderChanged?.call([path], []);
            } else if (event.type == ChangeType.REMOVE) {
              onStatusChanged?.call('🗑️ ${p.basename(path)}');
              onFolderChanged?.call([], [path]);
            }
          }
        },
      );
    } catch (e) {
      onStatusChanged?.call('❌ Error: $e');
    }
  }

  Future<void> stopMonitoring() async {
    await _watcherSubscription?.cancel();
    _watcherSubscription = null;
    _folderWatcher = null;
  }

  Future<void> clearMusicFolder() async {
    await stopMonitoring();
    await _prefs.remove(_folderPathKey);
    _previousFolderPath = _currentFolderPath;
    _currentFolderPath = null;
    onFolderCleared?.call();
    onStatusChanged?.call('Limpiada');
  }

  bool hasMusicFolderConfigured() => _currentFolderPath != null;
}