// lib/services/telegram_service.dart
//
// ROOT CAUSE OF "timed out waiting for SMS code":
// ================================================
// The previous version spawned a background Isolate and called
// TdPlugin.initialize() + tdReceive() inside it.
//
// handy_tdlib registers its native methods through Flutter's plugin registry,
// which only exists on the MAIN isolate. Calling TdPlugin from a spawned
// isolate means the plugin is NOT registered there — tdReceive() always
// returns null, events never arrive, and every _awaitAuthState() call
// times out.
//
// This is why Termux (direct native TDLib, no Flutter plugin layer) works
// instantly: it talks to libtdjni.so directly without Flutter's method channel.
//
// FIX:
// ====
// 1. No background isolate. Everything runs on the MAIN isolate.
// 2. tdReceive is called via Flutter's compute() which runs the NATIVE ffi
//    call on a platform thread (so it can block for up to 1 s without
//    freezing the UI). tdReceive is a pure dart:ffi call — it does NOT
//    use Flutter's method channel — so compute() is safe for it.
// 3. The receive loop is a self-rescheduling async function that feeds
//    every TDLib event into a broadcast StreamController.
// 4. _awaitAuthState checks _authState synchronously BEFORE subscribing
//    to avoid race conditions where the state was already set.

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

// Top-level compute function — safe because tdReceive uses dart:ffi directly,
// NOT Flutter's method channel. It can run in compute()'s platform thread.
String? _tdReceiveCompute(double timeout) =>
    TdPlugin.instance.tdReceive(timeout);

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
  late int _clientId;

  final _updateCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get _updates => _updateCtrl.stream;

  bool _isInitialized = false;
  bool _loopRunning = false;

  AuthState _authState = AuthState.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;

  AuthState get authState => _authState;
  String get errorMessage => _errorMessage;
  bool get isLoggedIn => _isLoggedIn;
  bool get isInitialized => _isInitialized;

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
      // Must be called on the MAIN isolate — registers the Flutter plugin
      TdPlugin.initialize();

      _clientId = TdPlugin.instance.tdCreateClientId();

      // Start the receive loop BEFORE sending any request
      _startReceiveLoop();

      // Prepare storage directories
      final appDir = await getApplicationDocumentsDirectory();
      final dbPath = '${appDir.path}/tdlib_db';
      final filesPath = '${appDir.path}/tdlib_files';
      await io.Directory(dbPath).create(recursive: true);
      await io.Directory(filesPath).create(recursive: true);

      // Send TDLib parameters — this triggers the auth state machine
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

      // Wait for the first auth state update (max 10 s)
      await _updates
          .where((u) => u['@type'] == 'updateAuthorizationState')
          .first
          .timeout(const Duration(seconds: 10), onTimeout: () => {});
    } catch (e, st) {
      debugPrint('TelegramService.initialize error: $e\n$st');
      _errorMessage = e.toString();
      _authState = AuthState.error;
      notifyListeners();
    }
  }

  // ── Receive loop ───────────────────────────────────────────────────────────

  void _startReceiveLoop() {
    if (_loopRunning) return;
    _loopRunning = true;
    _receiveLoop();
  }

  void _receiveLoop() {
    if (_updateCtrl.isClosed) return;
    Future.microtask(() async {
      try {
        // compute() runs the native ffi call on a platform thread.
        // 1.0 second timeout: blocks until an event arrives or 1 s elapses.
        final raw = await compute(_tdReceiveCompute, 1.0);
        if (raw != null && raw.isNotEmpty) {
          _onRawUpdate(raw);
        }
      } catch (e) {
        debugPrint('tdReceive error: $e');
      }
      if (!_updateCtrl.isClosed) _receiveLoop();
    });
  }

  void _onRawUpdate(String raw) {
    try {
      final u = jsonDecode(raw) as Map<String, dynamic>;
      _updateCtrl.add(u);
      _handleUpdate(u);
    } catch (e) {
      debugPrint('TDLib JSON parse error: $e  raw=$raw');
    }
  }

  // ── TDLib update handler ───────────────────────────────────────────────────

  void _handleUpdate(Map<String, dynamic> u) {
    if (u['@type'] == 'updateAuthorizationState') {
      final state = u['authorization_state'] as Map<String, dynamic>?;
      if (state != null) _handleAuthState(state);
    }
  }

  void _handleAuthState(Map<String, dynamic> state) {
    final type = state['@type'] as String? ?? '';
    debugPrint('TDLib auth → $type');

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _authState = AuthState.idle;
        break;

      case 'authorizationStateWaitEncryptionKey':
        // MUST respond immediately or the entire auth chain hangs
        _send({'@type': 'checkDatabaseEncryptionKey', 'encryption_key': ''});
        return; // skip notifyListeners — not a real user-facing state

      case 'authorizationStateWaitPhoneNumber':
        _authState = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;

      case 'authorizationStateWaitCode':
        _authState = AuthState.waitingCode;
        break;

      case 'authorizationStateWaitOtherDeviceConfirmation':
        _authState = AuthState.waitingCode;
        _errorMessage =
            'Please confirm this login on your other Telegram app or device.';
        break;

      case 'authorizationStateWaitRegistration':
        _authState = AuthState.waitingRegistration;
        break;

      case 'authorizationStateWaitPassword':
        _authState = AuthState.waitingPassword;
        break;

      case 'authorizationStateReady':
        _authState = AuthState.authorized;
        _isLoggedIn = true;
        _errorMessage = '';
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

  // ── Await auth state transition ────────────────────────────────────────────

  Future<AuthState> _awaitAuthState(
    List<AuthState> targets, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // Check synchronously first — avoids missing a state already set
    if (targets.contains(_authState)) return _authState;
    if (_authState == AuthState.error) return AuthState.error;

    final completer = Completer<AuthState>();
    late StreamSubscription<Map<String, dynamic>> sub;

    sub = _updates.listen((u) {
      if (completer.isCompleted) return;
      if (u['@type'] != 'updateAuthorizationState') return;

      final stateType =
          (u['authorization_state'] as Map<String, dynamic>?)?['@type']
              as String?;
      final reached = _authStateFromType(stateType);
      if (reached == null) return;

      if (targets.contains(reached)) {
        completer.complete(reached);
        sub.cancel();
      }
    });

    // Double-check after subscribing — handles the tiny race window
    if (targets.contains(_authState) && !completer.isCompleted) {
      completer.complete(_authState);
      sub.cancel();
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        sub.cancel();
        debugPrint(
            '_awaitAuthState timeout. targets=$targets current=$_authState');
        if (targets.contains(_authState)) return _authState;
        return AuthState.error;
      },
    );
  }

  AuthState? _authStateFromType(String? type) {
    switch (type) {
      case 'authorizationStateWaitPhoneNumber':
        return AuthState.waitingPhone;
      case 'authorizationStateWaitCode':
      case 'authorizationStateWaitOtherDeviceConfirmation':
        return AuthState.waitingCode;
      case 'authorizationStateWaitRegistration':
        return AuthState.waitingRegistration;
      case 'authorizationStateWaitPassword':
        return AuthState.waitingPassword;
      case 'authorizationStateReady':
        return AuthState.authorized;
      default:
        return null;
    }
  }

  // ── Auth actions ───────────────────────────────────────────────────────────

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
      _errorMessage = res['message'] as String? ?? 'Error sending code';
      notifyListeners();
      return false;
    }

    final reached = await _awaitAuthState(
      [AuthState.waitingCode, AuthState.waitingPassword, AuthState.authorized],
      timeout: const Duration(seconds: 60),
    );

    if (reached == AuthState.error) {
      if (_authState == AuthState.waitingCode ||
          _authState == AuthState.waitingPassword ||
          _authState == AuthState.authorized) return true;
      if (_errorMessage.isEmpty) {
        _errorMessage =
            'Could not send verification code. Check your number and try again.';
      }
      notifyListeners();
      return false;
    }

    return true;
  }

  Future<bool> sendOtpCode(String code) async {
    _errorMessage = '';

    final res = await _request(
      {'@type': 'checkAuthenticationCode', 'code': code},
    );

    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Invalid code';
      notifyListeners();
      return false;
    }

    final reached = await _awaitAuthState(
      [AuthState.authorized, AuthState.waitingPassword],
    );

    if (reached == AuthState.error) {
      if (_authState == AuthState.authorized ||
          _authState == AuthState.waitingPassword) return true;
      _errorMessage =
          _errorMessage.isNotEmpty ? _errorMessage : 'Timed out. Try again.';
      notifyListeners();
      return false;
    }

    return true;
  }

  Future<bool> sendPassword(String password) async {
    _errorMessage = '';

    final res = await _request(
      {'@type': 'checkAuthenticationPassword', 'password': password},
    );

    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Wrong password';
      notifyListeners();
      return false;
    }

    final reached = await _awaitAuthState([AuthState.authorized]);

    if (reached == AuthState.error) {
      if (_authState == AuthState.authorized) return true;
      _errorMessage =
          _errorMessage.isNotEmpty ? _errorMessage : 'Timed out. Try again.';
      notifyListeners();
      return false;
    }

    return true;
  }

  Future<void> logout() async {
    try {
      await _request({'@type': 'logOut'});
    } catch (_) {}
    _authState = AuthState.waitingPhone;
    _isLoggedIn = false;
    notifyListeners();
  }

  // ── Resolve Telegram link ──────────────────────────────────────────────────

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
        _errorMessage = 'Unsupported message type: ${content['@type']}';
        notifyListeners();
        return null;
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

  // ── Streaming ──────────────────────────────────────────────────────────────

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

      final prefixSize = local?['downloaded_prefix_size'] as int? ?? 0;
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
      debugPrint('downloadFilePart error: $e');
      return null;
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

  // ── Low-level ─────────────────────────────────────────────────────────────

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
    final extra = '${req['@type']}_${DateTime.now().microsecondsSinceEpoch}';
    req['@extra'] = extra;

    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> sub;

    sub = _updates.listen((u) {
      if (completer.isCompleted) return;
      if (u['@extra'] == extra) {
        completer.complete(u);
        sub.cancel();
      }
    });

    _send(req);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        sub.cancel();
        debugPrint('_request timeout: ${req['@type']}');
        return null;
      },
    );
  }

  @override
  void dispose() {
    _updateCtrl.close();
    super.dispose();
  }
}
