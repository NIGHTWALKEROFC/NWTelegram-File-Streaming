// lib/services/telegram_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:handy_tdlib/handy_tdlib.dart';
import 'package:path_provider/path_provider.dart';

import '../models/telegram_file.dart';

const int _kApiId = int.fromEnvironment('TG_API_ID', defaultValue: 0);
const String _kApiHash =
    String.fromEnvironment('TG_API_HASH', defaultValue: '');

enum AuthState {
  idle,
  waitingPhone,
  waitingCode,
  waitingPassword,
  waitingRegistration,
  authorized,
  error,
}

class TelegramService extends ChangeNotifier {
  int _clientId = 0;
  Timer? _pollTimer;

  final _updateCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updateCtrl.stream;

  AuthState _authState = AuthState.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;
  bool _isInitialized = false;

  // Active download tracking — updated by updateFile events
  int    _activeDownloadFileId    = 0;
  String _activeDownloadPath      = '';
  int    _activeDownloadOffset    = 0; // offset we started downloading from
  int    _activeDownloadPrefix    = 0; // bytes downloaded so far (absolute)
  bool   _activeDownloadComplete  = false;

  AuthState get authState          => _authState;
  String    get errorMessage       => _errorMessage;
  bool      get isLoggedIn         => _isLoggedIn;
  bool      get isInitialized      => _isInitialized;
  // Exposed so stream_service can check how far TDLib has downloaded
  // before deciding whether to restart download on seek.
  int       get activeDownloadPrefix => _activeDownloadPrefix;

  // ── Initialize ─────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;

    if (_kApiId == 0 || _kApiHash.isEmpty) {
      _errorMessage =
          'Telegram API credentials missing.\n'
          'Set TG_API_ID and TG_API_HASH in Codemagic → Environment Variables '
          '(group: telegram_keys).';
      _authState = AuthState.error;
      notifyListeners();
      return;
    }

