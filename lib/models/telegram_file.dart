// lib/models/telegram_file.dart

enum TelegramFileType { video, audio, document, image, unknown }

class VideoQuality {
  final String label;
  final int width;
  final int height;
  final int fileId;
  final int fileSize;
  final String remoteId;

  const VideoQuality({
    required this.label,
    required this.width,
    required this.height,
    required this.fileId,
    required this.fileSize,
    required this.remoteId,
  });

  String get readableSize {
    if (fileSize <= 0) return 'Unknown';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class TelegramFile {
  final TelegramFileType type;
  final String name;
  final String mimeType;
  final int duration;
  final int width;
  final int height;
  final int fileId;
  final int fileSize;
  final String remoteFileId;
  final String? thumbnail;
  final List<VideoQuality> qualities;

  const TelegramFile({
    required this.type,
    required this.name,
    required this.mimeType,
    this.duration = 0,
    this.width = 0,
    this.height = 0,
    required this.fileId,
    required this.fileSize,
    required this.remoteFileId,
    this.thumbnail,
    required this.qualities,
  });

  // ── Type detection ─────────────────────────────────────────────────────────
  // Telegram sends .mkv, .mp4, .avi etc. as messageDocument.
  // We detect the real type from mime + extension so the right player is used.

  bool get isVideo {
    if (type == TelegramFileType.video) return true;
    if (type == TelegramFileType.document) return mimeIsVideo(mimeType);
    return false;
  }

  bool get isAudio {
    if (type == TelegramFileType.audio) return true;
    if (type == TelegramFileType.document) return mimeIsAudio(mimeType);
    return false;
  }

  bool get isDocument => !isVideo && !isAudio;

  bool get hasMultipleQualities => qualities.length > 1;

  VideoQuality? get bestQuality =>
      qualities.isNotEmpty ? qualities.first : null;

  VideoQuality? qualityByLabel(String label) {
    try {
      return qualities.firstWhere((q) => q.label == label);
    } catch (_) {
      return null;
    }
  }

  String get readableSize {
    if (fileSize <= 0) return 'Unknown size';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get readableDuration {
    if (duration <= 0) return '';
    final h = duration ~/ 3600;
    final m = (duration % 3600) ~/ 60;
    final s = duration % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── Public static mime/extension helpers ───────────────────────────────────
  // Public (no underscore) so telegram_service.dart can call them during
  // parsing, before a TelegramFile instance is created.

  static bool mimeIsVideo(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('video/')) return true;
    const videoTypes = {
      'application/x-matroska', // .mkv
      'application/mkv',
      'application/mp4',
      'application/x-mp4',
      'application/mpeg',
      'application/x-mpeg',
    };
    return videoTypes.contains(m);
  }

  static bool mimeIsAudio(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('audio/')) return true;
    const audioTypes = {
      'application/ogg',
      'application/x-ogg',
      'application/flac',
      'application/x-flac',
    };
    return audioTypes.contains(m);
  }

  /// Detect type from file extension when mime type is ambiguous
  static TelegramFileType typeFromExtension(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    const videoExts = {
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'mpeg', 'mpg',
      'm4v', 'ts', '3gp', 'ogv', 'rm', 'rmvb', 'divx', 'xvid',
    };
    const audioExts = {
      'mp3', 'aac', 'ogg', 'flac', 'wav', 'm4a', 'opus', 'wma', 'aiff',
      'alac', 'ape', 'mka',
    };
    if (videoExts.contains(ext)) return TelegramFileType.video;
    if (audioExts.contains(ext)) return TelegramFileType.audio;
    return TelegramFileType.document;
  }
}
