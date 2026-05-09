// lib/screens/player_screen.dart
//
// FIXES IN THIS VERSION
// ─────────────────────
// 1. Seek → download restarts from exact byte offset
//    _onPosition detects a forward jump > 10 s and calls
//    streamSvc.prepareFile with the calculated byte offset so TDLib
//    starts fetching from that position immediately.
//
// 2. _switchQuality also uses prepareFile with offset=0 for the new file.
//
// 3. Back / dispose always calls cancelAndDeleteFile → cache cleared.
//
// 4. Controls overlay uses MediaQuery.padding so buttons are never hidden
//    behind the Android gesture-nav bar.
//
// 5. Speed picker, fullscreen toggle, slow-connection indicator all wired.

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
  final TelegramFile  file;
  final VideoQuality? initialQuality;
  final String        streamUrl;

  const PlayerScreen({
    super.key,
    required this.file,
    required this.initialQuality,
    required this.streamUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  late final Player          _player;
  late final VideoController _videoController;
  late final TelegramService _telegramSvc;
  late final StreamService   _streamSvc;

  // ── Player state ────────────────────────────────────────────────────────
  Duration _position  = Duration.zero;
  Duration _duration  = Duration.zero;
  bool     _playing   = false;
  bool     _buffering = true;
  double   _rate      = 1.0;
  String?  _error;

  // ── UI state ─────────────────────────────────────────────────────────────
  bool _showControls = true;
  bool _isFullscreen = false;
  bool _slowNetwork  = false;
  Timer? _hideTimer;
  Timer? _slowNetTimer;

  // ── Seek-restart tracking ───────────────────────────────────────────────
  Duration _lastKnownPosition = Duration.zero;

  VideoQuality? _currentQuality;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _telegramSvc    = context.read<TelegramService>();
    _streamSvc      = context.read<StreamService>();
    _currentQuality = widget.initialQuality;

    if (widget.file.isVideo) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    _videoController = VideoController(_player);

    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.duration.listen(
        (d) { if (mounted) setState(() => _duration = d); }));
    _subs.add(_player.stream.playing.listen(
        (v) { if (mounted) setState(() => _playing = v); }));
    _subs.add(_player.stream.buffering.listen(_onBuffering));
    _subs.add(_player.stream.rate.listen(
        (r) { if (mounted) setState(() => _rate = r); }));
    _subs.add(_player.stream.error.listen((err) {
      if (err.isNotEmpty && mounted && _error == null) {
        debugPrint('media_kit error: $err');
        setState(() => _error = err);
      }
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openMedia();
    });

    _resetHideTimer();
  }

  // ── Open media ─────────────────────────────────────────────────────────
  void _openMedia() {
    if (!mounted) return;
    setState(() { _error = null; _buffering = true; });
    _player.open(Media(
      widget.streamUrl,
      httpHeaders: const {
        'Accept': '*/*',
        'Connection': 'keep-alive',
      },
    ));
  }

  // ── Position: detect forward seek > 10 s → restart download ────────────
  void _onPosition(Duration pos) {
    if (!mounted) return;
    setState(() => _position = pos);

    final jump = pos - _lastKnownPosition;
    if (jump.inSeconds > 10 && _duration.inSeconds > 0) {
      final totalBytes = _currentQuality?.fileSize ?? widget.file.fileSize;
      final fileId     = _currentQuality?.fileId   ?? widget.file.fileId;
      if (totalBytes > 0 && fileId > 0) {
        final ratio      = pos.inMilliseconds / _duration.inMilliseconds;
        final byteOffset = (ratio * totalBytes).toInt();
        debugPrint('PlayerScreen: seek-restart fileId=$fileId offset=$byteOffset');
        // Fire-and-forget: prepareFile cancels old download and restarts
        // TDLib from byteOffset so data is available at the new position.
        _streamSvc.prepareFile(
          fileId:   fileId,
          fileSize: totalBytes,
          mimeType: widget.file.mimeType,
          offset:   byteOffset,
        );
      }
    }
    _lastKnownPosition = pos;
  }

  // ── Buffering → slow-network detection ─────────────────────────────────
  void _onBuffering(bool buffering) {
    if (!mounted) return;
    setState(() => _buffering = buffering);

    if (buffering) {
      _slowNetTimer?.cancel();
      _slowNetTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _buffering) setState(() => _slowNetwork = true);
      });
    } else {
      _slowNetTimer?.cancel();
      if (mounted) setState(() => _slowNetwork = false);
    }
  }

  // ── Controls auto-hide ─────────────────────────────────────────────────
  void _resetHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _resetHideTimer();
  }

  // ── Quality switch ─────────────────────────────────────────────────────
  Future<void> _switchQuality(VideoQuality q) async {
    if (!mounted) return;
    await _player.pause();
    setState(() {
      _currentQuality = q;
      _buffering      = true;
      _error          = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 12),
        Text('Switching to ${q.label}...'),
      ]),
      backgroundColor: const Color(0xFF1A1A2E),
      duration: const Duration(seconds: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));

    final ok = await _streamSvc.prepareFile(
      fileId:   q.fileId,
      fileSize: q.fileSize,
      mimeType: widget.file.mimeType,
      offset:   0,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (!ok) {
      setState(() => _error = 'Failed to start ${q.label}');
      return;
    }
    _openMedia();
  }

  // ── Back → clear cache ──────────────────────────────────────────────────
  Future<void> _handleBack() async {
    _player.pause();
    await _telegramSvc.cancelAndDeleteFile();
    if (mounted) Navigator.of(context).pop();
  }

  // ── Dispose ────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _hideTimer?.cancel();
    _slowNetTimer?.cancel();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final s in _subs) s.cancel();
    _player.dispose();
    // Fire-and-forget cache cleanup (also called in _handleBack,
    // but this covers the case where the OS kills the widget directly)
    _telegramSvc.cancelAndDeleteFile();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (widget.file.isVideo) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (!didPop) await _handleBack();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _buildVideoView(),
        ),
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
          onPressed: _handleBack,
        ),
        title: Text(widget.file.name,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            overflow: TextOverflow.ellipsis),
      );

  // ── VIDEO VIEW ─────────────────────────────────────────────────────────
  Widget _buildVideoView() {
    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: _videoController,
            fit: BoxFit.contain,
            controls: NoVideoControls,
          ),
          if (_buffering) _buildBufferingOverlay(),
          if (_error != null) _buildErrorOverlay(),
          if (_showControls && _error == null) _buildControlsOverlay(),
        ],
      ),
    );
  }

  Widget _buildBufferingOverlay() {
    return Container(
      color: Colors.black38,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 44, height: 44,
              child: CircularProgressIndicator(
                  color: Color(0xFF2AABEE), strokeWidth: 3),
            ),
            const SizedBox(height: 14),
            Text(
              _slowNetwork
                  ? '⚡ Slow connection — buffering...'
                  : 'Buffering...',
              style: TextStyle(
                color: _slowNetwork
                    ? const Color(0xFFFFC107)
                    : const Color(0xFFCCCCCC),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Color(0xFFCF6679), size: 52),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFF9090B0), fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _openMedia,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Controls overlay ────────────────────────────────────────────────────
  // MediaQuery.of(context).padding pushes every button above the OS
  // gesture-nav bar and below the status bar on all Android devices.
  Widget _buildControlsOverlay() {
    final pad       = MediaQuery.of(context).padding;
    final qualities = widget.file.qualities;
    final hasMultiQ = qualities.length > 1;
    final curLabel  = _currentQuality?.label ?? '';

    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end:   Alignment.bottomCenter,
            colors: [
              Color(0xCC000000),
              Colors.transparent,
              Colors.transparent,
              Color(0xCC000000),
            ],
            stops: [0.0, 0.25, 0.75, 1.0],
          ),
        ),
        child: Stack(
          children: [
            // ── TOP BAR ─────────────────────────────────────────
            Positioned(
              top: pad.top + 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  _overlayBtn(
                      icon: Icons.arrow_back_rounded,
                      onTap: _handleBack),
                  const Spacer(),
                  if (hasMultiQ)
                    GestureDetector(
                      onTap: () => _showQualityPicker(qualities),
                      child: _qualityBadge(curLabel),
                    ),
                ],
              ),
            ),

            // ── CENTER CONTROLS ──────────────────────────────────
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _overlayBtn(
                      icon: Icons.replay_10_rounded,
                      size: 40,
                      onTap: _skipBack),
                  const SizedBox(width: 32),
                  GestureDetector(
                    onTap: () {
                      _playing ? _player.pause() : _player.play();
                      _resetHideTimer();
                    },
                    child: Container(
                      width: 68, height: 68,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withOpacity(0.4),
                            width: 2),
                      ),
                      child: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white, size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(width: 32),
                  _overlayBtn(
                      icon: Icons.forward_30_rounded,
                      size: 40,
                      onTap: _skipForward),
                ],
              ),
            ),

            // ── BOTTOM BAR ──────────────────────────────────────
            // pad.bottom = height of gesture nav bar / home indicator.
            // Adding 8 px gap keeps every button comfortably above it.
            Positioned(
              bottom: pad.bottom + 8,
              left:   12,
              right:  12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSeekBar(),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        '${_fmt(_position)} / '
                        '${_duration.inSeconds > 0 ? _fmt(_duration) : "--:--"}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500),
                      ),
                      const Spacer(),
                      // Speed
                      GestureDetector(
                        onTap: () {
                          _resetHideTimer();
                          _showSpeedPicker();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.speed_rounded,
                                  color: Colors.white, size: 16),
                              const SizedBox(width: 4),
                              Text(
                                _rate == 1.0 ? '1×' : '${_rate}×',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Fullscreen
                      _overlayBtn(
                        icon: _isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        onTap: _toggleFullscreen,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Seek bar ────────────────────────────────────────────────────────────
  Widget _buildSeekBar() {
    final progress = (_duration.inMilliseconds > 0)
        ? (_position.inMilliseconds / _duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor:   const Color(0xFF2AABEE),
        inactiveTrackColor: Colors.white24,
        thumbColor:         const Color(0xFF2AABEE),
        overlayColor:       const Color(0xFF2AABEE).withOpacity(0.2),
        trackHeight:        3,
        thumbShape:
            const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      child: Slider(
        value: progress,
        onChangeStart: (_) => _hideTimer?.cancel(),
        onChangeEnd:   (_) => _resetHideTimer(),
        onChanged: _duration.inMilliseconds > 0
            ? (v) {
                final newPos = Duration(
                    milliseconds:
                        (v * _duration.inMilliseconds).round());
                _player.seek(newPos);
              }
            : null,
      ),
    );
  }

  // ── Fullscreen ──────────────────────────────────────────────────────────
  Future<void> _toggleFullscreen() async {
    _resetHideTimer();
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky);
      if (mounted) setState(() => _isFullscreen = false);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky);
      if (mounted) setState(() => _isFullscreen = true);
    }
  }

  void _skipBack() {
    _resetHideTimer();
    final p = _position - const Duration(seconds: 10);
    _player.seek(p < Duration.zero ? Duration.zero : p);
  }

  void _skipForward() {
    _resetHideTimer();
    if (_duration == Duration.zero) return;
    final p = _position + const Duration(seconds: 30);
    _player.seek(p > _duration ? _duration : p);
  }

  Widget _overlayBtn({
    required IconData     icon,
    required VoidCallback onTap,
    double size = 24,
  }) =>
      GestureDetector(
        onTap: () { onTap(); _resetHideTimer(); },
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      );

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

  // ── Quality picker ──────────────────────────────────────────────────────
  void _showQualityPicker(List<VideoQuality> qualities) {
    _hideTimer?.cancel();
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
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: const Color(0xFF3A3A5A),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text('Video Quality',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            ...qualities.asMap().entries.map((e) {
              final isLowest   = e.key == qualities.length - 1;
              final q          = e.value;
              final isSelected = _currentQuality?.fileId == q.fileId;
              return _qualityTile(
                label:      isLowest ? '${q.label} · Auto (Fastest)' : q.label,
                sublabel:   q.readableSize,
                isSelected: isSelected,
                icon: isLowest
                    ? Icons.auto_awesome_rounded
                    : Icons.hd_rounded,
                onTap: () {
                  Navigator.pop(context);
                  if (!isSelected) _switchQuality(q);
                  _resetHideTimer();
                },
              );
            }),
          ],
        ),
      ),
    ).whenComplete(_resetHideTimer);
  }

  Widget _qualityTile({
    required String       label,
    required String       sublabel,
    required bool         isSelected,
    required IconData     icon,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF2AABEE).withOpacity(0.15)
                : const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF2AABEE)
                  : const Color(0xFF2A2A40),
            ),
          ),
          child: Row(children: [
            Icon(icon,
                color: isSelected
                    ? const Color(0xFF2AABEE)
                    : const Color(0xFF7070A0),
                size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFFD0D0E0),
                        fontSize: 14,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      )),
                  Text(sublabel,
                      style: const TextStyle(
                          color: Color(0xFF7070A0), fontSize: 11)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle_rounded,
                  color: Color(0xFF2AABEE), size: 18),
          ]),
        ),
      );

  // ── Speed picker ────────────────────────────────────────────────────────
  void _showSpeedPicker() {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    _hideTimer?.cancel();
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
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: const Color(0xFF3A3A5A),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text('Playback Speed',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: speeds.map((s) {
                final selected = (s - _rate).abs() < 0.01;
                return GestureDetector(
                  onTap: () {
                    _player.setRate(s);
                    Navigator.pop(context);
                    _resetHideTimer();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF2AABEE)
                          : const Color(0xFF1E1E35),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF2AABEE)
                            : const Color(0xFF3A3A5A),
                      ),
                    ),
                    child: Text(
                      s == 1.0 ? 'Normal' : '${s}×',
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
            ),
          ],
        ),
      ),
    ).whenComplete(_resetHideTimer);
  }

  // ── Audio player ────────────────────────────────────────────────────────
  Widget _buildAudioView() {
    final hasDuration = _duration.inSeconds > 0;
    final progress    = hasDuration
        ? (_position.inMilliseconds / _duration.inMilliseconds)
            .clamp(0.0, 1.0)
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
              begin: Alignment.topLeft,
              end:   Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF9B59B6).withOpacity(0.4),
                  blurRadius: 40, spreadRadius: 4)
            ],
          ),
          child: _buffering && !_playing
              ? const Center(
                  child: SizedBox(
                      width: 40, height: 40,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5)))
              : const Icon(Icons.music_note_rounded,
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
              color: Color(0xFF9090B0), fontSize: 13),
        ),
        if (_slowNetwork && _buffering) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFC107).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: const Color(0xFFFFC107).withOpacity(0.4)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_tethering_error_rounded,
                    color: Color(0xFFFFC107), size: 16),
                SizedBox(width: 8),
                Text('Slow connection — buffering...',
                    style: TextStyle(
                        color: Color(0xFFFFC107), fontSize: 12)),
              ],
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          _errorBanner(),
        ],
        const SizedBox(height: 28),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor:   const Color(0xFF9B59B6),
            inactiveTrackColor: const Color(0xFF3A3A5A),
            thumbColor:         const Color(0xFF9B59B6),
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
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((s) {
            final sel = (s - _rate).abs() < 0.01;
            return GestureDetector(
              onTap: () => _player.setRate(s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: sel
                      ? const Color(0xFF9B59B6)
                      : const Color(0xFF1E1E35),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(s == 1.0 ? '1×' : '${s}×',
                    style: TextStyle(
                        color: sel
                            ? Colors.white
                            : const Color(0xFF7070A0),
                        fontSize: 12,
                        fontWeight: sel
                            ? FontWeight.w700
                            : FontWeight.normal)),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 30,
              icon: const Icon(Icons.replay_10_rounded,
                  color: Colors.white),
              onPressed: _skipBack,
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () =>
                  _playing ? _player.pause() : _player.play(),
              child: Container(
                width: 68, height: 68,
                decoration: BoxDecoration(
                  color: const Color(0xFF9B59B6),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFF9B59B6).withOpacity(0.4),
                        blurRadius: 20, spreadRadius: 4)
                  ],
                ),
                child: Icon(
                  _playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white, size: 38,
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              iconSize: 30,
              icon: const Icon(Icons.forward_30_rounded,
                  color: Colors.white),
              onPressed: _skipForward,
            ),
          ],
        ),
        const SizedBox(height: 28),
        _buildStreamUrlCard(),
      ]),
    );
  }

  // ── Document view ───────────────────────────────────────────────────────
  Widget _buildDocumentView() {
    final mime = widget.file.mimeType.toLowerCase();
    final IconData icon;
    final Color    color;
    if (mime.contains('pdf')) {
      icon = Icons.picture_as_pdf_rounded;
      color = const Color(0xFFE74C3C);
    } else if (mime.contains('zip') || mime.contains('rar') ||
               mime.contains('7z') || mime.contains('tar')) {
      icon = Icons.folder_zip_rounded;
      color = const Color(0xFFF39C12);
    } else if (mime.contains('word') || mime.contains('document')) {
      icon = Icons.description_rounded;
      color = const Color(0xFF2980B9);
    } else if (mime.contains('sheet') || mime.contains('excel')) {
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
            width: 96, height: 96,
            decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(22)),
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
              'Copy the stream URL and open it in any app that supports '
              'HTTP streaming or direct download.'),
        ],
      ),
    );
  }

  // ── Shared widgets ──────────────────────────────────────────────────────
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
          Expanded(
              child: Text(_error!,
                  style: const TextStyle(
                      color: Color(0xFF9090B0), fontSize: 12))),
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
              Icon(Icons.link_rounded,
                  color: Color(0xFF2AABEE), size: 14),
              SizedBox(width: 6),
              Text('Stream URL',
                  style: TextStyle(
                      color: Color(0xFF2AABEE),
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            SelectableText(widget.streamUrl,
                style: const TextStyle(
                    color: Color(0xFF9090B0),
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.4)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: widget.streamUrl));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: const Text('Copied!'),
                    backgroundColor: const Color(0xFF27AE60),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    duration: const Duration(seconds: 2),
                  ));
                },
                icon:  const Icon(Icons.copy_rounded, size: 15),
                label: const Text('Copy URL'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF3A3A5A)),
                  padding:
                      const EdgeInsets.symmetric(vertical: 10),
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
            style: const TextStyle(
                color: Color(0xFF9090B0), fontSize: 12)));

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
                        height: 1.5))),
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
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
}
