// lib/services/telegram_service.dart
//
// KEY CHANGES vs previous version
// ────────────────────────────────
// 1. readFilePart()  — NEW.
//    Calls TDLib's own `readFilePart` API instead of reading from disk.
//    TDLib downloads exactly the requested bytes and returns them directly.
//    This is the fix for every "skip to end" / "only 1 second shows" bug:
//    we never read from TDLib's sparse temp file again.
//
// 2. downloadAndWait() — NEW.
//    For small files (audio, docs ≤ 50 MB): downloads the whole file
//    synchronously via TDLib and returns the local path when complete.
//    media_kit then plays from file:// — no HTTP proxy involved at all.
//    This eliminates every MIME-type / Content-Length / range-request issue
//    for audio and small files.
//
// 3. startFileDownload() — kept for large videos (proxy mode).
//    Uses synchronous:false so the proxy can start streaming immediately.
//    readFilePart() is used by the proxy instead of readFileBytes().
//
// 4. cancelAndDeleteFile() — unchanged logic, added retry for OS handle.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:handy_tdlib/handy_tdlib.dart';
import 'package:path_provider/path_provider.dart';

import '../models/telegram_file.dart';

const int _kApiId   = int.fromEnvironment('TG_API_ID',   defaultValue: 0);
const String _kApiHash = String.fromEnvironment('TG_API_HASH', defaultValue: '');

// Files smaller than this are downloaded fully before playback.
// 50 MB covers every audio file and most short videos.
const int kSmallFileThreshold = 50 * 1024 * 1024;

enum AuthState {
  idle, waitingPhone, waitingCode, waitingPassword,
  waitingRegistration, authorized, error,
}

class TelegramService extends ChangeNotifier {
  int    _clientId = 0;
  Timer? _pollTimer;

  final _updateCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updateCtrl.stream;

  AuthState _authState  = AuthState.idle;
  String _errorMessage  = '';
  bool _isLoggedIn      = false;
  bool _isInitialized   = false;

  // ── Active download state (used by proxy for large files) ──────────────────
  int    _dlFileId    = 0;
  String _dlPath      = '';
  int    _dlAbsPrefix = 0;
  bool   _dlComplete  = false;
  int    _dlFileSize  = 0; // resolved size (may start 0, filled by updateFile)

  AuthState get authState     => _authState;
  String    get errorMessage  => _errorMessage;
  bool      get isLoggedIn    => _isLoggedIn;
  bool      get isInitialized => _isInitialized;
  int       get dlAbsPrefix   => _dlAbsPrefix;
  bool      get dlComplete    => _dlComplete;
  int       get dlFileSize    => _dlFileSize;

