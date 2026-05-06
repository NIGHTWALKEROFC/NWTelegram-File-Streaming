// lib/screens/player_screen.dart

import 'dart:async'; // required for StreamSubscription

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';

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
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  AudioPlayer? _audioPlayer;

  bool _isInitializing = true;
  String? _initError;

  bool _isAudioPlaying = false;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  // Store subscriptions to cancel them on dispose — prevents
  // "setState() called after dispose()" crashes.
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    // Small delay so the local proxy has time to bind before the player
    // makes its first HTTP request.
    Future.delayed(const Duration(milliseconds: 400), _initPlayer);
  }

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
          _initError = 'Failed to start player:\n$e';
        });
      }
      return;
    }

    if (mounted) setState(() => _isInitializing = false);
  }

  Future<void> _initVideoPlayer() async {
    final uri = Uri.parse(widget.streamUrl);

    _videoController = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: const {'Accept': '*/*', 'Connection': 'keep-alive'},
    );

    _videoController!.addListener(_onVideoError);
    await _videoController!.initialize();
    if (!mounted) return;

    final qualityLabel = widget.selectedQuality?.label ??
        (widget.file.height > 0 ? '${widget.file.height}p' : '');

    // IMPORTANT: Chewie's `overlay` must NOT be a Positioned widget.
    // Positioned only works directly inside a Stack. Passing it as
    // ChewieController.overlay crashes with:
    //   "Positioned widgets must be placed directly inside a Stack."
    // Use Align instead — it works anywhere.
    Widget? overlay;
    if (qualityLabel.isNotEmpty) {
      overlay = Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 12, right: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              qualityLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    _chewieController = ChewieController(
      videoPlayerController: _videoController!,
      autoPlay: true,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
      showControlsOnInitialize: true,
      allowPlaybackSpeedChanging: true,
      playbackSpeeds: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
      deviceOrientationsAfterFullScreen: [DeviceOrientation.portraitUp],
      deviceOrientationsOnEnterFullScreen: [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      materialProgressColors: ChewieProgressColors(
        playedColor: const Color(0xFF2AABEE),
        handleColor: const Color(0xFF2AABEE),
        backgroundColor: const Color(0xFF3A3A5A),
        bufferedColor: const Color(0xFF2AABEE).withOpacity(0.3),
      ),
      overlay: overlay,
    );
  }

  void _onVideoError() {
    final value = _videoController?.value;
    if (value == null) return;
    if (value.hasError && _initError == null && mounted) {
      setState(() => _initError = value.errorDescription ?? 'Video error');
    }
  }

  Future<void> _initAudioPlayer() async {
    _audioPlayer = AudioPlayer();

    _subs.add(_audioPlayer!.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _audioDuration = d);
    }));
    _subs.add(_audioPlayer!.positionStream.listen((p) {
      if (mounted) setState(() => _audioPosition = p);
    }));
    _subs.add(_audioPlayer!.playingStream.listen((playing) {
      if (mounted) setState(() => _isAudioPlaying = playing);
    }));

    await _audioPlayer!.setUrl(widget.streamUrl);
    await _audioPlayer!.play();
  }

  void _disposeControllers() {
    // Cancel subscriptions FIRST to stop callbacks on disposed objects.
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();

    _videoController?.removeListener(_onVideoError);

    // Dispose ChewieController BEFORE VideoPlayerController.
    // Reverse order causes "VideoPlayerController was disposed" inside Chewie.
    _chewieController?.dispose();
    _chewieController = null;
    _videoController?.dispose();
    _videoController = null;

    _audioPlayer?.dispose();
    _audioPlayer = null;
  }

  @override
  void dispose() {
    // Restore portrait in case the user exits from fullscreen landscape.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _disposeControllers();
    super.dispose();
  }

  // ──────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: widget.file.isVideo ? null : _buildAudioAppBar(),
      body: _buildBody(),
    );
  }

  AppBar _buildAudioAppBar() {
    return AppBar(
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
  }

  Widget _buildBody() {
    if (_isInitializing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
                color: Color(0xFF2AABEE), strokeWidth: 2),
            SizedBox(height: 20),
            Text(
              'Connecting to stream...',
              style: TextStyle(color: Color(0xFF9090B0), fontSize: 15),
            ),
          ],
        ),
      );
    }
    if (_initError != null) return _buildErrorView();
    if (widget.file.isVideo) return _buildVideoView();
    if (widget.file.isAudio) return _buildAudioView();
    return _buildDocumentView();
  }

  Widget _buildVideoView() {
    final ctrl = _chewieController;
    final val = _videoController?.value;
    if (ctrl == null || val == null || !val.isInitialized || val.aspectRatio <= 0) {
      return const Center(
        child: CircularProgressIndicator(
            color: Color(0xFF2AABEE), strokeWidth: 2),
      );
    }
    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: val.aspectRatio,
            child: Chewie(controller: ctrl),
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: SafeArea(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.arrow_back,
                    color: Colors.white, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAudioView() {
    final progress = _audioDuration.inMilliseconds > 0
        ? (_audioPosition.inMilliseconds / _audioDuration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    return Container(
      color: const Color(0xFF0A0A0F),
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 200,
            height: 200,
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
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(Icons.music_note_rounded,
                color: Colors.white, size: 80),
          ),
          const SizedBox(height: 40),
          Text(
            widget.file.name,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            widget.file.mimeType.toUpperCase().replaceAll('AUDIO/', ''),
            style: const TextStyle(color: Color(0xFF9090B0), fontSize: 13),
          ),
          const SizedBox(height: 32),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF9B59B6),
              inactiveTrackColor: const Color(0xFF3A3A5A),
              thumbColor: const Color(0xFF9B59B6),
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: progress,
              onChanged: (v) {
                final pos = Duration(
                    milliseconds:
                        (v * _audioDuration.inMilliseconds).round());
                _audioPlayer?.seek(pos);
              },
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
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 32,
                icon:
                    const Icon(Icons.replay_10_rounded, color: Colors.white),
                onPressed: () {
                  final p =
                      _audioPosition - const Duration(seconds: 10);
                  _audioPlayer?.seek(
                      p < Duration.zero ? Duration.zero : p);
                },
              ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () => _isAudioPlaying
                    ? _audioPlayer?.pause()
                    : _audioPlayer?.play(),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF9B59B6),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF9B59B6).withOpacity(0.4),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Icon(
                    _isAudioPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              IconButton(
                iconSize: 32,
                icon: const Icon(Icons.forward_30_rounded,
                    color: Colors.white),
                onPressed: () {
                  final p =
                      _audioPosition + const Duration(seconds: 30);
                  _audioPlayer?.seek(
                      p > _audioDuration ? _audioDuration : p);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFF27AE60).withOpacity(0.15),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.insert_drive_file_rounded,
                  color: Color(0xFF27AE60), size: 52),
            ),
            const SizedBox(height: 24),
            Text(
              widget.file.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(widget.file.readableSize,
                style: const TextStyle(
                    color: Color(0xFF9090B0), fontSize: 14)),
            const SizedBox(height: 32),
            const Text(
              'Document streaming is not supported in the player.\n'
              'The file can be opened in a browser via the stream URL.',
              style: TextStyle(
                  color: Color(0xFF7070A0), fontSize: 14, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Color(0xFFCF6679), size: 64),
            const SizedBox(height: 20),
            const Text('Playback Error',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(
              _initError ?? 'Unknown error',
              style: const TextStyle(
                  color: Color(0xFF9090B0), fontSize: 14, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF3A3A5A)),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Go Back'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _initPlayer,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

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
