enum BookStatus {
  idle,
  zipping,
  uploading,
  decrypting,
  downloading,
  success,
  failed,
}

class BookItem {
  final String id;
  final String name;
  final String path;
  final bool isDirectory;
  final int fileCount;
  final int sizeBytes;
  final String? datFilePath;
  String? detectedTitle;
  String? savedFileName;

  bool isSelected;
  BookStatus status;
  double progress;
  String statusMessage;
  String? downloadedFilePath;
  String? errorMessage;

  BookItem({
    required this.id,
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.fileCount,
    required this.sizeBytes,
    this.datFilePath,
    this.detectedTitle,
    this.savedFileName,
    this.isSelected = true,
    this.status = BookStatus.idle,
    this.progress = 0.0,
    this.statusMessage = '대기',
    this.downloadedFilePath,
    this.errorMessage,
  });

  /// 표시할 제목 (복호화 결과/OPF에서 감지된 도서명 우선, 없으면 폴더/파일명)
  String get title => detectedTitle ?? name;
  String get displayName => title;

  /// DAT 키 파일 동봉 여부
  bool get hasDatFile => datFilePath != null && datFilePath!.isNotEmpty;

  /// 파일 크기 사람이 읽기 쉬운 포맷
  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void resetStatus() {
    status = BookStatus.idle;
    progress = 0.0;
    statusMessage = '대기';
    errorMessage = null;
    downloadedFilePath = null;
    savedFileName = null;
  }
}
