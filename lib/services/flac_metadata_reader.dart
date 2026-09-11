import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../debug_logger.dart';

class FlacMetadataReader {
  static Future<Map<String, String>> readMetadata(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return _defaultMetadata();

      final raf = await file.open(mode: FileMode.read);
      final header = await raf.read(4);
      await raf.close();

      Map<String, String> metadata;
      if (header.length >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
        metadata = await _readMp3Metadata(filePath);
      } else if (header.length >= 4 && header[0] == 0x66 && header[1] == 0x4C && header[2] == 0x61 && header[3] == 0x43) {
        metadata = await readFlacMetadata(filePath);
      } else {
        final ext = p.extension(filePath).toLowerCase();
        metadata = (ext == '.mp3') ? await _readMp3Metadata(filePath) : await readFlacMetadata(filePath);
      }

      // FALLBACK: Si no hay track, intentar adivinar del nombre del archivo
      if (metadata['track'] == '0' || metadata['track'] == null) {
        final fileName = p.basenameWithoutExtension(filePath);
        final match = RegExp(r'^(\d+)').firstMatch(fileName);
        if (match != null) {
          metadata['track'] = match.group(1)!;
          DebugLogger.logInfo('Metadata', 'Track adivinado del nombre: ${metadata['track']}');
        }
      }

      return metadata;
    } catch (e) {
      return _defaultMetadata();
    }
  }

  static Future<Map<String, String>> readFlacMetadata(String filePath) async {
    try {
      final file = File(filePath);
      final raf = await file.open(mode: FileMode.read);
      final header = await raf.read(4);
      if (header.length < 4 || header[0] != 0x66 || header[1] != 0x4C || header[2] != 0x61 || header[3] != 0x43) {
        await raf.close();
        return _defaultMetadata();
      }
      Map<String, String> metadata = _defaultMetadata();
      bool isLastBlock = false;
      while (!isLastBlock) {
        final blockHeader = (await raf.read(1))[0];
        isLastBlock = (blockHeader & 0x80) != 0;
        final blockType = blockHeader & 0x7F;
        final blockSizeBytes = await raf.read(3);
        final blockSize = (blockSizeBytes[0] << 16) | (blockSizeBytes[1] << 8) | blockSizeBytes[2];
        if (blockType == 4) {
          final commentData = await raf.read(blockSize);
          metadata.addAll(_parseVorbisComment(commentData, 0));
        } else if (blockType == 6) {
          final pictureData = await raf.read(blockSize);
          final coverPath = await _saveCoverArt(pictureData, filePath);
          if (coverPath != null) metadata['image'] = coverPath;
        } else {
          await raf.setPosition(await raf.position() + blockSize);
        }
      }
      await raf.close();
      return metadata;
    } catch (e) {
      return _defaultMetadata();
    }
  }

  static Future<Map<String, String>> _readMp3Metadata(String filePath) async {
    try {
      final file = File(filePath);
      final raf = await file.open(mode: FileMode.read);
      final header = await raf.read(10);
      if (header.length < 10 || header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        await raf.close();
        return _defaultMetadata();
      }
      int version = header[3];
      int totalTagSize = ((header[6] & 0x7F) << 21) | ((header[7] & 0x7F) << 14) | ((header[8] & 0x7F) << 7) | (header[9] & 0x7F);
      Map<String, String> metadata = _defaultMetadata();
      int pos = 10;
      while (pos < totalTagSize + 10) {
        final frameHeader = await raf.read(10);
        if (frameHeader.length < 10 || frameHeader[0] == 0) break;
        String frameId = latin1.decode(frameHeader.sublist(0, 4));
        int frameSize;
        if (version == 4) {
          frameSize = ((frameHeader[4] & 0x7F) << 21) | ((frameHeader[5] & 0x7F) << 14) | ((frameHeader[6] & 0x7F) << 7) | (frameHeader[7] & 0x7F);
        } else {
          frameSize = (frameHeader[4] << 24) | (frameHeader[5] << 16) | (frameHeader[6] << 8) | frameHeader[7];
        }
        if (frameSize <= 0 || pos + 10 + frameSize > totalTagSize + 10) break;
        final frameData = await raf.read(frameSize);
        pos += 10 + frameSize;
        if (frameId == 'TIT2') metadata['title'] = _decodeId3Text(frameData);
        else if (frameId == 'TPE1') metadata['artist'] = _decodeId3Text(frameData);
        else if (frameId == 'TALB') metadata['album'] = _decodeId3Text(frameData);
        else if (frameId == 'TRCK') {
          String trck = _decodeId3Text(frameData);
          if (trck.contains('/')) trck = trck.split('/')[0];
          metadata['track'] = trck;
        }
        else if (frameId == 'APIC') {
          final coverPath = await _saveMp3CoverArt(frameData, filePath);
          if (coverPath != null) metadata['image'] = coverPath;
        }
      }
      await raf.close();
      return metadata;
    } catch (e) {
      return _defaultMetadata();
    }
  }

  static String _decodeId3Text(Uint8List data) {
    if (data.isEmpty) return '';
    int encoding = data[0];
    try {
      if (encoding == 0) return latin1.decode(data.sublist(1)).replaceAll('\u0000', '').trim();
      if (encoding == 1 || encoding == 2) return _decodeUTF16(data.sublist(1)).trim();
      if (encoding == 3) return utf8.decode(data.sublist(1)).replaceAll('\u0000', '').trim();
    } catch (_) {}
    return utf8.decode(data.sublist(1), allowMalformed: true).replaceAll('\u0000', '').trim();
  }

  static String _decodeUTF16(Uint8List bytes) {
    if (bytes.length < 2) return '';
    int start = 0;
    bool bigEndian = false;
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) { bigEndian = true; start = 2; }
    else if (bytes[0] == 0xFF && bytes[1] == 0xFE) { bigEndian = false; start = 2; }
    List<int> units = [];
    for (int i = start; i < bytes.length - 1; i += 2) {
      int u = bigEndian ? (bytes[i] << 8) | bytes[i + 1] : (bytes[i + 1] << 8) | bytes[i];
      if (u != 0) units.add(u);
    }
    return String.fromCharCodes(units);
  }

  static Future<String?> _saveMp3CoverArt(Uint8List data, String musicFilePath) async {
    try {
      int imgStart = -1;
      for (int i = 0; i < data.length - 4; i++) {
        if (data[i] == 0xFF && data[i+1] == 0xD8 && data[i+2] == 0xFF) { imgStart = i; break; }
        if (data[i] == 0x89 && data[i+1] == 0x50 && data[i+2] == 0x4E && data[i+3] == 0x47) { imgStart = i; break; }
      }
      if (imgStart == -1) return null;
      final imgBytes = data.sublist(imgStart);
      final appDocDir = await getApplicationDocumentsDirectory();
      final coversDir = Directory(p.join(appDocDir.path, 'Covers'));
      if (!await coversDir.exists()) await coversDir.create(recursive: true);
      final fileName = p.basenameWithoutExtension(musicFilePath);
      final coverFile = File(p.join(coversDir.path, 'cover_$fileName.jpg'));
      await coverFile.writeAsBytes(imgBytes);
      return coverFile.path;
    } catch (e) { return null; }
  }

  static Future<String?> _saveCoverArt(Uint8List blockData, String musicFilePath) async {
    try {
      int pos = 4;
      int mimeLen = (blockData[pos] << 24) | (blockData[pos+1] << 16) | (blockData[pos+2] << 8) | blockData[pos+3];
      pos += 4 + mimeLen;
      int descLen = (blockData[pos] << 24) | (blockData[pos+1] << 16) | (blockData[pos+2] << 8) | blockData[pos+3];
      pos += 4 + descLen;
      pos += 16;
      int dataLen = (blockData[pos] << 24) | (blockData[pos+1] << 16) | (blockData[pos+2] << 8) | blockData[pos+3];
      pos += 4;
      if (pos + dataLen <= blockData.length) {
        final imgBytes = blockData.sublist(pos, pos + dataLen);
        final appDocDir = await getApplicationDocumentsDirectory();
        final coversDir = Directory(p.join(appDocDir.path, 'Covers'));
        if (!await coversDir.exists()) await coversDir.create(recursive: true);
        final fileName = p.basenameWithoutExtension(musicFilePath);
        final coverFile = File(p.join(coversDir.path, 'cover_$fileName.jpg'));
        await coverFile.writeAsBytes(imgBytes);
        return coverFile.path;
      }
    } catch (_) {}
    return null;
  }

  static Map<String, String> _parseVorbisComment(Uint8List bytes, int offset) {
    Map<String, String> result = {};
    try {
      int vendorLen = bytes[offset] | (bytes[offset+1] << 8) | (bytes[offset+2] << 16) | (bytes[offset+3] << 24);
      int commentPos = offset + 4 + vendorLen;
      int numComments = bytes[commentPos] | (bytes[commentPos+1] << 8) | (bytes[commentPos+2] << 16) | (bytes[commentPos+3] << 24);
      commentPos += 4;
      for (int i = 0; i < numComments; i++) {
        if (commentPos + 4 > bytes.length) break;
        int commentLen = bytes[commentPos] | (bytes[commentPos+1] << 8) | (bytes[commentPos+2] << 16) | (bytes[commentPos+3] << 24);
        commentPos += 4;
        if (commentPos + commentLen > bytes.length) break;
        String comment = utf8.decode(bytes.sublist(commentPos, commentPos + commentLen), allowMalformed: true);
        if (comment.contains('=')) {
          final parts = comment.split('=');
          final key = parts[0].toLowerCase().trim();
          final value = parts.sublist(1).join('=').trim();
          if (key == 'title') result['title'] = value;
          else if (key == 'artist') result['artist'] = value;
          else if (key == 'album') result['album'] = value;
          else if (key == 'tracknumber' || key == 'track' || key == 'track_number') result['track'] = value;
        }
        commentPos += commentLen;
      }
    } catch (_) {}
    return result;
  }

  static Map<String, String> _defaultMetadata() {
    return {'title': 'Desconocido', 'artist': 'Desconocido', 'album': 'Desconocido', 'image': '', 'track': '0'};
  }
}
