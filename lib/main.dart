import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
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

import 'music_folder_service.dart';
import 'music_folder_widget.dart';


late MyAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configurar AudioSession para iOS / Android
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  await session.setActive(true);

  CookieManager cookieManager = CookieManager.instance();
  await cookieManager.deleteAllCookies();

  audioHandler = await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.music_player_app.audio',
      androidNotificationChannelName: 'Reproductor de Música',
      androidNotificationOngoing: true,
    ),
  );

  runApp(const MyApp());
}

// ---------------------------------------------------------
// MANEJADOR DE AUDIO
// ---------------------------------------------------------

enum AudioSourceType { file, asset, network }

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  MyAudioHandler() {
    _initAudioPlayerStreams();
  }

  void _initAudioPlayerStreams() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    
    // Escuchar cambios en la duración para actualizar el MediaItem dinámicamente
    _player.durationStream.listen((d) {
      if (d != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value!.copyWith(duration: d));
      }
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onSongCompleted?.call();
      }
    });
  }

  static VoidCallback? _onSongCompleted;
  static set onSongCompleted(VoidCallback callback) {
    _onSongCompleted = callback;
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
        MediaAction.seek,
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
      queueIndex: 0,
      updateTime: DateTime.now(), // Asegura que iOS sincronice el tiempo actual
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
  Future<void> stop() async {
    await _player.stop();
  }

  void updateCurrentMetadata({
    required String title,
    required String artist,
    required String artUri,
    required String album,
    required String filePath,
    Duration? duration,
  }) {
    mediaItem.add(MediaItem(
      id: filePath,
      album: album,
      title: title,
      artist: artist,
      duration: duration,
      artUri: Uri.parse(artUri.startsWith('http') ? artUri : 'file://$artUri'),
    ));
  }
}

