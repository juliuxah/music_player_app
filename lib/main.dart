import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_taglib/flutter_taglib.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:palette_generator/palette_generator.dart';
import 'dart:convert';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MusicPlayerApp());
}

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reproductor de Música',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF000000),
      ),
      home: const AlbumCollectionScreen(),
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
  late final AudioPlayer _audioPlayer;

  double _currentPage = 0.0;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Duration _savedPosition = Duration.zero;
  bool _isSeeking = false;
  double _dragValue = 0.0;

  List<Map<String, dynamic>> albums = [];
  Timer? _simulationTimer;
  Timer? _paletteDebounce;
  String? _currentAudioPath;

  Color _ambientColor = const Color(0xFF1C1C1E);

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.72);
    _pageController.addListener(() {
      setState(() {
        _currentPage = _pageController.page ?? 0.0;
      });
    });

    _audioPlayer = AudioPlayer();
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

    _loadSavedAlbums();
  }

  Future<void> _loadSavedAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? savedData = prefs.getString('saved_albums');
      if (savedData != null) {
        final List<dynamic> decodedList = jsonDecode(savedData);
        setState(() {
          albums = decodedList.map((item) => Map<String, dynamic>.from(item)).toList();
        });
        if (albums.isNotEmpty) {
          _updatePaletteLazy(albums[0]['image']);
        }
      }
    } catch (e) {
      print('Error al cargar canciones guardadas: $e');
    }
  }

  Future<void> _saveAlbumsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encodedList = jsonEncode(albums);
      await prefs.setString('saved_albums', encodedList);
    } catch (e) {
      print('Error al guardar canciones: $e');
    }
  }

  Future<void> _deleteSongAtIndex(int index) async {
    if (index < 0 || index >= albums.length) return;

    final String deletedTitle = albums[index]['title'];

    if (_currentAudioPath == albums[index]['filePath']) {
      await _audioPlayer.stop();
      _simulationTimer?.cancel();
      setState(() {
        _isPlaying = false;
        _position = Duration.zero;
        _duration = Duration.zero;
        _currentAudioPath = null;
      });
    }

    setState(() {
      albums.removeAt(index);
    });

    await _saveAlbumsToPrefs();

    if (albums.isNotEmpty) {
      int newIndex = index >= albums.length ? albums.length - 1 : index;
      _updatePaletteLazy(albums[newIndex]['image']);
    } else {
      setState(() {
        _ambientColor = const Color(0xFF1C1C1E);
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Se eliminó "$deletedTitle"')),
      );
    }
  }

  void _updatePaletteLazy(String imageSource) {
    _paletteDebounce?.cancel();
    _paletteDebounce = Timer(const Duration(milliseconds: 150), () async {
      try {
        ImageProvider provider;
        if (imageSource.startsWith('http')) {
          provider = NetworkImage(imageSource);
        } else {
          provider = FileImage(File(imageSource));
        }

        final PaletteGenerator paletteGenerator = await PaletteGenerator.fromImageProvider(
          provider,
          maximumColorCount: 8,
        );

        if (mounted) {
          setState(() {
            _ambientColor = paletteGenerator.dominantColor?.color ?? const Color(0xFF2C2C2E);
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _ambientColor = const Color(0xFF1C1C1E);
          });
        }
      }
    });
  }

  Future<void> _pickMusicFiles() async {
    try {
      List<PlatformFile>? files = await FilePicker.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (files != null && files.isNotEmpty) {
        List<Map<String, dynamic>> newAlbums = [];
        final appDir = await getApplicationDocumentsDirectory();

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
              String genre = 'Desconocido';
              String? artPath;

              if (TagLibFile.isSupported) {
                final tagFile = TagLibFile.open(newPath);
                if (tagFile != null) {
                  try {
                    title = tagFile.title?.isNotEmpty == true ? tagFile.title! : title;
                    artist = tagFile.artist?.isNotEmpty == true ? tagFile.artist! : artist;
                    genre = tagFile.genre?.isNotEmpty == true ? tagFile.genre! : genre;

                    if (tagFile.hasCover) {
                      final Uint8List? artBytes = tagFile.coverData;
                      if (artBytes != null && artBytes.isNotEmpty) {
                        final artFile = File('${appDir.path}/${fileName}_cover.jpg');
                        await artFile.writeAsBytes(artBytes);
                        artPath = artFile.path;
                      }
                    }
                  } finally {
                    tagFile.close();
                  }
                }
              }

              String albumImage = artPath ??
                  'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&fit=crop';

              newAlbums.add({
                'title': title,
                'artist': artist,
                'image': albumImage,
                'genre': genre,
                'audioQuality': file.extension?.toUpperCase() ?? 'AUDIO',
                'filePath': newPath,
              });
            } catch (e) {
              print('Error procesando archivo individual: $e');
            }
          }
        }

        if (newAlbums.isNotEmpty) {
          setState(() {
            albums.addAll(newAlbums);
          });
          await _saveAlbumsToPrefs();
          if (albums.length == newAlbums.length) {
            _updatePaletteLazy(albums[0]['image']);
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${newAlbums.length} canciones añadidas y guardadas')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al buscar archivos: $e')),
      );
    }
  }

  Future<void> _playSongAtIndex(int index) async {
    if (albums.isEmpty) return;
    int clampedIndex = index.clamp(0, albums.length - 1);
    String path = albums[clampedIndex]['filePath'] ?? '';

    _updatePaletteLazy(albums[clampedIndex]['image']);
    _simulationTimer?.cancel();

    if (path.isNotEmpty) {
      try {
        _savedPosition = Duration.zero;
        _position = Duration.zero;
        await _audioPlayer.setAudioSource(AudioSource.file(path), preload: true);
        _currentAudioPath = path;
        await _audioPlayer.play();
        if (mounted) {
          setState(() {
            _isPlaying = true;
          });
        }
      } catch (e) {
        print('Error al reproducir archivo: $e');
      }
    } else {
      _simulatePlayback();
    }
  }

  Future<void> _togglePlayPause() async {
    if (albums.isEmpty) return;

    if (_isPlaying) {
      _simulationTimer?.cancel();
      _savedPosition = _audioPlayer.position;
      await _audioPlayer.pause();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = _savedPosition;
        });
      }
    } else {
      int activeIndex = _currentPage.round().clamp(0, albums.length - 1);
      String path = albums[activeIndex]['filePath'] ?? '';

      if (_currentAudioPath == path && path.isNotEmpty) {
        await _audioPlayer.seek(_savedPosition);
        await _audioPlayer.play();
        if (mounted) {
          setState(() {
            _isPlaying = true;
          });
        }
      } else {
        await _playSongAtIndex(activeIndex);
      }
    }
  }

  void _simulatePlayback() {
    _simulationTimer?.cancel();
    if (mounted) {
      setState(() {
        _isPlaying = true;
        _duration = const Duration(seconds: 180);
      });
    }
    _simulationTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted) {
        setState(() {
          if (_position < _duration) {
            _position += const Duration(seconds: 1);
          } else {
            _isPlaying = false;
            timer.cancel();
          }
        });
      }
    });
  }

  Future<void> _onPageChanged(int index) async {
    await _playSongAtIndex(index);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _paletteDebounce?.cancel();
    _pageController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Widget _buildAlbumImage(String imageSource) {
    if (imageSource.startsWith('http')) {
      return Image.network(
        imageSource,
        fit: BoxFit.cover,
        cacheWidth: 400,
        errorBuilder: (context, error, stackTrace) => _fallbackCover(),
      );
    } else {
      return Image.file(
        File(imageSource),
        fit: BoxFit.cover,
        cacheWidth: 400,
        errorBuilder: (context, error, stackTrace) => _fallbackCover(),
      );
    }
  }

  Widget _fallbackCover() {
    return Container(
      color: Colors.grey[800],
      child: const Icon(Icons.music_note, size: 80, color: Colors.grey),
    );
  }

  @override
  Widget build(BuildContext context) {
    int activeIndex = albums.isEmpty ? 0 : _currentPage.round().clamp(0, albums.length - 1);

    final double maxDurationMs = _duration.inMilliseconds.toDouble();
    final double currentPositionMs = _isSeeking
        ? _dragValue
        : _position.inMilliseconds.toDouble().clamp(0.0, maxDurationMs > 0 ? maxDurationMs : 1.0);

    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.black,
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      albums.isEmpty ? 'No hay canciones' : '${albums.length} canciones disponibles',
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
                        tooltip: 'Agregar canciones',
                        onPressed: _pickMusicFiles,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: albums.isEmpty
                    ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.music_note_rounded, size: 64, color: Colors.white24),
                      const SizedBox(height: 16),
                      const Text(
                        'Agrega canciones para comenzar',
                        style: TextStyle(color: Colors.white54, fontSize: 16),
                      ),
                    ],
                  ),
                )
                    : PageView.builder(
                  controller: _pageController,
                  physics: const BouncingScrollPhysics(),
                  clipBehavior: Clip.none,
                  onPageChanged: _onPageChanged,
                  itemCount: albums.length,
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    final pageViewValue = (_currentPage - index).abs();
                    final scale = (1.0 - (pageViewValue * 0.3)).clamp(0.7, 1.0);
                    final opacity = (1.0 - (pageViewValue * 0.5)).clamp(0.5, 1.0);

                    return Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: opacity,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 0),
                                child: AspectRatio(
                                  aspectRatio: 1.0,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned.fill(
                                        child: Transform.scale(
                                          scale: 1.35,
                                          child: ImageFiltered(
                                            imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                                            child: Opacity(
                                              opacity: 0.85,
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(40),
                                                child: _buildAlbumImage(album['image']),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(24),
                                          border: Border.all(
                                            color: Colors.white.withOpacity(0.25),
                                            width: 1.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.5),
                                              blurRadius: 20,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(22),
                                          child: _buildAlbumImage(album['image']),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 28),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Column(
                                  children: [
                                    Text(
                                      album['title'],
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      album['artist'],
                                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        _buildValueRow(Icons.category, album['genre']),
                                        const SizedBox(width: 20),
                                        _buildValueRow(Icons.high_quality, album['audioQuality']),
                                        const SizedBox(width: 4),
                                        PopupMenuButton<String>(
                                          icon: const Icon(Icons.more_vert, color: Colors.white70, size: 20),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          color: const Color(0xFF2C2C2E),
                                          onSelected: (value) {
                                            if (value == 'delete') {
                                              _deleteSongAtIndex(index);
                                            }
                                          },
                                          itemBuilder: (BuildContext context) => [
                                            const PopupMenuItem<String>(
                                              value: 'delete',
                                              child: Row(
                                                children: [
                                                  Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                                                  SizedBox(width: 8),
                                                  Text('Eliminar canción', style: TextStyle(color: Colors.redAccent)),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      children: [
                        // 🔹 SLIDER PARA ELEGIR LA POSICIÓN DE LA CANCIÓN
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                            activeTrackColor: _ambientColor.withOpacity(0.9),
                            inactiveTrackColor: Colors.white10,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white.withOpacity(0.2),
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
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(_isSeeking ? Duration(milliseconds: _dragValue.toInt()) : _position),
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                              Text(
                                _formatDuration(_duration),
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 🔹 BARRA DE CONTROLES SIMPLIFICADA (ANTERIOR, PLAY/PAUSA, SIGUIENTE)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36),
                          onPressed: albums.isEmpty ? null : () {
                            if (activeIndex > 0) {
                              int targetIndex = activeIndex - 1;
                              _pageController.animateToPage(
                                targetIndex,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                              );
                            }
                          },
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: albums.isEmpty ? null : _togglePlayPause,
                          child: SizedBox(
                            width: 70,
                            height: 70,
                            child: Center(
                              child: MorphingMascotWidget(
                                isPlaying: _isPlaying,
                                width: 70,
                                height: 70,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36),
                          onPressed: albums.isEmpty ? null : () {
                            if (activeIndex < albums.length - 1) {
                              int targetIndex = activeIndex + 1;
                              _pageController.animateToPage(
                                targetIndex,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildValueRow(IconData icon, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.white38),
        const SizedBox(width: 8),
        Text(
          value,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ],
    );
  }
}

class MorphingMascotWidget extends StatefulWidget {
  final bool isPlaying;
  final double? width;
  final double? height;

  const MorphingMascotWidget({
    super.key,
    required this.isPlaying,
    this.width,
    this.height,
  });

  @override
  State<MorphingMascotWidget> createState() => _MorphingMascotWidgetState();
}

class _MorphingMascotWidgetState extends State<MorphingMascotWidget> with TickerProviderStateMixin {
  late final AnimationController _blinkController;
  late final AnimationController _beatController;
  late final AnimationController _orbitRotationController;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..repeat();

    _beatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    _orbitRotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    );

    if (widget.isPlaying) {
      _orbitRotationController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant MorphingMascotWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _orbitRotationController.repeat();
      } else {
        _orbitRotationController.stop();
      }
    }
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _beatController.dispose();
    _orbitRotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double width = widget.width ?? 70;
    final double height = widget.height ?? 70;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _blinkController,
        _beatController,
        _orbitRotationController,
      ]),
      builder: (context, child) {
        double t = _blinkController.value;
        double blinkProgress = 0.0;
        if (t >= 0.45 && t <= 0.55) {
          blinkProgress = math.sin(((t - 0.45) / 0.1) * math.pi);
        }

        double beatScale = widget.isPlaying ? (1.0 + (_beatController.value * 0.08)) : 1.0;

        return Transform.scale(
          scale: beatScale,
          child: SizedBox(
            width: width,
            height: height,
            child: TweenAnimationBuilder<double>(
              key: ValueKey(widget.isPlaying),
              tween: Tween<double>(
                begin: widget.isPlaying ? 0.0 : 1.0,
                end: widget.isPlaying ? 1.0 : 0.0,
              ),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOutCubic,
              builder: (context, morphValue, child) {
                return CustomPaint(
                  painter: MorphingPainter(
                    morphProgress: morphValue,
                    blinkProgress: blinkProgress,
                    orbitRotationProgress: _orbitRotationController.value,
                    isPlaying: widget.isPlaying,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class MorphingPainter extends CustomPainter {
  final double morphProgress;
  final double blinkProgress;
  final double orbitRotationProgress;
  final bool isPlaying;

  MorphingPainter({
    required this.morphProgress,
    required this.blinkProgress,
    required this.orbitRotationProgress,
    required this.isPlaying,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double centerX = size.width / 2;
    final double centerY = size.height / 2;

    double orbitVisibility = morphProgress.clamp(0.0, 1.0);

    // ============================================================
    // 1. ÓRBITAS MULTICOLOR EN LA ESFERA (PLAY)
    // ============================================================
    if (orbitVisibility > 0.05) {
      final List<Color> orbitColors = [
        const Color(0xFF65D6AD),
        const Color(0xFF65CBE6),
        const Color(0xFFA685E2),
        const Color(0xFFE88DB6),
        const Color(0xFFE5C365),
        const Color(0xFFE87E65),
      ];

      double continuousRotation = orbitRotationProgress * math.pi * 2;

      for (int i = 0; i < orbitColors.length; i++) {
        final orbitPaint = Paint()
          ..color = orbitColors[i].withOpacity((orbitVisibility * 0.85).clamp(0.0, 1.0))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round;

        canvas.save();
        canvas.translate(centerX, centerY);
        canvas.rotate(continuousRotation + (i * math.pi / 3));

        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: size.width * 0.88,
          height: size.height * 0.44,
        );

        canvas.drawArc(rect, 0.15, math.pi * 1.65, false, orbitPaint);
        canvas.restore();
      }
    }

    // ============================================================
    // 2. MORPHING BÉZIER: TRIÁNGULO (0.0) ➔ CÍRCULO (1.0)
    // ============================================================
    final bodyPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final double radius = 30.0;
    const double kappa = 0.552284749831;

    // Estado Triángulo (Pausa: morphProgress = 0.0)
    final Offset triP0 = Offset(centerX + radius * 0.95, centerY);
    final Offset triC0a = Offset(centerX + radius * 0.95, centerY - radius * 0.2);
    final Offset triC0b = Offset(centerX + radius * 0.4, centerY - radius * 0.8);

    final Offset triP1 = Offset(centerX - radius * 0.65, centerY - radius * 0.85);
    final Offset triC1a = Offset(centerX - radius * 0.85, centerY - radius * 0.85);
    final Offset triC1b = Offset(centerX - radius * 0.85, centerY - radius * 0.3);

    final Offset triP2 = Offset(centerX - radius * 0.85, centerY);
    final Offset triC2a = Offset(centerX - radius * 0.85, centerY + radius * 0.3);
    final Offset triC2b = Offset(centerX - radius * 0.85, centerY + radius * 0.85);

    final Offset triP3 = Offset(centerX - radius * 0.65, centerY + radius * 0.85);
    final Offset triC3a = Offset(centerX + radius * 0.4, centerY + radius * 0.8);
    final Offset triC3b = Offset(centerX + radius * 0.95, centerY + radius * 0.2);

    // Estado Círculo / Esfera (Play: morphProgress = 1.0)
    final Offset circleP0 = Offset(centerX + radius, centerY);
    final Offset circleC0a = Offset(centerX + radius, centerY - radius * kappa);
    final Offset circleC0b = Offset(centerX + radius * kappa, centerY - radius);

    final Offset circleP1 = Offset(centerX, centerY - radius);
    final Offset circleC1a = Offset(centerX - radius * kappa, centerY - radius);
    final Offset circleC1b = Offset(centerX - radius, centerY - radius * kappa);

    final Offset circleP2 = Offset(centerX - radius, centerY);
    final Offset circleC2a = Offset(centerX - radius, centerY + radius * kappa);
    final Offset circleC2b = Offset(centerX - radius * kappa, centerY + radius);

    final Offset circleP3 = Offset(centerX, centerY + radius);
    final Offset circleC3a = Offset(centerX + radius * kappa, centerY + radius);
    final Offset circleC3b = Offset(centerX + radius, centerY + radius * kappa);

    // Interpolación de Triángulo a Círculo
    Offset p0 = Offset.lerp(triP0, circleP0, morphProgress)!;
    Offset c0a = Offset.lerp(triC0a, circleC0a, morphProgress)!;
    Offset c0b = Offset.lerp(triC0b, circleC0b, morphProgress)!;

    Offset p1 = Offset.lerp(triP1, circleP1, morphProgress)!;
    Offset c1a = Offset.lerp(triC1a, circleC1a, morphProgress)!;
    Offset c1b = Offset.lerp(triC1b, circleC1b, morphProgress)!;

    Offset p2 = Offset.lerp(triP2, circleP2, morphProgress)!;
    Offset c2a = Offset.lerp(triC2a, circleC2a, morphProgress)!;
    Offset c2b = Offset.lerp(triC2b, circleC2b, morphProgress)!;

    Offset p3 = Offset.lerp(triP3, circleP3, morphProgress)!;
    Offset c3a = Offset.lerp(triC3a, circleC3a, morphProgress)!;
    Offset c3b = Offset.lerp(triC3b, circleC3b, morphProgress)!;

    Path path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..cubicTo(c0a.dx, c0a.dy, c0b.dx, c0b.dy, p1.dx, p1.dy)
      ..cubicTo(c1a.dx, c1a.dy, c1b.dx, c1b.dy, p2.dx, p2.dy)
      ..cubicTo(c2a.dx, c2a.dy, c2b.dx, c2b.dy, p3.dx, p3.dy)
      ..cubicTo(c3a.dx, c3a.dy, c3b.dx, c3b.dy, p0.dx, p0.dy)
      ..close();

    canvas.drawPath(path, bodyPaint);

    // ============================================================
    // 3. OJOS NEGROS TOTALMENTE DERECHOS Y ALINEADOS
    // ============================================================
    final eyePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    double baseEyeHeight = 13.0;
    double currentEyeHeight = baseEyeHeight * (1.0 - (blinkProgress * 0.85));
    double eyeWidth = 5.0;

    // Ajuste de centro ligero para mantener el equilibrio visual entre las dos formas
    double eyeShiftX = lerpDouble(-2.0, 0.0, morphProgress)!;

    canvas.save();
    canvas.translate(centerX + eyeShiftX, centerY);

    // Ojo izquierdo y derecho en posición vertical perfecta (sin inclinación)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(-7, 0), width: eyeWidth, height: currentEyeHeight),
        const Radius.circular(2.5),
      ),
      eyePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(7, 0), width: eyeWidth, height: currentEyeHeight),
        const Radius.circular(2.5),
      ),
      eyePaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MorphingPainter oldDelegate) {
    return oldDelegate.morphProgress != morphProgress ||
        oldDelegate.blinkProgress != blinkProgress ||
        oldDelegate.orbitRotationProgress != orbitRotationProgress ||
        oldDelegate.isPlaying != isPlaying;
  }
}