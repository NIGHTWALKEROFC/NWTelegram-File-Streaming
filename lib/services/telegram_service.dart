import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib/tdlib.dart'; // ← fixed: was flutter_tdlib

import '../models/telegram_file.dart';

// ─────────────────────────────────────────────
//  REPLACE THESE WITH YOUR REAL VALUES FROM
//  https://my.telegram.org
//  (codemagic.yaml injects these at build time)
// ─────────────────────────────────────────────
const int kApiId = 12345678; // ← your api_id
const String kApiHash = 'your_api_hash_here'; // ← your api_hash
// ─────────────────────────────────────────────

enum AuthState {
  idle,
  waitingPhone,
  waitingCode,
  waitingPassword,
  authorized,
  error,
}

class TelegramService extends ChangeNotifier {
  TdClient? _client; // ← fixed: was TdPlugin
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  AuthState _authState = AuthState.idle;
  String _errorMessage = '';
  bool _isLoggedIn = false;
  bool _isInitialized = false;
  Timer? _receiveTimer;

  // Stream controller for TDLib updates
  final StreamController<Map<String, dynamic>> _updateController =
      StreamController.broadcast();

  AuthState get authState => _authState;
  String get errorMessage => _errorMessage;
  bool get isLoggedIn => _isLoggedIn;
  bool get isInitialized => _isInitialized;
  Stream<Map<String, dynamic>> get updates => _updateController.stream;

  // ──────────────────────────────────────────
  // Initialize TDLib
  // ──────────────────────────────────────────
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = '${dir.path}/tdlib';
      await Directory(dbPath).create(recursive: true);

      _client = TdClient(); // ← fixed: was TdPlugin.instance
      _isInitialized = true;

      // Start listening for updates
      _startUpdateListener();

      // Send TDLib parameters
      await _sendTdLibParams(dbPath);

