import 'package:flutter/material.dart';
import '../../models/device_status.dart';
import '../theme.dart';

class DeviceIdCard extends StatelessWidget {
  final TextEditingController controller;
  final String serviceId;
  final DeviceStatus? deviceStatus;
  final bool isExtracting;
  final VoidCallback onExtractFromFile; // 요청: 대상 서비스 경로 자동 읽기 및 API 요청
  final VoidCallback? onManualFilePick;  // 보조: 다른 파일 수동 선택
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const DeviceIdCard({
    super.key,
    required this.controller,
    required this.serviceId,
    required this.deviceStatus,
    required this.isExtracting,
    required this.onExtractFromFile,
    this.onManualFilePick,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AegisReaderTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AegisReaderTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.vpn_key_rounded, color: AegisReaderTheme.accentColor, size: 18),
              const SizedBox(width: 8),
              const Text(
                '디바이스 인증 & ID 설정',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AegisReaderTheme.textPrimary,
                ),
              ),
              const Spacer(),
              if (onManualFilePick != null)
                TextButton.icon(
                  onPressed: isExtracting ? null : onManualFilePick,
                  icon: const Icon(Icons.file_open_outlined, size: 13, color: AegisReaderTheme.textMuted),
                  label: const Text(
                    '다른 파일 직접 선택',
                    style: TextStyle(fontSize: 11, color: AegisReaderTheme.textMuted),
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
                  controller: controller,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  decoration: InputDecoration(
                    hintText: '디바이스 ID를 입력하거나 우측 [파일에서 추출]을 누르세요',
                    prefixIcon: const Icon(Icons.fingerprint, color: AegisReaderTheme.textMuted, size: 18),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                    suffixIcon: controller.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 15),
                            onPressed: () {
                              controller.clear();
                              onChanged?.call('');
                            },
                          )
                        : null,
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              // '파일에서 추출' 버튼 (자동 추출 및 검증)
              OutlinedButton.icon(
                onPressed: isExtracting ? null : onExtractFromFile,
                icon: isExtracting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AegisReaderTheme.accentColor),
                      )
                    : const Icon(Icons.auto_awesome, size: 15, color: AegisReaderTheme.secondaryColor),
                label: const Text('파일에서 추출', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  foregroundColor: AegisReaderTheme.secondaryColor,
                  side: const BorderSide(color: AegisReaderTheme.secondaryColor, width: 1.2),
                ),
              ),
            ],
          ),
          if (deviceStatus != null) ...[
            const SizedBox(height: 8),
            _buildStatusResult(context, deviceStatus!),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusResult(BuildContext context, DeviceStatus status) {
    final isPremium = status.isPremium;
    final remaining = status.remainingQuota;
    final totalDaily = status.dailyQuota;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isPremium
            ? AegisReaderTheme.accentColor.withOpacity(0.08)
            : AegisReaderTheme.secondaryColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isPremium
              ? AegisReaderTheme.accentColor.withOpacity(0.3)
              : AegisReaderTheme.secondaryColor.withOpacity(0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isPremium ? Icons.workspace_premium : Icons.account_circle,
            color: isPremium ? AegisReaderTheme.accentColor : AegisReaderTheme.secondaryColor,
            size: 18,
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: isPremium ? AegisReaderTheme.accentColor : AegisReaderTheme.secondaryColor,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              isPremium ? 'PREMIUM' : 'STANDARD',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 9,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isPremium
                  ? (status.expiresAt != null
                      ? '프리미엄 활성 (만료: ${status.expiresAt!.toLocal().toString().split(' ')[0]}) - 변환 무제한 / 워터마크 제거 가능'
                      : '프리미엄 활성 - 변환 무제한 / 워터마크 제거 가능')
                  : '작업 제한: 1시간당 ${status.quotaUsed} / $totalDaily 권 변환 (잔여: $remaining권)',
              style: const TextStyle(fontSize: 11, color: AegisReaderTheme.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!isPremium && remaining <= 5)
            Text(
              '잔여량 부족',
              style: TextStyle(
                fontSize: 10,
                color: remaining == 0 ? AegisReaderTheme.errorColor : AegisReaderTheme.warningColor,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}
