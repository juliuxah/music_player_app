import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_taglib/flutter_taglib.dart';

// Instancia global del manejador de audio para el sistema nativo
late MyAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializamos AudioService antes de arrancar la app
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
// CLASE HANDLER PARA CONTROL NATIVO (LockScreen / Background)
// ---------------------------------------------------------
// ---------------------------------------------------------
// CLASE HANDLER PARA CONTROL NATIVO (LockScreen / Background)
// ---------------------------------------------------------
class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  MyAudioHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  AudioPlayer get player => _player;

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
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
    await super.stop();
  }

  // Renombramos el método auxiliar para evitar colisiones con la clase base
  void updateCurrentMetadata({required String title, required String artist, required String artUri}) {
    mediaItem.add(MediaItem(
      id: artUri,
      album: "Álbum",
      title: title,
      artist: artist,
      artUri: Uri.parse(artUri.startsWith('http') ? artUri : 'file://$artUri'),
    ));
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iPod Cover Flow modern',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: Platform.isIOS ? '.SF Pro Text' : 'Roboto',
        ),
      ),
      home: const AlbumCollectionScreen(),
    );
  }
}

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
      songs: List<Map<String, dynamic>>.from(json['songs'] ?? []),
    );
  }
}

class AlbumCollectionScreen extends StatefulWidget {
  const AlbumCollectionScreen({super.key});

  @override
  State<AlbumCollectionScreen> createState() => _AlbumCollectionScreenState();
}

class _AlbumCollectionScreenState extends State<AlbumCollectionScreen> {
  late final PageController _pageController;

  // Enlazamos al reproductor central de audioHandler
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

