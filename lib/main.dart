import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_taglib/flutter_taglib.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:palette_generator/palette_generator.dart';
import 'update_service.dart';
import 'package:audio_session/audio_session.dart';
import 'services/flac_metadata_reader.dart';
import 'debug_logger.dart';
import 'music_folder_service.dart';

late MyAudioHandler audioHandler;
bool _tagLibSupported = true;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  DebugLogger.log('🚀 ═══════════════════════════════════════');
  await DebugLogger.init();
  DebugLogger.logSuccess('Main', 'Iniciando aplicación BIN Music');
  DebugLogger.logData('Main', 'Plataforma', Platform.operatingSystem);

  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await session.setActive(true);
    DebugLogger.logSuccess('AudioSession', 'Configurado correctamente');
  } catch (e) {
    DebugLogger.logError('AudioSession', 'Error configurando', e);
  }

  try {
    CookieManager cookieManager = CookieManager.instance();
    await cookieManager.deleteAllCookies();
    DebugLogger.logInfo('CookieManager', 'Cookies eliminadas');
  } catch (e) {
    DebugLogger.logError('CookieManager', 'Error limpiando cookies', e);
  }

  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.music_player_app.audio',
        androidNotificationChannelName: 'Reproductor de Música',
        // 🌟 DEBE ser false para poder usar androidStopForegroundOnPause: false
        androidNotificationOngoing: false,
        // 🌟 VITAL: evita que el sistema mate el servicio en segundo plano al pausar
        androidStopForegroundOnPause: false,
        preloadArtwork: true, // Mejora la carga de portadas en la notificación nativa
      ),
    );
    DebugLogger.logSuccess('AudioService', 'Inicializado correctamente');
  } catch (e) {
    DebugLogger.logError('AudioService', 'Error inicializando', e);
  }

  runApp(const MyApp());
  DebugLogger.logSuccess('Main', 'App iniciada correctamente');
}

// ---------------------------------------------------------
// MANEJADOR DE AUDIO (Optimizado para Background y Sync)
// ---------------------------------------------------------

enum AudioSourceType { file, asset, network }

// ---------------------------------------------------------
// MANEJADOR DE AUDIO (Corregido para barra de progreso nativa)
// ---------------------------------------------------------

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  MyAudioHandler() {
    _initAudioPlayerStreams();
  }

  void _initAudioPlayerStreams() {
    // 1. Sincronizar estado de reproducción (play/pause/buffering)
    // Usamos event.updateTime para que la barra de progreso del sistema funcione correctamente
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);

    // 2. Sincronizar el MediaItem (notificación nativa) cuando cambia la canción
    _player.currentIndexStream.listen((index) {
      if (index != null) {
        final currentQueue = queue.value;
        if (currentQueue != null && index >= 0 && index < currentQueue.length) {
          final newItem = currentQueue[index];
          final oldItem = mediaItem.value;

          // Preservamos la duración si ya la conocemos, o la obtenemos del reproductor
          final knownDuration = (oldItem?.id == newItem.id)
              ? oldItem?.duration
              : _player.duration;

          mediaItem.add(newItem.copyWith(duration: knownDuration));
        }
      }
    });

    // 3. Actualizar la duración en cuanto el reproductor la descubra
    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });
  }

  Future<void> setFullQueue({
    required List<MediaItem> queueItems,
    required ConcatenatingAudioSource playlist,
    int initialIndex = 0,
  }) async {
    try {
      queue.add(queueItems);

      await _player.setAudioSource(
        playlist,
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
      );

      if (initialIndex >= 0 && initialIndex < queueItems.length) {
        // Actualizamos con la duración si el reproductor ya la pudo leer instantáneamente
        mediaItem.add(queueItems[initialIndex].copyWith(duration: _player.duration));
      }
    } catch (e) {
      DebugLogger.logError('AudioService', 'Error al establecer la cola', e);
    }
  }

  AudioPlayer get player => _player;

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek, // Vital para que aparezca la barra de progreso
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      // 🌟 CORRECCIÓN CLAVE: Usar el tiempo del evento, no DateTime.now()
      updateTime: event.updateTime,
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }
}

