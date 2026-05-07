// lib/screens/player_screen.dart
//
// REWRITE: Replaced video_player + chewie with media_kit (libmpv/FFmpeg).
//
// WHY:
//   video_player uses Android's ExoPlayer with its default codec pipeline.
//   ExoPlayer does NOT support:
//     • HEVC / H.265 (software decode)
//     • Many MKV/TS container variations
//     • AV1 on older devices
//     • Certain AAC/AC3/DTS audio tracks
//   This caused the PlatformException(VideoError, ExoPlaybackException: Source error).
//
//   media_kit bundles its own FFmpeg (same library used by VLC and MPV) via
//   media_kit_libs_android_video, so it decodes everything natively in-process
//   without relying on the OS codec stack at all.
//
// CHANGES:
//   • VideoPlayerController + ChewieController → media_kit Player + VideoController
//   • Custom controls built with media_kit's StreamBuilders (play/pause, seek,
//     speed, fullscreen, volume, brightness)
//   • VLC / MX Player buttons removed — no longer needed
//   • Audio playback unchanged (just_audio is fine for audio-only files)

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
  // ── media_kit ──────────────────────────────────────────────────────────────
  Player? _player;
  VideoController? _videoController;

  // ── just_audio (audio-only files) ─────────────────────────────────────────
  AudioPlayer? _audioPlayer;
  bool _isAudioPlaying = false;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── UI state ───────────────────────────────────────────────────────────────
  bool _isInitializing = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    if (widget.file.isDocument) {
      setState(() => _isInitializing = false);
    } else {
      Future.delayed(const Duration(milliseconds: 300), _initPlayer);
    }
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> _initPlayer() async {
    if (!mounted) return;
    setState(() {
      _isInitializing = true;
      _initError = null;
    });
    _disposeControllers();

    try {
      if (widget.file.isVideo) {
        await _initVideoPlayer();
      } else if (widget.file.isAudio) {
        await _initAudioPlayer();
      }
    } catch (e) {
      debugPrint('PlayerScreen init error: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = e.toString();
        });
      }
      return;
    }

    if (mounted) setState(() => _isInitializing = false);
  }

  Future<void> _initVideoPlayer() async {
    // Create a media_kit Player.
    // configuration options: cache size, network timeout, etc.
    _player = Player(
      configuration: const PlayerConfiguration(
        // Buffer 8 MB ahead — good balance between startup latency and
        // continuous playback over the local proxy.
        bufferSize: 8 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );

    _videoController = VideoController(_player!);

    // Listen for player errors
    _subs.add(_player!.stream.error.listen((err) {
      debugPrint('media_kit error: $err');
      if (mounted && _initError == null) {
        setState(() => _initError = err);
      }
    }));

    // Open the stream URL — media_kit passes this straight to FFmpeg/libmpv
    // which handles HTTP range requests and all demuxing itself.
    await _player!.open(
      Media(
        widget.streamUrl,
        httpHeaders: const {
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      ),
    );
  }

  Future<void> _initAudioPlayer() async {
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
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  void _disposeControllers() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    // VideoController does NOT have a dispose() method in media_kit.
    // Only Player needs to be disposed — it cleans up the controller too.
    _videoController = null;
    _player?.dispose();
    _player = null;
    _audioPlayer?.dispose();
    _audioPlayer = null;
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _disposeControllers();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hideAppBar =
        widget.file.isVideo && !_isInitializing && _initError == null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: hideAppBar ? null : _buildAppBar(),
      body: _buildBody(),
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

  Widget _buildBody() {
    if (_isInitializing) return _buildLoading();
    if (_initError != null) return _buildErrorView();
    if (widget.file.isVideo) return _buildVideoView();
    if (widget.file.isAudio) return _buildAudioView();
    return _buildDocumentView();
  }

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

  // ── Video view (media_kit) ─────────────────────────────────────────────────
  //
  // MaterialVideoControlsThemeData gives us a polished, customised control
  // surface built on top of media_kit_video's built-in controls. This
  // includes: play/pause, seek bar, volume, brightness, speed, fullscreen.

  Widget _buildVideoView() {
    final ctrl = _videoController;
    if (ctrl == null) {
      return const Center(
          child: CircularProgressIndicator(
              color: Color(0xFF2AABEE), strokeWidth: 2));
    }

    final qualityLabel = widget.selectedQuality?.label ??
        (widget.file.height > 0 ? '${widget.file.height}p' : '');

    return MaterialVideoControlsTheme(
      normal: MaterialVideoControlsThemeData(
        // Control bar colours
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
          // Back button — plain widget, works on all platforms
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
          // Quality badge
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
          const MaterialSpeedButton(),
          const MaterialFullscreenButton(),
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
        controller: ctrl,
        // Fill the screen; media_kit letterboxes automatically
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
              widget.file.mimeType
                  .toUpperCase()
                  .replaceAll('AUDIO/', ''),
              style:
                  const TextStyle(color: Color(0xFF9090B0), fontSize: 13)),
          const SizedBox(height: 28),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF9B59B6),
              inactiveTrackColor: const Color(0xFF3A3A5A),
              thumbColor: const Color(0xFF9B59B6),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
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
              'Copy it and open it in any app that supports HTTP streaming.'),
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
                onPressed: _initPlayer,
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
            style:
                const TextStyle(color: Color(0xFF9090B0), fontSize: 12)),
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
