// lib/services/telegram_service.dart
//
// ROOT CAUSE OF SPLASH CRASH:
// TdPlugin.initialize() loads libtdjni.so synchronously on whichever
// thread calls it. In a release APK, calling this on the Flutter main
// isolate (UI thread) blocks the Android main looper long enough that
// the OS kills the process — this shows up as a splash screen freeze
// followed by a silent crash with no Dart exception.
//
// FIX: All TDLib work runs on a background Isolate.
// The handshake is:
//   1. UI spawns isolate, giving it the UI's ReceivePort sendPort.
//   2. Isolate sends back its OWN SendPort as the very first message.
//   3. UI waits for that SendPort via a Completer before sending anything.
//   4. UI sends _InitData; isolate loads TDLib and starts polling.
//   5. All TDLib updates flow to UI as _TdUpdate messages.
//   6. Requests are matched to responses via '@extra' string IDs.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:handy_tdlib/handy_tdlib.dart';

import '../models/telegram_file.dart';

const int _kApiId = int.fromEnvironment('TG_API_ID', defaultValue: 0);
const String _kApiHash =
    String.fromEnvironment('TG_API_HASH', defaultValue: '');

enum AuthState {
  idle,
  waitingPhone,
  waitingCode,
  waitingPassword,
  authorized,
  error,
}

// ── Messages sent between isolates ───────────────────────────────────────────

class _InitData {
  final String dbPath;
  final String filesPath;
  final int apiId;
  final String apiHash;
  const _InitData({
    required this.dbPath,
    required this.filesPath,
    required this.apiId,
    required this.apiHash,
  });
}

class _SendRequest {
  final String json;
  const _SendRequest(this.json);
}

class _TdUpdate {
  final String json;
  const _TdUpdate(this.json);
}

// ── Background isolate ────────────────────────────────────────────────────────

// Top-level: required by Isolate.spawn
void _isolateMain(SendPort uiSendPort) {
  final rp = ReceivePort();

  // Step 2: tell the UI how to reach us
  uiSendPort.send(rp.sendPort);

  // Step 3: wait for _InitData then start TDLib
  late StreamSubscription sub;
  sub = rp.listen((msg) {
    if (msg is _InitData) {
      sub.cancel();
      _runTdLib(msg, uiSendPort, rp);
    }
  });
}

void _runTdLib(_InitData init, SendPort uiSendPort, ReceivePort rp) {
  // Safe: we are on a background isolate, not the Android main thread
  TdPlugin.initialize();

  final clientId = TdPlugin.instance.tdCreateClientId();

  // Send TDLib parameters immediately
  TdPlugin.instance.tdSend(
    clientId,
    jsonEncode({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': init.dbPath,
      'files_directory': init.filesPath,
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': init.apiId,
      'api_hash': init.apiHash,
      'system_language_code': 'en',
      'device_model': io.Platform.isAndroid ? 'Android' : 'iOS',
      'system_version': 'Unknown',
      'application_version': '1.0.0',
      'enable_storage_optimizer': true,
    }),
  );

  // Forward requests from UI → TDLib
  rp.listen((msg) {
    if (msg is _SendRequest) {
      TdPlugin.instance.tdSend(clientId, msg.json);
    }
  });

  // Poll TDLib and forward updates → UI
  Timer.periodic(const Duration(milliseconds: 50), (_) {
    final raw = TdPlugin.instance.tdReceive(0.0);
    if (raw != null && raw.isNotEmpty) {
      uiSendPort.send(_TdUpdate(raw));
    }
  });
}

// ── TelegramService (UI isolate) ──────────────────────────────────────────────

class TelegramService extends ChangeNotifier {
  Isolate? _isolate;
  ReceivePort? _uiPort;
  SendPort? _bgPort;

  final _updates = StreamController<Map<String, dynamic>>.broadcast();

  AuthState _authState = AuthState.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;
  bool _isInitialized = false;

  AuthState get authState => _authState;
  String get errorMessage => _errorMessage;
  bool get isLoggedIn => _isLoggedIn;
  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    if (_isInitialized) return;

