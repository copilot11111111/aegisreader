import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../../services/api_service.dart';
import '../theme.dart';

class SpeedTestDialog extends StatefulWidget {
  final AegisReaderApiService apiService;
  final String serverUrl;
  final bool enableParallelTransfer;
  final ValueChanged<bool>? onToggleParallelTransfer;
  final void Function(SpeedTestResult result)? onSpeedMeasured;

  const SpeedTestDialog({
    super.key,
    required this.apiService,
    required this.serverUrl,
    this.enableParallelTransfer = true,
    this.onToggleParallelTransfer,
    this.onSpeedMeasured,
  });

  @override
  State<SpeedTestDialog> createState() => _SpeedTestDialogState();
}

class _SpeedTestDialogState extends State<SpeedTestDialog> {
  bool _isRunning = false;
  CancelToken? _cancelToken;

  int _selectedSizeMb = 20; // 기본 20MB
  late bool _isParallel;

  int? _pingMs;
  double _dlSpeedMBs = 0;
  double _dlSpeedMbps = 0;
  int _dlLoadedBytes = 0;
  int _dlDurationMs = 0;
  bool _dlDone = false;
  bool _dlTimedOut = false;

  double _upSpeedMBs = 0;
  double _upSpeedMbps = 0;
  int _upLoadedBytes = 0;
  int _upDurationMs = 0;
  bool _upDone = false;
  bool _upTimedOut = false;

  bool _showWarpRecommendation = false;
  bool _showWarpUploadBottleneck = false;

