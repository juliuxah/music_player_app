import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> checkForUpdates(BuildContext context) async {
  try {
    // 1. Obtiene la versión actual instalada en el dispositivo
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String currentVersion = packageInfo.version;

    // 2. Consulta los datos de la última Release en tu repositorio de GitHub
    final url = Uri.parse('https://api.github.com/repos/juliuxah/music_player_app/releases/latest');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      String latestVersion = data['tag_name'] ?? ''; // Ej: "1.0.1" o "v1.0.1"
      String downloadUrl = data['html_url'] ?? '';   // Enlace a la release en la web

      // Limpiamos la 'v' por si el tag en GitHub empieza con v (ej. "v1.0.1" -> "1.0.1")
      String cleanLatest = latestVersion.replaceAll('v', '');
      String cleanCurrent = currentVersion.replaceAll('v', '');

      // 3. Compara las versiones; si son diferentes, muestra el diálogo
      if (cleanLatest.isNotEmpty && cleanLatest != cleanCurrent) {
        _showUpdateDialog(context, latestVersion, downloadUrl);
      }
    }
  } catch (e) {
    print("Error al buscar actualizaciones: $e");
  }
}

// Función que dibuja la ventana emergente de actualización
void _showUpdateDialog(BuildContext context, String latestVersion, String downloadUrl) {
  showDialog(
    context: context,
    barrierDismissible: false, // Obliga al usuario a elegir una opción
    builder: (BuildContext context) {
      return AlertDialog(
        title: const Text("¡Nueva actualización disponible!"),
        content: Text(
          "Hay una nueva versión ($latestVersion) de tu reproductor de música en GitHub. Actualiza para obtener las mejoras recientes.",
        ),
        actions: [
          TextButton(
            child: const Text("Más tarde"),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
            child: const Text("Descargar"),
            onPressed: () async {
              final Uri uri = Uri.parse(downloadUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
              Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  );
}