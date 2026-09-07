import 'dart:io';
import 'package:flutter/material.dart';
import 'music_folder_service.dart';
import 'package:path/path.dart' as p;

class MusicFolderWidget extends StatefulWidget {
  final MusicFolderService musicFolderService;
  final Function(List<String> files) onMusicFilesFound;
  final Function(List<String> addedFiles, List<String> removedFiles) onFolderChanged;
  final Function() onFolderCleared;

  const MusicFolderWidget({
    Key? key,
    required this.musicFolderService,
    required this.onMusicFilesFound,
    required this.onFolderChanged,
    required this.onFolderCleared,
  }) : super(key: key);

  @override
  State<MusicFolderWidget> createState() => _MusicFolderWidgetState();
}

class _MusicFolderWidgetState extends State<MusicFolderWidget> {
  String _statusMessage = 'Selecciona una carpeta de música';
  String? _selectedFolderPath;
  int _musicFileCount = 0;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  Future<void> _initializeService() async {
    widget.musicFolderService.onStatusChanged = (message) {
      setState(() {
        _statusMessage = message;
      });
    };

    widget.musicFolderService.onFolderChanged = (addedFiles, removedFiles) {
      widget.onFolderChanged(addedFiles, removedFiles);
      _refreshMusicFiles();
    };

    widget.musicFolderService.onFolderCleared = () {
      widget.onFolderCleared();
      setState(() {
        _musicFileCount = 0;
      });
    };

    _selectedFolderPath = widget.musicFolderService.getCurrentMusicFolder();
    if (_selectedFolderPath != null) {
      setState(() {
        _statusMessage = 'Carpeta: ${p.basename(_selectedFolderPath!)}';
      });
      await _refreshMusicFiles();
    }
  }

  Future<void> _selectMusicFolder() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final hasPermission = await widget.musicFolderService.requestStoragePermissions();

      if (!hasPermission) {
        setState(() {
          _statusMessage = 'Permisos denegados';
          _isLoading = false;
        });
        _showPermissionErrorDialog();
        return;
      }

      // Al usar selectMusicFolder, el servicio se encarga de disparar onFolderCleared
      final selectedPath = await widget.musicFolderService.selectMusicFolder();

      if (selectedPath != null) {
        setState(() {
          _selectedFolderPath = selectedPath;
          _statusMessage = 'Escaneando carpeta...';
        });

        await _refreshMusicFiles();
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshMusicFiles() async {
    try {
      final files = await widget.musicFolderService.scanMusicFolder();
      setState(() {
        _musicFileCount = files.length;
      });
      widget.onMusicFilesFound(files);
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
    }
  }

  Future<void> _clearSelection() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222224),
        title: const Text('¿Limpiar carpeta?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Se eliminarán todas las canciones de la biblioteca.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              await widget.musicFolderService.clearMusicFolder();
              setState(() {
                _selectedFolderPath = null;
                _musicFileCount = 0;
                _statusMessage = 'Selecciona una carpeta';
              });
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Limpiar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showPermissionErrorDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222224),
        title: const Text('Permisos Requeridos', style: TextStyle(color: Colors.white)),
        content: const Text(
          'La app necesita permisos de almacenamiento.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  void _showFolderInfo() {
    if (_selectedFolderPath == null) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Información de la Carpeta',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              _buildInfoRow('Ruta:', _selectedFolderPath ?? 'N/A'),
              const SizedBox(height: 12),
              _buildInfoRow('Canciones:', '$_musicFileCount'),
              const SizedBox(height: 12),
              _buildInfoRow('Estado:', _statusMessage),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _refreshMusicFiles,
                      child: const Text('Actualizar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _clearSelection,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade300,
                      ),
                      child: const Text('Limpiar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 14),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _selectedFolderPath != null ? Icons.folder : Icons.folder_open,
                    color: _selectedFolderPath != null ? Colors.blue : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedFolderPath != null
                              ? p.basename(_selectedFolderPath!)
                              : 'Sin carpeta',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _statusMessage,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (_selectedFolderPath != null)
                    IconButton(
                      icon: const Icon(Icons.info_outline),
                      onPressed: _showFolderInfo,
                      tooltip: 'Info',
                    ),
                ],
              ),
              if (_selectedFolderPath != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.music_note, color: Colors.blue.shade700, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '$_musicFileCount canciones',
                        style: TextStyle(
                          color: Colors.blue.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _selectMusicFolder,
                  icon: _isLoading
                      ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.folder_open),
                  label: Text(
                    _selectedFolderPath != null ? 'Cambiar Carpeta' : 'Seleccionar',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    widget.musicFolderService.stopMonitoring();
    super.dispose();
  }
}