      // Wait for auth state
      await _waitForInitialAuthState();
    } catch (e) {
      _errorMessage = 'Failed to initialize: $e';
      _authState = AuthState.error;
      notifyListeners();
    }
  }

  void _startUpdateListener() {
    // Poll TDLib every 100 ms for incoming updates
    _receiveTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (_client == null) return;
      try {
        // ← fixed: was tdReceive(); now async receive()
        final response = await _client!.receive(0.1);
        if (response != null) {
          final Map<String, dynamic> update = json.decode(response);
          _updateController.add(update);
          _handleUpdate(update);
        }
      } catch (_) {}
    });
  }

  Future<void> _sendTdLibParams(String dbPath) async {
    await _sendRequest({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': dbPath,
      'files_directory': '$dbPath/files',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': kApiId,
      'api_hash': kApiHash,
      'system_language_code': 'en',
      'device_model': 'Android',
      'application_version': '1.0.0',
      'enable_storage_optimizer': true,
    });
  }

  Future<void> _waitForInitialAuthState() async {
    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = _updateController.stream.listen((update) {
      if (update['@type'] == 'updateAuthorizationState') {
        final state = update['authorization_state'];
        if (state != null) {
          completer.complete();
          sub.cancel();
        }
      }
    });
    await Future.any([
      completer.future,
      Future.delayed(const Duration(seconds: 5)),
    ]);
  }

  void _handleUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String?;
    if (type == null) return;

    if (type == 'updateAuthorizationState') {
      final authStateMap =
          update['authorization_state'] as Map<String, dynamic>?;
      if (authStateMap == null) return;
      _handleAuthState(authStateMap);
    }
  }

  void _handleAuthState(Map<String, dynamic> authStateMap) {
    final stateType = authStateMap['@type'] as String?;
    switch (stateType) {
      case 'authorizationStateWaitTdlibParameters':
        _authState = AuthState.idle;
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
      case 'authorizationStateClosed':
        _authState = AuthState.waitingPhone;
        _isLoggedIn = false;
        break;
    }
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // Auth Methods
  // ──────────────────────────────────────────
  Future<bool> sendPhoneNumber(String phoneNumber) async {
    try {
      _errorMessage = '';
      final response = await _sendRequest({
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
      return response != null && response['@type'] != 'error';
    } catch (e) {
      _errorMessage = 'Failed to send phone number: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendOtpCode(String code) async {
    try {
      _errorMessage = '';
      final response = await _sendRequest({
        '@type': 'checkAuthenticationCode',
        'code': code,
      });
      return response != null && response['@type'] != 'error';
    } catch (e) {
      _errorMessage = 'Failed to verify code: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendPassword(String password) async {
    try {
      _errorMessage = '';
      final response = await _sendRequest({
        '@type': 'checkAuthenticationPassword',
        'password': password,
      });
      return response != null && response['@type'] != 'error';
    } catch (e) {
      _errorMessage = 'Failed to verify password: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await _sendRequest({'@type': 'logOut'});
    _isLoggedIn = false;
    _authState = AuthState.waitingPhone;
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // Resolve Telegram Link → File Info
  // ──────────────────────────────────────────
  Future<TelegramFile?> resolveLink(String link) async {
    try {
      // Step 1: Parse the link
      final linkInfo = await _sendRequest({
        '@type': 'getMessageLinkInfo',
        'url': link,
      });

      if (linkInfo == null || linkInfo['@type'] == 'error') {
        throw Exception('Invalid or inaccessible link');
      }

      final message = linkInfo['message'] as Map<String, dynamic>?;
      if (message == null) throw Exception('No message found at this link');

      return _extractFileFromMessage(message);
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  TelegramFile? _extractFileFromMessage(Map<String, dynamic> message) {
    final content = message['content'] as Map<String, dynamic>?;
    if (content == null) return null;

    final contentType = content['@type'] as String?;

    switch (contentType) {
      case 'messageVideo':
        final video = content['video'] as Map<String, dynamic>?;
        if (video == null) return null;
        final file = video['video'] as Map<String, dynamic>?;
        if (file == null) return null;

        // Extract qualities from video
        final alternatives =
            video['alternative_videos'] as List<dynamic>? ?? [];
        final qualities = <VideoQuality>[];

        // Main video quality
        final width = video['width'] as int? ?? 0;
        final height = video['height'] as int? ?? 0;
        qualities.add(VideoQuality(
          label: _heightToLabel(height),
          width: width,
          height: height,
          fileId: (file['id'] as int?) ?? 0,
          fileSize: (file['size'] as int?) ?? 0,
          remoteId: (file['remote'] as Map?)?['id'] as String? ?? '',
        ));

        // Alternative qualities
        for (final alt in alternatives) {
          final altMap = alt as Map<String, dynamic>;
          final altFile = altMap['video'] as Map<String, dynamic>?;
          if (altFile == null) continue;
          final altH = altMap['height'] as int? ?? 0;
          final altW = altMap['width'] as int? ?? 0;
          qualities.add(VideoQuality(
            label: _heightToLabel(altH),
            width: altW,
            height: altH,
            fileId: (altFile['id'] as int?) ?? 0,
            fileSize: (altFile['size'] as int?) ?? 0,
            remoteId: (altFile['remote'] as Map?)?['id'] as String? ?? '',
          ));
        }

        // Sort descending by height
        qualities.sort((a, b) => b.height.compareTo(a.height));

        return TelegramFile(
          type: TelegramFileType.video,
          name: video['file_name'] as String? ?? 'video.mp4',
          mimeType: video['mime_type'] as String? ?? 'video/mp4',
          duration: video['duration'] as int? ?? 0,
          width: width,
          height: height,
          fileId: (file['id'] as int?) ?? 0,
          fileSize: (file['size'] as int?) ?? 0,
          remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
          thumbnail: _extractThumbnail(video['thumbnail']),
          qualities: qualities,
        );

      case 'messageAudio':
        final audio = content['audio'] as Map<String, dynamic>?;
        if (audio == null) return null;
        final file = audio['audio'] as Map<String, dynamic>?;
        if (file == null) return null;
        return TelegramFile(
          type: TelegramFileType.audio,
          name: audio['file_name'] as String? ?? 'audio.mp3',
          mimeType: audio['mime_type'] as String? ?? 'audio/mpeg',
          duration: audio['duration'] as int? ?? 0,
          fileId: (file['id'] as int?) ?? 0,
          fileSize: (file['size'] as int?) ?? 0,
          remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
          qualities: [],
        );

      case 'messageDocument':
        final doc = content['document'] as Map<String, dynamic>?;
        if (doc == null) return null;
        final file = doc['document'] as Map<String, dynamic>?;
        if (file == null) return null;
        return TelegramFile(
          type: TelegramFileType.document,
          name: doc['file_name'] as String? ?? 'file',
          mimeType: doc['mime_type'] as String? ?? 'application/octet-stream',
          fileId: (file['id'] as int?) ?? 0,
          fileSize: (file['size'] as int?) ?? 0,
          remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
          qualities: [],
        );

      case 'messageVoiceNote':
        final voice = content['voice_note'] as Map<String, dynamic>?;
        if (voice == null) return null;
        final file = voice['voice'] as Map<String, dynamic>?;
        if (file == null) return null;
        return TelegramFile(
          type: TelegramFileType.audio,
          name: 'voice_note.ogg',
          mimeType: voice['mime_type'] as String? ?? 'audio/ogg',
          duration: voice['duration'] as int? ?? 0,
          fileId: (file['id'] as int?) ?? 0,
          fileSize: (file['size'] as int?) ?? 0,
          remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
          qualities: [],
        );

      case 'messageVideoNote':
        final videoNote = content['video_note'] as Map<String, dynamic>?;
        if (videoNote == null) return null;
        final file = videoNote['video'] as Map<String, dynamic>?;
        if (file == null) return null;
        return TelegramFile(
          type: TelegramFileType.video,
          name: 'video_note.mp4',
          mimeType: 'video/mp4',
          duration: videoNote['duration'] as int? ?? 0,
          fileId: (file['id'] as int?) ?? 0,
          fileSize: (file['size'] as int?) ?? 0,
          remoteFileId: (file['remote'] as Map?)?['id'] as String? ?? '',
          qualities: [],
        );

      default:
        _errorMessage = 'Unsupported file type: $contentType';
        notifyListeners();
        return null;
    }
  }

  String _heightToLabel(int height) {
    if (height >= 2160) return '4K';
    if (height >= 1440) return '1440p';
    if (height >= 1080) return '1080p';
    if (height >= 720) return '720p';
    if (height >= 480) return '480p';
    if (height >= 360) return '360p';
    if (height >= 240) return '240p';
    return '${height}p';
  }

  String? _extractThumbnail(dynamic thumbnail) {
    if (thumbnail == null) return null;
    final thumbMap = thumbnail as Map<String, dynamic>?;
    if (thumbMap == null) return null;
    final file = thumbMap['file'] as Map<String, dynamic>?;
    if (file == null) return null;
    final local = file['local'] as Map<String, dynamic>?;
    return local?['path'] as String?;
  }

  // ──────────────────────────────────────────
  // Download file part for streaming
  // Fixed: uses RandomAccessFile for true range reads instead of
  // loading the entire file into memory (critical for large videos).
  // ──────────────────────────────────────────
  Future<Uint8List?> downloadFilePart({
    required int fileId,
    required int offset,
    required int count,
  }) async {
    try {
      final response = await _sendRequest({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 32,
        'offset': offset,
        'limit': count,
        'synchronous': true,
      });

      if (response == null || response['@type'] == 'error') return null;

      final localPath = response['local']?['path'] as String?;
      if (localPath == null || localPath.isEmpty) return null;

      final file = File(localPath);
      if (!await file.exists()) return null;

      // ← fixed: RandomAccessFile range read instead of readAsBytes()
      // which previously loaded the entire file into memory for every chunk.
      final raf = await file.open();
      try {
        final fileLength = await raf.length();
        if (offset >= fileLength) return Uint8List(0);
        await raf.setPosition(offset);
        final bytesToRead = count.clamp(0, fileLength - offset);
        return await raf.read(bytesToRead);
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint('downloadFilePart error: $e');
      return null;
    }
  }

  /// Gets the total size of a remote file without downloading
  Future<int> getFileSize(int fileId) async {
    try {
      final response = await _sendRequest({
        '@type': 'getFile',
        'file_id': fileId,
      });
      if (response == null) return 0;
      return (response['size'] as int?) ??
          (response['expected_size'] as int?) ??
          0;
    } catch (e) {
      return 0;
    }
  }

  // ──────────────────────────────────────────
  // Low-level TDLib request
  // ──────────────────────────────────────────
  Future<Map<String, dynamic>?> _sendRequest(
    Map<String, dynamic> request,
  ) async {
    if (_client == null) return null;

    final String requestId = DateTime.now().millisecondsSinceEpoch.toString();
    request['@extra'] = requestId;

    final Completer<Map<String, dynamic>?> completer = Completer();

    late StreamSubscription sub;
    sub = _updateController.stream.listen((update) {
      if (update['@extra'] == requestId) {
        completer.complete(update);
        sub.cancel();
      }
    });

    // ← fixed: was tdSend(); now send()
    _client!.send(json.encode(request));

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        sub.cancel();
        return null;
      },
    );
  }

  @override
  void dispose() {
    _receiveTimer?.cancel(); // ← fixed: cancel timer properly on dispose
    _updateController.close();
    super.dispose();
  }
}
