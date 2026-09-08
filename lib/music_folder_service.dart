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
    final savedPath = _prefs.getString(_folderPathKey);
    
    if (savedPath != null) {
      // Resolver la ruta real (especialmente importante en iOS donde los IDs de contenedor cambian)
      _currentFolderPath = await _resolvePath(savedPath);
      
      if (_currentFolderPath != null && await Directory(_currentFolderPath!).exists()) {
        debugPrint('✅ Carpeta auto-detectada: $_currentFolderPath');
        _startMonitoringFolder(_currentFolderPath!);
      } else {
        debugPrint('⚠️ La carpeta guardada ya no es accesible o no existe');
      }
    }
  }

  /// Resuelve la ruta guardada. Si es iOS y estaba en Documentos, la reconstruye con el ID actual.
  Future<String?> _resolvePath(String path) async {
    if (Platform.isIOS && path.contains('/Documents/')) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final parts = path.split('/Documents/');
      if (parts.length > 1) {
        return p.join(appDocDir.path, parts[1]);
      }
    }
    return path;
  }

  /// Guarda la ruta de forma segura para persistencia entre reinicios
  Future<void> _savePath(String path) async {
    _currentFolderPath = path;
    // En iOS guardamos la ruta completa, pero initialize se encargará de resolverla si cambia el contenedor
    await _prefs.setString(_folderPathKey, path);
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
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) return true;
    final newManageStatus = await Permission.manageExternalStorage.request();
    if (newManageStatus.isGranted) return true;
    final audioStatus = await Permission.audio.request();
    final storageStatus = await Permission.storage.request();
    return audioStatus.isGranted || storageStatus.isGranted;
  }

  Future<void> openSettings() async {
    await openAppSettings();
  }

  Future<bool> _requestIOSPermissions() async {
    try {
      final status = await Permission.mediaLibrary.status;
      if (status.isDenied) {
        await Permission.mediaLibrary.request();
      }
    } catch (e) {
      debugPrint('Aviso iOS: MediaLibrary no disponible o no requerida');
    }
    return true; 
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

        await stopMonitoring();
        onFolderCleared?.call();

        await _savePath(selectedPath);
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
      String? result = await FilePicker.getDirectoryPath();

      if (result != null) {
        debugPrint('✅ Carpeta iOS seleccionada: $result');
        return result;
      }

      final appDocDir = await getApplicationDocumentsDirectory();
      debugPrint('ℹ️ Usando carpeta de documentos como alternativa: ${appDocDir.path}');
      return appDocDir.path;
      
    } catch (e) {
      debugPrint('⚠️ Error en _selectFolderOnIOS: $e');
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