// ---------------------------------------------------------
// SERVICIO DE DESCARGA Y PROCESAMIENTO FLAC
// ---------------------------------------------------------
class FlacDownloadService {
  static Future<File?> processDownloadFile({
    required File tempFile,
    required Function(double progress, String status) onProgress,
    String? customDestinationDir,
  }) async {
    Directory? tempFolder;
    try {
      Directory musicFolder;
      if (Platform.isIOS || customDestinationDir == null) {
        final appDocDir = await getApplicationDocumentsDirectory();
        musicFolder = Directory(p.join(appDocDir.path, 'MusicLibrary'));
      } else {
        musicFolder = Directory(p.join(customDestinationDir, 'flacDownloader'));
      }

      if (!await musicFolder.exists()) {
        await musicFolder.create(recursive: true);
      }

      final tempDir = await getTemporaryDirectory();
      final downloadSessionId = DateTime.now().millisecondsSinceEpoch.toString();
      final tempFolderPath = p.join(tempDir.path, 'download_$downloadSessionId');
      tempFolder = Directory(tempFolderPath);
      await tempFolder.create(recursive: true);

      DebugLogger.log('Analizando archivo: ${tempFile.path} (Tamaño: ${await tempFile.length()} bytes)');

      try {
        final header = await tempFile.openRead(0, 4).first;
        final headerHex = header.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        final isFlac = headerHex == '66 4c 61 43';
        DebugLogger.log('Header del archivo: $headerHex (¿Es FLAC válido?: $isFlac)');
      } catch (e) {
        DebugLogger.log('Error leyendo header: $e');
      }

      onProgress(0.90, 'Analizando archivo...');

      String? targetFilePath;
      final isZip = _isZipFile(tempFile);
      DebugLogger.log('¿Es archivo ZIP?: $isZip');

      if (isZip) {
        onProgress(0.93, 'Descomprimiendo archivo...');
        final bytes = await tempFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filename = file.name;
          final ext = p.extension(filename).toLowerCase();
          if (file.isFile && (ext == '.flac' || ext == '.mp3')) {
            final extractedFilePath = p.join(tempFolderPath, p.basename(filename));
            final outFile = File(extractedFilePath);
            await outFile.create(recursive: true);
            await outFile.writeAsBytes(file.content as List<int>);
            targetFilePath = extractedFilePath;
            break;
          }
        }
      } else {
        targetFilePath = tempFile.path;
      }

      if (targetFilePath == null || !File(targetFilePath).existsSync()) {
        throw Exception('No se encontró un archivo de audio válido (.flac o .mp3).');
      }

      onProgress(0.98, 'Guardando en la biblioteca...');

      String title = 'track';
      String artist = '';

      String extension = '.flac';
      try {
        final header = await File(targetFilePath!).openRead(0, 4).first;
        if (header.length >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
          extension = '.mp3';
        } else if (header.length >= 4 && header[0] == 0x66 && header[1] == 0x4C && header[2] == 0x61 && header[3] == 0x43) {
          extension = '.flac';
        } else {
          final originalExt = p.extension(targetFilePath).toLowerCase();
          if (originalExt != '.tmp' && originalExt.isNotEmpty) extension = originalExt;
        }
      } catch (_) {}

      DebugLogger.logInfo('MusicDownload', '📝 Leyendo metadatos reales para formato $extension...');

      try {
        final metadata = await FlacMetadataReader.readMetadata(targetFilePath!);
        title = metadata['title'] ?? 'track';
        artist = metadata['artist'] ?? '';
      } catch (_) {}

      String safeTitle = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
      String safeArtist = artist.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

      String finalFileName = safeArtist.isNotEmpty ? '$safeTitle - $safeArtist$extension' : '$safeTitle$extension';

      String finalDestinationPath = p.join(musicFolder.path, finalFileName);
      int counter = 1;
      while (await File(finalDestinationPath).exists()) {
        finalFileName = safeArtist.isNotEmpty
            ? '$safeTitle - $safeArtist ($counter)$extension'
            : '$safeTitle ($counter)$extension';
        finalDestinationPath = p.join(musicFolder.path, finalFileName);
        counter++;
      }

      DebugLogger.log('Copiando archivo a: $finalDestinationPath');
      final File finalAudioFile = await File(targetFilePath).copy(finalDestinationPath);
      DebugLogger.log('Copia completada con éxito');

      if (await tempFolder.exists()) {
        await tempFolder.delete(recursive: true);
      }

      onProgress(1.0, 'Completado');
      return finalAudioFile;
    } catch (e, stack) {
      DebugLogger.log('❌ Error en FlacDownloadService: $e\nStack: $stack');
      if (tempFolder != null && await tempFolder.exists()) {
        try {
          await tempFolder.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  static bool _isZipFile(File file) {
    try {
      final bytes = file.readAsBytesSync().sublist(0, 4);
      return bytes.length == 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04;
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------
// MODELO Y SERVICIO DE LETRAS (LYRICS)
// ---------------------------------------------------------
class LrcLine {
  final Duration timestamp;
  final String text;
  LrcLine(this.timestamp, this.text);
}

class LyricsService {
  static Future<List<LrcLine>?> fetchLyrics({
    required String trackName,
    required String artistName,
    required String albumName,
    int? durationSeconds,
  }) async {
    final syncedLrc1 = await _fetchFromLRCLibExact(trackName, artistName, albumName, durationSeconds);
    if (syncedLrc1 != null) return syncedLrc1;

    final syncedLrc2 = await _fetchFromLRCLibSearch(trackName, artistName);
    if (syncedLrc2 != null) return syncedLrc2;

    final syncedLrc3 = await _fetchFromTextyl(trackName, artistName);
    if (syncedLrc3 != null) return syncedLrc3;

    return null;
  }

  static Future<List<LrcLine>?> _fetchFromLRCLibExact(String track, String artist, String album, int? duration) async {
    try {
      final query = 'track_name=${Uri.encodeComponent(track)}'
          '&artist_name=${Uri.encodeComponent(artist)}'
          '&album_name=${Uri.encodeComponent(album)}'
          '${duration != null ? "&duration=$duration" : ""}';
      final url = Uri.parse('https://lrclib.net/api/get?$query');
      final response = await http.get(url).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['syncedLyrics'] != null) return _parseLrc(data['syncedLyrics']);
      }
    } catch (_) {}
    return null;
  }

  static Future<List<LrcLine>?> _fetchFromLRCLibSearch(String track, String artist) async {
    try {
      final url = Uri.parse('https://lrclib.net/api/search?q=${Uri.encodeComponent("$track $artist")}');
      final response = await http.get(url).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final List<dynamic> searchData = json.decode(response.body);
        for (var item in searchData) {
          if (item['syncedLyrics'] != null && item['syncedLyrics'].toString().isNotEmpty) {
            return _parseLrc(item['syncedLyrics']);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<List<LrcLine>?> _fetchFromTextyl(String track, String artist) async {
    try {
      final url = Uri.parse('https://api.textyl.co/api/lyrics?q=${Uri.encodeComponent("$track $artist")}');
      final response = await http.get(url).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        final List<LrcLine> lines = [];
        for (var item in data) {
          final seconds = (item['seconds'] as num).toDouble();
          lines.add(LrcLine(
            Duration(milliseconds: (seconds * 1000).toInt()),
            item['lyrics'].toString().trim(),
          ));
        }
        if (lines.isNotEmpty) return lines;
      }
    } catch (_) {}
    return null;
  }

  static List<LrcLine> _parseLrc(String lrcContent) {
    final List<LrcLine> lines = [];
    final RegExp regExp = RegExp(r'\[(\d+):(\d+\.\d+)\](.*)');

    for (var line in lrcContent.split('\n')) {
      final match = regExp.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = double.parse(match.group(2)!);
        final text = match.group(3)!.trim();

        if (text.isNotEmpty) {
          final timestamp = Duration(
            minutes: minutes,
            milliseconds: (seconds * 1000).toInt(),
          );
          lines.add(LrcLine(timestamp, text));
        }
      }
    }
    return lines;
  }
}

// ---------------------------------------------------------
// PANTALLA DE NAVEGACIÓN WEB
// ---------------------------------------------------------
class FlacWebBrowserScreen extends StatefulWidget {
  final Function(File flacFile) onDownloadComplete;
  final MusicFolderService musicFolderService;

  const FlacWebBrowserScreen({
    super.key,
    required this.onDownloadComplete,
    required this.musicFolderService,
  });

  @override
  State<FlacWebBrowserScreen> createState() => _FlacWebBrowserScreenState();
}

class _FlacWebBrowserScreenState extends State<FlacWebBrowserScreen> {
  InAppWebViewController? webViewController;
  bool _isLoadingPage = true;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';

  File? _tempDownloadFile;
  IOSink? _downloadSink;

  Future<void> _extractBlobInChunks(String blobUrl) async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.05;
      _downloadStatus = 'Iniciando lectura de Blob...';
    });
    DebugLogger.log('Iniciando extracción de Blob: $blobUrl');

    try {
      final tempDir = await getTemporaryDirectory();
      _tempDownloadFile = File(p.join(tempDir.path, 'streaming_download_${DateTime.now().millisecondsSinceEpoch}.tmp'));
      _downloadSink = _tempDownloadFile!.openWrite();

      final String jsChunkedExtractor = '''
        (function() {
          var xhr = new XMLHttpRequest();
          xhr.open('GET', '$blobUrl', true);
          xhr.responseType = 'arraybuffer';
          
          xhr.onprogress = function(e) {
            if (e.lengthComputable) {
              var percent = (e.loaded / e.total) * 0.4;
              window.flutter_inappwebview.callHandler('onBlobProgress', percent);
            }
          };

          xhr.onload = function() {
            if (this.status == 200) {
              var buffer = this.response;
              var byteArray = new Uint8Array(buffer);
              var chunkSize = 1024 * 512;
              var totalChunks = Math.ceil(byteArray.length / chunkSize);
              
              window.flutter_inappwebview.callHandler('onBlobStart', {
                totalBytes: byteArray.length,
                totalChunks: totalChunks
              });

              function sendNextChunk(index) {
                if (index >= totalChunks) {
                  window.flutter_inappwebview.callHandler('onBlobEnd');
                  return;
                }

                var start = index * chunkSize;
                var end = Math.min(start + chunkSize, byteArray.length);
                var chunk = Array.from(byteArray.subarray(start, end));
                
                window.flutter_inappwebview.callHandler('onBlobChunk', {
                  index: index,
                  chunk: chunk
                });

                setTimeout(function() {
                  sendNextChunk(index + 1);
                }, 10);
              }

              sendNextChunk(0);
            } else {
              window.flutter_inappwebview.callHandler('onBlobError', 'HTTP Status: ' + this.status);
            }
          };

          xhr.onerror = function() {
            window.flutter_inappwebview.callHandler('onBlobError', 'Error de red al leer Blob');
          };

          xhr.send();
        })();
      ''';

      await webViewController?.evaluateJavascript(source: jsChunkedExtractor);
    } catch (e) {
      debugPrint('Error inicializando descarga: $e');
      setState(() => _isDownloading = false);
    }
  }

  Future<void> _processDownloadedFile() async {
    try {
      await _downloadSink?.flush();
      await _downloadSink?.close();
      _downloadSink = null;

      if (_tempDownloadFile == null || !await _tempDownloadFile!.exists()) {
        throw Exception('Archivo temporal no encontrado');
      }

      setState(() {
        _downloadProgress = 0.85;
        _downloadStatus = 'Procesando archivo de audio...';
      });

      final flacFile = await FlacDownloadService.processDownloadFile(
        tempFile: _tempDownloadFile!,
        customDestinationDir: widget.musicFolderService.getCurrentMusicFolder(),
        onProgress: (progress, status) {
          if (mounted) {
            setState(() {
              _downloadProgress = progress;
              _downloadStatus = status;
            });
          }
        },
      );

      if (_tempDownloadFile != null && await _tempDownloadFile!.exists()) {
        await _tempDownloadFile!.delete();
      }

      if (flacFile != null && mounted) {
        widget.onDownloadComplete(flacFile);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Canción agregada a la biblioteca')),
        );
      }
    } catch (e) {
      debugPrint('Error al procesar archivo: $e');
      if (mounted) {
        setState(() => _isDownloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al procesar FLAC: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Flac Downloader', style: TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF1E1E20),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => webViewController?.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('https://flacdownloader.com'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              javaScriptCanOpenWindowsAutomatically: true,
              supportMultipleWindows: true,
              useShouldOverrideUrlLoading: true,
              useOnDownloadStart: true,
              thirdPartyCookiesEnabled: true,
              mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
              allowsInlineMediaPlayback: true,
              allowFileAccessFromFileURLs: true,
              allowUniversalAccessFromFileURLs: true,
            ),
            onWebViewCreated: (controller) {
              webViewController = controller;

              controller.addJavaScriptHandler(
                handlerName: 'onBlobProgress',
                callback: (args) {
                  if (mounted && args.isNotEmpty) {
                    setState(() {
                      _downloadProgress = (args[0] as num).toDouble();
                      _downloadStatus = 'Descargando datos del navegador...';
                    });
                  }
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'onBlobStart',
                callback: (args) {
                  if (mounted) {
                    setState(() {
                      _downloadProgress = 0.4;
                      _downloadStatus = 'Recibiendo fragmentos de audio...';
                    });
                  }
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'onBlobChunk',
                callback: (args) {
                  if (args.isNotEmpty && args[0] is Map) {
                    final data = args[0] as Map;
                    final List<dynamic> chunkList = data['chunk'] as List<dynamic>;
                    final uint8chunk = Uint8List.fromList(chunkList.cast<int>());
                    _downloadSink?.add(uint8chunk);
                  }
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'onBlobEnd',
                callback: (args) {
                  _processDownloadedFile();
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'onBlobError',
                callback: (args) async {
                  DebugLogger.log('❌ Error en JS Blob Handler: ${args.firstOrNull}');
                  await _downloadSink?.close();
                  _downloadSink = null;
                  if (_tempDownloadFile != null && await _tempDownloadFile!.exists()) {
                    await _tempDownloadFile!.delete();
                  }

                  setState(() => _isDownloading = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error al extraer archivo: ${args.firstOrNull ?? "Desconocido"}'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                },
              );
            },
            onLoadStart: (controller, url) => setState(() => _isLoadingPage = true),
            onLoadStop: (controller, url) => setState(() => _isLoadingPage = false),
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final uri = navigationAction.request.url;
              if (uri != null) {
                final urlString = uri.toString();
                if (urlString.startsWith('blob:')) {
                  _extractBlobInChunks(urlString);
                  return NavigationActionPolicy.CANCEL;
                }
              }
              return NavigationActionPolicy.ALLOW;
            },
            onDownloadStartRequest: (controller, downloadStartRequest) {
              final urlString = downloadStartRequest.url.toString();
              if (urlString.startsWith('blob:')) {
                _extractBlobInChunks(urlString);
              }
            },
          ),
          if (_isLoadingPage && !_isDownloading)
            const Center(child: CircularProgressIndicator(color: Colors.amber)),
          if (_isDownloading)
            Container(
              color: Colors.black87,
              child: Center(
                child: Card(
                  color: const Color(0xFF1E1E20),
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.amber),
                        const SizedBox(height: 20),
                        Text(
                          _downloadStatus,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _downloadProgress,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// APP Y SPLASH SCREEN
// ---------------------------------------------------------
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late MusicFolderService _musicFolderService;

  @override
  void initState() {
    super.initState();
    _initializeMusicFolderService();
  }

  Future<void> _initializeMusicFolderService() async {
    _musicFolderService = MusicFolderService();
    await _musicFolderService.initialize();
  }

  @override
  void dispose() {
    _musicFolderService.stopMonitoring();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BIN Music Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: Platform.isIOS ? '.SF Pro Text' : 'Roboto',
        ),
      ),
      home: SplashScreen(musicFolderService: _musicFolderService),
    );
  }
}

class SplashScreen extends StatefulWidget {
  final MusicFolderService musicFolderService;

  const SplashScreen({
    super.key,
    required this.musicFolderService,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => AlbumCollectionScreen(
              musicFolderService: widget.musicFolderService,
            ),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset(
                'assets/ojo.gif',
                width: 120,
                height: 120,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.remove_red_eye_rounded,
                  size: 80,
                  color: Colors.white54,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'BIN Music',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// MODELOS Y PANTALLA PRINCIPAL
// ---------------------------------------------------------
class AlbumModel {
  final String title;
  final String artist;
  final String image;
  final List<Map<String, dynamic>> songs;

  AlbumModel({
    required this.title,
    required this.artist,
    required this.image,
    required this.songs,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'image': image,
    'songs': songs,
  };

  factory AlbumModel.fromJson(Map<String, dynamic> json) {
    return AlbumModel(
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
      image: json['image'] ?? '',
      songs: (json['songs'] as List<dynamic>?)
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList() ??
          [],
    );
  }
}

class AlbumCollectionScreen extends StatefulWidget {
  final MusicFolderService musicFolderService;

  const AlbumCollectionScreen({
    super.key,
    required this.musicFolderService,
  });

  @override
  State<AlbumCollectionScreen> createState() => _AlbumCollectionScreenState();
}

class _AlbumCollectionScreenState extends State<AlbumCollectionScreen> with WidgetsBindingObserver {
  MediaItem? _currentMediaItem;
  late final PageController _pageController;
  final GlobalKey _shareCardKey = GlobalKey();

  AudioPlayer get _audioPlayer => audioHandler.player;

  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isSeeking = false;
  double _dragValue = 0.0;

  List<AlbumModel> albumList = [];
  int _currentPlayingAlbumIndex = -1;
  int _currentSongInAlbumIndex = -1;
  String? _currentAudioPath;

  bool _showLyricsView = false;
  bool _showTracklistView = false;
  int _selectedTracklistAlbumIndex = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(viewportFraction: 0.5, initialPage: 0);
    checkForUpdates(context);

    _audioPlayer.setVolume(1.0);

    _audioPlayer.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d ?? Duration.zero);
    });

    _audioPlayer.positionStream.listen((p) {
      if (_isPlaying && !_isSeeking && mounted) {
        setState(() => _position = p);
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state.playing);
      }
    });

    widget.musicFolderService.onFolderChanged = (added, removed) {
      _handleFolderChanges(added, removed);
    };

    widget.musicFolderService.onFolderCleared = () {
      setState(() {
        albumList.clear();
        _currentPlayingAlbumIndex = -1;
        _currentSongInAlbumIndex = -1;
        _currentAudioPath = null;
        _audioPlayer.stop();
      });
      _saveAlbumsToPrefs();
    };

    final currentFolder = widget.musicFolderService.getCurrentMusicFolder();
    if (currentFolder != null) {
      widget.musicFolderService.scanMusicFolder().then((files) {
        if (files.isNotEmpty) _loadMusicFilesFromFolder(files);
      });
    }

    _initAppStartup();

    Future.delayed(Duration.zero, () {
      _resumePlaybackIfNeeded();
    });

    // 🌟 Escuchar cambios en el media item para actualizar la UI cuando cambia en segundo plano
    audioHandler.mediaItem.listen((mediaItem) {
      if (mediaItem == null || !mounted) return;
      _currentMediaItem = mediaItem;
      _updateCurrentSongFromMediaItem(mediaItem);
    });
  }

  void _updateCurrentSongFromMediaItem(MediaItem mediaItem) {
    for (int albumIdx = 0; albumIdx < albumList.length; albumIdx++) {
      final album = albumList[albumIdx];
      for (int songIdx = 0; songIdx < album.songs.length; songIdx++) {
        final song = album.songs[songIdx];
        if (song['filePath'] == mediaItem.id) {
          setState(() {
            _currentPlayingAlbumIndex = albumIdx;
            _currentSongInAlbumIndex = songIdx;
            _currentAudioPath = song['filePath'];
          });

          if (_pageController.hasClients && _getCurrentPageIndex() != albumIdx) {
            _pageController.animateToPage(
              albumIdx,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          }
          return;
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (audioHandler.mediaItem.value != null) {
        _updateCurrentSongFromMediaItem(audioHandler.mediaItem.value!);
      }
    }
  }

  void _resumePlaybackIfNeeded() {
    if (_currentAudioPath != null && _currentPlayingAlbumIndex != -1) {
      if (!_audioPlayer.playing) {
        if (_audioPlayer.playerState.processingState != ProcessingState.idle) {
          _audioPlayer.play();
          setState(() => _isPlaying = true);
        } else {
          _playSong(_currentPlayingAlbumIndex, _currentSongInAlbumIndex);
        }
      }
    }
  }

  Future<void> _initAppStartup() async {
    await _loadSavedAlbums();
    await _scanAssetsForMusic();
    await _cleanOrphanedSongs();
  }

  Future<void> _scanAssetsForMusic() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final audioPaths = manifest.listAssets()
          .where((String key) => key.startsWith('assets/audios/'))
          .where((String key) =>
      key.toLowerCase().endsWith('.mp3') ||
          key.toLowerCase().endsWith('.flac') ||
          key.toLowerCase().endsWith('.wav') ||
          key.toLowerCase().endsWith('.m4a') ||
          key.toLowerCase().endsWith('.aac') ||
          key.toLowerCase().endsWith('.ogg'))
          .toList();

      if (audioPaths.isEmpty) return;

      bool importedAny = false;
      for (String path in audioPaths) {
        bool exists = false;
        for (var album in albumList) {
          if (album.songs.any((s) => s['filePath'] == path)) {
            exists = true;
            break;
          }
        }

        if (!exists) {
          await _addFlacOrMusicFile(path, sourceType: AudioSourceType.asset, updateState: false);
          importedAny = true;
        }
      }

      if (importedAny) {
        setState(() {});
        await _saveAlbumsToPrefs();
      }
    } catch (e) {
      debugPrint('Aviso: No se pudieron escanear los assets de música: $e');
    }
  }

  Future<void> _loadSavedAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? savedData = prefs.getString('saved_albums_catalog');
      if (savedData != null) {
        final List<dynamic> decodedList = jsonDecode(savedData);
        setState(() {
          albumList = decodedList.map((item) => AlbumModel.fromJson(item)).toList();
        });
      }
    } catch (e) {
      debugPrint('Error al cargar colección: $e');
    }
  }

  Future<void> _saveAlbumsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encodedList = jsonEncode(albumList.map((a) => a.toJson()).toList());
      await prefs.setString('saved_albums_catalog', encodedList);
    } catch (e) {
      debugPrint('Error al guardar colección: $e');
    }
  }

  Future<void> _cleanOrphanedSongs() async {
    bool modified = false;

    for (int i = albumList.length - 1; i >= 0; i--) {
      final album = albumList[i];

      album.songs.removeWhere((song) {
        final path = song['filePath'] ?? '';
        final sourceTypeName = song['sourceType'] as String?;

        if (sourceTypeName == AudioSourceType.asset.name || sourceTypeName == AudioSourceType.network.name) {
          return false;
        }

        final exists = path.isNotEmpty && File(path).existsSync();
        if (!exists) modified = true;
        return !exists;
      });

      if (album.songs.isEmpty) {
        albumList.removeAt(i);
        modified = true;
        if (_currentPlayingAlbumIndex == i) {
          _audioPlayer.stop();
          _currentPlayingAlbumIndex = -1;
          _currentSongInAlbumIndex = -1;
          _currentAudioPath = null;
        } else if (_currentPlayingAlbumIndex > i) {
          _currentPlayingAlbumIndex--;
        }
      }
    }

    if (modified) {
      setState(() {});
      await _saveAlbumsToPrefs();
    }
  }

  Future<void> _addFlacOrMusicFile(String filePath, {AudioSourceType sourceType = AudioSourceType.file, bool updateState = true}) async {
    if (sourceType == AudioSourceType.file && !File(filePath).existsSync()) {
      debugPrint('Archivo no encontrado: $filePath');
      return;
    }

    String title = p.basenameWithoutExtension(filePath);
    String artist = 'Artista Desconocido';
    String albumName = 'Música General';
    String albumImage = 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&fit=crop';
    int trackNumber = 0;

    final tempDir = await getTemporaryDirectory();
    String tagFilePath = filePath;
    bool isTempFile = false;

    try {
      final metadata = await FlacMetadataReader.readMetadata(tagFilePath);
      title = metadata['title'] ?? title;
      artist = metadata['artist'] ?? artist;
      albumName = metadata['album'] ?? albumName;
      trackNumber = _parseTrackNumber(metadata);
      if (metadata['image'] != null && metadata['image']!.isNotEmpty) {
        albumImage = metadata['image']!;
      }
    } catch (e) {
      DebugLogger.logWarning('Metadata', 'Error leyendo metadatos: $e');
    } finally {
      if (isTempFile) {
        final f = File(tagFilePath);
        if (f.existsSync()) f.deleteSync();
      }
    }

    final normData = _normalizeAlbumData(albumName);
    final String cleanAlbumName = normData['name'];
    final int discNumber = normData['disc'];
    final String mainArtist = _getMainArtist(artist);

    final songData = {
      'title': title,
      'artist': artist,
      'album': cleanAlbumName,
      'genre': 'Música',
      'filePath': filePath,
      'track': trackNumber,
      'disc': discNumber,
      'sourceType': sourceType.name,
    };

    void updateDataModel() {
      int existingAlbumIndex = albumList.indexWhere((a) {
        final titleMatch = a.title.toLowerCase() == cleanAlbumName.toLowerCase();
        final artistMatch = _getMainArtist(a.artist).toLowerCase() == mainArtist.toLowerCase();
        return titleMatch && artistMatch;
      });

      if (existingAlbumIndex != -1) {
        bool exists = albumList[existingAlbumIndex].songs.any((s) => s['filePath'] == filePath);
        if (!exists) {
          albumList[existingAlbumIndex].songs.add(songData);
          albumList[existingAlbumIndex].songs.sort((a, b) {
            final discA = a['disc'] as int? ?? 1;
            final discB = b['disc'] as int? ?? 1;
            if (discA != discB) return discA.compareTo(discB);
            return (a['track'] as int).compareTo(b['track'] as int);
          });
        }
      } else {
        albumList.add(AlbumModel(
          title: cleanAlbumName,
          artist: artist,
          image: albumImage,
          songs: [songData],
        ));
      }
    }

    if (updateState) {
      setState(() {
        updateDataModel();
      });
      await _saveAlbumsToPrefs();
    } else {
      updateDataModel();
    }
  }

  Future<void> _loadMusicFilesFromFolder(List<String> filePaths) async {
    int count = 0;
    for (String filePath in filePaths) {
      bool exists = false;
      for (var album in albumList) {
        if (album.songs.any((s) => s['filePath'] == filePath)) {
          exists = true;
          break;
        }
      }

      if (!exists && File(filePath).existsSync()) {
        try {
          await _addFlacOrMusicFile(filePath, updateState: false);
          count++;

          if (count % 5 == 0) {
            await Future.delayed(Duration.zero);
            setState(() {});
          }
        } catch (e) {
          debugPrint('Error cargando archivo $filePath: $e');
        }
      }
    }

    if (count > 0) {
      setState(() {});
      await _saveAlbumsToPrefs();
    }
  }

  Future<void> _handleFolderChanges(List<String> addedFiles, List<String> removedFiles) async {
    for (String removedPath in removedFiles) {
      int albumIndexToRemove = -1;
      int songIndexToRemove = -1;

      for (int a = 0; a < albumList.length; a++) {
        for (int s = 0; s < albumList[a].songs.length; s++) {
          if (albumList[a].songs[s]['filePath'] == removedPath) {
            albumIndexToRemove = a;
            songIndexToRemove = s;
            break;
          }
        }
        if (albumIndexToRemove != -1) break;
      }

      if (albumIndexToRemove != -1) {
        setState(() {
          albumList[albumIndexToRemove].songs.removeAt(songIndexToRemove);

          if (albumList[albumIndexToRemove].songs.isEmpty) {
            albumList.removeAt(albumIndexToRemove);

            if (_currentPlayingAlbumIndex == albumIndexToRemove) {
              _audioPlayer.stop();
              _currentPlayingAlbumIndex = -1;
              _currentSongInAlbumIndex = -1;
              _currentAudioPath = null;
            } else if (_currentPlayingAlbumIndex > albumIndexToRemove) {
              _currentPlayingAlbumIndex--;
            }
          }
        });
      }
    }

    for (String addedPath in addedFiles) {
      if (!File(addedPath).existsSync()) continue;

      bool exists = false;
      for (var album in albumList) {
        if (album.songs.any((s) => s['filePath'] == addedPath)) {
          exists = true;
          break;
        }
      }

      if (!exists) {
        try {
          await _addFlacOrMusicFile(addedPath);
        } catch (e) {
          debugPrint('Error agregando archivo $addedPath: $e');
        }
      }
    }

    await _saveAlbumsToPrefs();
  }

  Future<void> _deleteSong(int albumIndex, int songIndex) async {
    final song = albumList[albumIndex].songs[songIndex];
    final path = song['filePath'] ?? '';

    if (path.isNotEmpty && File(path).existsSync()) {
      try {
        await File(path).delete();
      } catch (e) {
        debugPrint('Error al borrar el archivo en disco: $e');
      }
    }

    setState(() {
      albumList[albumIndex].songs.removeAt(songIndex);

      if (albumList[albumIndex].songs.isEmpty) {
        albumList.removeAt(albumIndex);
        if (_currentPlayingAlbumIndex == albumIndex) {
          _audioPlayer.stop();
          _currentPlayingAlbumIndex = -1;
          _currentSongInAlbumIndex = -1;
          _currentAudioPath = null;
        } else if (_currentPlayingAlbumIndex > albumIndex) {
          _currentPlayingAlbumIndex--;
        }
      } else if (_currentPlayingAlbumIndex == albumIndex) {
        if (_currentSongInAlbumIndex == songIndex) {
          _audioPlayer.stop();
          _currentSongInAlbumIndex = -1;
          _currentAudioPath = null;
        } else if (_currentSongInAlbumIndex > songIndex) {
          _currentSongInAlbumIndex--;
        }
      }
    });

    await _saveAlbumsToPrefs();
  }

  Future<void> _deleteAlbum(int albumIndex) async {
    final album = albumList[albumIndex];

    for (var song in album.songs) {
      final path = song['filePath'] ?? '';
      if (path.isNotEmpty && File(path).existsSync()) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }

    setState(() {
      albumList.removeAt(albumIndex);

      if (_currentPlayingAlbumIndex == albumIndex) {
        _audioPlayer.stop();
        _currentPlayingAlbumIndex = -1;
        _currentSongInAlbumIndex = -1;
        _currentAudioPath = null;
      } else if (_currentPlayingAlbumIndex > albumIndex) {
        _currentPlayingAlbumIndex--;
      }
    });

    await _saveAlbumsToPrefs();
  }

  Future<bool> _showConfirmDeleteDialog({
    required String title,
    required String content,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF222224),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(content, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _processDownloadedMusic(File musicFile) async {
    final filePath = musicFile.path;
    final extension = p.extension(filePath).toLowerCase();

    String title = p.basenameWithoutExtension(filePath);
    String artist = 'Artista Desconocido';
    String albumName = extension == '.mp3' ? 'Descargas MP3' : 'Descargas FLAC';
    String albumImage = 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=500&fit=crop';
    int trackNumber = 0;

    DebugLogger.logInfo('UI', 'Procesando archivo descargado ($extension): $filePath');

    try {
      final metadata = await FlacMetadataReader.readMetadata(filePath);
      title = metadata['title'] ?? title;
      artist = metadata['artist'] ?? artist;
      albumName = metadata['album'] ?? albumName;
      trackNumber = _parseTrackNumber(metadata);

      if (metadata['image'] != null && metadata['image']!.isNotEmpty) {
        albumImage = metadata['image']!;
      }

      DebugLogger.logSuccess('UI', 'Metadatos procesados: $title - $artist (Track: $trackNumber)');
    } catch (e) {
      DebugLogger.logError('UI', 'Error leyendo metadatos', e);
    }

    final normData = _normalizeAlbumData(albumName);
    final String cleanAlbumName = normData['name'];
    final int discNumber = normData['disc'];

    int existingAlbumIndex = albumList.indexWhere((a) {
      return a.title.toLowerCase() == cleanAlbumName.toLowerCase();
    });

    if (trackNumber == 0 && existingAlbumIndex != -1) {
      final maxTrack = albumList[existingAlbumIndex].songs
          .fold<int>(0, (max, song) {
        final t = song['track'] as int? ?? 0;
        return t > max ? t : max;
      });
      trackNumber = maxTrack + 1;
    } else if (trackNumber == 0) {
      trackNumber = 1;
    }

    final songData = {
      'title': title,
      'artist': artist,
      'album': cleanAlbumName,
      'genre': extension == '.mp3' ? 'MP3 Audio' : 'FLAC Audio',
      'filePath': filePath,
      'track': trackNumber,
      'disc': discNumber,
      'sourceType': AudioSourceType.file.name,
    };

    setState(() {
      if (existingAlbumIndex != -1) {
        bool exists = albumList[existingAlbumIndex].songs.any((s) => s['filePath'] == filePath);
        if (!exists) {
          albumList[existingAlbumIndex].songs.add(songData);
        }
        albumList[existingAlbumIndex].songs.sort((a, b) {
          final discA = a['disc'] as int? ?? 1;
          final discB = b['disc'] as int? ?? 1;
          if (discA != discB) return discA.compareTo(discB);
          return (a['track'] as int).compareTo(b['track'] as int);
        });
      } else {
        albumList.add(AlbumModel(
          title: cleanAlbumName,
          artist: artist,
          image: albumImage,
          songs: [songData],
        ));
      }
    });

    await _saveAlbumsToPrefs();
  }

  Future<void> _selectMusicFolderAction() async {
    final hasPermission = await widget.musicFolderService.requestStoragePermissions();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permisos de almacenamiento denegados')),
        );
      }
      return;
    }

    if (Platform.isIOS) {
      final files = await widget.musicFolderService.selectMusicFiles();
      if (files.isNotEmpty) {
        await _loadMusicFilesFromFolder(files);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${files.length} canciones agregadas')),
          );
        }
      }
      return;
    }

    final selectedPath = await widget.musicFolderService.selectMusicFolder();
    if (selectedPath != null) {
      final files = await widget.musicFolderService.scanMusicFolder();
      await _loadMusicFilesFromFolder(files);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Carpeta vinculada: ${p.basename(selectedPath)}')),
        );
      }
    }
  }

  // 🌟 MÉTODO UNIFICADO DE REPRODUCCIÓN (Construye la cola global)
  Future<void> _playSong(int albumIndex, int songIndex) async {
    if (albumList.isEmpty) return;
    if (albumIndex < 0 || albumIndex >= albumList.length) return;
    if (songIndex < 0 || songIndex >= albumList[albumIndex].songs.length) return;

    try {
      final List<MediaItem> allMediaItems = [];
      final List<AudioSource> allAudioSources = [];
      int targetGlobalIndex = 0;

      // Construir cola global de TODOS los álbumes y canciones
      for (int a = 0; a < albumList.length; a++) {
        final album = albumList[a];
        for (int s = 0; s < album.songs.length; s++) {
          final song = album.songs[s];
          final path = song['filePath'] ?? '';
          final sourceType = song['sourceType'] as String?;

          if (a == albumIndex && s == songIndex) {
            targetGlobalIndex = allMediaItems.length;
          }

          AudioSource source;
          if (sourceType == AudioSourceType.asset.name) {
            source = AudioSource.asset(path);
          } else if (sourceType == AudioSourceType.network.name) {
            source = AudioSource.uri(Uri.parse(path));
          } else {
            source = AudioSource.uri(Uri.file(path));
          }
          allAudioSources.add(source);

          allMediaItems.add(MediaItem(
            id: path,
            album: album.title,
            title: song['title'] ?? 'Sin título',
            artist: song['artist'] ?? album.artist,
            artUri: Uri.parse(album.image.startsWith('http') ? album.image : 'file://${album.image}'),
          ));
        }
      }

      final playlist = ConcatenatingAudioSource(
        useLazyPreparation: true, // Vital para rendimiento con muchas canciones
        children: allAudioSources,
      );

      await AudioSession.instance.then((s) => s.setActive(true));

      // Sincronizar just_audio + audio_service de una sola vez
      await audioHandler.setFullQueue(
        queueItems: allMediaItems,
        playlist: playlist,
        initialIndex: targetGlobalIndex,
      );

      if (!mounted) return;
      setState(() {
        _currentPlayingAlbumIndex = albumIndex;
        _currentSongInAlbumIndex = songIndex;
        _currentAudioPath = albumList[albumIndex].songs[songIndex]['filePath'];
        _position = Duration.zero;
        _isPlaying = false;
      });

      await _audioPlayer.play();

      if (mounted) {
        setState(() => _isPlaying = _audioPlayer.playing);
      }
    } catch (e, stack) {
      DebugLogger.logError('AudioPlayer', 'Error al reproducir', e);
      DebugLogger.log('Stack: $stack');
      if (mounted) {
        setState(() => _isPlaying = false);
      }
    }
  }

  // 🌟 Delegamos la navegación a audio_service (nativo y seguro en background)
  Future<void> _playPreviousSong() async {
    await audioHandler.skipToPrevious();
  }

  Future<void> _playNextSongManual() async {
    await audioHandler.skipToNext();
  }

  Future<void> _togglePlayPause() async {
    if (_currentAudioPath == null || _currentPlayingAlbumIndex == -1) {
      int page = _getCurrentPageIndex();
      if (albumList.isNotEmpty && albumList[page].songs.isNotEmpty) {
        await _playSong(page, 0);
      }
      return;
    }

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
    if (mounted) {
      setState(() => _isPlaying = _audioPlayer.playing);
    }
  }

  int _getCurrentPageIndex() {
    if (!_pageController.hasClients || !_pageController.position.haveDimensions) {
      return 0;
    }
    return _pageController.page?.round().clamp(0, albumList.isEmpty ? 0 : albumList.length - 1) ?? 0;
  }

  String _getMainArtist(String artist) {
    final regex = RegExp(r'[,;&]|feat\.?|with|(?<=\s)y(?=\s)', caseSensitive: false);
    String mainArtist = artist.split(regex).first.trim();
    return mainArtist.isEmpty ? artist : mainArtist;
  }

  Map<String, dynamic> _normalizeAlbumData(String albumName) {
    String cleanName = albumName.trim();
    final discRegex = RegExp(
        r'[(\[\s\-/]*(?:Disc|Disco|CD|Lado|Side|Vol|Volume|Part|Parte|Pt)\s*(\d+|[A-Z])[\s)\]]*$',
        caseSensitive: false);

    int discNumber = 1;
    final discMatch = discRegex.firstMatch(cleanName);
    if (discMatch != null) {
      String discStr = discMatch.group(1) ?? '1';
      if (RegExp(r'^[A-Z]$', caseSensitive: false).hasMatch(discStr)) {
        discNumber = discStr.toUpperCase().codeUnitAt(0) - 64;
      } else {
        discNumber = int.tryParse(discStr) ?? 1;
      }
      cleanName = cleanName.substring(0, discMatch.start).trim();
    }

    final editionRegex = RegExp(
        r'[(\[\s\-/]*(?:Deluxe|Expanded|Remastered|Special|Anniversary|Collector|Bonus|Standard|Original|Soundtrack|OST).*(?:Edition|Version|Ver|Ed|Master|Mix|Release|Issue)*[\s)\]]*$',
        caseSensitive: false);
    cleanName = cleanName.replaceFirst(editionRegex, '').trim();
    cleanName = cleanName.replaceAll(RegExp(r'[\s\-\[({,:;]+$'), '').trim();

    return {'name': cleanName.isEmpty ? albumName : cleanName, 'disc': discNumber};
  }

  int _parseTrackNumber(Map<dynamic, dynamic> metadata) {
    final keys = ['track', 'trackNumber', 'tracknumber', 'TRCK', 'track_number'];
    String? trackStr;
    String? foundKey;

    for (var key in keys) {
      if (metadata.containsKey(key) && metadata[key] != null && metadata[key].toString().trim().isNotEmpty) {
        trackStr = metadata[key].toString();
        foundKey = key;
        break;
      }
    }

    if (trackStr == null || trackStr.trim().isEmpty) {
      DebugLogger.logWarning('TrackParser', 'No se encontró número de pista. Claves disponibles: ${metadata.keys}');
      return 0;
    }

    DebugLogger.logInfo('TrackParser', 'Encontrada clave "$foundKey" con el valor crudo: "$trackStr"');

    String t = trackStr.trim();

    if (t.contains('/')) {
      t = t.split('/').first.trim();
      DebugLogger.logInfo('TrackParser', 'Formato múltiple detectado. Valor extraído: "$t"');
    }

    t = t.replaceAll(RegExp(r'[^0-9]'), '');
    DebugLogger.logInfo('TrackParser', 'Valor después de limpiar: "$t"');

    int finalTrack = int.tryParse(t) ?? 0;

    if (finalTrack == 0) {
      DebugLogger.logWarning('TrackParser', 'Fallo al convertir "$t" a número. Se asignó 0.');
    } else {
      DebugLogger.logSuccess('TrackParser', 'Track interpretado correctamente como: $finalTrack');
    }

    return finalTrack;
  }

  Future<Color> _getDominantColor(String imageSource) async {
    try {
      ImageProvider provider;
      if (imageSource.startsWith('http')) {
        provider = NetworkImage(imageSource);
      } else if (imageSource.isNotEmpty && File(imageSource).existsSync()) {
        provider = FileImage(File(imageSource));
      } else {
        return const Color(0xFF1F1C2C);
      }

      final palette = await PaletteGenerator.fromImageProvider(
        provider,
        maximumColorCount: 10,
        size: const Size(40, 40),
      ).timeout(const Duration(milliseconds: 800));
      return palette.dominantColor?.color ?? const Color(0xFF1F1C2C);
    } catch (e) {
      return const Color(0xFF1F1C2C);
    }
  }

  void _closeLyricsOrTracklist() {
    if (_showLyricsView || _showTracklistView) {
      final targetPage = _showTracklistView
          ? _selectedTracklistAlbumIndex
          : (_currentPlayingAlbumIndex != -1 ? _currentPlayingAlbumIndex : _getCurrentPageIndex());

      setState(() {
        _showLyricsView = false;
        _showTracklistView = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(targetPage);
        }
      });
    }
  }