    try {
      TdPlugin.initialize();
      _clientId = TdPlugin.instance.tdCreateClientId();
      _startPolling();

      final appDir  = await getApplicationDocumentsDirectory();
      final dbPath  = '${appDir.path}/tdlib_db';
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
        final state = u['authorization_state'] as Map<String, dynamic>?;
        if (state != null) _handleAuthState(state);
        break;

      // Track file download progress — used by readFileBytes polling loop
      case 'updateFile':
        final file   = u['file'] as Map<String, dynamic>?;
        if (file == null) break;
        final fileId = file['id'] as int? ?? 0;
        if (fileId != _activeDownloadFileId) break;

        final local    = file['local'] as Map<String, dynamic>?;
        if (local == null) break;
        final path     = local['path'] as String? ?? '';
        final prefix   = local['downloaded_prefix_size'] as int? ?? 0;
        final complete = local['is_downloading_completed'] as bool? ?? false;

        if (path.isNotEmpty && _activeDownloadPath.isEmpty) {
          _activeDownloadPath = path;
        }
        // prefix is absolute from byte 0, even if we started at an offset
        if (prefix > _activeDownloadPrefix) _activeDownloadPrefix = prefix;
        if (complete) _activeDownloadComplete = complete;
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
        _authState = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;
      case 'authorizationStateWaitCode':
        _authState = AuthState.waitingCode;
        break;
      case 'authorizationStateWaitOtherDeviceConfirmation':
        _authState = AuthState.waitingCode;
        _errorMessage = 'Confirm login on your other Telegram device.';
        break;
      case 'authorizationStateWaitRegistration':
        _authState = AuthState.waitingRegistration;
        break;
      case 'authorizationStateWaitPassword':
        _authState = AuthState.waitingPassword;
        break;
      case 'authorizationStateReady':
        _authState   = AuthState.authorized;
        _isLoggedIn  = true;
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
    final completer = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (completer.isCompleted) return;
      if (u['@type'] == 'error') {
        _errorMessage = u['message'] as String? ?? 'Error';
        notifyListeners();
        completer.complete(false);
        sub.cancel();
        return;
      }
      if (u['@type'] == 'updateAuthorizationState') {
        final t = (u['authorization_state'] as Map<String, dynamic>?)?['@type'] as String?;
        if (t == 'authorizationStateWaitCode' ||
            t == 'authorizationStateWaitOtherDeviceConfirmation' ||
            t == 'authorizationStateWaitPassword' ||
            t == 'authorizationStateReady') {
          completer.complete(true);
          sub.cancel();
        }
      }
    });
    _send({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phone,
      'settings': {
        '@type': 'phoneNumberAuthenticationSettings',
        'allow_flash_call': false,
        'allow_missed_call': false,
        'is_current_phone_number': true,
        'allow_sms_retriever_api': false,
      },
    });
    if (!completer.isCompleted &&
        (_authState == AuthState.waitingCode ||
         _authState == AuthState.waitingPassword ||
         _authState == AuthState.authorized)) {
      completer.complete(true);
      sub.cancel();
    }
    return completer.future.timeout(const Duration(seconds: 60),
        onTimeout: () {
      sub.cancel();
      if (_authState == AuthState.waitingCode ||
          _authState == AuthState.waitingPassword ||
          _authState == AuthState.authorized) return true;
      _errorMessage = 'Check your internet and try again.';
      notifyListeners();
      return false;
    });
  }

  Future<bool> sendOtpCode(String code) async {
    _errorMessage = '';
    final completer = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (completer.isCompleted) return;
      if (u['@type'] == 'error') {
        _errorMessage = u['message'] as String? ?? 'Invalid code';
        notifyListeners();
        completer.complete(false);
        sub.cancel();
        return;
      }
      if (u['@type'] == 'updateAuthorizationState') {
        final t = (u['authorization_state'] as Map<String, dynamic>?)?['@type'] as String?;
        if (t == 'authorizationStateReady' ||
            t == 'authorizationStateWaitPassword') {
          completer.complete(true);
          sub.cancel();
        }
      }
    });
    _send({'@type': 'checkAuthenticationCode', 'code': code});
    if (!completer.isCompleted &&
        (_authState == AuthState.authorized ||
         _authState == AuthState.waitingPassword)) {
      completer.complete(true);
      sub.cancel();
    }
    return completer.future.timeout(const Duration(seconds: 30),
        onTimeout: () {
      sub.cancel();
      if (_authState == AuthState.authorized ||
          _authState == AuthState.waitingPassword) return true;
      _errorMessage = _errorMessage.isNotEmpty ? _errorMessage : 'Timed out.';
      notifyListeners();
      return false;
    });
  }

  Future<bool> sendPassword(String password) async {
    _errorMessage = '';
    final completer = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (completer.isCompleted) return;
      if (u['@type'] == 'error') {
        _errorMessage = u['message'] as String? ?? 'Wrong password';
        notifyListeners();
        completer.complete(false);
        sub.cancel();
        return;
      }
      if (u['@type'] == 'updateAuthorizationState') {
        final t = (u['authorization_state'] as Map<String, dynamic>?)?['@type'] as String?;
        if (t == 'authorizationStateReady') {
          completer.complete(true);
          sub.cancel();
        }
      }
    });
    _send({'@type': 'checkAuthenticationPassword', 'password': password});
    if (!completer.isCompleted && _authState == AuthState.authorized) {
      completer.complete(true);
      sub.cancel();
    }
    return completer.future.timeout(const Duration(seconds: 30),
        onTimeout: () {
      sub.cancel();
      if (_authState == AuthState.authorized) return true;
      _errorMessage = _errorMessage.isNotEmpty ? _errorMessage : 'Timed out.';
      notifyListeners();
      return false;
    });
  }

  Future<void> logout() async {
    _send({'@type': 'logOut'});
    _authState  = AuthState.waitingPhone;
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
      'searchMessagesFilterVideo',
      'searchMessagesFilterAudio',
      'searchMessagesFilterDocument',
      'searchMessagesFilterVoiceNote',
      'searchMessagesFilterVideoNote',
    ];
    final results = await Future.wait(filters.map((filter) async {
      try {
        final res = await _request({
          '@type': 'searchChatMessages',
          'chat_id': chatId,
          'query': '',
          'from_message_id': 0,
          'offset': 0,
          'limit': limit,
          'filter': {'@type': filter},
          'message_thread_id': 0,
        }, timeout: const Duration(seconds: 15));
        if (res == null || res['@type'] == 'error') return <TelegramFile>[];
        final msgs = res['messages'] as List? ?? [];
        final files = <TelegramFile>[];
        for (final msg in msgs) {
          final f = _parseMessage(msg as Map<String, dynamic>);
          if (f != null && f.fileId > 0) files.add(f);
        }
        return files;
      } catch (_) {
        return <TelegramFile>[];
      }
    }));
    return results.expand((r) => r).toList();
  }

  Stream<List<TelegramFile>> streamAllMediaFiles({int limitPerChat = 30}) async* {
    final accumulated = <TelegramFile>[];
    List<int> chatIds;
    try {
      chatIds = await _getChatIds();
    } catch (_) {
      yield [];
      return;
    }
    if (chatIds.isEmpty) { yield []; return; }

    const batchSize = 3;
    for (int i = 0; i < chatIds.length; i += batchSize) {
      final batch = chatIds.skip(i).take(batchSize).toList();
      final results = await Future.wait(batch.map(
          (id) => _getMediaFromChat(id, limitPerChat)
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

  // ── Streaming ──────────────────────────────────────────────────────────────
  //
  // startFileDownload(fileId, offset):
  //   - Downloads from [offset] forward at full speed in TDLib's C++ thread
  //   - offset=0 for initial play, offset=seekTarget for seeks
  //   - Returns 'pending' on success (path arrives via updateFile shortly)
  //   - Returns null on TDLib error
  //
  // readFileBytes(offset, count):
  //   - Polls _activeDownloadPrefix until enough bytes are available
  //   - Reads directly from local file — no blocking Dart calls
  //
  // cancelAndDeleteFile():
  //   - Stops download + deletes local file immediately
  //   - Call this when player closes (guaranteed cleanup)

  Future<String?> startFileDownload(int fileId, {int offset = 0}) async {
    // Cancel and delete the previous file first
    await cancelAndDeleteFile();

    _activeDownloadFileId   = fileId;
    _activeDownloadPath     = '';
    _activeDownloadOffset   = offset;
    _activeDownloadPrefix   = offset; // TDLib prefix starts at offset
    _activeDownloadComplete = false;

    debugPrint('TG.startFileDownload fileId=$fileId offset=$offset');

    try {
      final res = await _request(
        {
          '@type': 'downloadFile',
          'file_id': fileId,
          'priority': 32,
          'offset': offset,
          'limit': 0,          // 0 = download everything from offset onward
          'synchronous': false, // return immediately, download in background
        },
        timeout: const Duration(seconds: 15),
      );

      if (res == null || res['@type'] == 'error') {
        debugPrint('TG.startFileDownload error: ${res?['message']}');
        _activeDownloadFileId = 0;
        return null;
      }

      final local    = res['local'] as Map<String, dynamic>?;
      final path     = local?['path']    as String? ?? '';
      final prefix   = local?['downloaded_prefix_size'] as int? ?? 0;
      final complete = local?['is_downloading_completed'] as bool? ?? false;

      if (path.isNotEmpty)  _activeDownloadPath     = path;
      if (prefix  > offset) _activeDownloadPrefix   = prefix;
      if (complete)         _activeDownloadComplete = true;

      debugPrint('TG.startFileDownload: path=$path prefix=$prefix complete=$complete');
      // 'pending' = success (path may arrive via updateFile shortly)
      return 'ok';
    } catch (e) {
      debugPrint('TG.startFileDownload exception: $e');
      _activeDownloadFileId = 0;
      return null;
    }
  }

  // Read [count] bytes from local file at [offset].
  // Waits until TDLib has downloaded up to offset+count.
  Future<Uint8List?> readFileBytes({
    required int offset,
    required int count,
    int timeoutSeconds = 120,
  }) async {
    final fileId = _activeDownloadFileId;
    if (fileId == 0) {
      debugPrint('TG.readFileBytes: no active download');
      return null;
    }

    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));

    while (DateTime.now().isBefore(deadline)) {
      // Stop if file was cancelled or switched
      if (_activeDownloadFileId != fileId) {
        debugPrint('TG.readFileBytes: fileId changed, stopping');
        return null;
      }

      final path     = _activeDownloadPath;
      final prefix   = _activeDownloadPrefix;
      final complete = _activeDownloadComplete;

      // Path not yet created — TDLib hasn't written any bytes yet
      if (path.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      final needed = offset + count;

      // Have enough bytes OR download is complete — try to read
      if (prefix >= needed || complete) {
        try {
          final file = io.File(path);
          if (!await file.exists()) {
            debugPrint('TG.readFileBytes: file missing $path');
            return null;
          }
          final fileLen = await file.length();
          if (fileLen <= offset) return Uint8List(0); // real EOF
          final canRead = (fileLen - offset).clamp(0, count);
          final raf = await file.open();
          try {
            await raf.setPosition(offset);
            return await raf.read(canRead);
          } finally {
            await raf.close();
          }
        } catch (e) {
          debugPrint('TG.readFileBytes read error: $e');
          return null;
        }
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }

    debugPrint('TG.readFileBytes: timeout at offset=$offset after ${timeoutSeconds}s');
    return null;
  }

  // ── Guaranteed cleanup ─────────────────────────────────────────────────────
  //
  // Stops TDLib download + deletes local file from device storage.
  // Safe to call multiple times (no-op if nothing active).
  // Stores fileId/path locally BEFORE resetting state so async ops
  // can complete even if called from dispose().

  Future<void> cancelAndDeleteFile() async {
    if (_activeDownloadFileId == 0) return;

    final fileId = _activeDownloadFileId;
    final path   = _activeDownloadPath;

    // Reset state immediately so readFileBytes stops polling
    _activeDownloadFileId   = 0;
    _activeDownloadPath     = '';
    _activeDownloadOffset   = 0;
    _activeDownloadPrefix   = 0;
    _activeDownloadComplete = false;

    debugPrint('TG.cancelAndDeleteFile fileId=$fileId path=$path');

    // Step 1: stop TDLib download
    try {
      await _request({
        '@type': 'cancelDownloadFile',
        'file_id': fileId,
        'only_if_pending': false,
      });
    } catch (e) {
      debugPrint('TG.cancelDownloadFile error (non-fatal): $e');
    }

    // Step 2: delete via TDLib API
    try {
      await _request({'@type': 'deleteFile', 'file_id': fileId});
      debugPrint('TG.deleteFile done fileId=$fileId');
    } catch (e) {
      debugPrint('TG.deleteFile error (non-fatal): $e');
    }

    // Step 3: physical delete as safety net
    if (path.isNotEmpty) {
      try {
        final f = io.File(path);
        if (await f.exists()) {
          await f.delete();
          debugPrint('TG.cancelAndDeleteFile: physical delete done');
        }
      } catch (e) {
        debugPrint('TG.cancelAndDeleteFile: physical delete error: $e');
      }
    }
  }

  // Wipe ALL cached files (for manual clear cache button)
  Future<void> clearAllCache() async {
    try {
      await _request({
        '@type': 'optimizeStorage',
        'size': 0,
        'ttl': 0,
        'count': 0,
        'immunity_delay': 0,
        'file_types': [],
        'chat_ids': [],
        'exclude_chat_ids': [],
        'return_deleted_file_statistics': true,
        'chat_limit': 1000,
      }, timeout: const Duration(seconds: 60));
      debugPrint('TG.clearAllCache done');
    } catch (e) {
      debugPrint('TG.clearAllCache error: $e');
    }
  }

  Future<int> getFileSize(int fileId) async {
    try {
      final res = await _request({'@type': 'getFile', 'file_id': fileId});
      if (res == null || res['@type'] == 'error') return 0;
      final s = res['size'] as int? ?? 0;
      return s > 0 ? s : (res['expected_size'] as int? ?? 0);
    } catch (_) {
      return 0;
    }
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
    final file  = video['video'] as Map<String, dynamic>?;
    if (file == null) return null;
    final w = video['width']  as int? ?? 0;
    final h = video['height'] as int? ?? 0;
    final qualities = <VideoQuality>[
      VideoQuality(
        label: _label(h), width: w, height: h,
        fileId: file['id'] as int? ?? 0,
        fileSize: _sz(file),
        remoteId: (file['remote'] as Map?)?['id'] as String? ?? '',
      ),
    ];
    for (final alt in (video['alternative_videos'] as List? ?? [])) {
      final a  = alt as Map<String, dynamic>;
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
      duration: video['duration'] as int? ?? 0,
      width: w, height: h,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      thumbnail: _thumbPath(video['thumbnail']),
      qualities: qualities,
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
      thumbnail: _thumbPath(doc['thumbnail']),
      qualities: [],
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
      type: TelegramFileType.video, name: 'video_note.mp4', mimeType: 'video/mp4',
      duration: vn['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0, fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  String _label(int h) {
    if (h >= 2160) return '4K';
    if (h >= 1440) return '1440p';
    if (h >= 1080) return '1080p';
    if (h >= 720)  return '720p';
    if (h >= 480)  return '480p';
    if (h >= 360)  return '360p';
    return '${h}p';
  }

  String? _thumbPath(dynamic t) {
    if (t == null) return null;
    final f = (t as Map<String, dynamic>?)?['file'] as Map<String, dynamic>?;
    return (f?['local'] as Map<String, dynamic>?)?['path'] as String?;
  }

  // ── Low level ──────────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> req) {
    try {
      TdPlugin.instance.tdSend(_clientId, jsonEncode(req));
    } catch (e) {
      debugPrint('_send error: $e');
    }
  }

  Future<Map<String, dynamic>?> _request(
    Map<String, dynamic> req, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final extra =
        '${req['@type']}_${DateTime.now().microsecondsSinceEpoch}';
    req['@extra'] = extra;
    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = updates.listen((u) {
      if (completer.isCompleted) return;
      if (u['@extra'] == extra) {
        completer.complete(u);
        sub.cancel();
      }
    });
    _send(req);
    return completer.future.timeout(timeout, onTimeout: () {
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