// ---------------------------------------------------------
// SERVICIO DE DESCARGA Y PROCESAMIENTO FLAC
// ---------------------------------------------------------
class FlacDownloadService {
  static Future<File?> processRawBytes({
    required Uint8List bytes,
    required Function(double progress, String status) onProgress,
    String? customDestinationDir,
  }) async {
    Directory? tempFolder;
    try {
      Directory musicFolder;
      // En iOS SIEMPRE usamos la carpeta interna de documentos de la app
      // Intentar crear carpetas en rutas externas (iCloud, carpetas compartidas) falla con "Operation not permitted"
      if (Platform.isIOS || customDestinationDir == null) {
        final appDocDir = await getApplicationDocumentsDirectory();
        musicFolder = Directory(p.join(appDocDir.path, 'MusicLibrary'));
      } else {
        // En Android podemos usar la carpeta vinculada
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

      onProgress(0.90, 'Escribiendo en disco...');

      final tempFilePath = p.join(tempFolderPath, 'payload.tmp');
      final tempFile = File(tempFilePath);
      await tempFile.writeAsBytes(bytes);

      String? targetFlacPath;
      final isZip = _isZipFile(tempFile);

      if (isZip) {
        onProgress(0.93, 'Descomprimiendo archivo...');
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filename = file.name;
          if (file.isFile && p.extension(filename).toLowerCase() == '.flac') {
            final extractedFilePath = p.join(tempFolderPath, p.basename(filename));
            final outFile = File(extractedFilePath);
            await outFile.create(recursive: true);
            await outFile.writeAsBytes(file.content as List<int>);
            targetFlacPath = extractedFilePath;
            break;
          }
        }
      } else {
        targetFlacPath = tempFilePath;
      }

      if (targetFlacPath == null || !File(targetFlacPath).existsSync()) {
        throw Exception('No se encontró un archivo .flac válido en los datos.');
      }

      onProgress(0.98, 'Guardando en la biblioteca...');

      final String finalFileName = 'track_${DateTime.now().millisecondsSinceEpoch}.flac';
      final String finalDestinationPath = p.join(musicFolder.path, finalFileName);
      
      // Usar writeAsBytes en lugar de copy para evitar problemas de permisos cruzados en algunos dispositivos Android
      final bytesToSave = await File(targetFlacPath).readAsBytes();
      final File finalFlacFile = File(finalDestinationPath);
      await finalFlacFile.writeAsBytes(bytesToSave);

      if (await tempFolder.exists()) {
        await tempFolder.delete(recursive: true);
      }

      onProgress(1.0, 'Completado');
      return finalFlacFile;
    } catch (e) {
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
    try {
      final query = 'track_name=${Uri.encodeComponent(trackName)}'
          '&artist_name=${Uri.encodeComponent(artistName)}'
          '&album_name=${Uri.encodeComponent(albumName)}'
          '${durationSeconds != null ? "&duration=$durationSeconds" : ""}';

      final url = Uri.parse('https://lrclib.net/api/get?$query');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final String? syncedLyrics = data['syncedLyrics'];
        
        if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
          return _parseLrc(syncedLyrics);
        }
      }
      
      // Si no encuentra por coincidencia exacta, probar búsqueda general
      final searchUrl = Uri.parse('https://lrclib.net/api/search?q=${Uri.encodeComponent("$trackName $artistName")}');
      final searchResponse = await http.get(searchUrl);
      
      if (searchResponse.statusCode == 200) {
        final List<dynamic> searchData = json.decode(searchResponse.body);
        if (searchData.isNotEmpty) {
          final String? syncedLyrics = searchData[0]['syncedLyrics'];
          if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
            return _parseLrc(syncedLyrics);
          }
        }
      }
    } catch (e) {
      debugPrint('Error obteniendo letras: $e');
    }
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

  final List<int> _chunkBuffer = [];

  Future<void> _extractBlobInChunks(String blobUrl) async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.05;
      _downloadStatus = 'Iniciando lectura de Blob...';
    });

    _chunkBuffer.clear();

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
            var chunkSize = 1024 * 1024;
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
              }, 0);
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
  }

  Future<void> _processBufferedBytes() async {
    try {
      setState(() {
        _downloadProgress = 0.85;
        _downloadStatus = 'Procesando archivo de audio...';
      });

      final flacFile = await FlacDownloadService.processRawBytes(
        bytes: Uint8List.fromList(_chunkBuffer),
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

      _chunkBuffer.clear();

      if (flacFile != null && mounted) {
        widget.onDownloadComplete(flacFile);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Canción agregada a la biblioteca')),
        );
      }
    } catch (e) {
      _chunkBuffer.clear();
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
                  _chunkBuffer.clear();
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
                    _chunkBuffer.addAll(chunkList.cast<int>());
                  }
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'onBlobEnd',
                callback: (args) {
                  _processBufferedBytes();
                },
              );

              controller.addJavaScriptHandler(
                handlerName: 'onBlobError',
                callback: (args) {
                  _chunkBuffer.clear();
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
  double _volume = 0.8;

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

    _audioPlayer.setVolume(_volume);

    // Escuchar el cambio de índice nativo (funciona perfecto en segundo plano en iOS)
    _audioPlayer.currentIndexStream.listen((index) {
      if (index != null &&
          _currentPlayingAlbumIndex != -1 &&
          _currentPlayingAlbumIndex < albumList.length) {
        final album = albumList[_currentPlayingAlbumIndex];
        if (index < album.songs.length) {
          final song = album.songs[index];
          setState(() {
            _currentSongInAlbumIndex = index;
            _currentAudioPath = song['filePath'];
          });

          audioHandler.updateCurrentMetadata(
            title: song['title'] ?? 'Sin título',
            artist: song['artist'] ?? album.artist,
            artUri: album.image,
            album: album.title,
            filePath: song['filePath'] ?? '',
          );
        }
      }
    });

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
        setState(() {
          _isPlaying = state.playing;
        });
      }

      // Detectar el fin de la cola nativa
      if (state.processingState == ProcessingState.completed) {
        _playNextAlbum();
      }
    });

    // --- Configurar el servicio de carpeta ---
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

    // Escaneo inicial si ya hay una carpeta
    final currentFolder = widget.musicFolderService.getCurrentMusicFolder();
    if (currentFolder != null) {
      widget.musicFolderService.scanMusicFolder().then((files) {
        if (files.isNotEmpty) _loadMusicFilesFromFolder(files);
      });
    }
    // ------------------------------------------

    _initAppStartup();

    Future.delayed(Duration.zero, () {
      _resumePlaybackIfNeeded();
    });

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

          // Mover el PageView al álbum que está sonando actualmente
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
      // Sincronizar UI con la reproducción activa
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
          _playSongInAlbum(_currentPlayingAlbumIndex, _currentSongInAlbumIndex);
        }
      }
    }
  }

  // Variable de bandera a nivel de clase para evitar que se dispare múltiples veces
  bool _isTransitioningAlbum = false;

  Future<void> _playNextAlbum() async {
    if (albumList.isEmpty || _currentPlayingAlbumIndex == -1) return;
    if (_isTransitioningAlbum) return; // Evitar ejecuciones duplicadas

    _isTransitioningAlbum = true;

    try {
      // 1. Detener explícitamente el reproductor para limpiar el decodificador (MediaCodec)
      await _audioPlayer.stop();

      // 2. Darle un pequeñísimo respiro al hilo principal para que el GC de Android actúe
      // sin interrumpir el nuevo audio (evita el "trabón")
      await Future.delayed(const Duration(milliseconds: 300));

      int nextAlbumIndex = _currentPlayingAlbumIndex + 1;

      if (nextAlbumIndex >= albumList.length) {
        nextAlbumIndex = 0;
      }

      if (albumList[nextAlbumIndex].songs.isNotEmpty) {
        await _playSongInAlbum(nextAlbumIndex, 0);
      }
    } finally {
      _isTransitioningAlbum = false;
    }
  }

  // ------------------------------------------------------------
  // Métodos existentes (todos implementados)
  // ------------------------------------------------------------
  Future<void> _initAppStartup() async {
    await _loadSavedAlbums();
    await _scanAssetsForMusic();
    await _cleanOrphanedSongs();
  }

  Future<void> _scanAssetsForMusic() async {
    try {
      // Intentar cargar el manifiesto de assets
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      final audioPaths = manifestMap.keys
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
        // Verificar si ya existe
        bool exists = false;
        for (var album in albumList) {
          if (album.songs.any((s) => s['filePath'] == path)) {
            exists = true;
            break;
          }
        }

        if (!exists) {
          await _addFlacOrMusicFile(path, sourceType: AudioSourceType.asset);
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

        // Los assets y URLs de red no se consideran huérfanos por falta de archivo local
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

  // ========== MÉTODO GENÉRICO PARA AGREGAR ARCHIVOS ==========
  /// Agrega un archivo de música a la biblioteca (genérico para cualquier formato)
  Future<void> _addFlacOrMusicFile(String filePath, {AudioSourceType sourceType = AudioSourceType.file}) async {
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
      if (sourceType == AudioSourceType.asset) {
        // Para assets, copiamos a un archivo temporal para leer los tags
        final byteData = await rootBundle.load(filePath);
        final file = File('${tempDir.path}/temp_tag_${DateTime.now().microsecondsSinceEpoch}${p.extension(filePath)}');
        await file.writeAsBytes(byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
        tagFilePath = file.path;
        isTempFile = true;
      }

      final tagFile = TagLibFile.open(tagFilePath);
      if (tagFile != null) {
        if (tagFile.title != null && tagFile.title!.isNotEmpty) title = tagFile.title!;
        if (tagFile.artist != null && tagFile.artist!.isNotEmpty) artist = tagFile.artist!;
        if (tagFile.album != null && tagFile.album!.isNotEmpty) albumName = tagFile.album!;
        trackNumber = tagFile.track ?? 0;

        if (tagFile.hasCover) {
          final coverBytes = tagFile.coverData;
          if (coverBytes != null && coverBytes.isNotEmpty) {
            final coverFile = File('${tempDir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
            await coverFile.writeAsBytes(coverBytes);
            albumImage = coverFile.path;
          }
        }
        tagFile.close();
      }
    } catch (e) {
      debugPrint('Aviso: No se pudieron leer los tags de $filePath ($sourceType): $e');
    } finally {
      if (isTempFile) {
        final f = File(tagFilePath);
        if (f.existsSync()) f.deleteSync();
      }
    }

    final songData = {
      'title': title,
      'artist': artist,
      'genre': 'Música',
      'filePath': filePath,
      'track': trackNumber,
      'sourceType': sourceType.name,
    };

    setState(() {
      int existingAlbumIndex = albumList.indexWhere(
            (a) =>
        a.title.toLowerCase() == albumName.toLowerCase() &&
            a.artist.toLowerCase() == artist.toLowerCase(),
      );

      if (existingAlbumIndex != -1) {
        bool exists = albumList[existingAlbumIndex].songs.any((s) => s['filePath'] == filePath);
        if (!exists) {
          albumList[existingAlbumIndex].songs.add(songData);
          albumList[existingAlbumIndex]
              .songs
              .sort((a, b) => (a['track'] as int).compareTo(b['track'] as int));
        }
      } else {
        albumList.add(AlbumModel(
          title: albumName,
          artist: artist,
          image: albumImage,
          songs: [songData],
        ));
      }
    });

    await _saveAlbumsToPrefs();
  }

  // ========== MÉTODOS PARA GESTOR DE CARPETA ==========
  /// Cargar archivos de música desde la carpeta seleccionada
  Future<void> _loadMusicFilesFromFolder(List<String> filePaths) async {
    for (String filePath in filePaths) {
      // Verificar si ya existe la canción en la biblioteca
      bool exists = false;
      for (var album in albumList) {
        if (album.songs.any((s) => s['filePath'] == filePath)) {
          exists = true;
          break;
        }
      }

      if (!exists && File(filePath).existsSync()) {
        try {
          await _addFlacOrMusicFile(filePath);
        } catch (e) {
          debugPrint('Error cargando archivo $filePath: $e');
        }
      }
    }
  }

  /// Manejar cambios en la carpeta (archivos agregados o removidos)
  Future<void> _handleFolderChanges(List<String> addedFiles, List<String> removedFiles) async {
    // Manejar archivos removidos
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

          // Si el álbum quedó sin canciones, eliminarlo
          if (albumList[albumIndexToRemove].songs.isEmpty) {
            albumList.removeAt(albumIndexToRemove);

            // Ajustar índice de reproducción si es necesario
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

    // Manejar archivos agregados
    for (String addedPath in addedFiles) {
      if (!File(addedPath).existsSync()) continue;

      // Verificar si ya existe
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
  // ====================================================

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

  Future<void> _processDownloadedFlac(File flacFile) async {
    final filePath = flacFile.path;
    String title = p.basenameWithoutExtension(filePath);
    String artist = 'Artista Desconocido';
    String albumName = 'Descargas FLAC';
    String albumImage =
        'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=500&fit=crop';
    int trackNumber = 0;

    final tempDir = await getTemporaryDirectory();

    try {
      final tagFile = TagLibFile.open(filePath);
      if (tagFile != null) {
        if (tagFile.title != null && tagFile.title!.isNotEmpty) title = tagFile.title!;
        if (tagFile.artist != null && tagFile.artist!.isNotEmpty) artist = tagFile.artist!;
        if (tagFile.album != null && tagFile.album!.isNotEmpty) albumName = tagFile.album!;
        trackNumber = tagFile.track ?? 0;

        if (tagFile.hasCover) {
          final coverBytes = tagFile.coverData;
          if (coverBytes != null && coverBytes.isNotEmpty) {
            final coverFile =
            File('${tempDir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
            await coverFile.writeAsBytes(coverBytes);
            albumImage = coverFile.path;
          }
        }
        tagFile.close();
      }
    } catch (e) {
      debugPrint('Aviso: No se pudieron leer tags del FLAC: $e');
    }

    final songData = {
      'title': title,
      'artist': artist,
      'genre': 'FLAC Audio',
      'filePath': filePath,
      'track': trackNumber,
    };

    setState(() {
      int existingAlbumIndex = albumList.indexWhere(
            (a) =>
        a.title.toLowerCase() == albumName.toLowerCase() &&
            a.artist.toLowerCase() == artist.toLowerCase(),
      );

      if (existingAlbumIndex != -1) {
        albumList[existingAlbumIndex].songs.add(songData);
        albumList[existingAlbumIndex]
            .songs
            .sort((a, b) => (a['track'] as int).compareTo(b['track'] as int));
      } else {
        albumList.add(AlbumModel(
          title: albumName,
          artist: artist,
          image: albumImage,
          songs: [songData],
        ));
      }
    });

    await _saveAlbumsToPrefs();
  }

  Future<void> _selectMusicFolderAction() async {
    if (Platform.isIOS) {
      // En iOS, el escaneo de carpetas es restringido por el Sandbox.
      // Por eso, usamos directamente el selector de archivos (múltiple).
      try {
        List<PlatformFile> result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['flac', 'mp3', 'm4a', 'wav', 'aac'],
          allowMultiple: true,
        );

        if (result.isNotEmpty) {
          final List<String> validPaths = result.map((e) => e.path).whereType<String>().toList();
          await _loadMusicFilesFromFolder(validPaths);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${validPaths.length} canciones importadas')),
            );
          }
        }
      } catch (e) {
        debugPrint('Error en selector iOS: $e');
      }
    } else {
      // Android: Flujo normal de vinculación de carpeta
      final hasPermission = await widget.musicFolderService.requestStoragePermissions();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permisos de almacenamiento denegados')),
          );
        }
        return;
      }

      final selectedPath = await widget.musicFolderService.selectMusicFolder();
      if (selectedPath != null) {
        final files = await widget.musicFolderService.scanMusicFolder();
        _loadMusicFilesFromFolder(files);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Carpeta vinculada: ${p.basename(selectedPath)}')),
          );
        }
      }
    }
  }

  Future<void> _playSongInAlbum(int albumIndex, int songIndex) async {
    if (albumList.isEmpty) return;

    try {
      if (albumIndex < 0 || albumIndex >= albumList.length) return;
      var album = albumList[albumIndex];

      if (album.songs.isEmpty) return;
      if (songIndex < 0 || songIndex >= album.songs.length) return;

      // 1. Crear una lista de fuentes de audio concatenadas (Queue Nativa)
      final playlist = ConcatenatingAudioSource(
        useLazyPreparation: true,
        children: album.songs.map((song) {
          final path = song['filePath'] ?? '';
          final sourceTypeName = song['sourceType'] as String?;

          if (sourceTypeName == AudioSourceType.asset.name) {
            return AudioSource.asset(path);
          } else if (sourceTypeName == AudioSourceType.network.name) {
            return AudioSource.uri(Uri.parse(path));
          } else {
            return AudioSource.file(path);
          }
        }).toList(),
      );

      final song = album.songs[songIndex];
      String path = song['filePath'] ?? '';
      String songTitle = song['title'] ?? 'Sin título';
      String songArtist = song['artist'] ?? album.artist;

      setState(() {
        _currentPlayingAlbumIndex = albumIndex;
        _currentSongInAlbumIndex = songIndex;
        _currentAudioPath = path;
        _position = Duration.zero;
        _isPlaying = false;
      });

      audioHandler.updateCurrentMetadata(
        title: songTitle,
        artist: songArtist,
        artUri: album.image,
        album: album.title,
        filePath: path,
      );

      await _audioPlayer.setVolume(_volume);

      // 2. Establecer la playlist nativa en just_audio e indicar el índice inicial
      await _audioPlayer.setAudioSource(
        playlist,
        initialIndex: songIndex,
        initialPosition: Duration.zero,
      );

      await _audioPlayer.play();

      if (mounted) {
        setState(() {
          _isPlaying = _audioPlayer.playing;
        });
      }
    } catch (e) {
      debugPrint('Error al reproducir audio: $e');
      if (mounted) {
        setState(() => _isPlaying = false);
      }
    }
  }

  Future<void> _playNextSongAutomatically() async {
    if (albumList.isEmpty) return;

    // Obtener la canción actual desde la metadata de audio_service o del estado local
    final currentMediaItem = audioHandler.mediaItem.value;
    int currentAlbumIdx = _currentPlayingAlbumIndex;
    int currentSongIdx = _currentSongInAlbumIndex;

    // Si tenemos el id (filePath) en el mediaItem, aseguramos encontrar la posición exacta
    if (currentMediaItem != null) {
      for (int a = 0; a < albumList.length; a++) {
        for (int s = 0; s < albumList[a].songs.length; s++) {
          if (albumList[a].songs[s]['filePath'] == currentMediaItem.id) {
            currentAlbumIdx = a;
            currentSongIdx = s;
            break;
          }
        }
      }
    }

    if (currentAlbumIdx == -1) return;

    final currentAlbum = albumList[currentAlbumIdx];

    // 1. Si hay más canciones en el MISMO álbum, reproducir la siguiente
    if (currentSongIdx + 1 < currentAlbum.songs.length) {
      await _playSongInAlbum(currentAlbumIdx, currentSongIdx + 1);
    }
    // 2. Si se acabaron las canciones de este álbum, pasar al SIGUIENTE álbum que tenga canciones
    else if (currentAlbumIdx + 1 < albumList.length) {
      int nextAlbumIndex = currentAlbumIdx + 1;

      while (nextAlbumIndex < albumList.length && albumList[nextAlbumIndex].songs.isEmpty) {
        nextAlbumIndex++;
      }

      if (nextAlbumIndex < albumList.length) {
        await _playSongInAlbum(nextAlbumIndex, 0);
      } else {
        await _audioPlayer.stop();
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _currentSongInAlbumIndex = -1;
          });
        }
      }
    }
    // 3. Fin de la biblioteca
    else {
      await _audioPlayer.stop();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _currentSongInAlbumIndex = -1;
        });
      }
    }
  }

  Future<void> _playPreviousSong() async {
    if (albumList.isEmpty) return;

    int currentAlbum =
    _currentPlayingAlbumIndex != -1 ? _currentPlayingAlbumIndex : _getCurrentPageIndex();
    int currentSong = _currentSongInAlbumIndex != -1 ? _currentSongInAlbumIndex : 0;

    if (currentSong > 0) {
      await _playSongInAlbum(currentAlbum, currentSong - 1);
    } else if (currentAlbum > 0) {
      int prevAlbum = currentAlbum - 1;
      int lastSongInPrevAlbum = albumList[prevAlbum].songs.length - 1;
      await _playSongInAlbum(prevAlbum, lastSongInPrevAlbum);
    } else {
      await _audioPlayer.seek(Duration.zero);
    }
  }

  Future<void> _playNextSongManual() async {
    if (albumList.isEmpty) return;

    int currentAlbum =
    _currentPlayingAlbumIndex != -1 ? _currentPlayingAlbumIndex : _getCurrentPageIndex();
    int currentSong = _currentSongInAlbumIndex != -1 ? _currentSongInAlbumIndex : 0;

    var album = albumList[currentAlbum];

    if (currentSong < album.songs.length - 1) {
      await _playSongInAlbum(currentAlbum, currentSong + 1);
    } else if (currentAlbum < albumList.length - 1) {
      await _playSongInAlbum(currentAlbum + 1, 0);
    }
  }

  Future<void> _togglePlayPause() async {
    if (_currentAudioPath == null || _currentPlayingAlbumIndex == -1) {
      int page = _getCurrentPageIndex();
      if (albumList.isNotEmpty && albumList[page].songs.isNotEmpty) {
        await _playSongInAlbum(page, 0);
      }
      return;
    }

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
    if (mounted) {
      setState(() {
        _isPlaying = _audioPlayer.playing;
      });
    }
  }

  int _getCurrentPageIndex() {
    if (!_pageController.hasClients || !_pageController.position.haveDimensions) {
      return 0;
    }
    return _pageController.page?.round().clamp(0, albumList.isEmpty ? 0 : albumList.length - 1) ?? 0;
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
            // Cargar color dominante si es el por defecto
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
                        child: RepaintBoundary(
                          key: _shareCardKey,
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
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.graphic_eq_rounded,
                                            color: Colors.white70,
                                            size: 16,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Text(
                                          'NOW PLAYING',
                                          style: TextStyle(
                                            color: Colors.white60,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.5,
                                          ),
                                        ),
                                      ],
                                    ),
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
                                          // Añadir un pequeño retraso (delay) evita capturas en blanco o errores dentro del Dialog
                                          final imageUint8List = await _screenshotController.capture(
                                            delay: const Duration(milliseconds: 150),
                                          );

                                          if (imageUint8List != null) {
                                            final tempDir = await getTemporaryDirectory();
                                            final file = File('${tempDir.path}/share_track.png');
                                            await file.writeAsBytes(imageUint8List);

                                            // Lanza la hoja de compartir ANTES de hacer el pop del contexto
                                            await Share.shareXFiles(
                                              [XFile(file.path)],
                                              text: '¡Escuchando "$songTitle" de $artistName en BIN Music! 🎵',
                                            );

                                            // Cierra el diálogo solo cuando se ha lanzado la acción, verificando que siga montado
                                            if (ctx.mounted) {
                                              Navigator.pop(ctx);
                                            }
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

  void _showAlbumTracklist(int albumIndex) {
    if (albumIndex >= albumList.length) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            if (albumIndex >= albumList.length) return const SizedBox.shrink();
            final album = albumList[albumIndex];

            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF161618),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.65,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: _buildAlbumImage(album.image),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                album.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                album.artist,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert_rounded, color: Colors.white54, size: 22),
                          color: const Color(0xFF222224),
                          onSelected: (value) async {
                            if (value == 'delete') {
                              final confirm = await _showConfirmDeleteDialog(
                                title: 'Eliminar álbum',
                                content:
                                '¿Estás seguro de que deseas eliminar "${album.title}" y todas sus canciones?',
                              );

                              if (confirm) {
                                Navigator.pop(context);
                                await _deleteAlbum(albumIndex);
                              }
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(Icons.delete_outline_rounded,
                                      color: Colors.redAccent, size: 18),
                                  SizedBox(width: 8),
                                  Text('Eliminar álbum',
                                      style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Divider(height: 1, color: Colors.white12),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: album.songs.length,
                      itemBuilder: (context, idx) {
                        final song = album.songs[idx];
                        final bool isSelected =
                            _currentPlayingAlbumIndex == albumIndex && _currentSongInAlbumIndex == idx;
                        final int trackNum = song['track'] ?? 0;

                        return Material(
                          color: Colors.transparent,
                          child: ListTile(
                            key: ValueKey(song['filePath'] ?? idx),
                            dense: true,
                            contentPadding: const EdgeInsets.only(left: 20, right: 4),
                            leading: SizedBox(
                              width: 24,
                              child: Center(
                                child: isSelected && _isPlaying
                                    ? const Icon(Icons.volume_up_rounded, color: Colors.white, size: 20)
                                    : Text(
                                  trackNum > 0 ? '$trackNum' : '${idx + 1}',
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : Colors.white38,
                                    fontSize: 13,
                                    fontWeight:
                                    isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              song['title'] ?? 'Sin título',
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.white70,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song['artist'] ?? album.artist,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 18),
                              color: const Color(0xFF222224),
                              onSelected: (value) async {
                                if (value == 'delete') {
                                  final confirm = await _showConfirmDeleteDialog(
                                    title: 'Eliminar canción',
                                    content:
                                    '¿Deseas eliminar "${song['title'] ?? 'esta canción'}"?',
                                  );

                                  if (confirm) {
                                    await _deleteSong(albumIndex, idx);
                                    if (albumList.length > albumIndex &&
                                        albumList[albumIndex].songs.isNotEmpty) {
                                      setModalState(() {});
                                    } else {
                                      Navigator.pop(context);
                                    }
                                  }
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete_outline_rounded,
                                          color: Colors.redAccent, size: 18),
                                      SizedBox(width: 8),
                                      Text('Eliminar canción',
                                          style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            onTap: () async {
                              Navigator.pop(context);
                              await _playSongInAlbum(albumIndex, idx);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
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
    // Determinar qué álbum mostrar en el fondo (background)
    // Prioridad 1: El álbum que se está reproduciendo actualmente
    // Prioridad 2: El álbum que se está visualizando en el carrusel
    int backgroundIndex = 0;
    if (_currentPlayingAlbumIndex != -1) {
      backgroundIndex = _currentPlayingAlbumIndex;
    } else if (albumList.isNotEmpty) {
      backgroundIndex = _getCurrentPageIndex();
    }

    AlbumModel? activeAlbum = albumList.isNotEmpty ? albumList[backgroundIndex] : null;

    // --- INICIO: LÓGICA MODIFICADA PARA MOSTRAR SOLO LA CANCIÓN EN REPRODUCCIÓN ---
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
    // --- FIN: ya no se usan los datos del álbum activo ---

    final double maxDurationMs = _duration.inMilliseconds.toDouble();
    final double currentPositionMs = _isSeeking
        ? _dragValue
        : _position.inMilliseconds.toDouble().clamp(0.0, maxDurationMs > 0 ? maxDurationMs : 1.0);

    return Scaffold(
      body: Stack(
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
                                onAlbumTap: (index) {
                                  _pageController.animateToPage(
                                    index,
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                  );
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
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.public_rounded, color: Colors.white, size: 26),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => FlacWebBrowserScreen(
                                musicFolderService: widget.musicFolderService,
                                onDownloadComplete: (flacFile) => _processDownloadedFlac(flacFile),
                              ),
                            ),
                          );
                        },
                        tooltip: 'Navegar a Flac Downloader Web',
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 26),
                        onPressed: _selectMusicFolderAction,
                        tooltip: 'Vincular carpeta de música',
                      ),
                    ],
                  ),
                ),
                // ================================================
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
                                        currentPlayingAlbumIndex: _currentPlayingAlbumIndex,
                                        currentSongInAlbumIndex: _currentSongInAlbumIndex,
                                        isPlaying: _isPlaying,
                                        onSongTap: (idx) async {
                                          await _playSongInAlbum(_selectedTracklistAlbumIndex, idx);
                                        },
                                        onClose: () {
                                          setState(() {
                                            _showTracklistView = false;
                                          });
                                          // Sincronizar carrusel
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
                // --- BOTÓN DE LETRAS / CERRAR CENTRADO ---
                if (albumList.isNotEmpty && (currentTitle != 'Sin canción' || _showLyricsView || _showTracklistView))
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Center(
                      child: GestureDetector(
                        onTap: () {
                          if (_showLyricsView || _showTracklistView) {
                            // Al cerrar, asegurarnos de volver al álbum correcto
                            final targetPage = _showTracklistView 
                                ? _selectedTracklistAlbumIndex 
                                : (_currentPlayingAlbumIndex != -1 ? _currentPlayingAlbumIndex : _getCurrentPageIndex());
                            
                            setState(() {
                              _showLyricsView = false;
                              _showTracklistView = false;
                            });

                            // Esperar a que el PageView se monte para hacer el salto
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(targetPage);
                              }
                            });
                          } else {
                            setState(() {
                              _showLyricsView = true;
                            });
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: (_showLyricsView || _showTracklistView) ? Colors.white.withOpacity(0.2) : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: (_showLyricsView || _showTracklistView) ? Colors.white30 : Colors.white10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                (_showLyricsView || _showTracklistView) ? Icons.keyboard_arrow_down_rounded : Icons.lyrics_rounded,
                                color: Colors.white70,
                                size: 14,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                (_showLyricsView || _showTracklistView) ? 'CERRAR' : 'LETRAS',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
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
                          value: currentPositionMs.clamp(
                              0.0, maxDurationMs > 0 ? maxDurationMs : 1.0),
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
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36.0, vertical: 12.0),
                  child: Row(
                    children: [
                      Icon(Icons.volume_down_rounded,
                          color: Colors.white.withOpacity(0.5), size: 18),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            activeTrackColor: Colors.white.withOpacity(0.85),
                            inactiveTrackColor: Colors.white.withOpacity(0.2),
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            value: _volume,
                            onChanged: (val) {
                              setState(() {
                                _volume = val;
                                _audioPlayer.setVolume(_volume);
                              });
                            },
                          ),
                        ),
                      ),
                      Icon(Icons.volume_up_rounded,
                          color: Colors.white.withOpacity(0.5), size: 18),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// PANTALLA DE BIBLIOTECA (GRILLA DE ÁLBUMES)
// ---------------------------------------------------------
class AlbumGridScreen extends StatelessWidget {
  final List<AlbumModel> albums;
  final Function(int) onAlbumTap;

  const AlbumGridScreen({
    super.key,
    required this.albums,
    required this.onAlbumTap,
  });

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
      ),
      body: albums.isEmpty
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
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final album = albums[index];
                return GestureDetector(
                  onTap: () {
                    onAlbumTap(index);
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
  final Stream<Duration> positionStream;
  final AudioPlayer player;
  final VoidCallback? onClose;

  const LyricsBottomSheet({
    super.key,
    required this.trackName,
    required this.artistName,
    required this.albumName,
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
  final int currentPlayingAlbumIndex;
  final int currentSongInAlbumIndex;
  final bool isPlaying;
  final Function(int) onSongTap;
  final VoidCallback onClose;
  final VoidCallback onDeleteAlbum;
  final Function(int) onDeleteSong;

  const TracklistView({
    super.key,
    required this.album,
    required this.currentPlayingAlbumIndex,
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
          Padding(
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
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: ListView.builder(
              itemCount: album.songs.length,
              padding: const EdgeInsets.only(bottom: 20),
              itemBuilder: (context, idx) {
                final song = album.songs[idx];
                // Comprobamos si es la canción que suena
                final bool isSelected = (album.title.toLowerCase() == (song['album'] ?? '').toString().toLowerCase()) && currentSongInAlbumIndex == idx;
                final int trackNum = song['track'] ?? (idx + 1);

                return ListTile(
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
