import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/device_status.dart';
import '../../models/quest_book.dart';
import '../theme.dart';

class QuestDialog extends StatefulWidget {
  final Future<List<QuestBook>> Function() onFetchQuestBooks;
  final DeviceStatus? deviceStatus;
  final void Function(String url)? onOpenUrl;

  const QuestDialog({
    super.key,
    required this.onFetchQuestBooks,
    this.deviceStatus,
    this.onOpenUrl,
  });

  @override
  State<QuestDialog> createState() => _QuestDialogState();
}

class _QuestDialogState extends State<QuestDialog> {
  bool _isLoading = true;
  String? _errorMessage;
  List<QuestBook> _books = [];

  @override
  void initState() {
    super.initState();
    _loadQuestBooks();
  }

  Future<void> _loadQuestBooks() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final fetched = await widget.onFetchQuestBooks();
      if (!mounted) return;
      setState(() {
        _books = fetched;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '퀘스트 도서 목록을 불러오지 못했습니다.';
        _isLoading = false;
      });
    }
  }

  void _handleOpenUrl(String url) {
    if (widget.onOpenUrl != null) {
      widget.onOpenUrl!(url);
      return;
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    if (Platform.isWindows) {
      Process.run('rundll32', ['url.dll,FileProtocolHandler', uri.toString()]);
    } else if (Platform.isMacOS) {
      Process.run('open', [uri.toString()]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [uri.toString()]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.deviceStatus;
    final isPremium = status?.isPremium ?? false;

    return Dialog(
      backgroundColor: AegisReaderTheme.cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: AegisReaderTheme.accentColor.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. 모달 헤더
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            AegisReaderTheme.primary,
                            AegisReaderTheme.warning,
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(1.2),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AegisReaderTheme.background,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const Icon(
                          Icons.emoji_events_rounded,
                          color: AegisReaderTheme.warningColor,
                          size: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '[퀘스트] 프리미엄 활성화',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AegisReaderTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AegisReaderTheme.accentColor
                                      .withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AegisReaderTheme.accentColor
                                        .withValues(alpha: 0.35),
                                  ),
                                ),
                                child: const Text(
                                  'Quest',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFA5B4FC),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '지정된 도서를 복호화하면 프리미엄(30일) 기능이 활성화됩니다.',
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
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: AegisReaderTheme.textMuted,
                      ),
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(),
                      tooltip: '닫기',
                    ),
                  ],
                ),

                const SizedBox(height: 14),
                const Divider(color: AegisReaderTheme.cardBorder, height: 1),
                const SizedBox(height: 14),

                // 2. 현재 프리미엄 상태 배너 (프리미엄 활성 시)
                if (isPremium) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AegisReaderTheme.warningColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AegisReaderTheme.warningColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.workspace_premium_rounded,
                          color: AegisReaderTheme.warningColor,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '프리미엄 계정이 활성화되어 있습니다.',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFFCD34D),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '만료: ${status?.expiresAt != null ? status!.expiresAt!.toLocal().toString().split(' ')[0] : '확인 중'} (잔여 ${status?.remainingDays ?? 0}일)',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFFDE68A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AegisReaderTheme.warningColor
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: AegisReaderTheme.warningColor
                                  .withValues(alpha: 0.35),
                            ),
                          ),
                          child: const Text(
                            '퀘스트 달성 시 +30일 연장',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFFFCD34D),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // 3. 퀘스트 달성 조건
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AegisReaderTheme.background.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AegisReaderTheme.accentColor.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '📋 퀘스트 달성 조건',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFC7D2FE),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _buildConditionItem('대상 도서 업로드'),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildConditionItem('복호화 성공'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // 4. 퀘스트 대상 도서 목록 헤더
                Row(
                  children: [
                    const Text(
                      '📖 퀘스트 대상 도서',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: AegisReaderTheme.textPrimary,
                      ),
                    ),
                    if (!_isLoading && _books.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AegisReaderTheme.surfaceBg,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_books.length}권',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: AegisReaderTheme.textMuted,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    InkWell(
                      onTap: _isLoading ? null : _loadQuestBooks,
                      borderRadius: BorderRadius.circular(6),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.refresh_rounded,
                              size: 13,
                              color: AegisReaderTheme.textMuted,
                            ),
                            SizedBox(width: 4),
                            Text(
                              '새로고침',
                              style: TextStyle(
                                fontSize: 11,
                                color: AegisReaderTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // 5. 퀘스트 대상 도서 본문
                _buildBookListSection(),

                const SizedBox(height: 14),

                // 6. 퀘스트 참여 방법 안내
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AegisReaderTheme.accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AegisReaderTheme.accentColor.withValues(alpha: 0.22),
                    ),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline_rounded,
                            size: 15,
                            color: Color(0xFFFCD34D),
                          ),
                          SizedBox(width: 6),
                          Text(
                            '퀘스트 참여 방법',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AegisReaderTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 4),
                      Text(
                        '퀘스트 대상 도서를 복호화에 성공하면 해당 Device ID에 대해 프리미엄(30일) 기능이 활성화됩니다. 자동으로 활성화되지 않는 경우 문의해주세요.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFC7D2FE),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 7. 하단 확인 버튼
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AegisReaderTheme.surfaceBg,
                      foregroundColor: AegisReaderTheme.textPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(
                          color: AegisReaderTheme.cardBorder,
                        ),
                      ),
                    ),
                    child: const Text(
                      '확인',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConditionItem(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AegisReaderTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AegisReaderTheme.cardBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_rounded,
            size: 15,
            color: AegisReaderTheme.successColor,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AegisReaderTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookListSection() {
    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          color: AegisReaderTheme.background.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AegisReaderTheme.cardBorder),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: AegisReaderTheme.accentColor,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '퀘스트 도서 목록을 불러오는 중...',
              style: TextStyle(
                fontSize: 12,
                color: AegisReaderTheme.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(
          color: AegisReaderTheme.background.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AegisReaderTheme.errorColor.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AegisReaderTheme.errorColor,
              size: 26,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: const TextStyle(
                fontSize: 12,
                color: AegisReaderTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _loadQuestBooks,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('다시 시도', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_books.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
        decoration: BoxDecoration(
          color: AegisReaderTheme.background.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AegisReaderTheme.cardBorder),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_rounded,
              size: 28,
              color: AegisReaderTheme.textMuted,
            ),
            SizedBox(height: 8),
            Text(
              '진행중인 퀘스트 없음',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AegisReaderTheme.textPrimary,
              ),
            ),
            SizedBox(height: 4),
            Text(
              '현재 등록된 퀘스트 도서가 없습니다. 다음 퀘스트를 기다려 주세요.',
              style: TextStyle(
                fontSize: 11.5,
                color: AegisReaderTheme.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 260),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _books.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final book = _books[index];
          return _buildQuestBookItem(book);
        },
      ),
    );
  }

  Widget _buildQuestBookItem(QuestBook book) {
    final completed = book.isCompletedBy(widget.deviceStatus);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: completed
            ? AegisReaderTheme.successColor.withValues(alpha: 0.08)
            : AegisReaderTheme.background.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: completed
              ? AegisReaderTheme.successColor.withValues(alpha: 0.4)
              : AegisReaderTheme.cardBorder,
        ),
      ),
      child: Row(
        children: [
          Icon(
            completed
                ? Icons.check_circle_rounded
                : Icons.menu_book_rounded,
            size: 18,
            color: completed
                ? AegisReaderTheme.successColor
                : AegisReaderTheme.accentColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                SelectableText(
                  book.name,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: AegisReaderTheme.textPrimary,
                  ),
                ),
                if (completed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AegisReaderTheme.successColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: AegisReaderTheme.successColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Text(
                      '✔ 달성 완료',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6EE7B7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!completed) ...[
            const SizedBox(width: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (book.supportsService('1'))
                  _buildServiceBadge(
                    label: '리디',
                    url: book.linkForService('1'),
                    color: const Color(0xFF818CF8),
                  ),
                if (book.supportsService('2'))
                  _buildServiceBadge(
                    label: 'Yes24',
                    url: book.linkForService('2'),
                    color: const Color(0xFF60A5FA),
                  ),
                if (book.supportsService('3'))
                  _buildServiceBadge(
                    label: '알라딘',
                    url: book.linkForService('3'),
                    color: const Color(0xFFF472B6),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildServiceBadge({
    required String label,
    required String? url,
    required Color color,
  }) {
    final hasLink = url != null && url.trim().isNotEmpty;

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: hasLink ? color.withValues(alpha: 0.15) : AegisReaderTheme.surfaceBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: hasLink ? color.withValues(alpha: 0.35) : AegisReaderTheme.cardBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: hasLink ? color : AegisReaderTheme.textMuted,
            ),
          ),
          if (hasLink) ...[
            const SizedBox(width: 3),
            Icon(
              Icons.open_in_new_rounded,
              size: 11,
              color: color,
            ),
          ],
        ],
      ),
    );

    if (!hasLink) return badge;

    return Tooltip(
      message: '$label에서 도서 보기',
      child: InkWell(
        onTap: () => _handleOpenUrl(url),
        borderRadius: BorderRadius.circular(6),
        child: badge,
      ),
    );
  }
}
