// lib/screens/player_screen.dart
//
// FIXES in this revision:
// ========================
// 1. Player + VideoController are created SYNCHRONOUSLY in initState.
//    media_kit requires the VideoController to exist before the Video widget
//    is first built so the native surface (SurfaceTexture on Android) is
//    registered before libmpv tries to attach to it. Creating them inside an
//    async function that runs after a delay means the surface may not exist
//    when libmpv starts — resulting in a black screen / no controls.
//
// 2. player.open() is called via addPostFrameCallback AFTER the first frame
//    is drawn. This guarantees the Video widget's Texture is registered and
//    the local proxy server (started in HomeScreen.initState) has had time to
//    bind its port before libmpv makes its first HTTP request to 127.0.0.1.
//
// 3. _isInitializing gate removed for video. The Video widget renders its own
//    buffering spinner internally. Gating on _isInitializing meant the Video
//    widget was never in the tree, so no surface existed for libmpv to render
//    to and no controls were ever shown.
//
// 4. Error detection uses player.stream.error (string stream from libmpv).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/telegram_file.dart';

class PlayerScreen extends StatefulWidget {
  final TelegramFile file;
  final VideoQuality? selectedQuality;
  final String streamUrl;

  const PlayerScreen({
    super.key,
    required this.file,
    required this.selectedQuality,
    required this.streamUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // ── media_kit — created synchronously in initState ─────────────────────────
  late final Player _player;
  late final VideoController _videoController;

  // ── just_audio (audio-only files) ─────────────────────────────────────────
  AudioPlayer? _audioPlayer;
  bool _isAudioPlaying = false;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  final List<StreamSubscription<dynamic>> _subs = [];

  // ── UI state ───────────────────────────────────────────────────────────────
  bool _isAudioInitializing = true;
  String? _initError;

  @override
  void initState() {
    super.initState();

    if (widget.file.isVideo) {
      // Create Player + VideoController synchronously so the Video widget has
      // a valid controller on its very first build. The native surface
      // (SurfaceTexture) is registered here — deferring this means libmpv
      // has nothing to render to.
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 8 * 1024 * 1024,
          logLevel: MPVLogLevel.warn,
        ),
      );
      _videoController = VideoController(_player);

      _subs.add(_player.stream.error.listen((err) {
        debugPrint('media_kit error: $err');
        if (mounted && _initError == null && err.isNotEmpty) {
          setState(() => _initError = err);
        }
      }));

      // Open media AFTER first frame — by then the Texture is registered
      // and the local proxy server has finished binding port 8484.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _player.open(
          Media(
            widget.streamUrl,
            httpHeaders: const {
              'Accept': '*/*',
              'Connection': 'keep-alive',
            },
          ),
        );
      });
    } else if (widget.file.isAudio) {
      _player = Player();
      _videoController = VideoController(_player);
      Future.delayed(const Duration(milliseconds: 200), _initAudioPlayer);
    } else {
      _player = Player();
      _videoController = VideoController(_player);
      _isAudioInitializing = false;
    }
  }

  // ── Audio init ─────────────────────────────────────────────────────────────

  Future<void> _initAudioPlayer() async {
    if (!mounted) return;
    try {
      _audioPlayer = AudioPlayer();
      _subs.add(_audioPlayer!.durationStream.listen((d) {
        if (d != null && mounted) setState(() => _audioDuration = d);
      }));
      _subs.add(_audioPlayer!.positionStream.listen((p) {
        if (mounted) setState(() => _audioPosition = p);
      }));
      _subs.add(_audioPlayer!.playingStream.listen((v) {
        if (mounted) setState(() => _isAudioPlaying = v);
      }));
      await _audioPlayer!.setUrl(widget.streamUrl);
      await _audioPlayer!.play();
    } catch (e) {
      debugPrint('Audio init error: $e');
      if (mounted) setState(() => _initError = e.toString());
    } finally {
      if (mounted) setState(() => _isAudioInitializing = false);
    }
  }

  // ── Retry video ────────────────────────────────────────────────────────────

  void _retryVideo() {
    if (!mounted) return;
    setState(() => _initError = null);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _player.open(
        Media(
          widget.streamUrl,
          httpHeaders: const {
            'Accept': '*/*',
            'Connection': 'keep-alive',
          },
        ),
      );
    });
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    // VideoController has no dispose() — Player.dispose() cleans it up.
    _player.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_initError != null && widget.file.isVideo) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0F),
        appBar: _buildAppBar(),
        body: _buildErrorView(),
      );
    }

    if (widget.file.isVideo) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildVideoView(),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: _buildAppBar(),
      body: widget.file.isAudio
          ? (_isAudioInitializing ? _buildLoading() : _buildAudioView())
          : _buildDocumentView(),
    );
  }

  AppBar _buildAppBar() => AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.file.name,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          overflow: TextOverflow.ellipsis,
        ),
      );

  Widget _buildLoading() => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
                color: Color(0xFF2AABEE), strokeWidth: 2),
            SizedBox(height: 20),
            Text('Connecting to stream...',
                style: TextStyle(color: Color(0xFF9090B0), fontSize: 15)),
          ],
        ),
      );

  // ── Video view ─────────────────────────────────────────────────────────────

  Widget _buildVideoView() {
    final qualityLabel = widget.selectedQuality?.label ??
        (widget.file.height > 0 ? '${widget.file.height}p' : '');

    return MaterialVideoControlsTheme(
      normal: MaterialVideoControlsThemeData(
        controlsHoverDuration: const Duration(seconds: 4),
        seekBarColor: const Color(0xFF3A3A5A),
        seekBarPositionColor: const Color(0xFF2AABEE),
        seekBarThumbColor: const Color(0xFF2AABEE),
        primaryButtonBar: [
          const Spacer(),
          MaterialPlayOrPauseButton(iconSize: 48),
          const Spacer(),
        ],
        topButtonBar: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.45),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.arrow_back,
                  color: Colors.white, size: 20),
            ),
          ),
          const Spacer(),
          if (qualityLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  qualityLabel,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
        bottomButtonBar: [
          const MaterialPositionIndicator(),
          const Spacer(),
          MaterialCustomButton(
            onPressed: _showSpeedPicker,
            icon: const Icon(Icons.speed_rounded, color: Colors.white),
          ),
          MaterialFullscreenButton(),
        ],
        volumeGesture: true,
        brightnessGesture: true,
        seekGesture: true,
      ),
      fullscreen: const MaterialVideoControlsThemeData(
        volumeGesture: true,
        brightnessGesture: true,
        seekGesture: true,
      ),
      child: Video(
        controller: _videoController,
        fit: BoxFit.contain,
        onEnterFullscreen: () async {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
          await SystemChrome.setEnabledSystemUIMode(
              SystemUiMode.immersiveSticky);
        },
        onExitFullscreen: () async {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
          await SystemChrome.setEnabledSystemUIMode(
              SystemUiMode.edgeToEdge);
        },
      ),
    );
  }

  // ── Speed picker ───────────────────────────────────────────────────────────

  void _showSpeedPicker() {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141420),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3A5A),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 8, bottom: 10),
              child: Text('Playback Speed',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15)),
            ),
            StreamBuilder<double>(
              stream: _player.stream.rate,
              initialData: 1.0,
              builder: (ctx, snap) {
                final current = snap.data ?? 1.0;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: speeds.map((s) {
                    final selected = (s - current).abs() < 0.01;
                    return GestureDetector(
                      onTap: () {
                        _player.setRate(s);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF2AABEE)
                              : const Color(0xFF1E1E35),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          s == 1.0 ? 'Normal' : '${s}x',
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : const Color(0xFF9090B0),
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.normal,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Audio view ─────────────────────────────────────────────────────────────

  Widget _buildAudioView() {
    final progress = _audioDuration.inMilliseconds > 0
        ? (_audioPosition.inMilliseconds / _audioDuration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        children: [
          const SizedBox(height: 32),
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF9B59B6), Color(0xFF6C3483)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF9B59B6).withOpacity(0.4),
                    blurRadius: 40,
                    spreadRadius: 4)
              ],
            ),
            child: const Icon(Icons.music_note_rounded,
                color: Colors.white, size: 72),
          ),
          const SizedBox(height: 32),
          Text(widget.file.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Text(
              widget.file.mimeType.toUpperCase().replaceAll('AUDIO/', ''),
              style: const TextStyle(
                  color: Color(0xFF9090B0), fontSize: 13)),
          const SizedBox(height: 28),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF9B59B6),
              inactiveTrackColor: const Color(0xFF3A3A5A),
              thumbColor: const Color(0xFF9B59B6),
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: progress,
              onChanged: (v) => _audioPlayer?.seek(Duration(
                  milliseconds:
                      (v * _audioDuration.inMilliseconds).round())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(_audioPosition),
                    style: const TextStyle(
                        color: Color(0xFF9090B0), fontSize: 12)),
                Text(_fmt(_audioDuration),
                    style: const TextStyle(
                        color: Color(0xFF9090B0), fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 30,
                icon: const Icon(Icons.replay_10_rounded,
                    color: Colors.white),
                onPressed: () {
                  final p = _audioPosition - const Duration(seconds: 10);
                  _audioPlayer
                      ?.seek(p < Duration.zero ? Duration.zero : p);
                },
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => _isAudioPlaying
                    ? _audioPlayer?.pause()
                    : _audioPlayer?.play(),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: const Color(0xFF9B59B6),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: const Color(0xFF9B59B6).withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 4)
                    ],
                  ),
                  child: Icon(
                    _isAudioPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                iconSize: 30,
                icon: const Icon(Icons.forward_30_rounded,
                    color: Colors.white),
                onPressed: () {
                  final p = _audioPosition + const Duration(seconds: 30);
                  _audioPlayer
                      ?.seek(p > _audioDuration ? _audioDuration : p);
                },
              ),
            ],
          ),
          const SizedBox(height: 28),
          _buildStreamUrlCard(),
        ],
      ),
    );
  }

  // ── Document view ──────────────────────────────────────────────────────────

  Widget _buildDocumentView() {
    final mime = widget.file.mimeType.toLowerCase();
    final IconData icon;
    final Color color;

    if (mime.contains('pdf')) {
      icon = Icons.picture_as_pdf_rounded;
      color = const Color(0xFFE74C3C);
    } else if (mime.contains('zip') ||
        mime.contains('rar') ||
        mime.contains('7z') ||
        mime.contains('tar') ||
        mime.contains('gz')) {
      icon = Icons.folder_zip_rounded;
      color = const Color(0xFFF39C12);
    } else if (mime.contains('word') ||
        mime.contains('msword') ||
        mime.contains('document')) {
      icon = Icons.description_rounded;
      color = const Color(0xFF2980B9);
    } else if (mime.contains('sheet') ||
        mime.contains('excel') ||
        mime.contains('spreadsheet')) {
      icon = Icons.table_chart_rounded;
      color = const Color(0xFF27AE60);
    } else if (mime.contains('presentation') ||
        mime.contains('powerpoint')) {
      icon = Icons.slideshow_rounded;
      color = const Color(0xFFE67E22);
    } else {
      icon = Icons.insert_drive_file_rounded;
      color = const Color(0xFF27AE60);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(icon, color: color, size: 50),
          ),
          const SizedBox(height: 18),
          Text(widget.file.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _badge(widget.file.readableSize),
              const SizedBox(width: 8),
              _badge(widget.file.mimeType.split('/').last.toUpperCase()),
            ],
          ),
          const SizedBox(height: 28),
          _buildStreamUrlCard(),
          const SizedBox(height: 16),
          _buildInfoCard(
              'The stream URL is served live from this device. '
              'Copy it and open in any app that supports HTTP streaming.'),
        ],
      ),
    );
  }

  // ── Error view ─────────────────────────────────────────────────────────────

  Widget _buildErrorView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const SizedBox(height: 40),
          const Icon(Icons.error_outline_rounded,
              color: Color(0xFFCF6679), size: 60),
          const SizedBox(height: 16),
          const Text('Playback Error',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Text(_initError ?? 'Unknown error',
              style: const TextStyle(
                  color: Color(0xFF9090B0), fontSize: 13, height: 1.5),
              textAlign: TextAlign.center),
          const SizedBox(height: 20),
          _buildStreamUrlCard(),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF3A3A5A)),
                    foregroundColor: Colors.white),
                child: const Text('Go Back'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _retryVideo,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Stream URL card ────────────────────────────────────────────────────────

  Widget _buildStreamUrlCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.link_rounded, color: Color(0xFF2AABEE), size: 14),
              SizedBox(width: 6),
              Text('Stream URL',
                  style: TextStyle(
                    color: Color(0xFF2AABEE),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  )),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            widget.streamUrl,
            style: const TextStyle(
              color: Color(0xFF9090B0),
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.streamUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Stream URL copied!'),
                    backgroundColor: const Color(0xFF27AE60),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 15),
              label: const Text('Copy URL'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFF3A3A5A)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E35),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Color(0xFF9090B0), fontSize: 12)),
      );

  Widget _buildInfoCard(String text) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0F1020),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A2A40)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded,
                color: Color(0xFF2AABEE), size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                    color: Color(0xFF7070A0),
                    fontSize: 12,
                    height: 1.5,
                  )),
            ),
          ],
        ),
      );

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
