import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/server_status.dart';
import '../theme.dart';

class ServerHeader extends StatelessWidget {
  final TextEditingController serverUrlController;
  final ServerStatus serverStatus;
  final bool isCheckingServer;
  final String selectedService;
  final bool isPremium;
  final bool removeWatermark;
  final VoidCallback onCheckServer;
  final ValueChanged<String> onServiceChanged;
  final ValueChanged<bool> onToggleWatermark;
  final VoidCallback? onOpenQuest;
  final VoidCallback? onOpenSpeedTest;
  final bool enableParallelTransfer;
  final ValueChanged<bool>? onToggleParallelTransfer;

  const ServerHeader({
    super.key,
    required this.serverUrlController,
    required this.serverStatus,
    required this.isCheckingServer,
    required this.selectedService,
    required this.isPremium,
    required this.removeWatermark,
    required this.onCheckServer,
    required this.onServiceChanged,
    required this.onToggleWatermark,
    this.onOpenQuest,
    this.onOpenSpeedTest,
    this.enableParallelTransfer = true,
    this.onToggleParallelTransfer,
  });

  @override
  Widget build(BuildContext context) {
    final isOnline = serverStatus.online;
    final isServiceActive = serverStatus.isServiceActive(selectedService);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AegisReaderTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AegisReaderTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 헤더 브랜드 및 API URL 입력줄
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AegisReaderTheme.primary, AegisReaderTheme.accent],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.shield_outlined, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'aegisreader',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: AegisReaderTheme.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text(
                    'https://aegisreader.com/',
                    style: TextStyle(fontSize: 10, color: AegisReaderTheme.textMuted),
                  ),
                ],
              ),
              const Spacer(),
              // aegisreader API 엔드포인트 URL (우측 고정)
              SizedBox(
                width: 280,
                height: 36,
                child: TextField(
                  controller: serverUrlController,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.cloud_sync_rounded, size: 16, color: AegisReaderTheme.textMuted),
                    hintText: 'https://aegisreader.com/api/',
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  ),
                  onSubmitted: (_) => onCheckServer(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: isCheckingServer ? null : onCheckServer,
                icon: isCheckingServer
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AegisReaderTheme.accentColor),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                tooltip: '서버 연결 상태 확인',
                style: IconButton.styleFrom(
                  backgroundColor: AegisReaderTheme.surfaceBg,
                  padding: const EdgeInsets.all(8),
                  minimumSize: Size.zero,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 10),
              // 온라인/오프라인 상태 뱃지
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: isOnline
                      ? AegisReaderTheme.successColor.withOpacity(0.15)
                      : AegisReaderTheme.errorColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isOnline
                        ? AegisReaderTheme.successColor.withOpacity(0.4)
                        : AegisReaderTheme.errorColor.withOpacity(0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isOnline ? AegisReaderTheme.successColor : AegisReaderTheme.errorColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isOnline ? '온라인' : '오프라인 (연결 대기)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isOnline ? AegisReaderTheme.successColor : AegisReaderTheme.errorColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),
          const Divider(color: AegisReaderTheme.cardBorder, height: 1),
          const SizedBox(height: 10),

          // 2. 서비스 선택 탭 및 옵션
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '대상 서비스:',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: AegisReaderTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _buildServiceTab('service1', '리디 (RIDI)', serverStatus.service1Active),
                  const SizedBox(width: 8),
                  _buildServiceTab(
                    'service2',
                    '예스24 (Yes24)',
                    serverStatus.service2Active,
                    enabled: !Platform.isMacOS,
                    disabledReason: '미지원',
                  ),
                  const SizedBox(width: 8),
                  _buildServiceTab('service3', '알라딘 (Aladin)', serverStatus.service3Active),
                  if (onOpenQuest != null) ...[
                    const SizedBox(width: 8),
                    _buildQuestButton(),
                  ],
                  if (onOpenSpeedTest != null) ...[
                    const SizedBox(width: 8),
                    _buildSpeedTestButton(),
                  ],
                  if (onToggleParallelTransfer != null) ...[
                    const SizedBox(width: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: enableParallelTransfer,
                            activeColor: AegisReaderTheme.accentColor,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            onChanged: (val) => onToggleParallelTransfer!(val ?? true),
                          ),
                        ),
                        const SizedBox(width: 5),
                        GestureDetector(
                          onTap: () => onToggleParallelTransfer!(!enableParallelTransfer),
                          child: Tooltip(
                            message: '체크 시: 파일을 청크 단위로 분할하여 다중 스트림으로 동시 업로드/다운로드합니다.\n체크 해제 시: 파일을 분할하지 않고 전체 파일을 단 1개의 단일 요청으로 업로드/다운로드합니다.',
                            child: Text(
                              '분할 전송',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: enableParallelTransfer ? FontWeight.bold : FontWeight.normal,
                                color: enableParallelTransfer ? AegisReaderTheme.accentColor : AegisReaderTheme.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              if (selectedService == 'service1' && isPremium)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: removeWatermark,
                      activeColor: AegisReaderTheme.accentColor,
                      onChanged: (val) => onToggleWatermark(val ?? false),
                    ),
                    GestureDetector(
                      onTap: () => onToggleWatermark(!removeWatermark),
                      child: const Text(
                        '워터마크 제거 [실험] (프리미엄 전용)',
                        style: TextStyle(fontSize: 12, color: AegisReaderTheme.textPrimary),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          if (!isServiceActive && isOnline) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AegisReaderTheme.warningColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AegisReaderTheme.warningColor.withOpacity(0.3)),
              ),
              child: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, size: 15, color: AegisReaderTheme.warningColor),
                  SizedBox(width: 6),
                  Text(
                    '선택된 서비스가 현재 점검 중일 수 있습니다. 변환 요청이 실패하면 잠시 후 다시 시도하세요.',
                    style: TextStyle(fontSize: 11, color: AegisReaderTheme.warningColor),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildServiceTab(
    String serviceId,
    String label,
    bool active, {
    bool enabled = true,
    String? disabledReason,
  }) {
    final isSelected = selectedService == serviceId;

    final child = Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AegisReaderTheme.accentColor.withOpacity(0.2)
              : AegisReaderTheme.surfaceBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AegisReaderTheme.accentColor : AegisReaderTheme.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : AegisReaderTheme.textMuted,
              ),
            ),
            if (!enabled && disabledReason != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  disabledReason,
                  style: const TextStyle(
                    fontSize: 9,
                    color: AegisReaderTheme.textMuted,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ] else if (!active && serverStatus.online) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AegisReaderTheme.warningColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '점검',
                  style: TextStyle(
                    fontSize: 9,
                    color: AegisReaderTheme.warningColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (!enabled) {
      return Tooltip(
        message: 'macOS에서는 지원되지 않는 서비스입니다.',
        child: child,
      );
    }

    return InkWell(
      onTap: () => onServiceChanged(serviceId),
      borderRadius: BorderRadius.circular(8),
      child: child,
    );
  }

  Widget _buildQuestButton() {
    return Tooltip(
      message: '퀘스트 대상 도서 확인',
      child: InkWell(
        onTap: onOpenQuest,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AegisReaderTheme.accentColor.withValues(alpha: 0.22),
                AegisReaderTheme.warningColor.withValues(alpha: 0.16),
              ],
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isPremium
                  ? AegisReaderTheme.warningColor.withValues(alpha: 0.6)
                  : AegisReaderTheme.accentColor.withValues(alpha: 0.6),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPremium ? Icons.workspace_premium_rounded : Icons.emoji_events_rounded,
                size: 14,
                color: AegisReaderTheme.warningColor,
              ),
              const SizedBox(width: 5),
              const Text(
                '퀘스트',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedTestButton() {
    return Tooltip(
      message: '서버 네트워크 속도 측정 (업로드/다운로드)',
      child: InkWell(
        onTap: onOpenSpeedTest,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.cyan.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.cyanAccent.withValues(alpha: 0.5),
              width: 1.2,
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.speed_rounded,
                size: 14,
                color: Colors.cyanAccent,
              ),
              SizedBox(width: 5),
              Text(
                '속도 측정',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
