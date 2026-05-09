// lib/screens/player_screen.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../models/telegram_file.dart';
import '../services/stream_service.dart';
import '../services/telegram_service.dart';

class PlayerScreen extends StatefulWidget {
  final TelegramFile   file;
  final VideoQuality?  initialQuality;
  final String         streamUrl;

  const PlayerScreen({
    super.key,
    required this.file,
    required this.initialQuality,
    required this.streamUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player          _player;
  late final VideoController _videoController;

  // Store service references here — safe to use after dispose()
  // because we grab them in initState before the widget is removed.
  late final TelegramService _telegramSvc;
  late final StreamService   _streamSvc;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool     _playing  = false;
  bool     _buffering = true;
  String?  _error;

  late VideoQuality? _currentQuality;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();

    // Grab service references NOW while context is valid
    _telegramSvc    = context.read<TelegramService>();
    _streamSvc      = context.read<StreamService>();
    _currentQuality = widget.initialQuality;

    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 16 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    _videoController = VideoController(_player);

    _subs.add(_player.stream.position.listen(
        (p) { if (mounted) setState(() => _position = p); }));
    _subs.add(_player.stream.duration.listen(
        (d) { if (mounted) setState(() => _duration = d); }));
    _subs.add(_player.stream.playing.listen(
        (v) { if (mounted) setState(() => _playing = v); }));
    _subs.add(_player.stream.buffering.listen(
        (v) { if (mounted) setState(() => _buffering = v); }));
    _subs.add(_player.stream.error.listen((err) {
      if (err.isNotEmpty && mounted && _error == null) {
        debugPrint('media_kit error: $err');
        setState(() => _error = err);
      }
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openMedia();
    });
  }

  void _openMedia() {
    if (!mounted) return;
    setState(() { _error = null; _buffering = true; });
    _player.open(Media(
      widget.streamUrl,
      httpHeaders: const {'Accept': '*/*', 'Connection': 'keep-alive'},
    ));
  }

  // ── Quality switch ─────────────────────────────────────────────────────────

  Future<void> _switchQuality(VideoQuality q) async {
    if (!mounted) return;
    await _player.pause();
    setState(() { _currentQuality = q; _buffering = true; _error = null; });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 12),
        Text('Switching to ${q.label}...'),
      ]),
      backgroundColor: const Color(0xFF1A1A2E),
      duration: const Duration(seconds: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));

    // Cancel old WITHOUT deleting (we'll start fresh immediately after)
    await _telegramSvc.cancelAndDeleteFile();

    final ok = await _streamSvc.prepareFile(
      fileId:   q.fileId,
      fileSize: q.fileSize,
      mimeType: widget.file.mimeType,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (!ok) {
      setState(() => _error = 'Failed to start download for ${q.label}');
      return;
    }
    _openMedia();
  }

  // ── Dispose — guaranteed delete even if context is gone ───────────────────

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final s in _subs) s.cancel();
    _player.dispose();
    // Use stored reference — never fails even after widget removal
    _telegramSvc.cancelAndDeleteFile();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
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
        title: Text(widget.file.name,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            overflow: TextOverflow.ellipsis),
      );

  // ── Video player ───────────────────────────────────────────────────────────
  //
  // Layout (portrait, bottom→top):
  //   [gesture nav bar — system, untouchable]
  //   [16px SafeArea padding]
  //   [position indicator | spacer | speed | fullscreen]  ← bottom bar
  //   [seek bar]
  //   [←10s | play/pause | +30s]                          ← primary bar
  //   ...
  //   [back | spacer | quality]                            ← top bar

  Widget _buildVideoView() {
    final qualities   = widget.file.qualities;
    final hasMultiQ   = qualities.length > 1;
    final currentLabel = _currentQuality?.label ?? '';

    return MaterialVideoControlsTheme(
      normal: MaterialVideoControlsThemeData(
        controlsHoverDuration: const Duration(seconds: 5),
        seekBarColor:          const Color(0xFF3A3A5A),
        seekBarPositionColor:  const Color(0xFF2AABEE),
        seekBarThumbColor:     const Color(0xFF2AABEE),
        seekBarMargin: const EdgeInsets.symmetric(horizontal: 16),

        // Extra bottom padding: SafeArea handles the gesture bar,
        // then we add 12px so the row is visually above it.
        bottomButtonBarMargin: EdgeInsets.fromLTRB(
          12, 0, 12,
          MediaQuery.of(context).padding.bottom + 12,
        ),
        topButtonBarMargin: const EdgeInsets.fromLTRB(4, 8, 4, 0),

        // ── PRIMARY — skip + play ──
        primaryButtonBar: [
          // Skip back 10s
          MaterialCustomButton(
            onPressed: () {
              final p = _position - const Duration(seconds: 10);
              _player.seek(p < Duration.zero ? Duration.zero : p);
            },
            icon: const Icon(Icons.replay_10_rounded,
                color: Colors.white, size: 32),
          ),
          const Spacer(),
          const MaterialPlayOrPauseButton(iconSize: 52),
          const Spacer(),
          // Skip forward 30s
          MaterialCustomButton(
            onPressed: () {
              if (_duration == Duration.zero) return;
              final p = _position + const Duration(seconds: 30);
              _player.seek(p > _duration ? _duration : p);
            },
            icon: const Icon(Icons.forward_30_rounded,
                color: Colors.white, size: 32),
          ),
        ],

        // ── TOP ── back + quality
        topButtonBar: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.arrow_back,
                  color: Colors.white, size: 20),
            ),
          ),
          const Spacer(),
          if (hasMultiQ)
            GestureDetector(
              onTap: () => _showQualityPicker(qualities),
              child: _qualityBadge(currentLabel),
            ),
        ],

        // ── BOTTOM — position | spacer | speed | fullscreen
        // All lifted above gesture bar by bottomButtonBarMargin
        bottomButtonBar: [
          const MaterialPositionIndicator(),
          const Spacer(),
          MaterialCustomButton(
            onPressed: _showSpeedPicker,
            icon: const Icon(Icons.speed_rounded,
                color: Colors.white, size: 22),
          ),
          const MaterialFullscreenButton(),
        ],

        volumeGesture:     true,
        brightnessGesture: true,
        seekGesture:       true,
      ),

      // ── FULLSCREEN — same layout ──────────────────────────────────────────
      fullscreen: MaterialVideoControlsThemeData(
        seekBarColor:         const Color(0xFF3A3A5A),
        seekBarPositionColor: const Color(0xFF2AABEE),
        seekBarThumbColor:    const Color(0xFF2AABEE),
        seekBarMargin: const EdgeInsets.symmetric(horizontal: 16),
        bottomButtonBarMargin: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        topButtonBarMargin: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        primaryButtonBar: [
          MaterialCustomButton(
            onPressed: () {
              final p = _position - const Duration(seconds: 10);
              _player.seek(p < Duration.zero ? Duration.zero : p);
            },
            icon: const Icon(Icons.replay_10_rounded,
                color: Colors.white, size: 32),
          ),
          const Spacer(),
          const MaterialPlayOrPauseButton(iconSize: 52),
          const Spacer(),
          MaterialCustomButton(
            onPressed: () {
              if (_duration == Duration.zero) return;
              final p = _position + const Duration(seconds: 30);
              _player.seek(p > _duration ? _duration : p);
            },
            icon: const Icon(Icons.forward_30_rounded,
                color: Colors.white, size: 32),
          ),
        ],
        topButtonBar: [
          const Spacer(),
          if (hasMultiQ)
            GestureDetector(
              onTap: () => _showQualityPicker(qualities),
              child: _qualityBadge(currentLabel),
            ),
        ],
        bottomButtonBar: [
          const MaterialPositionIndicator(),
          const Spacer(),
          MaterialCustomButton(
            onPressed: _showSpeedPicker,
            icon: const Icon(Icons.speed_rounded,
                color: Colors.white, size: 22),
          ),
          const MaterialFullscreenButton(),
        ],
        volumeGesture:     true,
        brightnessGesture: true,
        seekGesture:       true,
      ),

      child: Video(
        controller: _videoController,
        fit: BoxFit.contain,
        onEnterFullscreen: () async {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        },
        onExitFullscreen: () async {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        },
      ),
    );
  }

  Widget _qualityBadge(String label) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: const Color(0xFF2AABEE).withOpacity(0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hd_rounded,
                color: Color(0xFF2AABEE), size: 14),
            const SizedBox(width: 4),
            Text(label.isNotEmpty ? label : 'Auto',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            const Icon(Icons.arrow_drop_down,
                color: Colors.white, size: 14),
          ],
        ),
      );

  // ── Quality picker ─────────────────────────────────────────────────────────

  void _showQualityPicker(List<VideoQuality> qualities) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141420),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: const Color(0xFF3A3A5A),
                  borderRadius: BorderRadius.circular(2)),
            )),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text('Video Quality',
                  style: TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            ...qualities.asMap().entries.map((e) {
              final isLowest  = e.key == qualities.length - 1;
              final q         = e.value;
              final isSelected = _currentQuality?.fileId == q.fileId;
              return _qualityTile(
                label:      isLowest ? '${q.label} · Auto (Fastest)' : q.label,
                sublabel:   q.readableSize,
                isSelected: isSelected,
                icon: isLowest ? Icons.auto_awesome_rounded : Icons.hd_rounded,
                onTap: () {
                  Navigator.pop(context);
                  if (!isSelected) _switchQuality(q);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _qualityTile({
    required String      label,
    required String      sublabel,
    required bool        isSelected,
    required IconData    icon,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isSelected
            ? const Color(0xFF2AABEE).withOpacity(0.15)
            : const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? const Color(0xFF2AABEE) : const Color(0xFF2A2A40)),
      ),
      child: Row(children: [
        Icon(icon,
            color: isSelected ? const Color(0xFF2AABEE) : const Color(0xFF7070A0),
            size: 18),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(
              color: isSelected ? Colors.white : const Color(0xFFD0D0E0),
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            )),
            Text(sublabel, style: const TextStyle(
                color: Color(0xFF7070A0), fontSize: 11)),
          ],
        )),
        if (isSelected)
          const Icon(Icons.check_circle_rounded,
              color: Color(0xFF2AABEE), size: 18),
      ]),
    ),
  );

  // ── Speed picker ───────────────────────────────────────────────────────────

  void _showSpeedPicker() {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141420),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: const Color(0xFF3A3A5A),
                  borderRadius: BorderRadius.circular(2)),
            )),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text('Playback Speed',
                  style: TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            StreamBuilder<double>(
              stream: _player.stream.rate,
              initialData: 1.0,
              builder: (ctx, snap) {
                final current = snap.data ?? 1.0;
                return Wrap(
                  spacing: 8, runSpacing: 8,
                  children: speeds.map((s) {
                    final selected = (s - current).abs() < 0.01;
                    return GestureDetector(
                      onTap: () { _player.setRate(s); Navigator.pop(ctx); },
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
                            color: selected ? Colors.white : const Color(0xFF9090B0),
                            fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
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

  // ── Audio player ───────────────────────────────────────────────────────────

  Widget _buildAudioView() {
    final hasDuration = _duration.inSeconds > 0;
    final progress = hasDuration
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(children: [
        const SizedBox(height: 32),
        Container(
          width: 180, height: 180,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF9B59B6), Color(0xFF6C3483)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(
                color: const Color(0xFF9B59B6).withOpacity(0.4),
                blurRadius: 40, spreadRadius: 4)],
          ),
          child: _buffering && !_playing
              ? const Center(child: SizedBox(width: 40, height: 40,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5)))
              : const Icon(Icons.music_note_rounded,
                  color: Colors.white, size: 72),
        ),
        const SizedBox(height: 32),
        Text(widget.file.name,
            style: const TextStyle(color: Colors.white,
                fontSize: 17, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center, maxLines: 2,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        Text(widget.file.mimeType.toUpperCase().replaceAll('AUDIO/', ''),
            style: const TextStyle(color: Color(0xFF9090B0), fontSize: 13)),
        if (_error != null) ...[
          const SizedBox(height: 16),
          _errorBanner(),
        ],
        const SizedBox(height: 28),
        // Seek bar
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor:   const Color(0xFF9B59B6),
            inactiveTrackColor: const Color(0xFF3A3A5A),
            thumbColor:         const Color(0xFF9B59B6),
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: progress,
            onChanged: hasDuration
                ? (v) => _player.seek(Duration(
                    milliseconds: (v * _duration.inMilliseconds).round()))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(_position),
                  style: const TextStyle(color: Color(0xFF9090B0), fontSize: 12)),
              Text(hasDuration ? _fmt(_duration) : '--:--',
                  style: const TextStyle(color: Color(0xFF9090B0), fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Controls: ←10s | play | +30s
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 30,
              icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
              onPressed: () {
                final p = _position - const Duration(seconds: 10);
                _player.seek(p < Duration.zero ? Duration.zero : p);
              },
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => _playing ? _player.pause() : _player.play(),
              child: Container(
                width: 68, height: 68,
                decoration: BoxDecoration(
                  color: const Color(0xFF9B59B6),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(
                      color: const Color(0xFF9B59B6).withOpacity(0.4),
                      blurRadius: 20, spreadRadius: 4)],
                ),
                child: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white, size: 38,
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              iconSize: 30,
              icon: const Icon(Icons.forward_30_rounded, color: Colors.white),
              onPressed: hasDuration
                  ? () {
                      final p = _position + const Duration(seconds: 30);
                      _player.seek(p > _duration ? _duration : p);
                    }
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 28),
        _buildStreamUrlCard(),
      ]),
    );
  }

  // ── Document view ──────────────────────────────────────────────────────────

  Widget _buildDocumentView() {
    final mime = widget.file.mimeType.toLowerCase();
    IconData icon;
    Color    color;
    if (mime.contains('pdf')) {
      icon = Icons.picture_as_pdf_rounded;  color = const Color(0xFFE74C3C);
    } else if (mime.contains('zip') || mime.contains('rar') ||
               mime.contains('7z') || mime.contains('tar')) {
      icon = Icons.folder_zip_rounded;       color = const Color(0xFFF39C12);
    } else if (mime.contains('word') || mime.contains('document')) {
      icon = Icons.description_rounded;      color = const Color(0xFF2980B9);
    } else if (mime.contains('sheet') || mime.contains('excel')) {
      icon = Icons.table_chart_rounded;      color = const Color(0xFF27AE60);
    } else if (mime.contains('presentation') || mime.contains('powerpoint')) {
      icon = Icons.slideshow_rounded;        color = const Color(0xFFE67E22);
    } else {
      icon = Icons.insert_drive_file_rounded; color = const Color(0xFF27AE60);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          Container(
            width: 96, height: 96,
            decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(22)),
            child: Icon(icon, color: color, size: 50),
          ),
          const SizedBox(height: 18),
          Text(widget.file.name,
              style: const TextStyle(color: Colors.white,
                  fontSize: 17, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center, maxLines: 3,
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
          _buildInfoCard('Copy the stream URL and open it in any app that '
              'supports HTTP streaming or direct download.'),
        ],
      ),
    );
  }

  // ── Shared widgets ─────────────────────────────────────────────────────────

  Widget _errorBanner() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A1020),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFCF6679)),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline_rounded,
              color: Color(0xFFCF6679), size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(_error!,
              style: const TextStyle(color: Color(0xFF9090B0), fontSize: 12))),
          TextButton(
            onPressed: _openMedia,
            child: const Text('Retry',
                style: TextStyle(color: Color(0xFF2AABEE))),
          ),
        ]),
      );

  Widget _buildStreamUrlCard() => Container(
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
            const Row(children: [
              Icon(Icons.link_rounded, color: Color(0xFF2AABEE), size: 14),
              SizedBox(width: 6),
              Text('Stream URL', style: TextStyle(
                  color: Color(0xFF2AABEE), fontSize: 11,
                  fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            SelectableText(widget.streamUrl,
                style: const TextStyle(color: Color(0xFF9090B0),
                    fontSize: 12, fontFamily: 'monospace', height: 1.4)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.streamUrl));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: const Text('Copied!'),
                    backgroundColor: const Color(0xFF27AE60),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    duration: const Duration(seconds: 2),
                  ));
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

  Widget _badge(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: const Color(0xFF1E1E35),
            borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: const TextStyle(color: Color(0xFF9090B0), fontSize: 12)));

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
            Expanded(child: Text(text,
                style: const TextStyle(
                    color: Color(0xFF7070A0), fontSize: 12, height: 1.5))),
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
