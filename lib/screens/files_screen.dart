// lib/screens/files_screen.dart
//
// Shows all media files from all Telegram chats.
// Files appear progressively as each chat is scanned — no waiting for all
// chats to finish. Search bar filters by name in real time.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/telegram_file.dart';
import '../services/telegram_service.dart';
import '../services/stream_service.dart';
import 'player_screen.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen>
    with SingleTickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────
  List<TelegramFile> _allFiles = [];
  List<TelegramFile> _filtered = [];
  bool _isLoading = true;   // true while stream is still emitting
  bool _hasData = false;    // true once at least one file has arrived
  String? _loadError;

  StreamSubscription<List<TelegramFile>>? _fileSub;

  // Filter tab: 0=All, 1=Video, 2=Audio, 3=Docs
  int _tabIndex = 0;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  late final TabController _tabController;

  static const _tabs = ['All', 'Video', 'Audio', 'Docs'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      setState(() => _tabIndex = _tabController.index);
      _applyFilter();
    });
    _searchController.addListener(_applyFilter);

    WidgetsBinding.instance.addPostFrameCallback((_) => _startLoading());
  }

  @override
  void dispose() {
    _fileSub?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  void _startLoading() {
    _fileSub?.cancel();

    setState(() {
      _allFiles = [];
      _filtered = [];
      _isLoading = true;
      _hasData = false;
      _loadError = null;
    });

    final svc = context.read<TelegramService>();

    _fileSub = svc.streamAllMediaFiles(limitPerChat: 30).listen(
      (files) {
        if (!mounted) return;
        setState(() {
          _allFiles = files;
          _hasData = files.isNotEmpty;
        });
        _applyFilter();
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _loadError = e.toString();
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _isLoading = false);
      },
    );
  }

  void _applyFilter() {
    final query = _searchController.text.trim().toLowerCase();

    List<TelegramFile> result = List.of(_allFiles);

    switch (_tabIndex) {
      case 1:
        result = result.where((f) => f.isVideo).toList();
        break;
      case 2:
        result = result.where((f) => f.isAudio).toList();
        break;
      case 3:
        result = result.where((f) => f.isDocument).toList();
        break;
    }

    if (query.isNotEmpty) {
      result =
          result.where((f) => f.name.toLowerCase().contains(query)).toList();
    }

    setState(() => _filtered = result);
  }

  // ── Play a file ────────────────────────────────────────────────────────────

  Future<void> _playFile(TelegramFile file) async {
    final streamSvc = context.read<StreamService>();
    final telegramSvc = context.read<TelegramService>();

    if (!streamSvc.isRunning) {
      await streamSvc.startServer(telegramSvc);
    }

    final quality =
        file.isVideo && file.qualities.isNotEmpty ? file.qualities.first : null;

    streamSvc.setActiveFile(
      fileId: quality?.fileId ?? file.fileId,
      fileSize: quality?.fileSize ?? file.fileSize,
      mimeType: file.mimeType,
    );

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          file: file,
          selectedQuality: quality,
          streamUrl: streamSvc.streamUrl,
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildTabBar(),
          // Progress bar shown while still loading more files
          if (_isLoading)
            LinearProgressIndicator(
              backgroundColor: const Color(0xFF141420),
              color: const Color(0xFF2AABEE),
              minHeight: 2,
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0A0A0F),
      elevation: 0,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF2AABEE), Color(0xFF1A7FBF)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: 18),
          ),
          const SizedBox(width: 8),
          const Text(
            'TG Streamer',
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
      actions: [
        if (_allFiles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(
              child: Text(
                '${_allFiles.length} files',
                style: const TextStyle(
                    color: Color(0xFF5070A0), fontSize: 12),
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, color: Colors.white),
          tooltip: 'Refresh',
          onPressed: _isLoading ? null : _startLoading,
        ),
        IconButton(
          icon: const Icon(Icons.logout_rounded, color: Colors.white),
          tooltip: 'Logout',
          onPressed: _confirmLogout,
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0xFF141420),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _searchFocus.hasFocus
                ? const Color(0xFF2AABEE)
                : const Color(0xFF2A2A40),
            width: 1.5,
          ),
        ),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search files...',
            hintStyle:
                const TextStyle(color: Color(0xFF606080), fontSize: 14),
            prefixIcon: const Icon(Icons.search_rounded,
                color: Color(0xFF2AABEE), size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded,
                        color: Color(0xFF606080), size: 18),
                    onPressed: () {
                      _searchController.clear();
                      _searchFocus.unfocus();
                    },
                  )
                : null,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: const Color(0xFF2AABEE),
          borderRadius: BorderRadius.circular(8),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: const Color(0xFF7070A0),
        labelStyle:
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.all(3),
        tabs: _tabs.map((t) => Tab(text: t, height: 32)).toList(),
      ),
    );
  }

  Widget _buildBody() {
    // Still loading and nothing arrived yet — show spinner
    if (_isLoading && !_hasData) return _buildInitialLoading();

    // Stream errored before any data
    if (_loadError != null && !_hasData) return _buildError();

    // Stream finished with zero files
    if (!_isLoading && _allFiles.isEmpty) return _buildEmpty();

    // Have data (possibly still loading more) but search/tab filter is empty
    if (_filtered.isEmpty) return _buildNoResults();

    return _buildFileList();
  }

  Widget _buildInitialLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              color: Color(0xFF2AABEE),
              strokeWidth: 2.5,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Scanning your chats...',
            style: TextStyle(color: Color(0xFF9090B0), fontSize: 15),
          ),
          const SizedBox(height: 8),
          const Text(
            'Files will appear as they are found',
            style: TextStyle(color: Color(0xFF5050A0), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Color(0xFFCF6679), size: 56),
            const SizedBox(height: 16),
            const Text('Failed to load files',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFF9090B0), fontSize: 13)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startLoading,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFF141420),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.folder_open_rounded,
                color: Color(0xFF3A3A6A), size: 36),
          ),
          const SizedBox(height: 20),
          const Text('No media files found',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              'No videos, audio or documents were found in your chats.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Color(0xFF7070A0), fontSize: 13, height: 1.5),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _startLoading,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF2AABEE),
              side: const BorderSide(color: Color(0xFF2AABEE)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off_rounded,
              color: Color(0xFF3A3A6A), size: 56),
          const SizedBox(height: 16),
          const Text('No results found',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          const SizedBox(height: 6),
          Text(
            _searchController.text.isNotEmpty
                ? 'No files match "${_searchController.text}"'
                : 'No files in this category yet',
            style:
                const TextStyle(color: Color(0xFF7070A0), fontSize: 13),
          ),
          if (_isLoading) ...[
            const SizedBox(height: 16),
            const Text(
              'Still scanning — more files may appear shortly',
              style: TextStyle(color: Color(0xFF5050A0), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFileList() {
    return RefreshIndicator(
      color: const Color(0xFF2AABEE),
      backgroundColor: const Color(0xFF141420),
      onRefresh: () async => _startLoading(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _filtered.length,
        itemBuilder: (context, index) => _buildFileCard(_filtered[index]),
      ),
    );
  }

  Widget _buildFileCard(TelegramFile file) {
    final iconData = _iconFor(file);
    final iconColor = _colorFor(file);

    return GestureDetector(
      onTap: () => _playFile(file),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF141420),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF2A2A40)),
        ),
        child: Row(
          children: [
            _buildThumbOrIcon(file, iconData, iconColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _chip(file.readableSize),
                      if (file.duration > 0) ...[
                        const SizedBox(width: 6),
                        _chip(file.readableDuration,
                            icon: Icons.access_time_rounded),
                      ],
                      if (file.isVideo && file.height > 0) ...[
                        const SizedBox(width: 6),
                        _chip(
                          file.qualities.isNotEmpty
                              ? file.qualities.first.label
                              : '${file.height}p',
                          color: const Color(0xFF2AABEE),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF2AABEE).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                file.isVideo
                    ? Icons.play_arrow_rounded
                    : file.isAudio
                        ? Icons.play_circle_rounded
                        : Icons.open_in_new_rounded,
                color: const Color(0xFF2AABEE),
                size: 22,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbOrIcon(
      TelegramFile file, IconData iconData, Color iconColor) {
    if (file.thumbnail != null && file.thumbnail!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(file.thumbnail!),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _iconBox(iconData, iconColor),
        ),
      );
    }
    return _iconBox(iconData, iconColor);
  }

  Widget _iconBox(IconData icon, Color color) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 28),
    );
  }

  Widget _chip(String label, {IconData? icon, Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E35),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color ?? const Color(0xFF7070A0)),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: color ?? const Color(0xFF9090B0),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(TelegramFile file) {
    if (file.isVideo) return Icons.movie_rounded;
    if (file.isAudio) return Icons.audio_file_rounded;
    final mime = file.mimeType.toLowerCase();
    if (mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (mime.contains('zip') || mime.contains('rar') || mime.contains('7z')) {
      return Icons.folder_zip_rounded;
    }
    if (mime.contains('word') || mime.contains('document')) {
      return Icons.description_rounded;
    }
    if (mime.contains('sheet') || mime.contains('excel')) {
      return Icons.table_chart_rounded;
    }
    if (mime.contains('presentation') || mime.contains('powerpoint')) {
      return Icons.slideshow_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  Color _colorFor(TelegramFile file) {
    if (file.isVideo) return const Color(0xFF2AABEE);
    if (file.isAudio) return const Color(0xFF9B59B6);
    final mime = file.mimeType.toLowerCase();
    if (mime.contains('pdf')) return const Color(0xFFE74C3C);
    if (mime.contains('zip') || mime.contains('rar')) {
      return const Color(0xFFF39C12);
    }
    if (mime.contains('word') || mime.contains('document')) {
      return const Color(0xFF2980B9);
    }
    if (mime.contains('sheet') || mime.contains('excel')) {
      return const Color(0xFF27AE60);
    }
    return const Color(0xFF27AE60);
  }

  Future<void> _confirmLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141420),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title:
            const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(color: Color(0xFF9090B0)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout',
                style: TextStyle(color: Color(0xFFCF6679))),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      _fileSub?.cancel();
      await context.read<TelegramService>().logout();
      if (mounted) Navigator.of(context).pushReplacementNamed('/');
    }
  }
}
