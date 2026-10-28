import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../models/book_item.dart';
import '../theme.dart';

class FolderListView extends StatelessWidget {
  final TextEditingController pathController;
  final List<BookItem> books;
  final bool isScanning;
  final bool isBusy;
  final VoidCallback onBrowseFolder;
  final VoidCallback onScanFolder; // 필수 버튼: '폴더 목록 불러오기'
  final VoidCallback onUseDefaultPath;
  final ValueChanged<bool?> onSelectAll;
  final void Function(BookItem item, bool selected) onItemToggle;
  final void Function(BookItem item) onOpenDirectory;
  final void Function(BookItem item)? onSingleUpload;

  const FolderListView({
    super.key,
    required this.pathController,
    required this.books,
    required this.isScanning,
    required this.isBusy,
    required this.onBrowseFolder,
    required this.onScanFolder,
    required this.onUseDefaultPath,
    required this.onSelectAll,
    required this.onItemToggle,
    required this.onOpenDirectory,
    this.onSingleUpload,
  });

  @override
  Widget build(BuildContext context) {
    final selectedCount = books.where((b) => b.isSelected).length;
    final allSelected = books.isNotEmpty && selectedCount == books.length;
    final someSelected = selectedCount > 0 && selectedCount < books.length;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 폴더 경로 선택 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.folder_copy_rounded, color: AppTheme.accentColor, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      '도서 라이브러리 폴더',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: isScanning ? null : onUseDefaultPath,
                      icon: const Icon(Icons.refresh, size: 14, color: AppTheme.textMuted),
                      label: const Text(
                        '기본 경로 재설정',
                        style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pathController,
                        decoration: InputDecoration(
                          hintText: '도서가 다운로드된 디렉터리 경로를 입력하거나 찾아보기를 누르세요',
                          prefixIcon: const Icon(Icons.snippet_folder_outlined, color: AppTheme.textMuted, size: 20),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        style: const TextStyle(fontSize: 12),
                        onSubmitted: (_) => onScanFolder(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: isScanning || isBusy ? null : onBrowseFolder,
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('찾아보기'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 필수 구현 버튼: '폴더 목록 불러오기'
                    ElevatedButton.icon(
                      onPressed: (isScanning || isBusy || pathController.text.trim().isEmpty)
                          ? null
                          : onScanFolder,
                      icon: isScanning
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.sync_rounded, size: 16),
                      label: const Text(
                        '폴더 목록 불러오기',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppTheme.cardBorder),

          // 2. 도서 목록 상태 툴바 (전체 선택 체크박스, 카운트 요약)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: AppTheme.surfaceBg.withOpacity(0.5),
            child: Row(
              children: [
                Checkbox(
                  value: someSelected ? null : allSelected,
                  tristate: true,
                  onChanged: books.isEmpty ? null : onSelectAll,
                ),
                Text(
                  '전체 선택 ($selectedCount / ${books.length}권 선택됨)',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                if (books.isNotEmpty)
                  Text(
                    '총 ${_formatTotalSize(books)}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppTheme.cardBorder),

          // 3. 도서 목록 바디
          Expanded(
            child: books.isEmpty
                ? _buildEmptyState()
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: books.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.cardBorder),
                    itemBuilder: (context, index) {
                      final item = books[index];
                      return _buildBookRow(context, item);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.library_books_outlined, size: 48, color: AppTheme.textMuted),
          SizedBox(height: 12),
          Text(
            '불러온 도서 폴더 목록이 없습니다',
            style: TextStyle(fontSize: 15, color: AppTheme.textMuted, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 6),
          Text(
            '위 경로를 확인하고 [폴더 목록 불러오기] 버튼을 클릭하세요.',
            style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildBookRow(BuildContext context, BookItem item) {
    return InkWell(
      onTap: isBusy ? null : () => onItemToggle(item, !item.isSelected),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Checkbox(
                  value: item.isSelected,
                  onChanged: isBusy ? null : (val) => onItemToggle(item, val ?? false),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: item.isDirectory
                        ? AppTheme.accentColor.withOpacity(0.12)
                        : AppTheme.secondaryColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    item.isDirectory ? Icons.folder_zip_rounded : Icons.menu_book_rounded,
                    color: item.isDirectory ? AppTheme.accentColor : AppTheme.secondaryColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              item.title,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (item.hasDatFile) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppTheme.accentColor.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'DAT 키 포함',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.accentColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            item.isDirectory
                                ? '폴더 (${item.fileCount}개 파일, ${item.formattedSize})'
                                : '단일 파일 (${item.formattedSize})',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              item.path,
                              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (item.status == BookStatus.success &&
                          (item.savedFileName != null || item.downloadedFilePath != null)) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.successColor.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: AppTheme.successColor.withOpacity(0.35),
                                  width: 0.8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.file_download_done_rounded,
                                    size: 13,
                                    color: AppTheme.successColor,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '저장 완료: ${item.savedFileName ?? p.basename(item.downloadedFilePath!)}',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.successColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _buildStatusChip(item),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '폴더 위치 열기',
                  icon: const Icon(Icons.folder_open, size: 18, color: AppTheme.textMuted),
                  onPressed: () => onOpenDirectory(item),
                ),
              ],
            ),
            if (item.status == BookStatus.zipping ||
                item.status == BookStatus.uploading ||
                item.status == BookStatus.decrypting ||
                item.status == BookStatus.downloading) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: item.progress > 0 ? item.progress : null,
                backgroundColor: AppTheme.surfaceBg,
                color: (item.status == BookStatus.downloading ||
                        item.status == BookStatus.decrypting)
                    ? AppTheme.accentColor
                    : AppTheme.secondaryColor,
                minHeight: 4,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(BookItem item) {
    Color bg;
    Color fg;
    String label;
    IconData? icon;

    switch (item.status) {
      case BookStatus.idle:
        bg = AppTheme.cardBorder;
        fg = AppTheme.textMuted;
        label = '대기';
        break;
      case BookStatus.zipping:
        bg = AppTheme.warningColor.withOpacity(0.15);
        fg = AppTheme.warningColor;
        label = item.statusMessage.isNotEmpty ? item.statusMessage : '압축 중';
        icon = Icons.archive;
        break;
      case BookStatus.uploading:
        bg = AppTheme.secondaryColor.withOpacity(0.15);
        fg = AppTheme.secondaryColor;
        label = item.statusMessage.isNotEmpty ? item.statusMessage : '업로드 중';
        icon = Icons.cloud_upload;
        break;
      case BookStatus.decrypting:
        bg = AppTheme.accentColor.withOpacity(0.15);
        fg = AppTheme.accentColor;
        label = item.statusMessage.isNotEmpty ? item.statusMessage : '복호화 중';
        icon = Icons.key_rounded;
        break;
      case BookStatus.downloading:
        bg = AppTheme.accentColor.withOpacity(0.15);
        fg = AppTheme.accentColor;
        label = item.statusMessage.isNotEmpty ? item.statusMessage : '다운로드 중';
        icon = Icons.cloud_download;
        break;
      case BookStatus.success:
        bg = AppTheme.successColor.withOpacity(0.15);
        fg = AppTheme.successColor;
        label = '완료';
        icon = Icons.check_circle_rounded;
        break;
      case BookStatus.failed:
        bg = AppTheme.errorColor.withOpacity(0.15);
        fg = AppTheme.errorColor;
        label = '실패';
        icon = Icons.error_outline_rounded;
        break;
    }

    Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );

    if (item.status == BookStatus.failed && item.errorMessage != null) {
      return Tooltip(
        message: item.errorMessage!,
        child: chip,
      );
    }
    return chip;
  }

  String _formatTotalSize(List<BookItem> books) {
    final total = books.fold<int>(0, (sum, b) => sum + b.sizeBytes);
    if (total < 1024 * 1024) {
      return '${(total / 1024).toStringAsFixed(1)} KB';
    } else if (total < 1024 * 1024 * 1024) {
      return '${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(total / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}
