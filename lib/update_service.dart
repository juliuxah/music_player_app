import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> checkForUpdates(context) async {
  try {
    // 1. Obtener la versión actual de la app instalada
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String currentVersion = packageInfo.version; // Ejemplo: "1.0.0"

    // 2. Consultar la API de GitHub (Reemplaza con tu usuario y repositorio)
    final url = Uri.parse('https://api.github.com/repos/juliuxah/music_player_app/releases/latest');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      String latestVersion = data['tag_name'] ?? ''; // Ejemplo: "1.1.0"
      String downloadUrl = data['html_url'] ?? ''; // Enlace a la release

      // 3. Comparar versiones (si son distintas, hay actualización)
      if (latestVersion.isNotEmpty && latestVersion != currentVersion) {
        _showUpdateDialog(context, latestVersion, downloadUrl);
      }
    }
  } catch (e) {
    // Si no hay internet o falla, la app sigue normal sin molestar al usuario
    print("Error al buscar actualizaciones: $e");
  }
}