    if (_kApiId == 0 || _kApiHash.isEmpty) {
      _errorMessage =
          'Telegram API credentials are missing.\n'
          'Set TG_API_ID and TG_API_HASH in Codemagic → Environment Variables '
          '(group: telegram_keys).';
      _authState = AuthState.error;
      notifyListeners();
      return;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dbPath = '${appDir.path}/tdlib_db';
      final filesPath = '${appDir.path}/tdlib_files';
      await io.Directory(dbPath).create(recursive: true);
      await io.Directory(filesPath).create(recursive: true);

      // Create UI port BEFORE spawning so no messages are dropped
      _uiPort = ReceivePort();

      // Completer waits for the background SendPort (step 2 of handshake)
      final bgPortCompleter = Completer<SendPort>();

      _uiPort!.listen((msg) {
        if (msg is SendPort) {
          // First message from background — its SendPort
          if (!bgPortCompleter.isCompleted) bgPortCompleter.complete(msg);
          return;
        }
        if (msg is _TdUpdate) {
          _onRawUpdate(msg.json);
        }
      });

      _isolate = await Isolate.spawn(
        _isolateMain,
        _uiPort!.sendPort,
        debugName: 'tdlib_bg',
      );

      // Wait for background to send its SendPort (step 2)
      _bgPort = await bgPortCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            throw TimeoutException('TDLib isolate did not start in time'),
      );

      // Step 3: send init data to background
      _bgPort!.send(_InitData(
        dbPath: dbPath,
        filesPath: filesPath,
        apiId: _kApiId,
        apiHash: _kApiHash,
      ));

      _isInitialized = true;