  int _targetBytes = 20 * 1024 * 1024;
  String _statusText = '측정 크기(20MB/90MB)와 모드를 선택한 후 측정 시작을 누르세요.';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _isParallel = widget.enableParallelTransfer;
    _targetBytes = _selectedSizeMb * 1024 * 1024;
  }

  @override
  void dispose() {
    _cancelToken?.cancel('다이얼로그 닫힘');
    super.dispose();
  }

  void _openUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (Platform.isWindows) {
      Process.run('rundll32', ['url.dll,FileProtocolHandler', uri.toString()]);
    } else if (Platform.isMacOS) {
      Process.run('open', [uri.toString()]);
    }
  }

  Future<void> _startSpeedTest() async {
    if (_isRunning) return;

    final testBytes = _selectedSizeMb * 1024 * 1024;

    setState(() {
      _isRunning = true;
      _errorMessage = null;
      _targetBytes = testBytes;
      _pingMs = null;
      _dlSpeedMBs = 0;
      _dlSpeedMbps = 0;
      _dlLoadedBytes = 0;
      _dlDurationMs = 0;
      _dlDone = false;
      _dlTimedOut = false;
      _upSpeedMBs = 0;
      _upSpeedMbps = 0;
      _upLoadedBytes = 0;
      _upDurationMs = 0;
      _upDone = false;
      _upTimedOut = false;
      _showWarpRecommendation = false;
      _showWarpUploadBottleneck = false;
      _statusText = '서버 응답 지연 시간(Ping) 측정 중...';
      _cancelToken = CancelToken();
    });

    try {
      final result = await widget.apiService.runSpeedTest(
        rawUrl: widget.serverUrl,
        testBytes: testBytes,
        parallel: _isParallel,
        cancelToken: _cancelToken,
        onProgress: (prog) {
          if (!mounted) return;
          setState(() {
            _statusText = prog.message;
            if (prog.pingMs != null) {
              _pingMs = prog.pingMs;
            }
            if (prog.stage == 'download') {
              _dlLoadedBytes = prog.currentBytes;
              _dlSpeedMBs = prog.currentSpeedMBs;
              _dlSpeedMbps = prog.currentSpeedMbps;
            } else if (prog.stage == 'upload') {
              _dlDone = true;
              _upLoadedBytes = prog.currentBytes;
              _upSpeedMBs = prog.currentSpeedMBs;
              _upSpeedMbps = prog.currentSpeedMbps;
            } else if (prog.stage == 'done') {
              _dlDone = true;
              _upDone = true;
            }
          });
        },
      );

      if (!mounted) return;

      // 100Mbps 이상 감지 시 단일 요청 모드로 자동 전환
      bool autoSwitchedToSingle = false;
      final bothFast = !result.downloadTimedOut &&
          !result.uploadTimedOut &&
          result.downloadSpeedMbps >= 100.0 &&
          result.uploadSpeedMbps >= 100.0;

      if (bothFast) {
        if (_isParallel) {
          autoSwitchedToSingle = true;
          _isParallel = false;
          widget.onToggleParallelTransfer?.call(false);
        }
      }

      // WARP 관련 안내 배너 판별:
      // 1. 고지연(Ping > 1000ms)인데 속도가 10Mbps 미만인 경우 -> WARP 사용 권장
      // 2. 이미 WARP(Ping <= 300ms)인데 업로드가 10Mbps 미만인 경우 -> 다중 분할 전송 권장
      final isHighLatencySlow = !autoSwitchedToSingle &&
          result.pingMs > 1000 &&
          (result.downloadSpeedMbps < 10.0 || result.uploadSpeedMbps < 10.0);
      final isWarpUploadBottleneck = !autoSwitchedToSingle &&
          result.pingMs <= 300 &&
          (result.uploadSpeedMbps < 10.0);

      setState(() {
        _isRunning = false;
        _pingMs = result.pingMs;
        _dlSpeedMBs = result.downloadSpeedMBs;
        _dlSpeedMbps = result.downloadSpeedMbps;
        _dlLoadedBytes = result.downloadBytes;
        _dlDurationMs = result.downloadDurationMs;
        _dlTimedOut = result.downloadTimedOut;
        _dlDone = true;

        _upSpeedMBs = result.uploadSpeedMBs;
        _upSpeedMbps = result.uploadSpeedMbps;
        _upLoadedBytes = result.uploadBytes;
        _upDurationMs = result.uploadDurationMs;
        _upTimedOut = result.uploadTimedOut;
        _upDone = true;

        _showWarpRecommendation = isHighLatencySlow;
        _showWarpUploadBottleneck = isWarpUploadBottleneck;

        if (autoSwitchedToSingle) {
          _statusText =
              '속도 측정 완료: 대역폭이 100Mbps 이상이어서 [단일 전송] 모드로 자동 전환되었습니다.';
        } else if (result.downloadSpeedMbps >= 100.0 && result.uploadSpeedMbps < 100.0) {
          _statusText =
              '속도 측정 완료: 업로드 대역폭(${result.uploadSpeedMbps.toStringAsFixed(1)} Mbps) 확보를 위해 [분할 전송] 모드를 권장/유지합니다.';
        } else if (isHighLatencySlow) {
          _statusText =
              '속도 측정 완료: 10Mbps 미만 저속이 감지되었습니다. Cloudflare WARP 사용을 권장합니다.';
        } else {
          _statusText = '속도 측정이 성공적으로 완료되었습니다.';
        }
      });

      widget.onSpeedMeasured?.call(result);
    } catch (e) {
      if (!mounted) return;
      if (_cancelToken?.isCancelled == true) {
        setState(() {
          _isRunning = false;
          _statusText = '속도 측정이 중단되었습니다.';
        });
        return;
      }
      setState(() {
        _isRunning = false;
        _errorMessage = '속도 측정 실패: ${AegisReaderApiService.extractDioErrorMessage(e)}';
        _statusText = '오류가 발생하여 측정이 중단되었습니다.';
      });
    }
  }

  void _stopSpeedTest() {
    _cancelToken?.cancel('사용자 중단');
    setState(() {
      _isRunning = false;
      _statusText = '측정이 중단되었습니다.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final dlPercent = (_targetBytes > 0) ? (_dlLoadedBytes / _targetBytes).clamp(0.0, 1.0) : 0.0;
    final upPercent = (_targetBytes > 0) ? (_upLoadedBytes / _targetBytes).clamp(0.0, 1.0) : 0.0;

    return Dialog(
      backgroundColor: AegisReaderTheme.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: Colors.cyanAccent.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 모달 헤더
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.cyan.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.cyanAccent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Icon(
                      Icons.speed_rounded,
                      color: Colors.cyanAccent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '네트워크 속도 측정 (Speed Test)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AegisReaderTheme.textPrimary,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          '서버와의 전송 대역폭(단일/분할) 및 응답 지연(Ping)을 측정합니다.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AegisReaderTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    style: IconButton.styleFrom(
                      foregroundColor: AegisReaderTheme.textMuted,
                      hoverColor: Colors.white12,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // 옵션 설정 바 (크기 선택 & 병렬/분할 처리 토글)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AegisReaderTheme.surfaceBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AegisReaderTheme.cardBorder),
                ),
                child: Row(
                  children: [
                    const Text(
                      '측정 크기:',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AegisReaderTheme.textPrimary),
                    ),
                    const SizedBox(width: 8),
                    _buildSizeOption(20, '20MB'),
                    const SizedBox(width: 6),
                    _buildSizeOption(90, '90MB'),
                    const Spacer(),
                    // 병렬 처리(분할 전송) 체크박스
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: _isParallel,
                        activeColor: AegisReaderTheme.accentColor,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: _isRunning
                            ? null
                            : (val) {
                                final newVal = val ?? false;
                                setState(() => _isParallel = newVal);
                                widget.onToggleParallelTransfer?.call(newVal);
                              },
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: _isRunning
                          ? null
                          : () {
                              final newVal = !_isParallel;
                              setState(() => _isParallel = newVal);
                              widget.onToggleParallelTransfer?.call(newVal);
                            },
                      child: Tooltip(
                        message: '체크 시: 청크 단위 분할 전송\n체크 해제 시: 분할 없이 단일 요청으로 전송합니다.',
                        child: Text(
                          '분할 전송',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _isParallel ? FontWeight.bold : FontWeight.normal,
                            color: _isParallel ? AegisReaderTheme.accentColor : AegisReaderTheme.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),
              const Divider(color: AegisReaderTheme.cardBorder, height: 1),
              const SizedBox(height: 14),

              // 2. 지연 시간 (Ping) 카드
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: AegisReaderTheme.surfaceBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AegisReaderTheme.cardBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.network_check_rounded, color: Colors.cyanAccent, size: 20),
                    const SizedBox(width: 10),
                    const Text(
                      '지연 시간 (Latency / Ping)',
                      style: TextStyle(fontSize: 13, color: AegisReaderTheme.textPrimary),
                    ),
                    const Spacer(),
                    if (_pingMs != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: _pingMs! < 500
                              ? AegisReaderTheme.successColor.withValues(alpha: 0.15)
                              : (_pingMs! < 1000
                                  ? Colors.amber.withValues(alpha: 0.15)
                                  : AegisReaderTheme.errorColor.withValues(alpha: 0.15)),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _pingMs! < 500
                                ? AegisReaderTheme.successColor.withValues(alpha: 0.4)
                                : (_pingMs! < 1000
                                    ? Colors.amber.withValues(alpha: 0.4)
                                    : AegisReaderTheme.errorColor.withValues(alpha: 0.4)),
                          ),
                        ),
                        child: Text(
                          '$_pingMs ms',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _pingMs! < 500
                                ? AegisReaderTheme.successColor
                                : (_pingMs! < 1000 ? Colors.amberAccent : Colors.redAccent),
                          ),
                        ),
                      )
                    else
                      const Text(
                        '측정 전',
                        style: TextStyle(fontSize: 12, color: AegisReaderTheme.textMuted),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // 3. 다운로드 속도 카드
              _buildSpeedCard(
                title: '다운로드 속도 ($_selectedSizeMb MB)',
                modeLabel: _isParallel ? '분할' : '단일',
                icon: Icons.download_rounded,
                accentColor: Colors.lightGreenAccent,
                speedMBs: _dlSpeedMBs,
                speedMbps: _dlSpeedMbps,
                loadedBytes: _dlLoadedBytes,
                totalBytes: _targetBytes,
                percent: dlPercent,
                isDone: _dlDone,
                isTimedOut: _dlTimedOut,
                durationMs: _dlDurationMs,
              ),

              const SizedBox(height: 12),

              // 4. 업로드 속도 카드
              _buildSpeedCard(
                title: '업로드 속도 ($_selectedSizeMb MB)',
                modeLabel: _isParallel ? '분할' : '단일',
                icon: Icons.upload_rounded,
                accentColor: Colors.deepPurpleAccent,
                speedMBs: _upSpeedMBs,
                speedMbps: _upSpeedMbps,
                loadedBytes: _upLoadedBytes,
                totalBytes: _targetBytes,
                percent: upPercent,
                isDone: _upDone,
                isTimedOut: _upTimedOut,
                durationMs: _upDurationMs,
              ),

              // 4-1. WARP 추천 안내 배너
              if (_showWarpRecommendation) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.amberAccent.withValues(alpha: 0.45),
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt_rounded, color: Colors.amberAccent, size: 24),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '10Mbps 미만 저속 감지',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.amberAccent,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Cloudflare WARP(1.1.1.1)를 사용하시면 속도가 향상될 수 있습니다.',
                              style: TextStyle(fontSize: 11, color: AegisReaderTheme.textPrimary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: () => _openUrl('https://one.one.one.one/'),
                        icon: const Icon(Icons.open_in_new_rounded, size: 14),
                        label: const Text(
                          'one.one.one.one',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade800,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 4-2. WARP 연결 중 업로드 단일 스트림 병목 안내 배너
              if (_showWarpUploadBottleneck) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.cyanAccent.withValues(alpha: 0.45),
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Colors.cyanAccent, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'WARP 연결 중 단일 스트림 업로드 제약 감지',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.cyanAccent,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '상단의 [분할 전송] 모드를 켜면 병렬 전송으로 대역폭을 최대화할 수 있습니다.',
                              style: TextStyle(fontSize: 11, color: AegisReaderTheme.textPrimary.withValues(alpha: 0.9)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 14),

              // 5. 진행 상태 메시지
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _errorMessage != null
                      ? AegisReaderTheme.errorColor.withValues(alpha: 0.12)
                      : AegisReaderTheme.surfaceBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _errorMessage != null
                        ? AegisReaderTheme.errorColor.withValues(alpha: 0.35)
                        : AegisReaderTheme.cardBorder,
                  ),
                ),
                child: Row(
                  children: [
                    if (_isRunning)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
                      )
                    else if (_errorMessage != null)
                      const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16)
                    else
                      const Icon(Icons.info_outline, color: Colors.cyanAccent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage ?? _statusText,
                        style: TextStyle(
                          fontSize: 12,
                          color: _errorMessage != null
                              ? Colors.redAccent
                              : AegisReaderTheme.textPrimary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 6. 하단 버튼 영역
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AegisReaderTheme.textPrimary,
                      side: const BorderSide(color: AegisReaderTheme.cardBorder),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('닫기'),
                  ),
                  const SizedBox(width: 10),
                  if (_isRunning)
                    ElevatedButton.icon(
                      onPressed: _stopSpeedTest,
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('중단하기'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _startSpeedTest,
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: Text('$_selectedSizeMb MB 속도 측정 시작'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyan.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSizeOption(int sizeMb, String label) {
    final isSelected = _selectedSizeMb == sizeMb;
    return InkWell(
      onTap: _isRunning
          ? null
          : () {
              setState(() {
                _selectedSizeMb = sizeMb;
                _targetBytes = sizeMb * 1024 * 1024;
              });
            },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? Colors.cyanAccent : AegisReaderTheme.cardBorder,
            width: isSelected ? 1.4 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.cyanAccent : AegisReaderTheme.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedCard({
    required String title,
    required String modeLabel,
    required IconData icon,
    required Color accentColor,
    required double speedMBs,
    required double speedMbps,
    required int loadedBytes,
    required int totalBytes,
    required double percent,
    required bool isDone,
    required bool isTimedOut,
    required int durationMs,
  }) {
    final loadedMb = (loadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
    final durationSec = durationMs > 0 ? (durationMs / 1000.0).toStringAsFixed(1) : null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AegisReaderTheme.surfaceBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AegisReaderTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AegisReaderTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  modeLabel,
                  style: const TextStyle(fontSize: 10, color: AegisReaderTheme.textMuted),
                ),
              ),
              if (isTimedOut) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    '30초 제한 도달',
                    style: TextStyle(fontSize: 10, color: Colors.amberAccent),
                  ),
                ),
              ],
              const Spacer(),
              if (isDone && durationSec != null)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${durationSec}s',
                    style: const TextStyle(fontSize: 11, color: AegisReaderTheme.textMuted),
                  ),
                ),
              Text(
                speedMBs > 0
                    ? '${speedMBs.toStringAsFixed(1)} MB/s (${speedMbps.toStringAsFixed(1)} Mbps)'
                    : '대기 중',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: speedMBs > 0 ? accentColor : AegisReaderTheme.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 6,
              backgroundColor: AegisReaderTheme.cardBorder,
              valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$loadedMb / $totalMb MB',
                style: const TextStyle(fontSize: 11, color: AegisReaderTheme.textMuted),
              ),
              Text(
                '${(percent * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 11, color: AegisReaderTheme.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