  // ── Initialize ─────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_kApiId == 0 || _kApiHash.isEmpty) {
      _errorMessage =
          'Telegram API credentials missing.\n'
          'Set TG_API_ID and TG_API_HASH in Codemagic → '
          'Environment Variables (group: telegram_keys).';
      _authState = AuthState.error;
      notifyListeners();
      return;
    }
    try {
      TdPlugin.initialize();
      _clientId = TdPlugin.instance.tdCreateClientId();
      _startPolling();

      final appDir    = await getApplicationDocumentsDirectory();
      final dbPath    = '${appDir.path}/tdlib_db';
      final filesPath = '${appDir.path}/tdlib_files';
      await io.Directory(dbPath).create(recursive: true);
      await io.Directory(filesPath).create(recursive: true);

      _send({
        '@type': 'setTdlibParameters',
        'use_test_dc': false,
        'database_directory': dbPath,
        'files_directory': filesPath,
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': false,
        'api_id': _kApiId,
        'api_hash': _kApiHash,
        'system_language_code': 'en',
        'device_model': io.Platform.isAndroid ? 'Android' : 'iOS',
        'system_version': 'Unknown',
        'application_version': '1.0.0',
        'enable_storage_optimizer': true,
      });

      _isInitialized = true;
      await updates
          .where((u) => u['@type'] == 'updateAuthorizationState')
          .first
          .timeout(const Duration(seconds: 10), onTimeout: () => {});
    } catch (e, st) {
      debugPrint('TelegramService.initialize error: $e\n$st');
      _errorMessage = e.toString();
      _authState    = AuthState.error;
      notifyListeners();
    }
  }

  // ── Polling ────────────────────────────────────────────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (_updateCtrl.isClosed) return;
      try {
        final raw = TdPlugin.instance.tdReceive(0.0);
        if (raw != null && raw.isNotEmpty) _onRawUpdate(raw);
      } catch (e) {
        debugPrint('tdReceive error: $e');
      }
    });
  }

  void _onRawUpdate(String raw) {
    try {
      final u = jsonDecode(raw) as Map<String, dynamic>;
      _updateCtrl.add(u);
      _handleUpdate(u);
    } catch (e) {
      debugPrint('TDLib JSON parse error: $e');
    }
  }

  void _handleUpdate(Map<String, dynamic> u) {
    switch (u['@type'] as String?) {
      case 'updateAuthorizationState':
        final s = u['authorization_state'] as Map<String, dynamic>?;
        if (s != null) _handleAuthState(s);
        break;

      case 'updateFile':
        final file = u['file'] as Map<String, dynamic>?;
        if (file == null) break;
        final fileId = file['id'] as int? ?? 0;
        if (fileId != _dlFileId) break;
        final local     = file['local'] as Map<String, dynamic>?;
        if (local == null) break;
        final path      = local['path']                      as String? ?? '';
        final absPrefix = local['downloaded_prefix_size']    as int?    ?? 0;
        final complete  = local['is_downloading_completed']  as bool?   ?? false;
        if (path.isNotEmpty && _dlPath.isEmpty) _dlPath = path;
        if (absPrefix > _dlAbsPrefix) _dlAbsPrefix = absPrefix;
        if (complete) _dlComplete = true;
        // Also capture resolved file size
        final sz = (file['size'] as int? ?? 0) > 0
            ? file['size'] as int
            : (file['expected_size'] as int? ?? 0);
        if (sz > 0 && _dlFileSize == 0) _dlFileSize = sz;
        debugPrint(
            'updateFile[$fileId] absPrefix=$absPrefix complete=$complete sz=$sz');
        break;
    }
  }

  void _handleAuthState(Map<String, dynamic> state) {
    final type = state['@type'] as String? ?? '';
    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _authState = AuthState.idle;
        break;
      case 'authorizationStateWaitEncryptionKey':
        _send({'@type': 'checkDatabaseEncryptionKey', 'encryption_key': ''});
        return;
      case 'authorizationStateWaitPhoneNumber':
        _authState  = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;
      case 'authorizationStateWaitCode':
        _authState = AuthState.waitingCode;
        break;
      case 'authorizationStateWaitOtherDeviceConfirmation':
        _authState    = AuthState.waitingCode;
        _errorMessage = 'Confirm login on your other Telegram device.';
        break;
      case 'authorizationStateWaitRegistration':
        _authState = AuthState.waitingRegistration;
        break;
      case 'authorizationStateWaitPassword':
        _authState = AuthState.waitingPassword;
        break;
      case 'authorizationStateReady':
        _authState    = AuthState.authorized;
        _isLoggedIn   = true;
        _errorMessage = '';
        break;
      case 'authorizationStateLoggingOut':
      case 'authorizationStateClosing':
      case 'authorizationStateClosed':
        _authState  = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;
    }
    notifyListeners();
  }

  // ── Auth actions ───────────────────────────────────────────────────────────

  Future<bool> sendPhoneNumber(String phone) async {
    _errorMessage = '';
    final c = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (c.isCompleted) return;
      if (u['@type'] == 'error') {
        _errorMessage = u['message'] as String? ?? 'Error';
        notifyListeners(); c.complete(false); sub.cancel(); return;
      }
      if (u['@type'] == 'updateAuthorizationState') {
        final t = (u['authorization_state']
            as Map<String, dynamic>?)?['@type'] as String?;
        if (t == 'authorizationStateWaitCode' ||
            t == 'authorizationStateWaitOtherDeviceConfirmation' ||
            t == 'authorizationStateWaitPassword' ||
            t == 'authorizationStateReady') {
          c.complete(true); sub.cancel();
        }
      }
    });
    _send({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phone,
      'settings': {
        '@type': 'phoneNumberAuthenticationSettings',
        'allow_flash_call': false, 'allow_missed_call': false,
        'is_current_phone_number': true, 'allow_sms_retriever_api': false,
      },
    });
    if (!c.isCompleted && (_authState == AuthState.waitingCode ||
        _authState == AuthState.waitingPassword ||
        _authState == AuthState.authorized)) {
      c.complete(true); sub.cancel();
    }
    return c.future.timeout(const Duration(seconds: 60), onTimeout: () {
      sub.cancel();
      if (_authState == AuthState.waitingCode ||
          _authState == AuthState.waitingPassword ||
          _authState == AuthState.authorized) return true;
      _errorMessage = 'Check your internet and try again.';
      notifyListeners(); return false;
    });
  }

  Future<bool> sendOtpCode(String code) async {
    _errorMessage = '';
    final c = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (c.isCompleted) return;
      if (u['@type'] == 'error') {
        _errorMessage = u['message'] as String? ?? 'Invalid code';
        notifyListeners(); c.complete(false); sub.cancel(); return;
      }
      if (u['@type'] == 'updateAuthorizationState') {
        final t = (u['authorization_state']
            as Map<String, dynamic>?)?['@type'] as String?;
        if (t == 'authorizationStateReady' ||
            t == 'authorizationStateWaitPassword') {
          c.complete(true); sub.cancel();
        }
      }
    });
    _send({'@type': 'checkAuthenticationCode', 'code': code});
    if (!c.isCompleted && (_authState == AuthState.authorized ||
        _authState == AuthState.waitingPassword)) {
      c.complete(true); sub.cancel();
    }
    return c.future.timeout(const Duration(seconds: 30), onTimeout: () {
      sub.cancel();
      if (_authState == AuthState.authorized ||
          _authState == AuthState.waitingPassword) return true;
      _errorMessage = _errorMessage.isNotEmpty ? _errorMessage : 'Timed out.';
      notifyListeners(); return false;
    });
  }

  Future<bool> sendPassword(String password) async {
    _errorMessage = '';
    final c = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (c.isCompleted) return;
      if (u['@type'] == 'error') {
        _errorMessage = u['message'] as String? ?? 'Wrong password';
        notifyListeners(); c.complete(false); sub.cancel(); return;
      }
      if (u['@type'] == 'updateAuthorizationState') {
        final t = (u['authorization_state']
            as Map<String, dynamic>?)?['@type'] as String?;
        if (t == 'authorizationStateReady') { c.complete(true); sub.cancel(); }
      }
    });
    _send({'@type': 'checkAuthenticationPassword', 'password': password});
    if (!c.isCompleted && _authState == AuthState.authorized) {
      c.complete(true); sub.cancel();
    }
    return c.future.timeout(const Duration(seconds: 30), onTimeout: () {
      sub.cancel();
      if (_authState == AuthState.authorized) return true;
      _errorMessage = _errorMessage.isNotEmpty ? _errorMessage : 'Timed out.';
      notifyListeners(); return false;
    });
  }

  Future<void> logout() async {
    _send({'@type': 'logOut'});
    _authState = AuthState.waitingPhone;
    _isLoggedIn = false;
    notifyListeners();
  }

  // ── Chat + media loading ───────────────────────────────────────────────────

  Future<List<int>> _getChatIds() async {
    await _request({
      '@type': 'loadChats',
      'chat_list': {'@type': 'chatListMain'},
      'limit': 100,
    });
    final res = await _request({
      '@type': 'getChats',
      'chat_list': {'@type': 'chatListMain'},
      'limit': 100,
    });
    if (res == null || res['@type'] == 'error') return [];
    return (res['chat_ids'] as List?)?.map((e) => e as int).toList() ?? [];
  }

  Future<List<TelegramFile>> _getMediaFromChat(int chatId, int limit) async {
    const filters = [
      'searchMessagesFilterVideo',   'searchMessagesFilterAudio',
      'searchMessagesFilterDocument','searchMessagesFilterVoiceNote',
      'searchMessagesFilterVideoNote',
    ];
    final results = await Future.wait(filters.map((filter) async {
      try {
        final res = await _request({
          '@type': 'searchChatMessages',
          'chat_id': chatId, 'query': '', 'from_message_id': 0,
          'offset': 0, 'limit': limit,
          'filter': {'@type': filter}, 'message_thread_id': 0,
        }, timeout: const Duration(seconds: 15));
        if (res == null || res['@type'] == 'error') return <TelegramFile>[];
        final msgs = res['messages'] as List? ?? [];
        final files = <TelegramFile>[];
        for (final msg in msgs) {
          final f = _parseMessage(msg as Map<String, dynamic>);
          if (f != null && f.fileId > 0) files.add(f);
        }
        return files;
      } catch (_) { return <TelegramFile>[]; }
    }));
    return results.expand((r) => r).toList();
  }

  Stream<List<TelegramFile>> streamAllMediaFiles(
      {int limitPerChat = 30}) async* {
    final accumulated = <TelegramFile>[];
    List<int> chatIds;
    try { chatIds = await _getChatIds(); }
    catch (_) { yield []; return; }
    if (chatIds.isEmpty) { yield []; return; }

    const batchSize = 3;
    for (int i = 0; i < chatIds.length; i += batchSize) {
      final batch = chatIds.skip(i).take(batchSize).toList();
      final results = await Future.wait(
          batch.map((id) => _getMediaFromChat(id, limitPerChat)
              .catchError((_) => <TelegramFile>[])));
      bool added = false;
      for (final r in results) {
        if (r.isNotEmpty) { accumulated.addAll(r); added = true; }
      }
      if (added) {
        accumulated.sort((a, b) => b.fileSize.compareTo(a.fileSize));
        yield List.of(accumulated);
      }
    }
    yield List.of(accumulated);
  }

  // ── File size helper ───────────────────────────────────────────────────────

  Future<int> getFileSize(int fileId) async {
    try {
      final res = await _request({'@type': 'getFile', 'file_id': fileId});
      if (res == null || res['@type'] == 'error') return 0;
      final s = res['size'] as int? ?? 0;
      return s > 0 ? s : (res['expected_size'] as int? ?? 0);
    } catch (_) { return 0; }
  }

  // ── Download strategies ────────────────────────────────────────────────────

  // STRATEGY A: Small files (audio, docs ≤ 50 MB)
  // Download completely, return local file path.
  // Emits progress [0.0 … 1.0] via onProgress callback.
  // media_kit plays from file:// — no proxy, no MIME issues, no range bugs.
  Future<String?> downloadAndWait(
    int fileId, {
    int knownSize = 0,
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    await cancelAndDeleteFile();

    _dlFileId    = fileId;
    _dlPath      = '';
    _dlAbsPrefix = 0;
    _dlComplete  = false;
    _dlFileSize  = knownSize;

    debugPrint('TG.downloadAndWait fileId=$fileId knownSize=$knownSize');

    // Resolve size if unknown (common for audio)
    if (_dlFileSize <= 0) {
      _dlFileSize = await getFileSize(fileId);
      debugPrint('TG.downloadAndWait resolved size=$_dlFileSize');
    }

    // Tell TDLib to download the whole file (synchronous:false so we get
    // the file object back immediately, then watch updateFile events)
    final res = await _request({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': 32,
      'offset': 0,
      'limit': 0,            // 0 = entire file
      'synchronous': false,
    }, timeout: const Duration(seconds: 15));

    if (res == null || res['@type'] == 'error') {
      debugPrint('TG.downloadAndWait start error: ${res?['message']}');
      _dlFileId = 0;
      return null;
    }

    // Seed initial state from the response
    final local     = res['local'] as Map<String, dynamic>?;
    final initPath  = local?['path']                     as String? ?? '';
    final initPfx   = local?['downloaded_prefix_size']   as int?    ?? 0;
    final initDone  = local?['is_downloading_completed'] as bool?   ?? false;
    if (initPath.isNotEmpty) _dlPath      = initPath;
    if (initPfx > 0)         _dlAbsPrefix = initPfx;
    if (initDone)            _dlComplete  = true;

    // If TDLib already had the file cached, we're done immediately
    if (_dlComplete && _dlPath.isNotEmpty) {
      debugPrint('TG.downloadAndWait: already cached at $_dlPath');
      onProgress?.call(1.0);
      return _dlPath;
    }

    // Wait for updateFile events until complete
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_dlFileId != fileId) {
        debugPrint('TG.downloadAndWait: cancelled');
        return null;
      }

      if (_dlComplete && _dlPath.isNotEmpty) {
        onProgress?.call(1.0);
        debugPrint('TG.downloadAndWait: complete at $_dlPath');
        return _dlPath;
      }

      // Report progress
      if (_dlFileSize > 0 && onProgress != null) {
        onProgress((_dlAbsPrefix / _dlFileSize).clamp(0.0, 1.0));
      }

      await Future.delayed(const Duration(milliseconds: 150));
    }

    debugPrint('TG.downloadAndWait: timeout fileId=$fileId');
    _dlFileId = 0;
    return null;
  }

  // STRATEGY B: Large files (video ≥ 50 MB)
  // Start download in background; proxy fetches chunks via readFilePart().
  Future<String?> startFileDownload(int fileId,
      {int offset = 0, int knownSize = 0}) async {
    await cancelAndDeleteFile();

    _dlFileId    = fileId;
    _dlPath      = '';
    _dlAbsPrefix = 0;
    _dlComplete  = false;
    _dlFileSize  = knownSize;

    debugPrint('TG.startFileDownload fileId=$fileId offset=$offset');

    // Resolve size if unknown
    if (_dlFileSize <= 0) {
      _dlFileSize = await getFileSize(fileId);
    }

    try {
      final res = await _request({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 32,
        'offset': offset,
        'limit': 0,
        'synchronous': false,
      }, timeout: const Duration(seconds: 15));

      if (res == null || res['@type'] == 'error') {
        debugPrint('TG.startFileDownload error: ${res?['message']}');
        _dlFileId = 0;
        return null;
      }

      final local     = res['local'] as Map<String, dynamic>?;
      final path      = local?['path']                     as String? ?? '';
      final absPrefix = local?['downloaded_prefix_size']   as int?    ?? 0;
      final complete  = local?['is_downloading_completed'] as bool?   ?? false;

      if (path.isNotEmpty) _dlPath      = path;
      if (absPrefix > 0)   _dlAbsPrefix = absPrefix;
      if (complete)        _dlComplete  = true;

      // Update size from response
      final sz = (res['size'] as int? ?? 0) > 0
          ? res['size'] as int
          : (res['expected_size'] as int? ?? 0);
      if (sz > 0 && _dlFileSize == 0) _dlFileSize = sz;

      debugPrint(
          'TG.startFileDownload ok path=$path absPrefix=$absPrefix '
          'complete=$complete size=$_dlFileSize');
      return 'ok';
    } catch (e) {
      debugPrint('TG.startFileDownload exception: $e');
      _dlFileId = 0;
      return null;
    }
  }

  // ── readFilePart — THE KEY FIX ─────────────────────────────────────────────
  //
  // Uses TDLib's own readFilePart API.  TDLib downloads exactly [count] bytes
  // starting at [offset] and returns them. This is completely different from
  // reading the sparse temp file off disk:
  //   • Returns exactly what was asked for, every time
  //   • No sparse-file gaps, no "fileLen <= offset" false-EOF
  //   • Handles seeks correctly: TDLib re-downloads from the right offset
  //   • Works for any file size, any seek position
  //
  // Polls with 100 ms delay until data is available or timeout fires.
  Future<Uint8List?> readFilePart({
    required int fileId,
    required int offset,
    required int count,
    int timeoutSeconds = 120,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));

    while (DateTime.now().isBefore(deadline)) {
      // Check if download was cancelled
      if (_dlFileId != fileId) {
        debugPrint('TG.readFilePart: fileId changed, stopping');
        return null;
      }

      try {
        final res = await _request({
          '@type': 'readFilePart',
          'file_id': fileId,
          'offset': offset,
          'count': count,
        }, timeout: const Duration(seconds: 30));

        if (res == null) {
          // Timeout or not ready yet — wait and retry
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        if (res['@type'] == 'error') {
          final code = res['code'] as int? ?? 0;
          final msg  = res['message'] as String? ?? '';
          // Code 404 = bytes not downloaded yet → wait and retry
          // Code 400 = invalid offset (past EOF) → return empty
          if (code == 404 || msg.contains('not downloaded') ||
              msg.contains('FILE_DOWNLOAD_NOT_STARTED')) {
            await Future.delayed(const Duration(milliseconds: 100));
            continue;
          }
          debugPrint('TG.readFilePart error: $msg (code $code)');
          return null;
        }

        // Success: TDLib returns base64-encoded data in 'data' field
        final dataB64 = res['data'] as String? ?? '';
        if (dataB64.isEmpty) {
          // Empty = EOF
          return Uint8List(0);
        }
        return base64Decode(dataB64);
      } catch (e) {
        debugPrint('TG.readFilePart exception: $e');
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    debugPrint('TG.readFilePart: timeout at offset=$offset');
    return null;
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  Future<void> cancelAndDeleteFile() async {
    if (_dlFileId == 0) return;
    final fileId = _dlFileId;
    final path   = _dlPath;

    _dlFileId    = 0;
    _dlPath      = '';
    _dlAbsPrefix = 0;
    _dlComplete  = false;
    _dlFileSize  = 0;

    debugPrint('TG.cancelAndDeleteFile fileId=$fileId');

    try {
      await _request({
        '@type': 'cancelDownloadFile',
        'file_id': fileId,
        'only_if_pending': false,
      });
    } catch (e) { debugPrint('cancelDownload error: $e'); }

    try {
      await _request({'@type': 'deleteFile', 'file_id': fileId});
    } catch (e) { debugPrint('deleteFile error: $e'); }

    // Physical delete with retry (OS may hold file handle briefly)
    if (path.isNotEmpty) {
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final f = io.File(path);
          if (await f.exists()) await f.delete();
          debugPrint('TG.cancelAndDeleteFile: deleted (attempt $attempt)');
          break;
        } catch (e) {
          if (attempt < 3) {
            await Future.delayed(const Duration(milliseconds: 300));
          }
        }
      }
    }
  }

  Future<void> clearAllCache() async {
    try {
      await _request({
        '@type': 'optimizeStorage', 'size': 0, 'ttl': 0, 'count': 0,
        'immunity_delay': 0, 'file_types': [], 'chat_ids': [],
        'exclude_chat_ids': [], 'return_deleted_file_statistics': true,
        'chat_limit': 1000,
      }, timeout: const Duration(seconds: 60));
    } catch (e) { debugPrint('clearAllCache error: $e'); }
  }

  // ── Message parsers ────────────────────────────────────────────────────────

  TelegramFile? _parseMessage(Map<String, dynamic> message) {
    final content = message['content'] as Map<String, dynamic>?;
    if (content == null) return null;
    switch (content['@type'] as String?) {
      case 'messageVideo':     return _parseVideo(content);
      case 'messageAudio':     return _parseAudio(content);
      case 'messageDocument':  return _parseDocument(content);
      case 'messageVoiceNote': return _parseVoice(content);
      case 'messageVideoNote': return _parseVideoNote(content);
      default: return null;
    }
  }

  int _sz(Map<String, dynamic> f) {
    final s = f['size'] as int? ?? 0;
    return s > 0 ? s : (f['expected_size'] as int? ?? 0);
  }

  TelegramFile? _parseVideo(Map<String, dynamic> content) {
    final video = content['video'] as Map<String, dynamic>?;
    if (video == null) return null;
    final file = video['video'] as Map<String, dynamic>?;
    if (file == null) return null;
    final w = video['width']  as int? ?? 0;
    final h = video['height'] as int? ?? 0;
    final qualities = <VideoQuality>[
      VideoQuality(
        label: _label(h), width: w, height: h,
        fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
        remoteId: (file['remote'] as Map?)?['id'] as String? ?? '',
      ),
    ];
    for (final alt in (video['alternative_videos'] as List? ?? [])) {
      final a = alt as Map<String, dynamic>;
      final af = a['video'] as Map<String, dynamic>?;
      if (af == null) continue;
      final ah = a['height'] as int? ?? 0;
      qualities.add(VideoQuality(
        label: _label(ah), width: a['width'] as int? ?? 0, height: ah,
        fileId: af['id'] as int? ?? 0, fileSize: _sz(af),
        remoteId: (af['remote'] as Map?)?['id'] as String? ?? '',
      ));
    }
    qualities.sort((a, b) => b.height.compareTo(a.height));
    return TelegramFile(
      type: TelegramFileType.video,
      name: video['file_name'] as String? ?? 'video.mp4',
      mimeType: video['mime_type'] as String? ?? 'video/mp4',
      duration: video['duration'] as int? ?? 0, width: w, height: h,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      thumbnail: _thumbPath(video['thumbnail']), qualities: qualities,
    );
  }

  TelegramFile? _parseAudio(Map<String, dynamic> content) {
    final audio = content['audio'] as Map<String, dynamic>?;
    final file  = audio?['audio'] as Map<String, dynamic>?;
    if (audio == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.audio,
      name: audio['file_name'] as String? ?? 'audio.mp3',
      mimeType: audio['mime_type'] as String? ?? 'audio/mpeg',
      duration: audio['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  TelegramFile? _parseDocument(Map<String, dynamic> content) {
    final doc  = content['document'] as Map<String, dynamic>?;
    final file = doc?['document'] as Map<String, dynamic>?;
    if (doc == null || file == null) return null;
    final fileName = doc['file_name'] as String? ?? 'file';
    final mimeType = doc['mime_type'] as String? ?? 'application/octet-stream';
    TelegramFileType realType;
    if (TelegramFile.mimeIsVideo(mimeType)) {
      realType = TelegramFileType.video;
    } else if (TelegramFile.mimeIsAudio(mimeType)) {
      realType = TelegramFileType.audio;
    } else {
      realType = TelegramFile.typeFromExtension(fileName);
    }
    return TelegramFile(
      type: realType, name: fileName, mimeType: mimeType,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      thumbnail: _thumbPath(doc['thumbnail']), qualities: [],
    );
  }

  TelegramFile? _parseVoice(Map<String, dynamic> content) {
    final voice = content['voice_note'] as Map<String, dynamic>?;
    final file  = voice?['voice'] as Map<String, dynamic>?;
    if (voice == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.audio, name: 'voice_note.ogg',
      mimeType: voice['mime_type'] as String? ?? 'audio/ogg',
      duration: voice['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  TelegramFile? _parseVideoNote(Map<String, dynamic> content) {
    final vn   = content['video_note'] as Map<String, dynamic>?;
    final file = vn?['video'] as Map<String, dynamic>?;
    if (vn == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.video, name: 'video_note.mp4',
      mimeType: 'video/mp4', duration: vn['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  String _label(int h) {
    if (h >= 2160) return '4K';  if (h >= 1440) return '1440p';
    if (h >= 1080) return '1080p'; if (h >= 720) return '720p';
    if (h >= 480)  return '480p';  if (h >= 360) return '360p';
    return '${h}p';
  }

  String? _thumbPath(dynamic t) {
    if (t == null) return null;
    final f = (t as Map<String, dynamic>?)?['file'] as Map<String, dynamic>?;
    return (f?['local'] as Map<String, dynamic>?)?['path'] as String?;
  }

  // ── Low level ──────────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> req) {
    try { TdPlugin.instance.tdSend(_clientId, jsonEncode(req)); }
    catch (e) { debugPrint('_send error: $e'); }
  }

  Future<Map<String, dynamic>?> _request(
    Map<String, dynamic> req, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final extra = '${req['@type']}_${DateTime.now().microsecondsSinceEpoch}';
    req['@extra'] = extra;
    final c = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (c.isCompleted) return;
      if (u['@extra'] == extra) { c.complete(u); sub.cancel(); }
    });
    _send(req);
    return c.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      debugPrint('_request timeout: ${req['@type']}');
      return null;
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _updateCtrl.close();
    super.dispose();
  }
}
