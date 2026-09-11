import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watcher/watcher.dart';
import 'debug_logger.dart';

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
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('MusicFolderService', 'Inicializando servicio...');
    
    try {
      _prefs = await SharedPreferences.getInstance();
      DebugLogger.logSuccess('MusicFolderService', 'SharedPreferences inicializado');

      final savedPath = _prefs.getString(_folderPathKey);
      DebugLogger.logData('MusicFolderService', 'Ruta guardada', savedPath ?? 'ninguna');

      if (savedPath != null) {
        // Resolver la ruta real
        DebugLogger.logInfo('MusicFolderService', 'Resolviendo ruta guardada...');
        _currentFolderPath = await _resolvePath(savedPath);

        if (_currentFolderPath != null && await Directory(_currentFolderPath!).exists()) {
          DebugLogger.logSuccess('MusicFolderService', 'Carpeta auto-detectada: $_currentFolderPath');
          _startMonitoringFolder(_currentFolderPath!);
        } else {
          DebugLogger.logWarning('MusicFolderService', 'Carpeta guardada no accesible o no existe');
        }
      } else {
        DebugLogger.logInfo('MusicFolderService', 'No hay carpeta guardada');
      }
      
      DebugLogger.logSuccess('MusicFolderService', 'Inicialización completada');
    } catch (e) {
      DebugLogger.logError('MusicFolderService', 'Error en initialize', e);
    }
    DebugLogger.log('═══════════════════════════════════════');
  }

  Future<String?> _resolvePath(String path) async {
    DebugLogger.logData('ResolvePath', 'Input', path);
    
    if (Platform.isIOS && path.contains('/Documents/')) {
      DebugLogger.logInfo('ResolvePath', 'Detectado iOS, resolviendo ruta de Documents...');
      final appDocDir = await getApplicationDocumentsDirectory();
      final parts = path.split('/Documents/');
      if (parts.length > 1) {
        final resolved = p.join(appDocDir.path, parts[1]);
        DebugLogger.logSuccess('ResolvePath', 'Ruta resuelta: $resolved');
        return resolved;
      }
    }
    
    DebugLogger.logData('ResolvePath', 'Output', path);
    return path;
  }

  Future<void> _savePath(String path) async {
    DebugLogger.logInfo('SavePath', 'Guardando ruta: $path');
    try {
      _currentFolderPath = path;
      await _prefs.setString(_folderPathKey, path);
      DebugLogger.logSuccess('SavePath', 'Ruta guardada en SharedPreferences');
    } catch (e) {
      DebugLogger.logError('SavePath', 'Error guardando ruta', e);
    }
  }

  Future<bool> requestStoragePermissions() async {
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('Permisos', 'Solicitando permisos de almacenamiento...');
    DebugLogger.logData('Permisos', 'Plataforma', Platform.operatingSystem);
    
    try {
      if (Platform.isAndroid) {
        return await _requestAndroidPermissions();
      } else if (Platform.isIOS) {
        return await _requestIOSPermissions();
      }
    } catch (e) {
      DebugLogger.logError('Permisos', 'Error solicitando permisos', e);
    }
    
    DebugLogger.log('═══════════════════════════════════════');
    return false;
  }

  Future<bool> _requestAndroidPermissions() async {
    DebugLogger.logInfo('PermisosAndroid', 'Solicitando permisos Android...');
    
    try {
      // Primero intentar manageExternalStorage (Android 11+)
      final manageStatus = await Permission.manageExternalStorage.status;
      DebugLogger.logData('PermisosAndroid', 'manageExternalStorage status', manageStatus);
      
      if (manageStatus.isGranted) {
        DebugLogger.logSuccess('PermisosAndroid', 'manageExternalStorage ya concedido');
        return true;
      }

      final newManageStatus = await Permission.manageExternalStorage.request();
      DebugLogger.logData('PermisosAndroid', 'manageExternalStorage después de solicitar', newManageStatus);
      
      if (newManageStatus.isGranted) {
        DebugLogger.logSuccess('PermisosAndroid', 'manageExternalStorage concedido');
        return true;
      }

      // Fallback a permisos legados
      DebugLogger.logWarning('PermisosAndroid', 'manageExternalStorage denegado, intentando permisos legados...');
      
      final audioStatus = await Permission.audio.request();
      DebugLogger.logData('PermisosAndroid', 'audio status', audioStatus);
      
      final storageStatus = await Permission.storage.request();
      DebugLogger.logData('PermisosAndroid', 'storage status', storageStatus);

      final hasPermission = audioStatus.isGranted || storageStatus.isGranted;
      
      if (hasPermission) {
        DebugLogger.logSuccess('PermisosAndroid', 'Permisos concedidos (legados)');
      } else {
        DebugLogger.logWarning('PermisosAndroid', 'Todos los permisos denegados');
      }
      
      return hasPermission;
    } catch (e) {
      DebugLogger.logError('PermisosAndroid', 'Error solicitando permisos', e);
      return false;
    }
  }

  Future<void> openSettings() async {
    DebugLogger.logInfo('Settings', 'Abriendo configuración de la app...');
    try {
      await openAppSettings();
      DebugLogger.logSuccess('Settings', 'Configuración abierta');
    } catch (e) {
      DebugLogger.logError('Settings', 'Error abriendo configuración', e);
    }
  }

  Future<bool> _requestIOSPermissions() async {
    DebugLogger.logInfo('PermisosIOS', 'Solicitando permisos iOS...');
    
    try {
      final status = await Permission.mediaLibrary.status;
      DebugLogger.logData('PermisosIOS', 'mediaLibrary status', status);
      
      if (status.isDenied) {
        DebugLogger.logWarning('PermisosIOS', 'mediaLibrary denegado, solicitando...');
        await Permission.mediaLibrary.request();
        DebugLogger.logSuccess('PermisosIOS', 'Permiso solicitado');
      } else if (status.isGranted) {
        DebugLogger.logSuccess('PermisosIOS', 'mediaLibrary ya concedido');
      }
    } catch (e) {
      DebugLogger.logWarning('PermisosIOS', 'MediaLibrary no disponible: $e');
    }
    return true;
  }

  Future<String?> selectMusicFolder() async {
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('SelectFolder', 'Abriendo selector de carpeta...');
    DebugLogger.logData('SelectFolder', 'Plataforma', Platform.operatingSystem);

    try {
      onStatusChanged?.call('📁 Abriendo selector...');

      String? selectedPath;
      if (Platform.isAndroid) {
        DebugLogger.logInfo('SelectFolder', 'Usando FilePicker para Android...');
        selectedPath = await FilePicker.getDirectoryPath();
      } else if (Platform.isIOS) {
        DebugLogger.logInfo('SelectFolder', 'Usando selector personalizado para iOS...');
        selectedPath = await _selectFolderOnIOS();
      } else {
        DebugLogger.logInfo('SelectFolder', 'Usando FilePicker genérico...');
        selectedPath = await FilePicker.getDirectoryPath();
      }

      if (selectedPath != null) {
        DebugLogger.logSuccess('SelectFolder', 'Carpeta seleccionada: $selectedPath');
        DebugLogger.logData('SelectFolder', 'Nombre carpeta', p.basename(selectedPath));

        final dir = Directory(selectedPath);
        if (!await dir.exists()) {
          DebugLogger.logError('SelectFolder', 'Carpeta seleccionada no existe', selectedPath);
          onStatusChanged?.call('❌ Carpeta no existe');
          return null;
        }

        DebugLogger.logInfo('SelectFolder', 'Deteniendo monitoreo anterior...');
        await stopMonitoring();
        onFolderCleared?.call();

        DebugLogger.logInfo('SelectFolder', 'Guardando ruta...');
        await _savePath(selectedPath);
        
        onStatusChanged?.call('✅ Carpeta: ${p.basename(selectedPath)}');
        DebugLogger.logSuccess('SelectFolder', 'Iniciando monitoreo de carpeta...');

        await _startMonitoringFolder(selectedPath);
        return selectedPath;
      } else {
        DebugLogger.logWarning('SelectFolder', 'Usuario canceló la selección');
      }
    } catch (e) {
      DebugLogger.logError('SelectFolder', 'Error en selectMusicFolder', e);
      onStatusChanged?.call('❌ Error: $e');
    }
    
    DebugLogger.log('═══════════════════════════════════════');
    return null;
  }

  Future<String?> _selectFolderOnIOS() async {
    DebugLogger.logInfo('SelectFolderIOS', 'Abriendo selector de carpetas iOS...');
    
    try {
      String? result = await FilePicker.getDirectoryPath();

      if (result != null) {
        DebugLogger.logSuccess('SelectFolderIOS', 'Carpeta seleccionada: $result');
        return result;
      }

      DebugLogger.logWarning('SelectFolderIOS', 'FilePicker retornó null, usando carpeta Documentos como fallback');
      final appDocDir = await getApplicationDocumentsDirectory();
      DebugLogger.logData('SelectFolderIOS', 'Fallback', appDocDir.path);
      return appDocDir.path;

    } catch (e) {
      DebugLogger.logError('SelectFolderIOS', 'Error en _selectFolderOnIOS', e);
      final appDocDir = await getApplicationDocumentsDirectory();
      DebugLogger.logData('SelectFolderIOS', 'Fallback por error', appDocDir.path);
      return appDocDir.path;
    }
  }

  Future<String?> selectNewMusicFolder() async => selectMusicFolder();

  String? getCurrentMusicFolder() => _currentFolderPath;

  Future<List<String>> scanMusicFolder() async {
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('ScanFolder', 'Escaneando carpeta de música...');
    DebugLogger.logData('ScanFolder', 'Carpeta', _currentFolderPath ?? 'ninguna');

    if (_currentFolderPath == null) {
      DebugLogger.logWarning('ScanFolder', 'No hay carpeta configurada');
      return [];
    }

    final dir = Directory(_currentFolderPath!);
    if (!await dir.exists()) {
      DebugLogger.logError('ScanFolder', 'Carpeta no existe', _currentFolderPath);
      onStatusChanged?.call('❌ Carpeta no existe');
      return [];
    }

    try {
      final files = <String>[];
      int totalEntities = 0;
      int musicFiles = 0;

      DebugLogger.logInfo('ScanFolder', 'Listando archivos recursivamente...');

      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        totalEntities++;
        
        if (entity is File) {
          final extension = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          
          if (_supportedFormats.contains(extension)) {
            files.add(entity.path);
            musicFiles++;
            
            if (musicFiles <= 5) { // Mostrar primeros 5
              DebugLogger.logData('ScanFolder', 'Archivo encontrado ($musicFiles)', p.basename(entity.path));
            }
          }
        }
      }

      DebugLogger.logSuccess('ScanFolder', 'Escaneo completado');
      DebugLogger.logData('ScanFolder', 'Total entidades', totalEntities);
      DebugLogger.logData('ScanFolder', 'Archivos de música', musicFiles);
      
      if (musicFiles > 5) {
        DebugLogger.logData('ScanFolder', '... y', '${musicFiles - 5} archivos más');
      }

      onStatusChanged?.call('✅ $musicFiles canciones');
      return files;
    } catch (e) {
      DebugLogger.logError('ScanFolder', 'Error escaneando carpeta', e);
      onStatusChanged?.call('❌ Error: $e');
      return [];
    } finally {
      DebugLogger.log('═══════════════════════════════════════');
    }
  }

  Future<void> _startMonitoringFolder(String folderPath) async {
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('Monitor', 'Iniciando monitoreo de carpeta...');
    DebugLogger.logData('Monitor', 'Carpeta', folderPath);

    try {
      await _watcherSubscription?.cancel();
      DebugLogger.logInfo('Monitor', 'Suscripción anterior cancelada');

      final dir = Directory(folderPath);
      _folderWatcher = DirectoryWatcher(dir.path);
      DebugLogger.logSuccess('Monitor', 'DirectoryWatcher creado');
      onStatusChanged?.call('👁️ Monitoreando');

      _watcherSubscription = _folderWatcher!.events.listen(
        (event) async {
          DebugLogger.logData('Monitor', 'Evento', '${event.type} - ${p.basename(event.path)}');
          
          await Future.delayed(const Duration(milliseconds: 500));

          final path = event.path;
          final extension = p.extension(path).toLowerCase().replaceFirst('.', '');

          if (_supportedFormats.contains(extension)) {
            if (event.type == ChangeType.ADD) {
              DebugLogger.logSuccess('Monitor', '✨ Archivo añadido: ${p.basename(path)}');
              onStatusChanged?.call('✨ ${p.basename(path)}');
              onFolderChanged?.call([path], []);
            } else if (event.type == ChangeType.REMOVE) {
              DebugLogger.logInfo('Monitor', '🗑️ Archivo eliminado: ${p.basename(path)}');
              onStatusChanged?.call('🗑️ ${p.basename(path)}');
              onFolderChanged?.call([], [path]);
            }
          }
        },
        onError: (error) {
          DebugLogger.logError('Monitor', 'Error en stream de eventos', error);
        },
      );

      DebugLogger.logSuccess('Monitor', 'Monitoreo iniciado correctamente');
    } catch (e) {
      DebugLogger.logError('Monitor', 'Error iniciando monitoreo', e);
      onStatusChanged?.call('❌ Error: $e');
    }
    
    DebugLogger.log('═══════════════════════════════════════');
  }

  Future<void> stopMonitoring() async {
    DebugLogger.logInfo('Monitor', 'Deteniendo monitoreo...');
    try {
      await _watcherSubscription?.cancel();
      _watcherSubscription = null;
      _folderWatcher = null;
      DebugLogger.logSuccess('Monitor', 'Monitoreo detenido');
    } catch (e) {
      DebugLogger.logError('Monitor', 'Error deteniendo monitoreo', e);
    }
  }

  Future<void> clearMusicFolder() async {
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('ClearFolder', 'Limpiando carpeta de música...');

    try {
      await stopMonitoring();
      await _prefs.remove(_folderPathKey);
      _previousFolderPath = _currentFolderPath;
      _currentFolderPath = null;
      onFolderCleared?.call();
      onStatusChanged?.call('Limpiada');
      
      DebugLogger.logSuccess('ClearFolder', 'Carpeta de música limpiada');
    } catch (e) {
      DebugLogger.logError('ClearFolder', 'Error limpiando carpeta', e);
    }
    
    DebugLogger.log('═══════════════════════════════════════');
  }

  Future<List<String>> selectMusicFiles() async {
    DebugLogger.log('═══════════════════════════════════════');
    DebugLogger.logInfo('SelectFiles', 'Seleccionando archivos de música (iOS)...');

    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.audio,
      );

      if (result != null && result.isNotEmpty) {
        final paths = result.map((file) => file.path).whereType<String>().toList();
        DebugLogger.logSuccess('SelectFiles', '${paths.length} archivos seleccionados');
        paths.forEach((p) => DebugLogger.logData('SelectFiles', 'Archivo', p));
        return paths;
      } else {
        DebugLogger.logWarning('SelectFiles', 'Usuario canceló la selección');
      }
    } catch (e) {
      DebugLogger.logError('SelectFiles', 'Error seleccionando archivos', e);
    }
    
    DebugLogger.log('═══════════════════════════════════════');
    return [];
  }

  bool hasMusicFolderConfigured() => _currentFolderPath != null;
}
