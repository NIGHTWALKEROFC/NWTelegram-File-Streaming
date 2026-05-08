// lib/screens/player_screen.dart
//
// FIXES vs previous version:
// ===========================
// 1. Audio now uses media_kit (libmpv) instead of just_audio.
//    just_audio could not get duration from the proxy stream for OGG/OPUS/FLAC
//    because it relies on HTTP Content-Length + its own demuxer for duration.
//    libmpv demuxes the stream directly and reports duration as soon as the
//    first few KB arrive — works for every format.
//
// 2. Race condition fixed: setActiveFile is called by files_screen BEFORE
//    Navigator.push, so by the time initState runs the proxy already has the
//    correct fileId. player.open() in addPostFrameCallback is safe.
//
// 3. Audio player state (position, duration, playing) comes from
//    player.stream.* just like the video path — single code path, no
//    separate AudioPlayer instance needed.
//
// 4. just_audio dependency is now unused in this file (kept in pubspec for
//    any future use but not imported here).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // Single Player + VideoController for both video and audio.
  // For audio we just don't show the Video widget.
  late final Player _player;
  late final VideoController _videoController;

  // UI state driven by player.stream.*
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  String? _initError;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();

    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024, // 8 MB buffer
        logLevel: MPVLogLevel.warn,
      ),
    );
    _videoController = VideoController(_player);

    // Listen to player streams for UI updates
    _subs.add(_player.stream.position.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
    _subs.add(_player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.error.listen((err) {
      if (err.isNotEmpty && mounted && _initError == null) {
        debugPrint('media_kit error: $err');
        setState(() => _initError = err);
      }
    }));

    // Open after first frame so the Video widget's Texture is registered
    // and the proxy server has had time to bind.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openMedia();
    });
  }

  void _openMedia() {
    _player.open(
      Media(
        widget.streamUrl,
        httpHeaders: const {
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      ),
    );
  }

  void _retryMedia() {
    if (!mounted) return;
    setState(() {
      _initError = null;
      _buffering = true;
    });
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _openMedia();
    });
  }

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
    _player.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Error screen (video only — audio/doc shows inline)
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

    if (widget.file.isAudio) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0F),
        appBar: _buildAppBar(),
        body: _buildAudioView(),
      );
    }

    // Non-playable document
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: _buildAppBar(),
      body: _buildDocumentView(),
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

  // ── Video ──────────────────────────────────────────────────────────────────

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
          const MaterialPlayOrPauseButton(iconSize: 48),
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

  // ── Audio ──────────────────────────────────────────────────────────────────
  //
  // Uses the same _player (libmpv) as video — supports every audio format
  // including OGG, OPUS, FLAC, AAC, MP3. Duration is read from the stream
  // by libmpv's demuxer, so it works even without Content-Length headers.

  Widget _buildAudioView() {
    final hasDuration = _duration.inSeconds > 0;
    final progress = hasDuration
        ? (_position.inMilliseconds / _duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        children: [
          const SizedBox(height: 32),
          // Album art / icon
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
            child: _buffering && !_playing
                ? const Center(
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    ),
                  )
                : const Icon(Icons.music_note_rounded,
                    color: Colors.white, size: 72),
          ),
          const SizedBox(height: 32),
          Text(
            widget.file.name,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            widget.file.mimeType.toUpperCase().replaceAll('AUDIO/', ''),
            style:
                const TextStyle(color: Color(0xFF9090B0), fontSize: 13),
          ),

          // Error inline
          if (_initError != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1020),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFCF6679)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Color(0xFFCF6679), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _initError!,
                      style: const TextStyle(
                          color: Color(0xFF9090B0), fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _retryMedia,
                    child: const Text('Retry',
                        style: TextStyle(color: Color(0xFF2AABEE))),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 28),

          // Seek bar
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
              onChanged: hasDuration
                  ? (v) => _player.seek(Duration(
                      milliseconds:
                          (v * _duration.inMilliseconds).round()))
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(_position),
                    style: const TextStyle(
                        color: Color(0xFF9090B0), fontSize: 12)),
                Text(hasDuration ? _fmt(_duration) : '--:--',
                    style: const TextStyle(
                        color: Color(0xFF9090B0), fontSize: 12)),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 30,
                icon: const Icon(Icons.replay_10_rounded,
                    color: Colors.white),
                onPressed: () {
                  final p = _position - const Duration(seconds: 10);
                  _player.seek(
                      p < Duration.zero ? Duration.zero : p);
                },
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () =>
                    _playing ? _player.pause() : _player.play(),
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
                    _playing
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
                onPressed: hasDuration
                    ? () {
                        final p =
                            _position + const Duration(seconds: 30);
                        _player.seek(
                            p > _duration ? _duration : p);
                      }
                    : null,
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
          Text(
            widget.file.name,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
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
            'This is a document file. Copy the stream URL and open it '
            'in any app that supports HTTP streaming or downloading.',
          ),
        ],
      ),
    );
  }

  // ── Error view (video only) ────────────────────────────────────────────────

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
          Text(
            _initError ?? 'Unknown error',
            style: const TextStyle(
                color: Color(0xFF9090B0), fontSize: 13, height: 1.5),
            textAlign: TextAlign.center,
          ),
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
                onPressed: _retryMedia,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared widgets ─────────────────────────────────────────────────────────

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

  Widget _badge(String text) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
              child: Text(
                text,
                style: const TextStyle(
                  color: Color(0xFF7070A0),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
