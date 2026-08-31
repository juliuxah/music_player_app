import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_taglib/flutter_taglib.dart';

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

  List<Map<String, dynamic>> albums = [];
  Timer? _simulationTimer;
  String? _currentAudioPath;

  // 🔹 Lista de álbumes de relleno eliminada (queda vacía)
  final List<Map<String, dynamic>> _sampleAlbums = [];

  @override
  void initState() {
    super.initState();
    albums = _sampleAlbums;

    _pageController = PageController(viewportFraction: 0.72);
    _pageController.addListener(() {
      setState(() {
        _currentPage = _pageController.page ?? 0.0;
      });
    });

    _audioPlayer = AudioPlayer();
    _audioPlayer.durationStream.listen((d) => setState(() => _duration = d ?? Duration.zero));

    _audioPlayer.positionStream.listen((p) {
      if (_isPlaying) {
        setState(() => _position = p);
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      setState(() {
        _isPlaying = state.playing;
      });
    });
  }

  Future<void> _pickMusicFiles() async {
    try {
      List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (files.isNotEmpty) {
        List<Map<String, dynamic>> newAlbums = [];
        final appDir = await getApplicationDocumentsDirectory();

        for (var file in files) {
          if (file.path != null) {
            try {
              final String fileName = file.name;
              final String newPath = '${appDir.path}/$fileName';
              final File sourceFile = File(file.path!);
              await sourceFile.copy(newPath);

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
              print('Error procesando archivo: $e');
            }
          }
        }

        if (newAlbums.isNotEmpty) {
          setState(() {
            albums.addAll(newAlbums);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${newAlbums.length} canciones añadidas')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al buscar archivos: $e')),
      );
    }
  }

  Future<void> _togglePlayPause() async {
    if (albums.isEmpty) return;

    if (_isPlaying) {
      _simulationTimer?.cancel();
      _savedPosition = _audioPlayer.position;
      await _audioPlayer.pause();
      setState(() {
        _isPlaying = false;
        _position = _savedPosition;
      });
    } else {
      int activeIndex = _currentPage.round().clamp(0, albums.length - 1);
      String path = albums[activeIndex]['filePath'] ?? '';

      if (path.isNotEmpty) {
        if (_currentAudioPath == path) {
          await _audioPlayer.seek(_savedPosition);
          await _audioPlayer.play();
          setState(() {
            _isPlaying = true;
          });
        } else {
          _savedPosition = Duration.zero;
          _position = Duration.zero;
          await _audioPlayer.setAudioSource(AudioSource.file(path));
          _currentAudioPath = path;
          await _audioPlayer.play();
          setState(() {
            _isPlaying = true;
          });
        }
      } else {
        _simulatePlayback();
      }
    }
  }

  void _simulatePlayback() {
    _simulationTimer?.cancel();
    setState(() {
      _isPlaying = true;
      _duration = const Duration(seconds: 180);
    });
    _simulationTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      setState(() {
        if (_position < _duration) {
          _position += const Duration(seconds: 1);
        } else {
          _isPlaying = false;
          timer.cancel();
        }
      });
    });
  }

  Future<void> _onPageChanged(int index) async {
    _simulationTimer?.cancel();
    if (_isPlaying) {
      await _audioPlayer.stop();
    }
    setState(() {
      _isPlaying = false;
      _position = Duration.zero;
      _savedPosition = Duration.zero;
      _duration = Duration.zero;
      _currentAudioPath = null;
    });
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
    _pageController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Widget _buildAlbumImage(String imageSource) {
    if (imageSource.startsWith('http')) {
      return Image.network(
        imageSource,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                  : null,
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          return _fallbackCover();
        },
      );
    } else {
      return Image.file(
        File(imageSource),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _fallbackCover();
        },
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
    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1C1C1E), Colors.black],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Music Player',
                            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            albums.isEmpty ? 'No hay canciones' : '${albums.length} canciones disponibles',
                            style: const TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ],
                      ),
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
                      Icon(Icons.music_note_rounded, size: 64, color: Colors.white24),
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
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(24),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.white.withOpacity(0.1),
                                          blurRadius: 20,
                                          offset: const Offset(0, 10),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(24),
                                      child: _buildAlbumImage(album['image']),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
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
                                      children: [
                                        _buildValueRow(Icons.category, album['genre']),
                                        const SizedBox(width: 24),
                                        _buildValueRow(Icons.high_quality, album['audioQuality']),
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
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: albums.isEmpty ? 0.0 : (_duration.inMilliseconds > 0 ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0) : 0.0),
                            minHeight: 6,
                            backgroundColor: Colors.white10,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.blue.withOpacity(0.8),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_formatDuration(_position), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            Text(_formatDuration(_duration), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.shuffle_rounded, color: Colors.grey, size: 22),
                          onPressed: () {},
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 34),
                          onPressed: albums.isEmpty ? null : () async {
                            int activeIndex = _currentPage.round().clamp(0, albums.length - 1);
                            if (activeIndex > 0) {
                              await _pageController.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                        ),
                        // 🔹 Botón de Play/Pausa
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
                          icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 34),
                          onPressed: albums.isEmpty ? null : () async {
                            int activeIndex = _currentPage.round().clamp(0, albums.length - 1);
                            if (activeIndex < albums.length - 1) {
                              await _pageController.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.repeat_rounded, color: Colors.grey, size: 22),
                          onPressed: () {},
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

// ============================================================
// 🎵 MASCOTA INTERACTIVA (SOLO 2 ESTADOS / ANIMACIONES)
// ============================================================
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
  late final AnimationController _pulseController;

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

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _beatController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double width = widget.width ?? 70;
    final double height = widget.height ?? 70;

    return AnimatedBuilder(
      animation: Listenable.merge([_blinkController, _beatController, _pulseController]),
      builder: (context, child) {
        double t = _blinkController.value;
        double blinkProgress = 0.0;
        if (t >= 0.45 && t <= 0.55) {
          blinkProgress = math.sin(((t - 0.45) / 0.1) * math.pi);
        }

        double beatScale = widget.isPlaying ? (1.0 + (_beatController.value * 0.1)) : 1.0;
        double pulseProgress = _pulseController.value;

        return Transform.scale(
          scale: beatScale,
          child: SizedBox(
            width: width,
            height: height,
            child: TweenAnimationBuilder<double>(
              key: ValueKey(widget.isPlaying),
              tween: Tween<double>(begin: widget.isPlaying ? 0.0 : 1.0, end: widget.isPlaying ? 1.0 : 0.0),
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeInOutCubic,
              builder: (context, morphValue, child) {
                return CustomPaint(
                  painter: MorphingPainter(
                    morphProgress: morphValue,
                    blinkProgress: blinkProgress,
                    pulseProgress: pulseProgress,
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
  final double pulseProgress;

  MorphingPainter({
    required this.morphProgress,
    required this.blinkProgress,
    required this.pulseProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double centerX = size.width / 2;
    final double centerY = size.height / 2;

    // 1. Estado Pausado: Tres puntos flotantes dinámicos
    double inverseMorph = 1.0 - morphProgress;
    if (inverseMorph > 0.01) {
      final dotPaint = Paint()
        ..color = Colors.white.withOpacity(inverseMorph)
        ..style = PaintingStyle.fill;

      final double baseDotRadius = 6.0;
      final double spacing = 20.0;
      final double x1 = centerX - spacing;
      final double x2 = centerX;
      final double x3 = centerX + spacing;

      double r1 = (baseDotRadius + (math.sin(pulseProgress * math.pi) * 2.0)) * inverseMorph;
      double r2 = (baseDotRadius + (math.sin((pulseProgress + 0.33) * math.pi) * 2.0)) * inverseMorph;
      double r3 = (baseDotRadius + (math.sin((pulseProgress + 0.66) * math.pi) * 2.0)) * inverseMorph;

      canvas.drawCircle(Offset(x1, centerY), r1, dotPaint);
      canvas.drawCircle(Offset(x2, centerY), r2, dotPaint);
      canvas.drawCircle(Offset(x3, centerY), r3, dotPaint);
    }

    // 2. Estado Reproduciendo: Mascota circular blanca con ojos oscuros
    if (morphProgress > 0.01) {
      final double mascotRadius = 32.0;
      final paintBody = Paint()
        ..color = Colors.white.withOpacity(morphProgress)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(centerX, centerY), mascotRadius * morphProgress, paintBody);

      if (morphProgress > 0.2) {
        final cutPaint = Paint()
          ..color = Colors.black.withOpacity(morphProgress)
          ..style = PaintingStyle.fill;

        double baseEyeHeight = 14.0;
        double currentEyeHeight = baseEyeHeight * (1.0 - (blinkProgress * 0.85));
        double eyeWidth = 5.5;

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(centerX - 10, centerY), width: eyeWidth, height: currentEyeHeight),
            const Radius.circular(2),
          ),
          cutPaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(centerX + 10, centerY), width: eyeWidth, height: currentEyeHeight),
            const Radius.circular(2),
          ),
          cutPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant MorphingPainter oldDelegate) {
    return oldDelegate.morphProgress != morphProgress ||
        oldDelegate.blinkProgress != blinkProgress ||
        oldDelegate.pulseProgress != pulseProgress;
  }
}