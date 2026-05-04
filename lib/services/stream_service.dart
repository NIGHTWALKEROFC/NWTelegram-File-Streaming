import 'dart:async';
import 'dart:io'; // ← added: HttpServer lives here
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'telegram_service.dart';
import '../models/telegram_file.dart';

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

  // ──────────────────────────────────────────
  // Start / Stop the local proxy server
  // ──────────────────────────────────────────
  Future<void> startServer(TelegramService telegramService) async {
    if (_isRunning) await stopServer();

    _telegramService = telegramService;

    final router = Router();

    // Health check
    router.get('/ping', (Request req) {
      return Response.ok('pong');
    });

    // Main stream endpoint
    router.get('/stream', _handleStreamRequest);
    router.head('/stream', _handleHeadRequest);

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addHandler(router);

    try {
      _server = await shelf_io.serve(handler, '127.0.0.1', kProxyPort);
      _isRunning = true;
      debugPrint('StreamService: proxy running on port $kProxyPort');
      notifyListeners();
    } catch (e) {
      debugPrint('StreamService: failed to start server: $e');
    }
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    notifyListeners();
  }

  /// Set the active file to stream
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

  /// Returns the localhost URL the video player should use
  String get streamUrl => 'http://127.0.0.1:$kProxyPort/stream';

  // ──────────────────────────────────────────
  // Handle HEAD request (player needs this for metadata)
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
  // Handle GET stream request with Range support
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
      return _streamFullFile(fileSize);
    }

    final range = _parseRange(rangeHeader, fileSize);
    if (range == null) {
      return Response(416, headers: {
        'Content-Range': 'bytes */$fileSize',
      });
    }

    final start = range.$1;
    final end = range.$2;
    final length = end - start + 1;

    return _streamRange(start, end, length, fileSize);
  }

  Response _streamFullFile(int fileSize) {
    final controller = StreamController<List<int>>();
    _fetchChunksAsync(0, fileSize - 1, controller);
    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': _activeMimeType,
        'Content-Length': fileSize.toString(),
        'Accept-Ranges': 'bytes',
        'Connection': 'keep-alive',
      },
    );
  }

  Response _streamRange(int start, int end, int length, int fileSize) {
    final controller = StreamController<List<int>>();
    _fetchChunksAsync(start, end, controller);
    return Response(
      206,
      body: controller.stream,
      headers: {
        'Content-Type': _activeMimeType,
        'Content-Length': length.toString(),
        'Content-Range': 'bytes $start-$end/$fileSize',
        'Accept-Ranges': 'bytes',
        'Connection': 'keep-alive',
      },
    );
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
          if (!controller.isClosed) {
            controller.add(bytes);
          }
          offset += bytes.length;
        }
      } catch (e) {
        debugPrint('Streaming error: $e');
      } finally {
        if (!controller.isClosed) {
          await controller.close();
        }
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
    return (Handler innerHandler) {
      return (Request request) async {
        final response = await innerHandler(request);
        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
          'Access-Control-Allow-Headers': 'Range, Content-Type',
        });
      };
    };
  }

  @override
  void dispose() {
    stopServer();
    super.dispose();
  }
}
