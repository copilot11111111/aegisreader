import 'package:flutter/material.dart';
import '../theme.dart';

class ActionBarWidget extends StatelessWidget {
  final TextEditingController outputDirController;
  final int totalCount;
  final int selectedCount;
  final bool isBusy;
  final int currentProcessingIndex;
  final int totalProcessingCount;
  final VoidCallback onBrowseOutputDir;
  final VoidCallback onUploadSelected; // 필수 기능: '선택 업로드하기'
  final VoidCallback onUploadAll;      // 필수 기능: '전체 업로드하기'
  final VoidCallback onCancel;

  const ActionBarWidget({
    super.key,
    required this.outputDirController,
    required this.totalCount,
    required this.selectedCount,
    required this.isBusy,
    required this.currentProcessingIndex,
    required this.totalProcessingCount,
    required this.onBrowseOutputDir,
    required this.onUploadSelected,
    required this.onUploadAll,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 저장 디렉터리 경로 선택
          Row(
            children: [
              const Icon(Icons.download_done_rounded, color: AppTheme.accentColor, size: 18),
              const SizedBox(width: 8),
              const Text(
                '복호화 결과 저장 폴더:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: outputDirController,
                  decoration: const InputDecoration(
                    hintText: '복호화 완료 파일이 저장될 폴더 경로',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: isBusy ? null : onBrowseOutputDir,
                icon: const Icon(Icons.folder, size: 14),
                label: const Text('폴더 변경', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  minimumSize: Size.zero,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // 2. 일괄 업로드 진행 상태 (작업 중일 때 표시)
          if (isBusy) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppTheme.surfaceBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentColor),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '일괄 변환 처리 중: $currentProcessingIndex / $totalProcessingCount권 완료',
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary, fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.stop_circle_outlined, size: 16, color: AppTheme.errorColor),
                    label: const Text('중단하기', style: TextStyle(fontSize: 12, color: AppTheme.errorColor)),
                  ),
                ],
              ),
            ),
          ],

          // 3. 메인 업로드 실행 액션 버튼 그룹 (불러온 목록을 전체/선택 업로드하기)
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!isBusy && selectedCount > 0) ? onUploadSelected : null,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: Text(
                    selectedCount > 0
                        ? '선택 항목 업로드 ($selectedCount권)'
                        : '선택 항목 업로드',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.secondaryColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppTheme.cardBorder,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!isBusy && totalCount > 0) ? onUploadAll : null,
                  icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                  label: Text(
                    totalCount > 0
                        ? '불러온 목록 전체 업로드 ($totalCount권)'
                        : '불러온 목록 전체 업로드',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppTheme.cardBorder,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