  final ScreenshotController _screenshotController = ScreenshotController();

  void _showShareSongCard({
    required String songTitle,
    required String artistName,
    required String albumTitle,
    required String albumImage,
    Color dominantColor = const Color(0xFF1F1C2C),
  }) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black.withOpacity(0.75),
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (ctx, anim1, anim2) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            if (dominantColor.value == const Color(0xFF1F1C2C).value) {
              _getDominantColor(albumImage).then((color) {
                if (color.value != dominantColor.value && ctx.mounted) {
                  setModalState(() {
                    dominantColor = color;
                  });
                }
              });
            }

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
              child: Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Screenshot(
                        controller: _screenshotController,
                        child: Container(
                          color: Colors.transparent,
                          child: RepaintBoundary(
                            key: _shareCardKey,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(28),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(24),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(28),
                                  gradient: LinearGradient(
                                    colors: [
                                      dominantColor.withOpacity(0.95),
                                      dominantColor.withOpacity(0.6),
                                      Colors.black.withOpacity(0.9),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.12),
                                    width: 1.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.6),
                                      blurRadius: 30,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 15),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(14),
                                            border: Border.all(
                                              color: Colors.white.withOpacity(0.2),
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              ClipRRect(
                                                borderRadius: BorderRadius.circular(6),
                                                child: Image.asset(
                                                  'assets/ojo.gif',
                                                  width: 16,
                                                  height: 16,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (context, error, stackTrace) =>
                                                  const Icon(Icons.remove_red_eye, color: Colors.white, size: 14),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              const Text(
                                                'BIN Music',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 0.8,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 24),
                                    Center(
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Container(
                                            width: 210,
                                            height: 210,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(20),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: dominantColor.withOpacity(0.4),
                                                  blurRadius: 45,
                                                  spreadRadius: 8,
                                                ),
                                                BoxShadow(
                                                  color: Colors.black.withOpacity(0.7),
                                                  blurRadius: 25,
                                                  offset: const Offset(0, 12),
                                                ),
                                              ],
                                            ),
                                          ),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(20),
                                            child: SizedBox(
                                              width: 220,
                                              height: 220,
                                              child: _buildAlbumImage(albumImage),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 26),
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                songTitle,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 21,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: -0.5,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                artistName,
                                                style: TextStyle(
                                                  color: Colors.white.withOpacity(0.8),
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                albumTitle,
                                                style: TextStyle(
                                                  color: Colors.white.withOpacity(0.45),
                                                  fontSize: 12,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(16),
                                            onTap: () async {
                                              final imageUint8List = await _screenshotController.capture(
                                                delay: const Duration(milliseconds: 150),
                                              );
                                              if (imageUint8List != null) {
                                                final tempDir = await getTemporaryDirectory();
                                                final file = File('${tempDir.path}/share_track.png');
                                                await file.writeAsBytes(imageUint8List);
                                                await Share.shareXFiles(
                                                  [XFile(file.path, mimeType: 'image/png')],
                                                  text: '¡Escuchando "$songTitle" de $artistName en BIN Music! 🎵',
                                                );
                                                if (ctx.mounted) Navigator.pop(ctx);
                                              }
                                            },
                                            child: Container(
                                              padding: const EdgeInsets.all(12),
                                              decoration: BoxDecoration(
                                                color: Colors.white.withOpacity(0.12),
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(
                                                  color: Colors.white.withOpacity(0.2),
                                                  width: 1,
                                                ),
                                              ),
                                              child: const Icon(
                                                Icons.ios_share_rounded,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
      transitionBuilder: (ctx, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
            ),
            child: child,
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60);
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  String _formatRemainingDuration(Duration current, Duration total) {
    final remaining = total - current;
    if (remaining.isNegative) return '-0:00';
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = remaining.inMinutes.remainder(60);
    final seconds = twoDigits(remaining.inSeconds.remainder(60));
    return '-$minutes:$seconds';
  }

  Widget _buildAlbumImage(String imageSource) {
    if (imageSource.startsWith('http')) {
      return Image.network(
        imageSource,
        fit: BoxFit.cover,
        cacheWidth: 300,
        errorBuilder: (context, error, stackTrace) => _fallbackCover(),
      );
    } else {
      return Image.file(
        File(imageSource),
        fit: BoxFit.cover,
        cacheWidth: 300,
        errorBuilder: (context, error, stackTrace) => _fallbackCover(),
      );
    }
  }

  Widget _fallbackCover() {
    return Container(
      color: Colors.grey[900],
      child: const Icon(Icons.music_note, size: 40, color: Colors.white38),
    );
  }

  Widget _buildAnimatedAlbumCard(int index, double currentPage) {
    final album = albumList[index];
    final double difference = index - currentPage;
    final double absDiff = difference.abs();

    final double progress = absDiff.clamp(0.0, 1.0);

    final double rotationAngle = difference == 0 ? 0 : 1.1 * difference.sign * progress;
    final double translationX = difference * 115.0;
    final double translationZ = progress * -75.0;

    final double scale = 1.0 - (progress * 0.15);
    final double dimFactor = 1.0 - (progress * 0.4);

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0018)
        ..translate(translationX, 0.0, translationZ)
        ..rotateY(rotationAngle)
        ..scale(scale),
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix([
          dimFactor, 0, 0, 0, 0,
          0, dimFactor, 0, 0, 0,
          0, 0, dimFactor, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: SizedBox(
          width: 220,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.6),
                        blurRadius: 16,
                        spreadRadius: -2,
                        offset: Offset(difference * -5.0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: _buildAlbumImage(album.image),
                  ),
                ),
              ),
              ClipRect(
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ShaderMask(
                    shaderCallback: (rect) {
                      return const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.white30, Colors.transparent],
                        stops: [0.0, 0.85],
                      ).createShader(rect);
                    },
                    blendMode: BlendMode.dstIn,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..scale(1.0, -1.0),
                      child: AspectRatio(
                        aspectRatio: 1.0,
                        child: _buildAlbumImage(album.image),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    int backgroundIndex = 0;
    if (_currentPlayingAlbumIndex != -1) {
      backgroundIndex = _currentPlayingAlbumIndex;
    } else if (albumList.isNotEmpty) {
      backgroundIndex = _getCurrentPageIndex();
    }

    AlbumModel? activeAlbum = albumList.isNotEmpty ? albumList[backgroundIndex] : null;

    String currentTitle = 'Sin canción';
    String currentArtist = 'Desconocido';
    String currentAlbumName = '';
    String currentImage = '';

    if (_currentPlayingAlbumIndex != -1 &&
        _currentSongInAlbumIndex != -1 &&
        _currentPlayingAlbumIndex < albumList.length &&
        _currentSongInAlbumIndex < albumList[_currentPlayingAlbumIndex].songs.length) {
      final currentSong = albumList[_currentPlayingAlbumIndex].songs[_currentSongInAlbumIndex];
      currentTitle = currentSong['title'] ?? 'Sin título';
      currentArtist = currentSong['artist'] ?? albumList[_currentPlayingAlbumIndex].artist;
      currentAlbumName = albumList[_currentPlayingAlbumIndex].title;
      currentImage = albumList[_currentPlayingAlbumIndex].image;
    }

    final double maxDurationMs = _duration.inMilliseconds.toDouble();
    final double currentPositionMs = _isSeeking
        ? _dragValue
        : _position.inMilliseconds.toDouble().clamp(0.0, maxDurationMs > 0 ? maxDurationMs : 1.0);

    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity == null) return;

          if (details.primaryVelocity! < -50) {
            if (!_showLyricsView && !_showTracklistView) {
              setState(() {
                _showLyricsView = true;
              });
            }
          } else if (details.primaryVelocity! > 50) {
            _closeLyricsOrTracklist();
          }
        },
        child: Stack(
          children: [
            if (activeAlbum != null)
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 600),
                  child: KeyedSubtree(
                    key: ValueKey<String>(activeAlbum.image),
                    child: Container(
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: activeAlbum.image.startsWith('http')
                              ? NetworkImage(activeAlbum.image) as ImageProvider
                              : FileImage(File(activeAlbum.image)),
                          fit: BoxFit.cover,
                        ),
                      ),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                        child: Container(
                          color: Colors.black.withOpacity(0.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 22),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => AlbumGridScreen(
                                  albums: albumList,
                                  musicFolderService: widget.musicFolderService,
                                  onAddFolder: _selectMusicFolderAction,
                                  onDownloadComplete: _processDownloadedMusic,
                                  onAlbumTap: (index) {
                                    setState(() {
                                      _showLyricsView = false;
                                      _showTracklistView = false;
                                    });
                                    WidgetsBinding.instance.addPostFrameCallback((_) {
                                      if (_pageController.hasClients) {
                                        _pageController.animateToPage(
                                          index,
                                          duration: const Duration(milliseconds: 300),
                                          curve: Curves.easeInOut,
                                        );
                                      }
                                    });
                                  },
                                ),
                              ),
                            );
                          },
                          tooltip: 'Ver biblioteca',
                        ),
                        const Text(
                          'BIN Music',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: albumList.isEmpty
                        ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'No hay música en la biblioteca',
                            style: TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _selectMusicFolderAction,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Vincular carpeta'),
                          ),
                        ],
                      ),
                    )
                        : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 500),
                      transitionBuilder: (Widget child, Animation<double> animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                              CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                            ),
                            child: child,
                          ),
                        );
                      },
                      child: _showLyricsView
                          ? Container(
                        key: const ValueKey('lyrics_view'),
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        child: LyricsBottomSheet(
                          trackName: currentTitle,
                          artistName: currentArtist,
                          albumName: currentAlbumName,
                          duration: _duration,
                          positionStream: _audioPlayer.positionStream,
                          player: _audioPlayer,
                          onClose: () => setState(() => _showLyricsView = false),
                        ),
                      )
                          : _showTracklistView
                          ? Container(
                        key: const ValueKey('tracklist_view'),
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        child: TracklistView(
                          album: albumList[_selectedTracklistAlbumIndex],
                          isCurrentAlbum: _selectedTracklistAlbumIndex == _currentPlayingAlbumIndex,
                          currentSongInAlbumIndex: _currentSongInAlbumIndex,
                          isPlaying: _isPlaying,
                          onSongTap: (idx) async {
                            await _playSong(_selectedTracklistAlbumIndex, idx);
                          },
                          onClose: () {
                            setState(() {
                              _showTracklistView = false;
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(_selectedTracklistAlbumIndex);
                              }
                            });
                          },
                          onDeleteAlbum: () async {
                            final confirm = await _showConfirmDeleteDialog(
                              title: 'Eliminar álbum',
                              content: '¿Estás seguro de que deseas eliminar "${albumList[_selectedTracklistAlbumIndex].title}"?',
                            );
                            if (confirm) {
                              int idx = _selectedTracklistAlbumIndex;
                              setState(() => _showTracklistView = false);
                              await _deleteAlbum(idx);
                            }
                          },
                          onDeleteSong: (idx) async {
                            final song = albumList[_selectedTracklistAlbumIndex].songs[idx];
                            final confirm = await _showConfirmDeleteDialog(
                              title: 'Eliminar canción',
                              content: '¿Deseas eliminar "${song['title'] ?? 'esta canción'}"?',
                            );
                            if (confirm) {
                              await _deleteSong(_selectedTracklistAlbumIndex, idx);
                              if (albumList.length > _selectedTracklistAlbumIndex && albumList[_selectedTracklistAlbumIndex].songs.isNotEmpty) {
                                setState(() {});
                              } else {
                                setState(() => _showTracklistView = false);
                              }
                            }
                          },
                        ),
                      )
                          : AnimatedBuilder(
                        key: const ValueKey('album_view'),
                        animation: _pageController,
                        builder: (context, child) {
                          double page = _pageController.hasClients && _pageController.position.haveDimensions ? _pageController.page ?? 0.0 : 0.0;

                          List<int> sortedIndices = List.generate(albumList.length, (i) => i);
                          sortedIndices.sort((a, b) {
                            double distA = (page - a).abs();
                            double distB = (page - b).abs();
                            return distB.compareTo(distA);
                          });

                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              ...sortedIndices.map((i) {
                                return Center(
                                  child: _buildAnimatedAlbumCard(i, page),
                                );
                              }),
                              Positioned.fill(
                                child: PageView.builder(
                                  controller: _pageController,
                                  physics: const BouncingScrollPhysics(),
                                  itemCount: albumList.length,
                                  itemBuilder: (context, index) {
                                    return GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTap: () {
                                        int activePage = page.round();
                                        if (index == activePage) {
                                          setState(() {
                                            _selectedTracklistAlbumIndex = index;
                                            _showTracklistView = true;
                                            _showLyricsView = false;
                                          });
                                        } else {
                                          _pageController.animateToPage(
                                            index,
                                            duration: const Duration(milliseconds: 280),
                                            curve: Curves.easeOutCubic,
                                          );
                                        }
                                      },
                                      child: const SizedBox.expand(),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  if (albumList.isNotEmpty && (currentTitle != 'Sin canción' || _showLyricsView || _showTracklistView))
                    GestureDetector(
                      onTap: () {
                        if (_showLyricsView || _showTracklistView) {
                          _closeLyricsOrTracklist();
                        } else {
                          setState(() => _showLyricsView = true);
                        }
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16.0),
                        child: Center(
                          child: Icon(
                            _showLyricsView || _showTracklistView ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                            color: Colors.white.withOpacity(0.3),
                            size: 40,
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              if (_showLyricsView || _showTracklistView) {
                                _closeLyricsOrTracklist();
                              } else if (currentTitle != 'Sin canción') {
                                setState(() => _showLyricsView = true);
                              }
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentTitle,
                                  style: const TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  currentArtist,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.white.withOpacity(0.7),
                                    letterSpacing: -0.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 6),
                                if (currentAlbumName.isNotEmpty)
                                  Text(
                                    'From: "$currentAlbumName"',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w400,
                                      color: Colors.white.withOpacity(0.45),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.share_rounded, color: Colors.white, size: 24),
                          onPressed: () {
                            if (albumList.isEmpty || currentTitle == 'Sin canción') {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Reproduce una canción primero para compartirla')),
                              );
                              return;
                            }

                            _showShareSongCard(
                              songTitle: currentTitle,
                              artistName: currentArtist,
                              albumTitle: currentAlbumName,
                              albumImage: currentImage,
                            );
                          },
                          tooltip: 'Compartir canción BIN Music',
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28.0),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: SliderComponentShape.noOverlay,
                            activeTrackColor: Colors.white.withOpacity(0.85),
                            inactiveTrackColor: Colors.white.withOpacity(0.2),
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            min: 0.0,
                            max: maxDurationMs > 0 ? maxDurationMs : 1.0,
                            value: currentPositionMs.clamp(0.0, maxDurationMs > 0 ? maxDurationMs : 1.0),
                            onChangeStart: (value) {
                              setState(() {
                                _isSeeking = true;
                                _dragValue = value;
                              });
                            },
                            onChanged: (value) {
                              setState(() {
                                _dragValue = value;
                              });
                              _audioPlayer.seek(Duration(milliseconds: value.toInt()));
                            },
                            onChangeEnd: (value) async {
                              final newPosition = Duration(milliseconds: value.toInt());
                              await _audioPlayer.seek(newPosition);
                              setState(() {
                                _position = newPosition;
                                _isSeeking = false;
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_isSeeking
                                  ? Duration(milliseconds: _dragValue.toInt())
                                  : _position),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withOpacity(0.5),
                                  fontWeight: FontWeight.w500),
                            ),
                            Text(
                              _formatRemainingDuration(
                                _isSeeking ? Duration(milliseconds: _dragValue.toInt()) : _position,
                                _duration,
                              ),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withOpacity(0.5),
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 42,
                        icon: const Icon(Icons.fast_rewind_rounded, color: Colors.white),
                        onPressed: albumList.isEmpty ? null : _playPreviousSong,
                      ),
                      const SizedBox(width: 32),
                      IconButton(
                        iconSize: 52,
                        icon: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                        onPressed: albumList.isEmpty ? null : _togglePlayPause,
                      ),
                      const SizedBox(width: 32),
                      IconButton(
                        iconSize: 42,
                        icon: const Icon(Icons.fast_forward_rounded, color: Colors.white),
                        onPressed: albumList.isEmpty ? null : _playNextSongManual,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// PANTALLA DE BIBLIOTECA (GRILLA DE ÁLBUMES)
// ---------------------------------------------------------
class AlbumGridScreen extends StatefulWidget {
  final List<AlbumModel> albums;
  final Function(int) onAlbumTap;
  final MusicFolderService musicFolderService;
  final VoidCallback onAddFolder;
  final Function(File) onDownloadComplete;

  const AlbumGridScreen({
    super.key,
    required this.albums,
    required this.onAlbumTap,
    required this.musicFolderService,
    required this.onAddFolder,
    required this.onDownloadComplete,
  });

  @override
  State<AlbumGridScreen> createState() => _AlbumGridScreenState();
}

class _AlbumGridScreenState extends State<AlbumGridScreen> {
  Widget _buildGridImage(String imageSource) {
    if (imageSource.startsWith('http')) {
      return Image.network(imageSource, fit: BoxFit.cover);
    } else if (imageSource.isNotEmpty && File(imageSource).existsSync()) {
      return Image.file(File(imageSource), fit: BoxFit.cover);
    } else {
      return Container(
        color: Colors.grey[900],
        child: const Icon(Icons.music_note, color: Colors.white24, size: 40),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'BIBLIOTECA',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, color: Colors.white, size: 24),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => FlacWebBrowserScreen(
                    musicFolderService: widget.musicFolderService,
                    onDownloadComplete: (flacFile) async {
                      await widget.onDownloadComplete(flacFile);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              );
            },
            tooltip: 'Navegar a Flac Downloader Web',
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 24),
            onPressed: widget.onAddFolder,
            tooltip: 'Vincular carpeta de música',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: widget.albums.isEmpty
          ? const Center(
        child: Text(
          'No hay música en la biblioteca',
          style: TextStyle(color: Colors.white38),
        ),
      )
          : GridView.builder(
        padding: const EdgeInsets.all(20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 20,
          mainAxisSpacing: 24,
          childAspectRatio: 0.75,
        ),
        itemCount: widget.albums.length,
        itemBuilder: (context, index) {
          final album = widget.albums[index];
          return GestureDetector(
            onTap: () {
              widget.onAlbumTap(index);
              Navigator.pop(context);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 15,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _buildGridImage(album.image),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  album.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  album.artist,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------
// COMPONENTE DE LETRAS SINCRONIZADAS
// ---------------------------------------------------------
class LyricsBottomSheet extends StatefulWidget {
  final String trackName;
  final String artistName;
  final String albumName;
  final Duration? duration;
  final Stream<Duration> positionStream;
  final AudioPlayer player;
  final VoidCallback? onClose;

  const LyricsBottomSheet({
    super.key,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.duration,
    required this.positionStream,
    required this.player,
    this.onClose,
  });

  @override
  State<LyricsBottomSheet> createState() => _LyricsBottomSheetState();
}

class _LyricsBottomSheetState extends State<LyricsBottomSheet> {
  List<LrcLine>? _lyrics;
  bool _isLoading = true;
  final ScrollController _scrollController = ScrollController();
  int _currentLineIndex = -1;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  @override
  void didUpdateWidget(LyricsBottomSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackName != widget.trackName) {
      _loadLyrics();
    }
  }

  Future<void> _loadLyrics() async {
    setState(() => _isLoading = true);
    final lyrics = await LyricsService.fetchLyrics(
      trackName: widget.trackName,
      artistName: widget.artistName,
      albumName: widget.albumName,
      durationSeconds: widget.duration?.inSeconds,
    );
    if (mounted) {
      setState(() {
        _lyrics = lyrics;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.white70))
                : _lyrics == null || _lyrics!.isEmpty
                ? const Center(child: Text('Letras no disponibles', style: TextStyle(color: Colors.white38)))
                : StreamBuilder<Duration>(
              stream: widget.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;

                int index = _lyrics!.indexWhere((line) => line.timestamp > position) - 1;
                if (index == -2) index = _lyrics!.length - 1;

                if (index != _currentLineIndex && index >= 0) {
                  _currentLineIndex = index;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollController.hasClients) {
                      _scrollController.animateTo(
                        index * 70.0,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  });
                }

                return ListView.builder(
                  controller: _scrollController,
                  itemCount: _lyrics!.length,
                  padding: const EdgeInsets.only(bottom: 200, top: 40),
                  itemBuilder: (context, i) {
                    final isCurrent = i == _currentLineIndex;
                    return GestureDetector(
                      onTap: () => widget.player.seek(_lyrics![i].timestamp),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 70),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        alignment: Alignment.center,
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isCurrent ? Colors.white : Colors.white.withOpacity(0.2),
                            fontSize: isCurrent ? 26 : 18,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                            height: 1.3,
                          ),
                          child: Text(_lyrics![i].text),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// COMPONENTE DE LISTA DE CANCIONES (TRACKLIST)
// ---------------------------------------------------------
class TracklistView extends StatelessWidget {
  final AlbumModel album;
  final bool isCurrentAlbum;
  final int currentSongInAlbumIndex;
  final bool isPlaying;
  final Function(int) onSongTap;
  final VoidCallback onClose;
  final VoidCallback onDeleteAlbum;
  final Function(int) onDeleteSong;

  const TracklistView({
    super.key,
    required this.album,
    required this.isCurrentAlbum,
    required this.currentSongInAlbumIndex,
    required this.isPlaying,
    required this.onSongTap,
    required this.onClose,
    required this.onDeleteAlbum,
    required this.onDeleteSong,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: onClose,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 60,
                      height: 60,
                      child: _buildTracklistImage(album.image),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          album.title,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          album.artist,
                          style: const TextStyle(color: Colors.white60, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded, color: Colors.white54),
                    color: const Color(0xFF222224),
                    onSelected: (value) {
                      if (value == 'delete') onDeleteAlbum();
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                            SizedBox(width: 8),
                            Text('Eliminar álbum', style: TextStyle(color: Colors.redAccent)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: ListView.builder(
              itemCount: album.songs.length,
              padding: const EdgeInsets.only(bottom: 20),
              itemBuilder: (context, idx) {
                final song = album.songs[idx];
                final bool isSelected = isCurrentAlbum && currentSongInAlbumIndex == idx;
                final int trackNum = song['track'] ?? (idx + 1);

                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    leading: SizedBox(
                      width: 30,
                      child: Center(
                        child: isSelected && isPlaying
                            ? const Icon(Icons.volume_up_rounded, color: Colors.white, size: 18)
                            : Text(
                          '$trackNum',
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white38,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    title: Text(
                      song['title'] ?? 'Sin título',
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.white24, size: 18),
                      onPressed: () => onDeleteSong(idx),
                    ),
                    onTap: () => onSongTap(idx),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTracklistImage(String imageSource) {
    if (imageSource.startsWith('http')) {
      return Image.network(imageSource, fit: BoxFit.cover);
    } else if (imageSource.isNotEmpty && File(imageSource).existsSync()) {
      return Image.file(File(imageSource), fit: BoxFit.cover);
    } else {
      return Container(color: Colors.grey[900], child: const Icon(Icons.music_note, color: Colors.white24));
    }
  }
}