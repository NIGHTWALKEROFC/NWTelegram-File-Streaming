import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'telegram_service.dart';

class StreamService extends ChangeNotifier {
  HttpServer? _server;
  bool _isRunning = false;
  int _activeFileId = 0;

  bool get isRunning => _isRunning;
  // Restored: streamUrl getter
  String get streamUrl => 'http://127.0.0.1:8484/stream';

  // Restored: setActiveFile method
  void setActiveFile(int fileId, int fileSize, String mimeType) {
    _activeFileId = fileId;
    notifyListeners();
  }

  Future<void> startServer(TelegramService telegram) async {
    if (_isRunning) return;
    final router = Router();
    router.get('/stream', (Request req) => Response.ok('Streaming...'));
    try {
      _server = await shelf_io.serve(router, '127.0.0.1', 8484);
      _isRunning = true;
      notifyListeners();
    } catch (e) {
      debugPrint("Server Error: $e");
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _isRunning = false;
    notifyListeners();
  }
}
