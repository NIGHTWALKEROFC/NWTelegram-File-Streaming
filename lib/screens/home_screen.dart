import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/telegram_service.dart';
import '../services/stream_service.dart';
import '../models/telegram_file.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _linkController = TextEditingController();
  final FocusNode _linkFocusNode = FocusNode();

  bool _isResolving = false;
  TelegramFile? _resolvedFile;
  String? _errorText;
  VideoQuality? _selectedQuality;

  late AnimationController _animController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeIn);
    _animController.forward();

    // Start streaming proxy
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final streamService = context.read<StreamService>();
      final telegramService = context.read<TelegramService>();
      if (!streamService.isRunning) {
        await streamService.startServer(telegramService);
      }
    });
  }

  Future<void> _resolveLink() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      setState(() => _errorText = 'Please paste a Telegram link');
      return;
    }

    if (!link.contains('t.me') && !link.contains('telegram.me')) {
      setState(() => _errorText = 'Please enter a valid Telegram link (t.me/...)');
      return;
    }

    setState(() {
      _isResolving = true;
      _errorText = null;
      _resolvedFile = null;
    });

    _linkFocusNode.unfocus();

    final telegramService = context.read<TelegramService>();
    final file = await telegramService.resolveLink(link);

    if (!mounted) return;

    if (file == null) {
      setState(() {
        _isResolving = false;
        _errorText = telegramService.errorMessage.isNotEmpty
            ? telegramService.errorMessage
            : 'Could not resolve this link. Make sure you have access to this message.';
      });
      return;
    }

    setState(() {
      _isResolving = false;
      _resolvedFile = file;
      _selectedQuality =
          file.qualities.isNotEmpty ? file.qualities.first : null;
    });
  }

  void _startStreaming() {
    final file = _resolvedFile;
    if (file == null) return;

    final streamService = context.read<StreamService>();

    // Determine which fileId to use based on quality selection
    final int fileId;
    final int fileSize;

    if (_selectedQuality != null) {
      fileId = _selectedQuality!.fileId;
      fileSize = _selectedQuality!.fileSize;
    } else {
      fileId = file.fileId;
      fileSize = file.fileSize;
    }

    streamService.setActiveFile(
      fileId: fileId,
      fileSize: fileSize,
      mimeType: file.mimeType,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          file: file,
          selectedQuality: _selectedQuality,
          streamUrl: streamService.streamUrl,
        ),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _linkController.text = data!.text!;
      setState(() {
        _resolvedFile = null;
        _errorText = null;
      });
    }
  }

  void _clearAll() {
    setState(() {
      _linkController.clear();
      _resolvedFile = null;
      _errorText = null;
      _selectedQuality = null;
    });
  }

  @override
  void dispose() {
    _linkController.dispose();
    _linkFocusNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: _buildAppBar(),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: SlideTransition(
          position: _slideAnim,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 28),
                _buildLinkInput(),
                const SizedBox(height: 16),
                if (_errorText != null) _buildErrorCard(),
                if (_isResolving) _buildResolvingCard(),
                if (_resolvedFile != null) ...[
                  const SizedBox(height: 8),
                  _buildFileCard(_resolvedFile!),
                ],
                const SizedBox(height: 32),
                _buildTipsCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
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
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 8),
          const Text('TG Streamer'),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.logout_rounded),
          tooltip: 'Logout',
          onPressed: _confirmLogout,
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Stream a File',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Paste any Telegram file link to stream instantly',
          style: TextStyle(
            color: Color(0xFF7070A0),
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildLinkInput() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _linkFocusNode.hasFocus
              ? const Color(0xFF2AABEE)
              : const Color(0xFF2A2A40),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2AABEE).withOpacity(0.05),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          // Input field
          TextField(
            controller: _linkController,
            focusNode: _linkFocusNode,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              letterSpacing: 0.3,
            ),
            decoration: InputDecoration(
              hintText: 'https://t.me/channel/message_id',
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              prefixIcon: const Icon(
                Icons.link_rounded,
                color: Color(0xFF2AABEE),
                size: 20,
              ),
              suffixIcon: _linkController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Color(0xFF606080), size: 18),
                      onPressed: _clearAll,
                    )
                  : null,
            ),
            onChanged: (v) {
              setState(() {
                _resolvedFile = null;
                _errorText = null;
              });
            },
            onSubmitted: (_) => _resolveLink(),
          ),

          // Action row
          Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0xFF2A2A40), width: 1),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // Paste button
                _buildActionChip(
                  icon: Icons.content_paste_rounded,
                  label: 'Paste',
                  onTap: _pasteFromClipboard,
                ),
                const SizedBox(width: 8),
                const Spacer(),
                // Resolve button
                ElevatedButton.icon(
                  onPressed: _isResolving ? null : _resolveLink,
                  icon: _isResolving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.search_rounded, size: 16),
                  label: Text(_isResolving ? 'Resolving...' : 'Resolve'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    minimumSize: Size.zero,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E35),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFF2AABEE)),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF2AABEE),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1020),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCF6679).withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFCF6679), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorText!,
              style: const TextStyle(
                color: Color(0xFFCF6679),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResolvingCard() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A40)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF2AABEE),
            ),
          ),
          const SizedBox(width: 14),
          const Text(
            'Fetching file info from Telegram...',
            style: TextStyle(color: Color(0xFF9090B0), fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildFileCard(TelegramFile file) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2AABEE).withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2AABEE).withOpacity(0.08),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File info header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildFileIcon(file),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _buildBadge(file.readableSize),
                          if (file.duration > 0) ...[
                            const SizedBox(width: 8),
                            _buildBadge(file.readableDuration, icon: Icons.access_time),
                          ],
                          if (file.isVideo && file.height > 0) ...[
                            const SizedBox(width: 8),
                            _buildBadge(
                              '${file.height}p',
                              icon: Icons.hd,
                              color: const Color(0xFF2AABEE),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Quality selector for videos with multiple qualities
          if (file.isVideo && file.hasMultipleQualities) ...[
            const Divider(color: Color(0xFF2A2A40), height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select Quality',
                    style: TextStyle(
                      color: Color(0xFF9090B0),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: file.qualities.map((q) {
                      final isSelected = _selectedQuality?.label == q.label;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedQuality = q),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF2AABEE)
                                : const Color(0xFF1E1E35),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF2AABEE)
                                  : const Color(0xFF2A2A40),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                q.label,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF9090B0),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                q.readableSize,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white70
                                      : const Color(0xFF606080),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],

          // Play button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startStreaming,
                icon: const Icon(Icons.play_circle_filled_rounded, size: 22),
                label: Text(
                  file.isVideo
                      ? 'Play${_selectedQuality != null ? ' (${_selectedQuality!.label})' : ''}'
                      : file.isAudio
                          ? 'Play Audio'
                          : 'Stream File',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF2AABEE),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                  shadowColor: const Color(0xFF2AABEE).withOpacity(0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileIcon(TelegramFile file) {
    IconData icon;
    Color color;
    switch (file.type) {
      case TelegramFileType.video:
        icon = Icons.movie_rounded;
        color = const Color(0xFF2AABEE);
        break;
      case TelegramFileType.audio:
        icon = Icons.audio_file_rounded;
        color = const Color(0xFF9B59B6);
        break;
      case TelegramFileType.document:
        icon = Icons.insert_drive_file_rounded;
        color = const Color(0xFF27AE60);
        break;
      default:
        icon = Icons.file_present_rounded;
        color = const Color(0xFFE67E22);
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 26),
    );
  }

  Widget _buildBadge(String text, {IconData? icon, Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E35),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color ?? const Color(0xFF7070A0)),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: color ?? const Color(0xFF9090B0),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTipsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1020),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lightbulb_outline, color: Color(0xFFF39C12), size: 16),
              SizedBox(width: 8),
              Text(
                'How to get a Telegram link',
                style: TextStyle(
                  color: Color(0xFFF39C12),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildTip('Open any Telegram message with a file'),
          _buildTip('Long-press the message → Copy Link'),
          _buildTip('Paste the link here and tap Resolve'),
          _buildTip('Supported: Videos, Audio, Documents, Voice notes'),
        ],
      ),
    );
  }

  Widget _buildTip(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  ',
              style: TextStyle(color: Color(0xFF5050A0), fontSize: 13)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF7070A0), fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141420),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
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
      await context.read<TelegramService>().logout();
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/');
      }
    }
  }
}
