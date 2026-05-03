import 'dart:typed_data';

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
  final int duration; // seconds
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

  bool get isVideo => type == TelegramFileType.video;
  bool get isAudio => type == TelegramFileType.audio;
  bool get isDocument => type == TelegramFileType.document;

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
}
