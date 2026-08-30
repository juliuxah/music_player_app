import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

void main() {
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

  double _currentPage = 0.0;
  bool _isPlaying = false;
  Duration _duration = const Duration(seconds: 180); // duración ficticia
  Duration _position = Duration.zero;
  Timer? _progressTimer;

  // --- DATOS DE EJEMPLO (sin archivos reales) ---
  final List<Map<String, dynamic>> albums = [
    {
      'title': 'Blinding Lights',
      'artist': 'The Weeknd',
      'image': 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?q=80&w=500&auto=format&fit=crop',
      'genre': 'Pop',
      'audioQuality': 'FLAC',
    },
    {
      'title': 'Shape of You',
      'artist': 'Ed Sheeran',
      'image': 'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?q=80&w=500&auto=format&fit=crop',
      'genre': 'Pop',
      'audioQuality': 'MP3',
    },
    {
      'title': 'Bohemian Rhapsody',
      'artist': 'Queen',
      'image': 'https://images.unsplash.com/photo-1511379938547-c1f69419868d?q=80&w=500&auto=format&fit=crop',
      'genre': 'Rock',
      'audioQuality': 'WAV',
    },
    {
      'title': 'Billie Jean',
      'artist': 'Michael Jackson',
      'image': 'https://images.unsplash.com/photo-1508700115892-45d8b2d51ab2?q=80&w=500&auto=format&fit=crop',
      'genre': 'Pop',
      'audioQuality': 'MP3',
    },
    {
      'title': 'Smells Like Teen Spirit',
      'artist': 'Nirvana',
      'image': 'https://images.unsplash.com/photo-1498038432885-c6f3f1b912ee?q=80&w=500&auto=format&fit=crop',
      'genre': 'Grunge',
      'audioQuality': 'FLAC',
    },
    {
      'title': 'Hotel California',
      'artist': 'Eagles',
      'image': 'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?q=80&w=500&auto=format&fit=crop',
      'genre': 'Rock',
      'audioQuality': 'MP3',
    },
    {
      'title': 'Imagine',
      'artist': 'John Lennon',
      'image': 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?q=80&w=500&auto=format&fit=crop',
      'genre': 'Balada',
      'audioQuality': 'AAC',
    },
    {
      'title': 'Like a Rolling Stone',
      'artist': 'Bob Dylan',
      'image': 'https://images.unsplash.com/photo-1500462918059-b1a0cb512f1d?q=80&w=500&auto=format&fit=crop',
      'genre': 'Folk',
      'audioQuality': 'MP3',
    },
    {
      'title': 'Stairway to Heaven',
      'artist': 'Led Zeppelin',
      'image': 'https://images.unsplash.com/photo-1470229722913-7c0e2dbbafd3?q=80&w=500&auto=format&fit=crop',
      'genre': 'Rock',
      'audioQuality': 'FLAC',
    },
    {
      'title': 'Purple Rain',
      'artist': 'Prince',
      'image': 'https://images.unsplash.com/photo-1511379938547-c1f69419868d?q=80&w=500&auto=format&fit=crop',
      'genre': 'Pop',
      'audioQuality': 'WAV',
    },
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.6);
    _pageController.addListener(() {
      setState(() {
        _currentPage = _pageController.page ?? 0.0;
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _progressTimer?.cancel();
    super.dispose();
  }

  // --- Función simulada de "añadir música" (deshabilitada) ---
  void _fakeAddMusic() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Función de añadir música desactivada (vista de demostración)'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // --- Reproducción simulada ---
  void _togglePlayPause() {
    if (albums.isEmpty) return;

    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        // Iniciar simulación de progreso
        _progressTimer?.cancel();
        _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
          setState(() {
            if (_position < _duration) {
              _position += const Duration(seconds: 1);
              if (_position > _duration) _position = _duration;
            } else {
              _isPlaying = false;
              timer.cancel();
            }
          });
        });
      } else {
        _progressTimer?.cancel();
        _progressTimer = null;
      }
    });
  }

  // Reiniciar posición al cambiar de canción
  void _resetPosition() {
    _progressTimer?.cancel();
    _progressTimer = null;
    setState(() {
      _position = Duration.zero;
      _isPlaying = false;
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    int activeIndex = _currentPage.round().clamp(0, albums.length - 1);
    final currentAlbum = albums[activeIndex];

    final screenWidth = MediaQuery.of(context).size.width;
    final itemWidth = screenWidth * 0.6;
    final alignmentOffset = (_currentPage - activeIndex) * itemWidth;

    double progressValue = 0.0;
    if (_duration.inMilliseconds > 0) {
      progressValue = (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    }

    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1C1C1E),
              Color(0xFF000000),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- BARRA SUPERIOR ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Música',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // Botón de añadir (deshabilitado, solo muestra mensaje)
                    IconButton(
                      icon: const Icon(Icons.create_new_folder_outlined, color: Colors.white54, size: 28),
                      onPressed: _fakeAddMusic,
                      tooltip: "Añadir música (no disponible)",
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // --- CARRUSEL ---
              SizedBox(
                height: 280,
                child: PageView.builder(
                  controller: _pageController,
                  physics: const BouncingScrollPhysics(),
                  itemCount: albums.length,
                  onPageChanged: (index) {
                    // Al cambiar de página, reiniciar la reproducción simulada
                    _resetPosition();
                  },
                  itemBuilder: (context, index) {
                    double delta = index - _currentPage;
                    double angle = delta.clamp(-1.0, 1.0) * -math.pi / 6;
                    double scale = math.max(0.75, 1.0 - delta.abs() * 0.25);
                    double translateMultiplier = delta * -30.0;

                    return Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.001)
                        ..translate(translateMultiplier, 0.0, 0.0)
                        ..rotateY(angle)
                        ..scale(scale),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6.0),
                        child: Container(
                          height: 210,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            image: DecorationImage(
                              image: NetworkImage(albums[index]['image']!),
                              fit: BoxFit.cover,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.7),
                                blurRadius: 20,
                                spreadRadius: 2,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 14),

              // --- INFORMACIÓN DE LA CANCIÓN ---
              Transform(
                transform: Matrix4.translationValues(alignmentOffset, 0.0, 0.0),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Column(
                      key: ValueKey<int>(activeIndex),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildValueRow(Icons.person_outline_rounded, currentAlbum['artist']),
                        const SizedBox(height: 5),
                        _buildValueRow(Icons.music_note_rounded, currentAlbum['genre']),
                        const SizedBox(height: 5),
                        _buildValueRow(Icons.high_quality_rounded, currentAlbum['audioQuality']),
                      ],
                    ),
                  ),
                ),
              ),

              Expanded(
                child: Center(
                  child: MorphingMascotWidget(isPlaying: _isPlaying),
                ),
              ),

              // --- PANEL INFERIOR DE REPRODUCCIÓN ---
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E).withOpacity(0.85),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.6),
                      blurRadius: 25,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentAlbum['title']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                currentAlbum['artist']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.favorite_border_rounded, color: Colors.grey, size: 24),
                          onPressed: () {},
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Barra de progreso y tiempos
                    Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: progressValue,
                            backgroundColor: Colors.white.withOpacity(0.1),
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                            minHeight: 4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_position),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            Text(
                              _formatDuration(_duration),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    // Controles
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.shuffle_rounded, color: Colors.grey, size: 22),
                          onPressed: () {},
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 34),
                          onPressed: () {
                            if (activeIndex > 0) {
                              _pageController.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                              _resetPosition();
                            }
                          },
                        ),
                        Container(
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                          child: IconButton(
                            icon: Icon(
                              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.black,
                              size: 32,
                            ),
                            onPressed: _togglePlayPause,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 34),
                          onPressed: () {
                            if (activeIndex < albums.length - 1) {
                              _pageController.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                              _resetPosition();
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
          style: const TextStyle(
            fontSize: 13,
            color: Colors.white70,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------
// COMPONENTE MASCOTA (sin cambios)
// ---------------------------------------------------------
class MorphingMascotWidget extends StatefulWidget {
  final bool isPlaying;
  const MorphingMascotWidget({super.key, required this.isPlaying});

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
            width: 140,
            height: 80,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: widget.isPlaying ? 1.0 : 0.0),
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

    final double mascotX = centerX;
    final double mascotY = centerY;
    final double mascotRadius = 40.0;

    final double baseDotRadius = 8.0;
    final double spacing = 36.0;

    final double x1 = centerX - spacing;
    final double x2 = centerX;
    final double x3 = centerX + spacing;

    if (morphProgress > 0.01) {
      final paintBody = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      canvas.drawCircle(
        Offset(mascotX, mascotY),
        mascotRadius * morphProgress,
        paintBody,
      );

      if (morphProgress > 0.2) {
        final cutPaint = Paint()
          ..color = const Color(0xFF1C1C1E).withOpacity(morphProgress)
          ..style = PaintingStyle.fill;

        double baseEyeHeight = 18.0;
        double currentEyeHeight = baseEyeHeight * (1.0 - (blinkProgress * 0.85));
        double eyeWidth = 7.0;

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(mascotX - 12, mascotY),
              width: eyeWidth,
              height: currentEyeHeight,
            ),
            const Radius.circular(4),
          ),
          cutPaint,
        );

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(mascotX + 12, mascotY),
              width: eyeWidth,
              height: currentEyeHeight,
            ),
            const Radius.circular(4),
          ),
          cutPaint,
        );
      }
    }

    double inverseMorph = 1.0 - morphProgress;
    if (inverseMorph > 0.01) {
      final dotPaint = Paint()
        ..color = Colors.white.withOpacity(inverseMorph)
        ..style = PaintingStyle.fill;

      double r1 = (baseDotRadius + (math.sin(pulseProgress * math.pi) * 3.5)) * inverseMorph;
      double r2 = (baseDotRadius + (math.sin((pulseProgress + 0.33) * math.pi) * 3.5)) * inverseMorph;
      double r3 = (baseDotRadius + (math.sin((pulseProgress + 0.66) * math.pi) * 3.5)) * inverseMorph;

      canvas.drawCircle(Offset(x1, centerY), r1, dotPaint);
      canvas.drawCircle(Offset(x2, centerY), r2, dotPaint);
      canvas.drawCircle(Offset(x3, centerY), r3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant MorphingPainter oldDelegate) {
    return oldDelegate.morphProgress != morphProgress ||
        oldDelegate.blinkProgress != blinkProgress ||
        oldDelegate.pulseProgress != pulseProgress;
  }
}