      // Wait up to 10 s for first auth state
      await _awaitFirstAuthState();
    } catch (e, st) {
      debugPrint('TelegramService.initialize failed: $e\n$st');
      _errorMessage = e.toString();
      _authState = AuthState.error;
      notifyListeners();
    }
  }

  void _onRawUpdate(String raw) {
    try {
      final u = jsonDecode(raw) as Map<String, dynamic>;
      if (!_updates.isClosed) _updates.add(u);
      _handleUpdate(u);
    } catch (e) {
      debugPrint('TDLib parse error: $e  raw=$raw');
    }
  }

  Future<void> _awaitFirstAuthState() async {
    final done = Completer<void>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = _updates.stream.listen((u) {
      if (u['@type'] == 'updateAuthorizationState' && !done.isCompleted) {
        done.complete();
        sub.cancel();
      }
    });
    await Future.any([
      done.future,
      Future.delayed(const Duration(seconds: 10)),
    ]);
    sub.cancel();
  }

  void _handleUpdate(Map<String, dynamic> u) {
    if (u['@type'] == 'updateAuthorizationState') {
      final state = u['authorization_state'] as Map<String, dynamic>?;
      if (state != null) _handleAuthState(state);
    }
  }

  void _handleAuthState(Map<String, dynamic> state) {
    final type = state['@type'] as String?;
    debugPrint('TDLib auth → $type');
    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _authState = AuthState.idle;
        break;
      case 'authorizationStateWaitEncryptionKey':
        // TDLib 1.8+ emits this on first run — must respond or hangs forever
        _send({'@type': 'checkDatabaseEncryptionKey', 'encryption_key': ''});
        break;
      case 'authorizationStateWaitPhoneNumber':
        _authState = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;
      case 'authorizationStateWaitCode':
        _authState = AuthState.waitingCode;
        break;
      case 'authorizationStateWaitPassword':
        _authState = AuthState.waitingPassword;
        break;
      case 'authorizationStateReady':
        _authState = AuthState.authorized;
        _isLoggedIn = true;
        break;
      case 'authorizationStateLoggingOut':
      case 'authorizationStateClosing':
      case 'authorizationStateClosed':
        _authState = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;
    }
    notifyListeners();
  }

  // ── Auth actions ────────────────────────────────────────────────────────────

  Future<bool> sendPhoneNumber(String phone) async {
    _errorMessage = '';
    final res = await _request({
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
    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Error';
      notifyListeners();
      return false;
    }
    return true;
  }

  Future<bool> sendOtpCode(String code) async {
    _errorMessage = '';
    final res = await _request(
        {'@type': 'checkAuthenticationCode', 'code': code});
    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Invalid code';
      notifyListeners();
      return false;
    }
    return true;
  }

  Future<bool> sendPassword(String password) async {
    _errorMessage = '';
    final res = await _request(
        {'@type': 'checkAuthenticationPassword', 'password': password});
    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Wrong password';
      notifyListeners();
      return false;
    }
    return true;
  }

  Future<void> logout() async {
    try {
      await _request({'@type': 'logOut'});
    } catch (_) {}
    _isLoggedIn = false;
    _authState = AuthState.waitingPhone;
    notifyListeners();
  }

  // ── Resolve Telegram link ───────────────────────────────────────────────────

  Future<TelegramFile?> resolveLink(String link) async {
    _errorMessage = '';
    try {
      final res =
          await _request({'@type': 'getMessageLinkInfo', 'url': link});
      if (res == null) {
        _errorMessage = 'No response from Telegram';
        notifyListeners();
        return null;
      }
      if (res['@type'] == 'error') {
        _errorMessage = res['message'] as String? ?? 'Invalid link';
        notifyListeners();
        return null;
      }
      final msg = res['message'] as Map<String, dynamic>?;
      if (msg == null) {
        _errorMessage = 'No message found at this link';
        notifyListeners();
        return null;
      }
      return _parseMessage(msg);
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      return null;
    }
  }

  TelegramFile? _parseMessage(Map<String, dynamic> message) {
    final content = message['content'] as Map<String, dynamic>?;
    if (content == null) return null;
    switch (content['@type'] as String?) {
      case 'messageVideo':
        return _parseVideo(content);
      case 'messageAudio':
        return _parseAudio(content);
      case 'messageDocument':
        return _parseDocument(content);
      case 'messageVoiceNote':
        return _parseVoice(content);
      case 'messageVideoNote':
        return _parseVideoNote(content);
      default:
        _errorMessage = 'Unsupported type: ${content['@type']}';
        notifyListeners();
        return null;
    }
  }

  // prefer real size, fall back to expected_size
  int _sz(Map<String, dynamic> f) {
    final s = f['size'] as int? ?? 0;
    return s > 0 ? s : (f['expected_size'] as int? ?? 0);
  }

  TelegramFile? _parseVideo(Map<String, dynamic> content) {
    final video = content['video'] as Map<String, dynamic>?;
    if (video == null) return null;
    final file = video['video'] as Map<String, dynamic>?;
    if (file == null) return null;
    final w = video['width'] as int? ?? 0;
    final h = video['height'] as int? ?? 0;
    final qualities = <VideoQuality>[
      VideoQuality(
        label: _label(h),
        width: w,
        height: h,
        fileId: file['id'] as int? ?? 0,
        fileSize: _sz(file),
        remoteId: (file['remote'] as Map?)?['id'] as String? ?? '',
      ),
    ];
    for (final alt in (video['alternative_videos'] as List? ?? [])) {
      final a = alt as Map<String, dynamic>;
      final af = a['video'] as Map<String, dynamic>?;
      if (af == null) continue;
      final ah = a['height'] as int? ?? 0;
      qualities.add(VideoQuality(
        label: _label(ah),
        width: a['width'] as int? ?? 0,
        height: ah,
        fileId: af['id'] as int? ?? 0,
        fileSize: _sz(af),
        remoteId: (af['remote'] as Map?)?['id'] as String? ?? '',
      ));
    }
    qualities.sort((a, b) => b.height.compareTo(a.height));
    return TelegramFile(
      type: TelegramFileType.video,
      name: video['file_name'] as String? ?? 'video.mp4',
      mimeType: video['mime_type'] as String? ?? 'video/mp4',
      duration: video['duration'] as int? ?? 0,
      width: w,
      height: h,
      fileId: file['id'] as int? ?? 0,
      fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      thumbnail: _thumbPath(video['thumbnail']),
      qualities: qualities,
    );
  }

  TelegramFile? _parseAudio(Map<String, dynamic> content) {
    final audio = content['audio'] as Map<String, dynamic>?;
    final file = audio?['audio'] as Map<String, dynamic>?;
    if (audio == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.audio,
      name: audio['file_name'] as String? ?? 'audio.mp3',
      mimeType: audio['mime_type'] as String? ?? 'audio/mpeg',
      duration: audio['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0,
      fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  TelegramFile? _parseDocument(Map<String, dynamic> content) {
    final doc = content['document'] as Map<String, dynamic>?;
    final file = doc?['document'] as Map<String, dynamic>?;
    if (doc == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.document,
      name: doc['file_name'] as String? ?? 'file',
      mimeType: doc['mime_type'] as String? ?? 'application/octet-stream',
      fileId: file['id'] as int? ?? 0,
      fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  TelegramFile? _parseVoice(Map<String, dynamic> content) {
    final voice = content['voice_note'] as Map<String, dynamic>?;
    final file = voice?['voice'] as Map<String, dynamic>?;
    if (voice == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.audio,
      name: 'voice_note.ogg',
      mimeType: voice['mime_type'] as String? ?? 'audio/ogg',
      duration: voice['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0,
      fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  TelegramFile? _parseVideoNote(Map<String, dynamic> content) {
    final vn = content['video_note'] as Map<String, dynamic>?;
    final file = vn?['video'] as Map<String, dynamic>?;
    if (vn == null || file == null) return null;
    return TelegramFile(
      type: TelegramFileType.video,
      name: 'video_note.mp4',
      mimeType: 'video/mp4',
      duration: vn['duration'] as int? ?? 0,
      fileId: file['id'] as int? ?? 0,
      fileSize: _sz(file),
      remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
      qualities: [],
    );
  }

  String _label(int h) {
    if (h >= 2160) return '4K';
    if (h >= 1440) return '1440p';
    if (h >= 1080) return '1080p';
    if (h >= 720) return '720p';
    if (h >= 480) return '480p';
    if (h >= 360) return '360p';
    return '${h}p';
  }

  String? _thumbPath(dynamic t) {
    if (t == null) return null;
    final f = (t as Map<String, dynamic>?)?['file'] as Map<String, dynamic>?;
    return (f?['local'] as Map<String, dynamic>?)?['path'] as String?;
  }

  // ── Streaming ───────────────────────────────────────────────────────────────

  Future<Uint8List?> downloadFilePart({
    required int fileId,
    required int offset,
    required int count,
  }) async {
    try {
      final res = await _request({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 32,
        'offset': offset,
        'limit': count,
        'synchronous': true,
      });
      if (res == null || res['@type'] == 'error') return null;

      final local = res['local'] as Map<String, dynamic>?;
      final path = local?['path'] as String?;
      if (path == null || path.isEmpty) return null;

      final f = io.File(path);
      if (!await f.exists()) return null;

      final prefixSize = (local?['downloaded_prefix_size'] as int?) ?? 0;
      final available = (prefixSize - offset).clamp(0, count);
      if (available <= 0) return Uint8List(0);

      final raf = await f.open();
      try {
        await raf.setPosition(offset);
        return await raf.read(available);
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint('downloadFilePart: $e');
      return null;
    }
  }

  Future<int> getFileSize(int fileId) async {
    try {
      final res =
          await _request({'@type': 'getFile', 'file_id': fileId});
      if (res == null || res['@type'] == 'error') return 0;
      final s = res['size'] as int? ?? 0;
      return s > 0 ? s : (res['expected_size'] as int? ?? 0);
    } catch (_) {
      return 0;
    }
  }

  // ── Low-level send/receive ──────────────────────────────────────────────────

  void _send(Map<String, dynamic> req) {
    _bgPort?.send(_SendRequest(jsonEncode(req)));
  }

  Future<Map<String, dynamic>?> _request(Map<String, dynamic> req) async {
    if (_bgPort == null) return null;
    final extra = DateTime.now().microsecondsSinceEpoch.toString();
    req['@extra'] = extra;

    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> sub;
    sub = _updates.stream.listen((u) {
      if (u['@extra'] == extra && !completer.isCompleted) {
        completer.complete(u);
        sub.cancel();
      }
    });

    _bgPort!.send(_SendRequest(jsonEncode(req)));

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        debugPrint('TDLib timeout: ${req['@type']}');
        return null;
      },
    );
  }

  @override
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _uiPort?.close();
    _uiPort = null;
    _updates.close();
    super.dispose();
  }
}
