// lib/screens/player_screen.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

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

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    if (widget.file.isDocument) {
      setState(() => _isInitializing = false);
    } else {
      Future.delayed(const Duration(milliseconds: 300), _initPlayer);
    }
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
          _initError = e.toString();
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
      overlay: qualityLabel.isNotEmpty
          ? Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 12, right: 12),
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
            )
          : null,
    );
  }

  void _onVideoError() {
    final value = _videoController?.value;
    if (value == null) return;
    if (value.hasError && _initError == null && mounted) {
      setState(
          () => _initError = value.errorDescription ?? 'Unknown video error');
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
    _subs.add(_audioPlayer!.playingStream.listen((v) {
      if (mounted) setState(() => _isAudioPlaying = v);
    }));
    await _audioPlayer!.setUrl(widget.streamUrl);
    await _audioPlayer!.play();
  }

  void _disposeControllers() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _videoController?.removeListener(_onVideoError);
    _chewieController?.dispose();
    _chewieController = null;
    _videoController?.dispose();
    _videoController = null;
    _audioPlayer?.dispose();
    _audioPlayer = null;
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _disposeControllers();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hideAppBar =
        widget.file.isVideo && !_isInitializing && _initError == null;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
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

  // ── Video ──────────────────────────────────────────────────────────────────

  Widget _buildVideoView() {
    final ctrl = _chewieController;
    final val = _videoController?.value;
    if (ctrl == null || val == null || !val.isInitialized || val.aspectRatio <= 0) {
      return const Center(
          child: CircularProgressIndicator(
              color: Color(0xFF2AABEE), strokeWidth: 2));
    }
    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: val.aspectRatio,
            child: Chewie(controller: ctrl),
          ),
        ),
        // Back button
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
        // External player button
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: GestureDetector(
              onTap: () => _showExternalPlayerSheet(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new_rounded,
                        color: Color(0xFF2AABEE), size: 14),
                    SizedBox(width: 4),
                    Text('External',
                        style:
                            TextStyle(color: Colors.white, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Audio ──────────────────────────────────────────────────────────────────

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
                  milliseconds: (v * _audioDuration.inMilliseconds).round())),
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
          const SizedBox(height: 12),
          _buildExternalButtons(),
        ],
      ),
    );
  }

  // ── Document ───────────────────────────────────────────────────────────────

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
    } else if (mime.contains('presentation') || mime.contains('powerpoint')) {
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
          const SizedBox(height: 14),
          _buildExternalButtons(),
          const SizedBox(height: 16),
          _buildInfoCard(
              'The stream URL is served live from this device. '
              'Open in a browser, VLC, MX Player, or any app that '
              'supports HTTP streaming.'),
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
          _buildInfoCard(
              'The built-in player failed. Try opening in VLC or MX Player '
              'using the buttons below — they handle more formats.'),
          const SizedBox(height: 16),
          _buildStreamUrlCard(),
          const SizedBox(height: 12),
          _buildExternalButtons(),
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

  // ── External player buttons ────────────────────────────────────────────────

  Widget _buildExternalButtons() {
    return Column(
      children: [
        // Open in browser
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_browser_rounded, size: 17),
            label: const Text('Open in Browser',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2AABEE),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // VLC
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _openInApp('vlc'),
            icon: const Icon(Icons.play_circle_outline_rounded, size: 17),
            label: const Text('Open in VLC',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFE67E22),
              side: const BorderSide(color: Color(0xFFE67E22)),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // MX Player
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _openInApp('mx'),
            icon: const Icon(Icons.smart_display_rounded, size: 17),
            label: const Text('Open in MX Player',
                style: TextStyle(fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF9B59B6),
              side: const BorderSide(color: Color(0xFF9B59B6)),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }

  // ── Open in external app ───────────────────────────────────────────────────
  //
  // Both VLC and MX Player respond to android.intent.action.VIEW with an HTTP
  // URI and the correct MIME type. url_launcher handles this via
  // LaunchMode.externalApplication which fires the Android intent chooser.
  //
  // VLC also supports its own vlc:// scheme as a fallback.

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(widget.streamUrl);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _showError('Could not open browser. Copy the URL manually.');
      }
    } catch (e) {
      _showError('Error: $e');
    }
  }

  Future<void> _openInApp(String app) async {
    final mime = widget.file.mimeType.isNotEmpty
        ? widget.file.mimeType
        : 'video/*';

    if (app == 'vlc') {
      // Try VLC intent first, fall back to generic VIEW
      final vlcUri = Uri.parse(
          'vlc://${widget.streamUrl.replaceFirst('http://', '')}');
      final httpUri = Uri.parse(widget.streamUrl);

      bool launched = false;
      try {
        launched = await launchUrl(vlcUri,
            mode: LaunchMode.externalApplication);
      } catch (_) {}

      if (!launched) {
        try {
          launched = await launchUrl(httpUri,
              mode: LaunchMode.externalApplication);
        } catch (_) {}
      }

      if (!launched && mounted) {
        _showError('VLC not found. Install VLC and try again.');
      }
      return;
    }

    if (app == 'mx') {
      // MX Player Pro uses com.mxtech.videoplayer.pro
      // MX Player Free uses com.mxtech.videoplayer.ad
      // Both respond to ACTION_VIEW with an HTTP URI
      final uri = Uri.parse(widget.streamUrl);
      try {
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          _showError('MX Player not found. Install MX Player and try again.');
        }
      } catch (e) {
        _showError('Error: $e');
      }
      return;
    }
  }

  void _showExternalPlayerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141420),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A5A),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _buildStreamUrlCard(),
            const SizedBox(height: 14),
            _buildExternalButtons(),
          ],
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFFCF6679),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
