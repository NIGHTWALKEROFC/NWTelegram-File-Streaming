import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'telegram_service.dart';

/// Chunk size for streaming: 512 KB per request to Telegram
const int kChunkSize = 512 * 1024;

/// The local port used for the streaming proxy
const int kProxyPort = 8484;

class StreamService extends ChangeNotifier {
  HttpServer? _server;
  TelegramService? _telegramService;
  bool _isRunning = false;
  int _activeFileId = 0;
  int _activeFileSize = 0;
  String _activeMimeType = 'application/octet-stream';

  bool get isRunning => _isRunning;
  String get streamUrl => 'http://127.0.0.1:$kProxyPort/stream';

  // ──────────────────────────────────────────
  // Start / Stop the local proxy server
  // ──────────────────────────────────────────
  Future<void> startServer(TelegramService telegramService) async {
    // Always stop cleanly before rebinding — prevents "address already in use"
    await stopServer();

    _telegramService = telegramService;

    final router = Router();
    router.get('/ping', (Request req) => Response.ok('pong'));
    router.get('/stream', _handleStreamRequest);
    router.head('/stream', _handleHeadRequest);

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addHandler(router);

    // Retry binding up to 3 times in case the port is momentarily busy
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _server = await shelf_io.serve(handler, '127.0.0.1', kProxyPort);
        _server!.autoCompress = true;
        _isRunning = true;
        debugPrint('StreamService: proxy running on port $kProxyPort');
        notifyListeners();
        return;
      } on SocketException catch (e) {
        debugPrint('StreamService: bind attempt $attempt failed: $e');
        if (attempt < 3) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    debugPrint('StreamService: could not bind after 3 attempts');
  }

  Future<void> stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _isRunning = false;
    notifyListeners();
  }

  /// Call this before navigating to the player to register the active file
  void setActiveFile({
    required int fileId,
    required int fileSize,
    required String mimeType,
  }) {
    _activeFileId = fileId;
    _activeFileSize = fileSize;
    _activeMimeType = mimeType;
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // HEAD — lets the video player know file size & MIME upfront
  // ──────────────────────────────────────────
  Future<Response> _handleHeadRequest(Request request) async {
    if (_activeFileId == 0 || _telegramService == null) {
      return Response.notFound('No active file');
    }

    final fileSize = _activeFileSize > 0
        ? _activeFileSize
        : await _telegramService!.getFileSize(_activeFileId);

    return Response.ok(
      null,
      headers: {
        'Content-Type': _activeMimeType,
        'Content-Length': fileSize.toString(),
        'Accept-Ranges': 'bytes',
        'Connection': 'keep-alive',
      },
    );
  }

  // ──────────────────────────────────────────
  // GET — serve full file or a byte range
  // ──────────────────────────────────────────
  Future<Response> _handleStreamRequest(Request request) async {
    if (_activeFileId == 0 || _telegramService == null) {
      return Response.notFound('No active file');
    }

    final fileSize = _activeFileSize > 0
        ? _activeFileSize
        : await _telegramService!.getFileSize(_activeFileId);

    if (fileSize <= 0) {
      return Response.internalServerError(
          body: 'Could not determine file size');
    }

    final rangeHeader = request.headers['range'];
    if (rangeHeader == null) {
      return _streamRange(0, fileSize - 1, fileSize, fileSize,
          statusCode: 200);
    }

    final range = _parseRange(rangeHeader, fileSize);
    if (range == null) {
      return Response(416, headers: {'Content-Range': 'bytes */$fileSize'});
    }

    final start = range.$1;
    final end = range.$2;
    final length = end - start + 1;
    return _streamRange(start, end, length, fileSize);
  }

  Response _streamRange(
    int start,
    int end,
    int length,
    int fileSize, {
    int statusCode = 206,
  }) {
    final controller = StreamController<List<int>>();
    _fetchChunksAsync(start, end, controller);

    final headers = {
      'Content-Type': _activeMimeType,
      'Content-Length': length.toString(),
      'Accept-Ranges': 'bytes',
      'Connection': 'keep-alive',
    };
    if (statusCode == 206) {
      headers['Content-Range'] = 'bytes $start-$end/$fileSize';
    }

    return Response(statusCode, body: controller.stream, headers: headers);
  }

  void _fetchChunksAsync(
    int start,
    int end,
    StreamController<List<int>> controller,
  ) {
    Future(() async {
      try {
        int offset = start;
        while (offset <= end) {
          final chunkEnd = (offset + kChunkSize - 1).clamp(offset, end);
          final count = chunkEnd - offset + 1;

          final bytes = await _telegramService!.downloadFilePart(
            fileId: _activeFileId,
            offset: offset,
            count: count,
          );

          if (bytes == null || bytes.isEmpty) break;
          if (!controller.isClosed) controller.add(bytes);
          offset += bytes.length;
        }
      } catch (e) {
        debugPrint('Streaming chunk error: $e');
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    });
  }

  // ──────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────
  (int, int)? _parseRange(String header, int fileSize) {
    final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(header);
    if (match == null) return null;
    final startStr = match.group(1) ?? '';
    final endStr = match.group(2) ?? '';
    int start = startStr.isEmpty ? 0 : int.tryParse(startStr) ?? 0;
    int end =
        endStr.isEmpty ? fileSize - 1 : int.tryParse(endStr) ?? fileSize - 1;
    end = end.clamp(0, fileSize - 1);
    start = start.clamp(0, end);
    return (start, end);
  }

  Middleware _corsMiddleware() {
    return (Handler inner) => (Request req) async {
          final res = await inner(req);
          return res.change(headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
            'Access-Control-Allow-Headers': 'Range, Content-Type',
          });
        };
  }

  @override
  void dispose() {
    stopServer();
    super.dispose();
  }
}
