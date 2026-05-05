// lib/services/telegram_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:handy_tdlib/handy_tdlib.dart';

import '../models/telegram_file.dart';

// ─────────────────────────────────────────────────────
//  API credentials injected at build time via
//  --dart-define=TG_API_ID=... --dart-define=TG_API_HASH=...
//  Set inside codemagic.yaml. Get values from https://my.telegram.org
// ─────────────────────────────────────────────────────
const int kApiId = int.fromEnvironment('TG_API_ID', defaultValue: 0);
const String kApiHash = String.fromEnvironment('TG_API_HASH', defaultValue: '');
// ─────────────────────────────────────────────────────

enum AuthState {
  idle,
  waitingPhone,
  waitingCode,
  waitingPassword,
  authorized,
  error,
}

class TelegramService extends ChangeNotifier {
  int? _clientId;

  AuthState _authState = AuthState.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;
  bool _isInitialized = false;
  Timer? _receiveTimer;

  final _updateController = StreamController<Map<String, dynamic>>.broadcast();

  AuthState get authState => _authState;
  String get errorMessage => _errorMessage;
  bool get isLoggedIn => _isLoggedIn;
  bool get isInitialized => _isInitialized;

  // ──────────────────────────────────────────
  // Initialize
  // ──────────────────────────────────────────
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (kApiId == 0 || kApiHash.isEmpty) {
      _errorMessage =
          'Telegram API credentials are missing.\n'
          'Make sure TG_API_ID and TG_API_HASH are set in Codemagic '
          'environment variables and passed via --dart-define.';
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

      await TdPlugin.initialize();

      _clientId = TdPlugin.instance.tdCreateClientId();
      debugPrint('TelegramService: client created, id=$_clientId');

      _isInitialized = true;
      _startReceiveLoop();

      _sendRaw({
        '@type': 'setTdlibParameters',
        'use_test_dc': false,
        'database_directory': dbPath,
        'files_directory': filesPath,
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': false,
        'api_id': kApiId,
        'api_hash': kApiHash,
        'system_language_code': 'en',
        'device_model': io.Platform.isAndroid ? 'Android' : 'iOS',
        'system_version': 'Unknown',
        'application_version': '1.0.0',
        'enable_storage_optimizer': true,
      });

      await _waitForFirstAuthState();
    } catch (e, stack) {
      debugPrint('TelegramService.initialize FAILED: $e\n$stack');
      _errorMessage = e.toString();
      _authState = AuthState.error;
      notifyListeners();
    }
  }

  // ──────────────────────────────────────────
  // Receive loop — polls TDLib every 100ms
  // ──────────────────────────────────────────
  void _startReceiveLoop() {
    _receiveTimer?.cancel();
    _receiveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_isInitialized) return;
      try {
        final raw = TdPlugin.instance.tdReceive(0.1);
        if (raw == null || raw.isEmpty) return;

        final update = json.decode(raw) as Map<String, dynamic>;
        debugPrint('TDLib update: ${update['@type']}');

        if (!_updateController.isClosed) {
          _updateController.add(update);
        }
        _handleUpdate(update);
      } catch (e) {
        debugPrint('tdReceive error: $e');
      }
    });
  }

  Future<void> _waitForFirstAuthState() async {
    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = _updateController.stream.listen((u) {
      if (u['@type'] == 'updateAuthorizationState' && !completer.isCompleted) {
        completer.complete();
        sub.cancel();
      }
    });
    await Future.any([
      completer.future,
      Future.delayed(const Duration(seconds: 10)),
    ]);
    try {
      sub.cancel();
    } catch (_) {}
  }

  void _handleUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String?;
    if (type == 'updateAuthorizationState') {
      final state = update['authorization_state'] as Map<String, dynamic>?;
      if (state != null) _handleAuthState(state);
    }
  }

  void _handleAuthState(Map<String, dynamic> state) {
    final type = state['@type'] as String?;
    debugPrint('TDLib auth state → $type');

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _authState = AuthState.idle;
        break;

      // FIX: TDLib 1.8+ emits this on first run or after DB upgrades.
      // Must respond with checkDatabaseEncryptionKey or TDLib hangs forever,
      // causing the app to freeze on splash and never reach login.
      case 'authorizationStateWaitEncryptionKey':
        _sendRaw({'@type': 'checkDatabaseEncryptionKey', 'encryption_key': ''});
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

  // ──────────────────────────────────────────
  // Auth actions
  // ──────────────────────────────────────────
  Future<bool> sendPhoneNumber(String phoneNumber) async {
    _errorMessage = '';
    final res = await _sendRequest({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phoneNumber,
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
    final res = await _sendRequest({
      '@type': 'checkAuthenticationCode',
      'code': code,
    });
    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Invalid code';
      notifyListeners();
      return false;
    }
    return true;
  }

  Future<bool> sendPassword(String password) async {
    _errorMessage = '';
    final res = await _sendRequest({
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
    if (res != null && res['@type'] == 'error') {
      _errorMessage = res['message'] as String? ?? 'Wrong password';
      notifyListeners();
      return false;
    }
    return true;
  }

  Future<void> logout() async {
    try {
      await _sendRequest({'@type': 'logOut'});
    } catch (_) {}
    _isLoggedIn = false;
    _authState = AuthState.waitingPhone;
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // Resolve a t.me link to a TelegramFile
  // ──────────────────────────────────────────
  Future<TelegramFile?> resolveLink(String link) async {
    _errorMessage = '';
    try {
      final res = await _sendRequest({
        '@type': 'getMessageLinkInfo',
        'url': link,
      });
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
      final message = res['message'] as Map<String, dynamic>?;
      if (message == null) {
        _errorMessage = 'No message at this link';
        notifyListeners();
        return null;
      }
      return _extractFile(message);
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      return null;
    }
  }

  TelegramFile? _extractFile(Map<String, dynamic> message) {
    final content = message['content'] as Map<String, dynamic>?;
    if (content == null) return null;
    final type = content['@type'] as String?;

    switch (type) {
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
        _errorMessage = 'Unsupported content type: $type';
        notifyListeners();
        return null;
    }
  }

  TelegramFile? _parseVideo(Map<String, dynamic> content) {
    final video = content['video'] as Map<String, dynamic>?;
    if (video == null) return null;
    final file = video['video'] as Map<String, dynamic>?;
    if (file == null) return null;

    final w = video['width'] as int? ?? 0;
    final h = video['height'] as int? ?? 0;

    // FIX: Fall back to expected_size when size is 0 (file not yet downloaded)
    int _fileSize(Map<String, dynamic> f) =>
        (f['size'] as int? ?? 0) > 0
            ? f['size'] as int
            : (f['expected_size'] as int? ?? 0);

    final qualities = <VideoQuality>[
      VideoQuality(
        label: _label(h),
        width: w,
        height: h,
        fileId: file['id'] as int? ?? 0,
        fileSize: _fileSize(file),
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
        fileSize: _fileSize(af),
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
      fileSize: _fileSize(file),
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
      fileSize: (file['size'] as int? ?? 0) > 0
          ? file['size'] as int
          : (file['expected_size'] as int? ?? 0),
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
      fileSize: (file['size'] as int? ?? 0) > 0
          ? file['size'] as int
          : (file['expected_size'] as int? ?? 0),
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
      fileSize: (file['size'] as int? ?? 0) > 0
          ? file['size'] as int
          : (file['expected_size'] as int? ?? 0),
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
      fileSize: (file['size'] as int? ?? 0) > 0
          ? file['size'] as int
          : (file['expected_size'] as int? ?? 0),
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
    final m = t as Map<String, dynamic>?;
    final f = m?['file'] as Map<String, dynamic>?;
    return (f?['local'] as Map<String, dynamic>?)?['path'] as String?;
  }

  // ──────────────────────────────────────────
  // Download a byte range of a file for streaming
  // FIX: Original code read raf.length() (total disk size) to decide
  // how many bytes to read. For streaming, only a PREFIX of the file
  // is downloaded at any time. The correct field is
  // local.downloaded_prefix_size from TDLib's response.
  // ──────────────────────────────────────────
  Future<Uint8List?> downloadFilePart({
    required int fileId,
    required int offset,
    required int count,
  }) async {
    try {
      final res = await _sendRequest({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 32,
        'offset': offset,
        'limit': count,
        'synchronous': true,
      });

      if (res == null || res['@type'] == 'error') {
        debugPrint('downloadFilePart TDLib error: ${res?['message']}');
        return null;
      }

      final local = res['local'] as Map<String, dynamic>?;
      final path = local?['path'] as String?;
      if (path == null || path.isEmpty) return null;

      final f = io.File(path);
      if (!await f.exists()) return null;

      // How many bytes from the start of the file are actually on disk
      final downloadedPrefix = (local?['downloaded_prefix_size'] as int?) ?? 0;

      // Bytes available starting at our requested offset
      final available = (downloadedPrefix - offset).clamp(0, count);
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
      final res = await _sendRequest({'@type': 'getFile', 'file_id': fileId});
      if (res == null || res['@type'] == 'error') return 0;
      // FIX: also check expected_size when size is 0
      final size = res['size'] as int? ?? 0;
      return size > 0 ? size : (res['expected_size'] as int? ?? 0);
    } catch (_) {
      return 0;
    }
  }

  // ──────────────────────────────────────────
  // Low-level send/receive
  // ──────────────────────────────────────────
  void _sendRaw(Map<String, dynamic> req) {
    if (_clientId == null) return;
    try {
      TdPlugin.instance.tdSend(_clientId!, json.encode(req));
    } catch (e) {
      debugPrint('_sendRaw error: $e');
    }
  }

  Future<Map<String, dynamic>?> _sendRequest(
      Map<String, dynamic> req) async {
    if (_clientId == null) return null;

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    req['@extra'] = id;

    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription sub;
    sub = _updateController.stream.listen((u) {
      if (u['@extra'] == id && !completer.isCompleted) {
        completer.complete(u);
        sub.cancel();
      }
    });

    try {
      TdPlugin.instance.tdSend(_clientId!, json.encode(req));
    } catch (e) {
      sub.cancel();
      debugPrint('tdSend error: $e');
      return null;
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        debugPrint('Request timeout: ${req['@type']}');
        return null;
      },
    );
  }

  @override
  void dispose() {
    _receiveTimer?.cancel();
    _updateController.close();
    super.dispose();
  }
}
