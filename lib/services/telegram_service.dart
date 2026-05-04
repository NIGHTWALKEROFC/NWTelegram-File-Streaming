import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:handy_tdlib/handy_tdlib.dart';

const int kApiId = 12345678; 
const String kApiHash = 'your_api_hash_here';

enum AuthState { idle, waitingPhone, waitingCode, waitingPassword, authorized, error }

class TelegramService extends ChangeNotifier {
  int? _clientId;
  final _storage = const FlutterSecureStorage();
  AuthState _authState = AuthState.idle;
  bool _isLoggedIn = false;
  bool _isInitialized = false;
  final StreamController<Map<String, dynamic>> _updateController = StreamController.broadcast();

  bool get isLoggedIn => _isLoggedIn;
  AuthState get authState => _authState;

  Future<void> initialize() async {
    if (_isInitialized) return;

    final docsDir = await getApplicationDocumentsDirectory();
    final tdPath = io.Directory('${docsDir.path}/tdlib').path;
    
    if (!await io.Directory(tdPath).exists()) {
      await io.Directory(tdPath).create(recursive: true);
    }

    // This is the point where missing .so files cause a crash
    _clientId = TdPlugin.instance.tdCreate();
    
    _startReceiveLoop();

    await _sendRequest({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': tdPath,
      'files_directory': tdPath,
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': kApiId,
      'api_hash': kApiHash,
      'system_language_code': 'en',
      'device_model': 'Mobile',
      'system_version': 'Android',
      'application_version': '1.0.0',
    });

    _isInitialized = true;
    notifyListeners();
  }

  void _startReceiveLoop() {
    Future.delayed(Duration.zero, () async {
      while (_clientId != null) {
        final res = TdPlugin.instance.tdReceive(1.0);
        if (res != null) {
          final update = json.decode(res);
          _handleUpdate(update);
          _updateController.add(update);
        }
      }
    });
  }

  void _handleUpdate(Map<String, dynamic> update) {
    if (update['@type'] == 'updateAuthorizationState') {
      final state = update['authorization_state']['@type'];
      switch (state) {
        case 'authorizationStateWaitPhoneNumber':
          _authState = AuthState.waitingPhone;
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
          _isLoggedIn = false;
          _authState = AuthState.idle;
          break;
      }
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> _sendRequest(Map<String, dynamic> request) async {
    if (_clientId == null) return null;
    final completer = Completer<Map<String, dynamic>?>();
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    request['@extra'] = requestId;

    late StreamSubscription sub;
    sub = _updateController.stream.listen((data) {
      if (data['@extra'] == requestId) {
        completer.complete(data);
        sub.cancel();
      }
    });

    TdPlugin.instance.tdSend(_clientId!, json.encode(request));
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      sub.cancel();
      return null;
    });
  }

  Future<void> logout() async {
    await _sendRequest({'@type': 'logOut'});
    _isLoggedIn = false;
    notifyListeners();
  }
}