  bool _isChangingTrack = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.52, initialPage: 0);

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

        if (state.processingState == ProcessingState.completed) {
          _playNextSongAutomatically();
        }
      }
    });

    _loadSavedAlbums();
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

  Future<void> _pickMusicFiles() async {
    try {
      List<PlatformFile>? files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['flac', 'mp3', 'm4a', 'wav', 'aac', 'ogg'],
        allowMultiple: true,
      );

      if (files != null && files.isNotEmpty) {
        final appDir = await getApplicationDocumentsDirectory();
        final tempDir = await getTemporaryDirectory();

        for (var file in files) {
          if (file.path != null) {
            try {
              final String fileName = file.name;
              final String newPath = '${appDir.path}/$fileName';
              final File sourceFile = File(file.path!);

              final File savedFile = File(newPath);
              if (!await savedFile.exists()) {
                await sourceFile.copy(newPath);
              }

              String title = fileName.replaceAll(RegExp(r'\.[^.]*$'), '');
              String artist = 'Artista Desconocido';
              String albumName = 'Mis Canciones';
              String albumImage = 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&fit=crop';

              try {
                final tagFile = TagLibFile.open(newPath);
                if (tagFile != null) {
                  if (tagFile.title != null && tagFile.title!.isNotEmpty) {
                    title = tagFile.title!;
                  }
                  if (tagFile.artist != null && tagFile.artist!.isNotEmpty) {
                    artist = tagFile.artist!;
                  }
                  if (tagFile.album != null && tagFile.album!.isNotEmpty) {
                    albumName = tagFile.album!;
                  }

                  if (tagFile.hasCover) {
                    final Uint8List? coverBytes = tagFile.coverData;
                    if (coverBytes != null && coverBytes.isNotEmpty) {
                      final coverFile = File('${tempDir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
                      await coverFile.writeAsBytes(coverBytes);
                      albumImage = coverFile.path;
                    }
                  }
                  tagFile.close();
                }
              } catch (tagError) {
                debugPrint('Error leyendo tags con flutter_taglib: $tagError');
              }

              final songData = {
                'title': title,
                'artist': artist,
                'genre': 'Música',
                'filePath': newPath,
              };

              int existingAlbumIndex = albumList.indexWhere(
                    (a) =>
                a.title.toLowerCase() == albumName.toLowerCase() &&
                    a.artist.toLowerCase() == artist.toLowerCase(),
              );

              if (existingAlbumIndex != -1) {
                albumList[existingAlbumIndex].songs.add(songData);
              } else {
                albumList.add(AlbumModel(
                  title: albumName,
                  artist: artist,
                  image: albumImage,
                  songs: [songData],
                ));
              }
            } catch (e) {
              debugPrint('Error procesando archivo: $e');
            }
          }
        }

        setState(() {});
        await _saveAlbumsToPrefs();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al importar archivos: $e')),
        );
      }
    }
  }

  Future<void> _deleteSong(int albumIndex, int songIndex) async {
    setState(() {
      final album = albumList[albumIndex];
      album.songs.removeAt(songIndex);

      if (album.songs.isEmpty) {
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

  Future<void> _playSongInAlbum(int albumIndex, int songIndex) async {
    if (albumList.isEmpty) return;
    int clampedAlbumIndex = albumIndex.clamp(0, albumList.length - 1);
    var album = albumList[clampedAlbumIndex];

    if (album.songs.isEmpty) return;
    int clampedSongIndex = songIndex.clamp(0, album.songs.length - 1);

    final song = album.songs[clampedSongIndex];
    String path = song['filePath'] ?? '';
    String songTitle = song['title'] ?? 'Sin título';
    String songArtist = song['artist'] ?? album.artist;

    if (path.isNotEmpty) {
      try {
        _position = Duration.zero;

        // Sincronizamos los metadatos para la pantalla de bloqueo (iOS/Android)
        // Actualizamos usando el nuevo nombre del método
        audioHandler.updateCurrentMetadata(
          title: songTitle,
          artist: songArtist,
          artUri: album.image,
        );

        await _audioPlayer.setAudioSource(AudioSource.file(path), preload: true);
        _currentAudioPath = path;

        _currentPlayingAlbumIndex = clampedAlbumIndex;
        _currentSongInAlbumIndex = clampedSongIndex;

        await _audioPlayer.play();
        if (mounted) {
          setState(() {
            _isPlaying = true;
          });
        }
      } catch (e) {
        debugPrint('Error al reproducir audio: $e');
      }
    }
  }

  Future<void> _playNextSongAutomatically() async {
    if (_isChangingTrack || _currentPlayingAlbumIndex == -1 || albumList.isEmpty) return;
    _isChangingTrack = true;

    try {
      // Breve respiro de 200ms para estabilizar el buffer del sistema de audio
      await Future.delayed(const Duration(milliseconds: 200));

      final currentAlbum = albumList[_currentPlayingAlbumIndex];

      if (_currentSongInAlbumIndex < currentAlbum.songs.length - 1) {
        await _playSongInAlbum(_currentPlayingAlbumIndex, _currentSongInAlbumIndex + 1);
      } else if (_currentPlayingAlbumIndex < albumList.length - 1) {
        await _playSongInAlbum(_currentPlayingAlbumIndex + 1, 0);
      } else {
        await _audioPlayer.stop();
        setState(() {
          _isPlaying = false;
          _currentSongInAlbumIndex = -1;
        });
      }
    } finally {
      _isChangingTrack = false;
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

  void _showAlbumTracklist(int albumIndex) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        if (albumIndex >= albumList.length) return const SizedBox.shrink();
        final album = albumList[albumIndex];

        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              color: const Color(0xFF121212).withOpacity(0.85),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.65,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 56,
                          height: 56,
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
                                fontSize: 17,
                                color: Colors.white,
                                letterSpacing: -0.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              album.artist,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                letterSpacing: -0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Divider(height: 1, color: Colors.white12),
                  ),
                  Expanded(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: album.songs.length,
                      itemBuilder: (context, idx) {
                        final song = album.songs[idx];
                        final bool isSelected =
                            _currentPlayingAlbumIndex == albumIndex && _currentSongInAlbumIndex == idx;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white.withOpacity(0.08) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            leading: Icon(
                              isSelected && _isPlaying ? Icons.volume_up_rounded : Icons.music_note_rounded,
                              color: isSelected ? Colors.white : Colors.white38,
                              size: 20,
                            ),
                            title: Text(
                              song['title'],
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.white.withOpacity(0.9),
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                fontSize: 15,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song['artist'] ?? album.artist,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.45),
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.delete_outline_rounded, color: Colors.redAccent.withOpacity(0.7), size: 18),
                                  onPressed: () {
                                    _deleteSong(albumIndex, idx);
                                    Navigator.pop(context);
                                  },
                                ),
                              ],
                            ),
                            onTap: () async {
                              await _playSongInAlbum(albumIndex, idx);
                              Navigator.pop(context);
                            },
                          ),
                        );
                      },
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

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Widget _buildAlbumImage(String imageSource) {
    if (imageSource.startsWith('http')) {
      return Image.network(
        imageSource,
        fit: BoxFit.cover,
        cacheWidth: 500,
        errorBuilder: (context, error, stackTrace) => _fallbackCover(),
      );
    } else {
      return Image.file(
        File(imageSource),
        fit: BoxFit.cover,
        cacheWidth: 500,
        errorBuilder: (context, error, stackTrace) => _fallbackCover(),
      );
    }
  }

  Widget _fallbackCover() {
    return Container(
      color: Colors.grey[900],
      child: const Icon(Icons.music_note, size: 80, color: Colors.white38),
    );
  }

  Widget _buildAnimatedAlbumCard(int index, double currentPage) {
    final album = albumList[index];
    final difference = currentPage - index;
    final absDiff = difference.abs();

    double rotationAngle = 0.0;
    double translationX = 0.0;
    double scale = 1.0;

    if (difference > 0) {
      rotationAngle = -0.75 * (difference.clamp(0.0, 1.0));
    } else if (difference < 0) {
      rotationAngle = 0.75 * (difference.abs().clamp(0.0, 1.0));
    }

    translationX = -difference * 70;
    scale = (1.0 - (absDiff * 0.12)).clamp(0.75, 1.0);
    final double depthZ = -absDiff * 130.0;

    return Transform(
      alignment: difference < 0 ? Alignment.centerRight : Alignment.centerLeft,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..translate(translationX, 0.0, depthZ)
        ..rotateY(rotationAngle)
        ..scale(scale),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (absDiff < 0.4) {
            _showAlbumTracklist(index);
          } else {
            _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            );
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 240,
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
                            color: Colors.black.withOpacity(0.4),
                            blurRadius: 24,
                            spreadRadius: -2,
                            offset: const Offset(0, 12),
                          ),
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 8,
                            spreadRadius: 0,
                            offset: const Offset(0, 4),
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
                            stops: [0.0, 0.7],
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
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    int activeIndex = albumList.isEmpty ? 0 : _getCurrentPageIndex();
    AlbumModel? activeAlbum = albumList.isNotEmpty ? albumList[activeIndex] : null;

    String currentTitle = '';
    String currentArtist = '';

    if (_currentPlayingAlbumIndex != -1 &&
        _currentSongInAlbumIndex != -1 &&
        _currentPlayingAlbumIndex < albumList.length &&
        _currentSongInAlbumIndex < albumList[_currentPlayingAlbumIndex].songs.length) {
      final currentSong = albumList[_currentPlayingAlbumIndex].songs[_currentSongInAlbumIndex];
      currentTitle = currentSong['title'] ?? '';
      currentArtist = currentSong['artist'] ?? albumList[_currentPlayingAlbumIndex].artist;
    } else if (activeAlbum != null) {
      currentTitle = activeAlbum.title;
      currentArtist = activeAlbum.artist;
    }

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
                      filter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
                      child: Container(
                        color: Colors.black.withOpacity(0.45),
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 36,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.0),
                          borderRadius: BorderRadius.circular(2.5),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 28),
                        onPressed: _pickMusicFiles,
                        tooltip: 'Añadir canciones',
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
                          'No hay álbumes en la biblioteca',
                          style: TextStyle(color: Colors.white70, fontSize: 16),
                        ),
                        const SizedBox(height: 12),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Colors.white, size: 36),
                          onPressed: _pickMusicFiles,
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

                      List<int> visibleIndices = List.generate(albumList.length, (i) => i)
                          .where((i) => (i - page).abs() < 3.5)
                          .toList();

                      visibleIndices.sort((a, b) {
                        final distA = (a - page).abs();
                        final distB = (b - page).abs();
                        return distB.compareTo(distA);
                      });

                      return Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          PageView.builder(
                            controller: _pageController,
                            physics: const BouncingScrollPhysics(),
                            itemCount: albumList.length,
                            itemBuilder: (context, index) => const SizedBox.expand(),
                          ),
                          ...visibleIndices
                              .map((index) => _buildAnimatedAlbumCard(index, page)),
                        ],
                      );
                    },
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                  child: Column(
                    children: [
                      Text(
                        currentTitle.isNotEmpty ? currentTitle : 'Sin canción',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          letterSpacing: -0.3,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        currentArtist.isNotEmpty ? currentArtist : 'Desconocido',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: Colors.white.withOpacity(0.65),
                          letterSpacing: -0.2,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.w500),
                          ),
                          Text(
                            _formatRemainingDuration(
                              _isSeeking ? Duration(milliseconds: _dragValue.toInt()) : _position,
                              _duration,
                            ),
                            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.w500),
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
                      onPressed: albumList.isEmpty
                          ? null
                          : () {
                        if (_currentPlayingAlbumIndex == activeIndex &&
                            _currentSongInAlbumIndex > 0) {
                          _playSongInAlbum(activeIndex, _currentSongInAlbumIndex - 1);
                        } else {
                          _audioPlayer.seek(Duration.zero);
                        }
                      },
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
                      onPressed: albumList.isEmpty
                          ? null
                          : () {
                        var album = albumList[activeIndex];
                        if (_currentPlayingAlbumIndex == activeIndex &&
                            _currentSongInAlbumIndex < album.songs.length - 1) {
                          _playSongInAlbum(activeIndex, _currentSongInAlbumIndex + 1);
                        }
                      },
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36.0, vertical: 12.0),
                  child: Row(
                    children: [
                      Icon(Icons.volume_down_rounded, color: Colors.white.withOpacity(0.5), size: 18),
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
                      Icon(Icons.volume_up_rounded, color: Colors.white.withOpacity(0.5), size: 18),
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