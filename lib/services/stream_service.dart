// lib/services/stream_service.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'telegram_service.dart';

const int kChunkSize  = 256 * 1024; // 256 KB per read
const int kProxyPort  = 8484;

// If a Range request starts more than this many bytes ahead of where
// TDLib has downloaded so far, restart the download from the new offset.
// This makes seeking in large files instant instead of waiting for TDLib
// to download all bytes from the beginning.
const int kSeekRestartThreshold = 2 * 1024 * 1024; // 2 MB ahead = restart

class StreamService extends ChangeNotifier {
  HttpServer?      _server;
  TelegramService? _telegramService;
  bool   _isRunning      = false;
  int    _activeFileId   = 0;
  int    _activeFileSize = 0;
  String _activeMimeType = 'application/octet-stream';

  bool   get isRunning  => _isRunning;
  String get streamUrl  => 'http://127.0.0.1:$kProxyPort/stream';

  // ── Start / Stop ───────────────────────────────────────────────────────────

  Future<void> startServer(TelegramService telegramService) async {
    await stopServer();
    _telegramService = telegramService;

    final router = Router();
    router.get('/ping',   (Request req) => Response.ok('pong'));
    router.get('/stream', _handleStreamRequest);
    router.head('/stream', _handleHeadRequest);
    router.options('/stream',
        (Request req) => Response.ok('', headers: _corsHeaders()));

    final handler =
        const Pipeline().addMiddleware(_corsMiddleware()).addHandler(router);

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _server     = await shelf_io.serve(handler, '127.0.0.1', kProxyPort);
        _isRunning  = true;
        debugPrint('StreamService: proxy on port $kProxyPort');
        notifyListeners();
        return;
      } on SocketException catch (e) {
        debugPrint('StreamService: bind attempt $attempt failed: $e');
        if (attempt < 3) await Future.delayed(const Duration(milliseconds: 600));
      }
    }
    debugPrint('StreamService: could not bind after 3 attempts');
  }

  Future<void> stopServer() async {
    try { await _server?.close(force: true); } catch (_) {}
    _server    = null;
    _isRunning = false;
    notifyListeners();
  }

  // Called before opening the player.
  // Starts background TDLib download from byte 0.
  Future<bool> prepareFile({
    required int    fileId,
    required int    fileSize,
    required String mimeType,
  }) async {
    _activeFileId   = fileId;
    _activeFileSize = fileSize;
    _activeMimeType = mimeType;

    debugPrint('StreamService.prepareFile id=$fileId size=$fileSize');

    if (_telegramService == null) return false;

    final result = await _telegramService!.startFileDownload(fileId, offset: 0);
    debugPrint('StreamService.prepareFile result=$result');
    notifyListeners();
    return result != null;
  }

  // ── HEAD ───────────────────────────────────────────────────────────────────

  Future<Response> _handleHeadRequest(Request request) async {
    if (_activeFileId == 0 || _telegramService == null) {
      return Response.notFound('No active file');
    }

    int fileSize = _activeFileSize;
    if (fileSize <= 0) {
      fileSize = await _telegramService!.getFileSize(_activeFileId);
    }

    final headers = <String, String>{
      'Content-Type': _activeMimeType,
      'Accept-Ranges': 'bytes',
      'Connection': 'keep-alive',
    };
    if (fileSize > 0) headers['Content-Length'] = fileSize.toString();

    return Response.ok('', headers: headers);
  }

  // ── GET ────────────────────────────────────────────────────────────────────

  Future<Response> _handleStreamRequest(Request request) async {
    if (_activeFileId == 0 || _telegramService == null) {
      return Response.notFound('No active file');
    }

    int fileSize = _activeFileSize;
    if (fileSize <= 0) {
      fileSize = await _telegramService!.getFileSize(_activeFileId);
    }

    final rangeHeader = request.headers['range'];

    if (fileSize <= 0) {
      return _buildStreamResponse(
        start: 0, end: -1, contentLength: -1,
        fileSize: -1, statusCode: 200,
      );
    }

    if (rangeHeader == null) {
      return _buildStreamResponse(
        start: 0, end: fileSize - 1, contentLength: fileSize,
        fileSize: fileSize, statusCode: 200,
      );
    }

    final range = _parseRange(rangeHeader, fileSize);
    if (range == null) {
      return Response(416, headers: {'Content-Range': 'bytes */$fileSize'});
    }

    final start  = range.$1;
    final end    = range.$2;
    final length = end - start + 1;

    // ── SEEK DETECTION ──────────────────────────────────────────────────────
    // If libmpv asks for bytes far ahead of what TDLib has downloaded,
    // restart TDLib download from the seek position so playback resumes fast.
    // Without this, a seek to 50% of a 1GB file would wait for TDLib to
    // download 500MB from the start before serving a single byte.
    if (start > 0 && _telegramService != null) {
      final downloaded = _telegramService!.activeDownloadPrefix;
      final gap = start - downloaded;
      if (gap > kSeekRestartThreshold) {
        debugPrint(
            'StreamService: seek detected — start=$start downloaded=$downloaded '
            'gap=$gap > threshold=$kSeekRestartThreshold — restarting download');
        // Restart TDLib download from the seek offset
        await _telegramService!.startFileDownload(
          _activeFileId,
          offset: start,
        );
      }
    }

    return _buildStreamResponse(
      start: start, end: end, contentLength: length,
      fileSize: fileSize, statusCode: 206,
    );
  }

  // ── Stream builder ─────────────────────────────────────────────────────────

  Response _buildStreamResponse({
    required int start,
    required int end,
    required int contentLength,
    required int fileSize,
    required int statusCode,
  }) {
    final controller = StreamController<List<int>>();
    _fetchChunks(start, end, controller);

    final headers = <String, String>{
      'Content-Type': _activeMimeType,
      'Accept-Ranges': 'bytes',
      'Connection': 'keep-alive',
    };
    if (contentLength > 0) headers['Content-Length'] = contentLength.toString();
    if (statusCode == 206 && fileSize > 0) {
      headers['Content-Range'] = 'bytes $start-$end/$fileSize';
    }

    return Response(statusCode, body: controller.stream, headers: headers);
  }

  // ── Chunk fetcher ──────────────────────────────────────────────────────────

  void _fetchChunks(
    int start,
    int end,
    StreamController<List<int>> controller,
  ) {
    final bool unbounded = end < 0;

    Future(() async {
      int offset = start;
      try {
        while (true) {
          if (controller.isClosed) break;
          if (!unbounded && offset > end) break;

          final remaining = unbounded ? kChunkSize : (end - offset + 1);
          final count     = remaining.clamp(1, kChunkSize);

          final Uint8List? bytes = await _telegramService!.readFileBytes(
            offset: offset,
            count:  count,
            timeoutSeconds: 120,
          );

          if (bytes == null) {
            debugPrint('StreamService: null at offset=$offset — stopping');
            break;
          }
          if (bytes.isEmpty) {
            debugPrint('StreamService: EOF at offset=$offset');
            break;
          }

          if (!controller.isClosed) controller.add(bytes);
          offset += bytes.length;
        }
      } catch (e, st) {
        debugPrint('StreamService chunk error: $e\n$st');
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    });
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  (int, int)? _parseRange(String header, int fileSize) {
    final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(header);
    if (match == null) return null;
    final startStr = match.group(1) ?? '';
    final endStr   = match.group(2) ?? '';
    int start, end;
    if (startStr.isEmpty && endStr.isNotEmpty) {
      final suffix = int.tryParse(endStr) ?? 0;
      start = (fileSize - suffix).clamp(0, fileSize - 1);
      end   = fileSize - 1;
    } else {
      start = startStr.isEmpty ? 0 : int.tryParse(startStr) ?? 0;
      end   = endStr.isEmpty ? fileSize - 1 : int.tryParse(endStr) ?? fileSize - 1;
    }
    end   = end.clamp(0, fileSize - 1);
    start = start.clamp(0, end);
    return (start, end);
  }

  Map<String, String> _corsHeaders() => {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
        'Access-Control-Allow-Headers': 'Range, Content-Type',
      };

  Middleware _corsMiddleware() => (Handler inner) => (Request req) async {
        final res = await inner(req);
        return res.change(headers: _corsHeaders());
      };

  @override
  void dispose() {
    stopServer();
    super.dispose();
  }
}
