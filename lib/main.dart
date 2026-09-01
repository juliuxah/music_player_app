import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_taglib/flutter_taglib.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'update_service.dart';

late MyAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  MyAudioHandler() {
    _initAudioPlayerStreams();
  }

  void _initAudioPlayerStreams() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
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
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

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
  }) {
    mediaItem.add(MediaItem(
      id: filePath,  // Cambiado: ahora es la ruta del archivo
      album: album,
      title: title,
      artist: artist,
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
  }) async {
    Directory? tempFolder;
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final musicFolder = Directory(p.join(appDocDir.path, 'MusicLibrary'));
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
      final File finalFlacFile = await File(targetFlacPath).copy(finalDestinationPath);

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
// PANTALLA DE NAVEGACIÓN WEB
// ---------------------------------------------------------
class FlacWebBrowserScreen extends StatefulWidget {
  final Function(File flacFile) onDownloadComplete;

  const FlacWebBrowserScreen({super.key, required this.onDownloadComplete});

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
class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

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
          MaterialPageRoute(builder: (context) => const AlbumCollectionScreen()),
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
  const AlbumCollectionScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(viewportFraction: 0.5, initialPage: 0);
    checkForUpdates(context);

    _audioPlayer.setVolume(_volume);

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
    });

    MyAudioHandler.onSongCompleted = _playNextSongAutomatically;

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

  // ------------------------------------------------------------
  // Métodos existentes (todos implementados)
  // ------------------------------------------------------------
  Future<void> _initAppStartup() async {
    await _loadSavedAlbums();
    await _cleanOrphanedSongs();
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

  Future<void> _pickMusicFiles() async {
    try {
      List<PlatformFile>? files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['flac', 'mp3', 'm4a', 'wav', 'aac', 'ogg'],
        allowMultiple: true,
      );

      if (files == null || files.isEmpty) return;

      final tempDir = await getTemporaryDirectory();

      for (var file in files) {
        final filePath = file.path;
        final fileName = file.name;

        if (filePath != null) {
          String title = fileName.replaceAll(RegExp(r'\.[^.]*$'), '');
          String artist = 'Artista Desconocido';
          String albumName = 'Música General';
          String albumImage =
              'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&fit=crop';
          int trackNumber = 0;

          try {
            final tagFile = TagLibFile.open(filePath);
            if (tagFile != null) {
              if (tagFile.title != null && tagFile.title!.isNotEmpty) title = tagFile.title!;
              if (tagFile.artist != null && tagFile.artist!.isNotEmpty) artist = tagFile.artist!;
              if (tagFile.album != null && tagFile.album!.isNotEmpty) albumName = tagFile.album!;
              trackNumber = tagFile.track ?? 0;

              if (tagFile.hasCover) {
                final Uint8List? coverBytes = tagFile.coverData;
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
            debugPrint('Aviso: No se pudieron leer los tags de $fileName: $e');
          }

          final songData = {
            'title': title,
            'artist': artist,
            'genre': 'Música',
            'filePath': filePath,
            'track': trackNumber,
          };

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
        }
      }

      setState(() {});
      await _saveAlbumsToPrefs();
    } catch (e) {
      debugPrint('Error al importar archivos: $e');
    }
  }

  Future<void> _playSongInAlbum(int albumIndex, int songIndex) async {
    if (albumList.isEmpty) return;

    try {
      if (albumIndex < 0 || albumIndex >= albumList.length) return;
      var album = albumList[albumIndex];

      if (album.songs.isEmpty) return;
      if (songIndex < 0 || songIndex >= album.songs.length) return;

      final song = album.songs[songIndex];
      String path = song['filePath'] ?? '';
      String songTitle = song['title'] ?? 'Sin título';
      String songArtist = song['artist'] ?? album.artist;

      if (path.isNotEmpty && File(path).existsSync()) {
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
          artUri: album.image,          // Para la portada
          album: album.title,
          filePath: path,
        );

        await _audioPlayer.setVolume(_volume);

        await _audioPlayer.setAudioSource(
          AudioSource.file(path),
          preload: true,
        );

        await _audioPlayer.play();

        if (mounted) {
          setState(() {
            _isPlaying = _audioPlayer.playing;
          });
        }
      } else {
        debugPrint('El archivo de audio no existe en la ruta: $path');
        _playNextSongAutomatically();
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

  final ScreenshotController _screenshotController = ScreenshotController();

  void _showShareSongCard({
    required String songTitle,
    required String artistName,
    required String albumTitle,
    required String albumImage,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.75),
      builder: (ctx) {
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
                              const Color(0xFF1F1C2C).withOpacity(0.92),
                              const Color(0xFF928DAB).withOpacity(0.35),
                              const Color(0xFF0F0C20).withOpacity(0.95),
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
                                          color: Colors.indigoAccent.withOpacity(0.35),
                                          blurRadius: 40,
                                          spreadRadius: 10,
                                        ),
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.8),
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
                                      final imageUint8List = await _screenshotController.capture();

                                      if (imageUint8List != null) {
                                        final tempDir = await getTemporaryDirectory();
                                        final file = File('${tempDir.path}/share_track.png');
                                        await file.writeAsBytes(imageUint8List);

                                        Navigator.pop(ctx);

                                        await Share.shareXFiles(
                                          [XFile(file.path)],
                                          text: '¡Escuchando "$songTitle" de $artistName en BIN Music! 🎵',
                                        );
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
    int activeIndex = albumList.isEmpty ? 0 : _getCurrentPageIndex();
    AlbumModel? activeAlbum = albumList.isNotEmpty ? albumList[activeIndex] : null;

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
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Row(
                    children: [
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.asset(
                              'assets/ojo.gif',
                              width: 28,
                              height: 28,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                              const Icon(Icons.remove_red_eye, color: Colors.white, size: 24),
                            ),
                          ),
                          const SizedBox(width: 8),
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
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.public_rounded, color: Colors.white, size: 26),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => FlacWebBrowserScreen(
                                onDownloadComplete: (flacFile) => _processDownloadedFlac(flacFile),
                              ),
                            ),
                          );
                        },
                        tooltip: 'Navegar a Flac Downloader Web',
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 26),
                        onPressed: _pickMusicFiles,
                        tooltip: 'Añadir canciones locales',
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
                          onPressed: _pickMusicFiles,
                          icon: const Icon(Icons.library_add),
                          label: const Text('Añadir canciones'),
                        ),
                      ],
                    ),
                  )
                      : AnimatedBuilder(
                    animation: _pageController,
                    builder: (context, child) {
                      double page = _pageController.hasClients &&
                          _pageController.position.haveDimensions
                          ? _pageController.page ?? 0.0
                          : 0.0;

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
                                      _showAlbumTracklist(index);
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
                            const SizedBox(height: 2),
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
                        onPressed: albumList.isEmpty || currentTitle == 'Sin canción'
                            ? null
                            : () {
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