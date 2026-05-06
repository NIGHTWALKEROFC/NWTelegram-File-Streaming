// lib/services/telegram_service.dart
//
// DEFINITIVE FIX — Why all previous versions failed:
// ===================================================
//
// Version 1 — background Isolate + tdReceive(1.0):
//   FAILED: handy_tdlib's TdPlugin is registered only on the MAIN Flutter
//   isolate. Spawned isolates have no plugin registry, so tdReceive always
//   returned null. Every update was silently dropped.
//
// Version 2 — compute() + tdReceive(1.0):
//   FAILED: compute() spawns a new isolate internally. Same problem as above.
//   TdPlugin.instance in that isolate has no client, always returns null.
//
// CORRECT APPROACH — this file:
// ================================
// Run EVERYTHING on the MAIN isolate using Timer.periodic every 10 ms
// with tdReceive(0.0) (non-blocking). Because it runs on the main isolate
// where TdPlugin is properly registered, every TDLib event is captured
// immediately. 10 ms polling = imperceptible latency. CPU cost is near-zero
// since tdReceive(0.0) is a native no-op when nothing is queued.
//
// This is the correct pattern used by all working Flutter TDLib apps.
//
// KEY FIX for "could not send verification code":
// sendPhoneNumber() now subscribes to the raw update stream BEFORE sending
// the request, then waits for authorizationStateWaitCode directly. It no
// longer relies on _request()/@extra matching, which was unreliable because
// setAuthenticationPhoneNumber does not always echo @extra in its response.

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

  /// All raw TDLib updates — subscribe here to react to any event
  Stream<Map<String, dynamic>> get updates => _updateCtrl.stream;

  AuthState _authState = AuthState.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;
  bool _isInitialized = false;

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
          'Set TG_API_ID and TG_API_HASH in Codemagic → '
          'Environment Variables (group: telegram_keys).';
      _authState = AuthState.error;
      notifyListeners();
      return;
    }

    try {
      // MUST be called on the main isolate — registers the Flutter plugin
      TdPlugin.initialize();
      _clientId = TdPlugin.instance.tdCreateClientId();

      // Start polling BEFORE sending any request so no event is missed
      _startPolling();

      final appDir = await getApplicationDocumentsDirectory();
      final dbPath = '${appDir.path}/tdlib_db';
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

      // Wait for first auth state update — max 10 s
      await updates
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

  // ── Polling loop — main isolate, 10 ms, non-blocking ──────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (_updateCtrl.isClosed) return;
      try {
        // tdReceive(0.0) = return immediately; null if nothing queued
        final raw = TdPlugin.instance.tdReceive(0.0);
        if (raw != null && raw.isNotEmpty) {
          _onRawUpdate(raw);
        }
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
      debugPrint('TDLib JSON parse error: $e  raw=$raw');
    }
  }

  // ── Auth state machine ─────────────────────────────────────────────────────

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
        // Must respond immediately — otherwise auth chain hangs here forever
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

  // ── Auth actions ───────────────────────────────────────────────────────────
  //
  // All three auth methods follow the same pattern:
  // 1. Subscribe to the raw update stream BEFORE sending the request
  // 2. Send the request via _send() (fire-and-forget, no @extra needed)
  // 3. Wait for the expected authorizationState update or an error update
  // 4. Synchronous double-check after subscribing to close the race window

  Future<bool> sendPhoneNumber(String phone) async {
    _errorMessage = '';

    final completer = Completer<bool>();
    late StreamSubscription<Map<String, dynamic>> sub;

    sub = updates.listen((u) {
      if (completer.isCompleted) return;

      // Explicit error from TDLib (bad format, flood wait, etc.)
      if (u['@type'] == 'error') {
        final msg = u['message'] as String? ?? 'Error sending code';
        _errorMessage = msg;
        notifyListeners();
        completer.complete(false);
        sub.cancel();
        return;
      }

      if (u['@type'] == 'updateAuthorizationState') {
        final type =
            (u['authorization_state'] as Map<String, dynamic>?)?['@type']
                as String?;
        if (type == 'authorizationStateWaitCode' ||
            type == 'authorizationStateWaitOtherDeviceConfirmation' ||
            type == 'authorizationStateWaitPassword' ||
            type == 'authorizationStateReady') {
          completer.complete(true);
          sub.cancel();
        }
      }
    });

    // Send AFTER subscribing — never miss a response
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

    // Synchronous check — state may already be set from a prior update
    if (!completer.isCompleted &&
        (_authState == AuthState.waitingCode ||
            _authState == AuthState.waitingPassword ||
            _authState == AuthState.authorized)) {
      completer.complete(true);
      sub.cancel();
    }

    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        sub.cancel();
        // Final check before reporting failure
        if (_authState == AuthState.waitingCode ||
            _authState == AuthState.waitingPassword ||
            _authState == AuthState.authorized) return true;
        _errorMessage =
            'Could not reach Telegram. Check your internet and try again.';
        notifyListeners();
        return false;
      },
    );
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
        final type =
            (u['authorization_state'] as Map<String, dynamic>?)?['@type']
                as String?;
        if (type == 'authorizationStateReady' ||
            type == 'authorizationStateWaitPassword') {
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

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        if (_authState == AuthState.authorized ||
            _authState == AuthState.waitingPassword) return true;
        _errorMessage =
            _errorMessage.isNotEmpty ? _errorMessage : 'Timed out. Try again.';
        notifyListeners();
        return false;
      },
    );
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
        final type =
            (u['authorization_state'] as Map<String, dynamic>?)?['@type']
                as String?;
        if (type == 'authorizationStateReady') {
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

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        if (_authState == AuthState.authorized) return true;
        _errorMessage =
            _errorMessage.isNotEmpty ? _errorMessage : 'Timed out. Try again.';
        notifyListeners();
        return false;
      },
    );
  }

  Future<void> logout() async {
    _send({'@type': 'logOut'});
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
    final extra = '${req['@type']}_${DateTime.now().microsecondsSinceEpoch}';
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
    _pollTimer?.cancel();
    _updateCtrl.close();
    super.dispose();
  }
}
