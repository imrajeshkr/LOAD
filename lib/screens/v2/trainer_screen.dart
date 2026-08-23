import 'package:flutter/material.dart';
import '../../models/v2_models.dart';
import '../../services/haptics.dart';
import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../widgets/pressable.dart';
import '../../theme/app_theme.dart';

/// The Trainer tab: one thread that remembers. Notes arrive on their own,
/// carry the receipts they were based on, and the ones that change something
/// carry a button. Type back any time.
class TrainerTab extends StatefulWidget {
  /// Set by NavShell when another tab (Progress's stall cards) pushes a
  /// pre-filled question — e.g. "Ask the trainer about squat". Consumed once:
  /// this tab clears it back to null after loading it into the composer, so
  /// switching tabs and back doesn't re-fill a stale question.
  final ValueNotifier<String?>? pendingAsk;
  const TrainerTab({super.key, this.pendingAsk});
  @override
  State<TrainerTab> createState() => _TrainerTabState();
}

class _TrainerTabState extends State<TrainerTab> {
  List<CoachMessageV2> _messages = const [];
  final List<CoachMessageV2> _optimistic = [];
  bool _loading = true;
  String? _error;

  bool _search = false;
  String _query = '';
  bool _sending = false;
  bool _pinnedExpanded = true;
  String? _unreadId; // captured at load, before marking read
  bool _enteredThread = false; // true once the first load has settled
  bool _markedReadThisVisit = false;

  final _draft = TextEditingController();
  final _scroll = ScrollController();
  final _composerFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(_onScroll);
    widget.pendingAsk?.addListener(_onPendingAsk);
    // The tab may already be opening with a question pending (Progress
    // switches tabs and sets the value in the same tick). Deferred a frame
    // so it never calls setState mid-initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPendingAsk());
  }

  @override
  void dispose() {
    widget.pendingAsk?.removeListener(_onPendingAsk);
    _scroll.removeListener(_onScroll);
    _draft.dispose();
    _scroll.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  // Any scroll in the thread counts as "read it" — matches how a normal chat
  // app behaves, rather than requiring a separate "mark read" action.
  void _onScroll() {
    if (_unreadId == null) return;
    setState(() => _unreadId = null);
    _markRead();
  }

  void _markRead() {
    if (_markedReadThisVisit) return;
    _markedReadThisVisit = true;
    SupabaseService.instance.markCoachThreadRead();
  }

  void _onPendingAsk() {
    final q = widget.pendingAsk?.value;
    if (q == null || q.isEmpty) return;
    widget.pendingAsk!.value = null; // consume once
    if (_search) setState(() => _search = false);
    _draft.text = q;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).requestFocus(_composerFocus);
    });
  }

  /// [silent] skips the full-screen loading spinner — used for refreshes
  /// that happen while the thread is already on screen (after sending, after
  /// resolving a decision), so it reads as a quiet update, not a reload.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final msgs = await SupabaseService.instance.fetchTrainerThread();
      if (!mounted) return;
      // The unread divider only makes sense on first entry — once the user
      // is actively sitting in the thread, anything that arrives (like the
      // reply to what they just sent) is being read in real time, not unread.
      String? unread;
      if (!_enteredThread) {
        for (final m in msgs) {
          if (!m.isUser && m.readAt == null) {
            unread = m.id;
            break;
          }
        }
      }
      setState(() {
        _messages = msgs;
        _optimistic.clear();
        _unreadId = unread;
        _loading = false;
        _enteredThread = true;
      });
      _scrollToBottom(animate: silent);
      if (unread != null) {
        _markRead();
      } else if (silent) {
        // A silent refresh while already inside the thread — nothing to mark
        // unread in the first place, but keep the flag consistent.
        _markedReadThisVisit = true;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _scrollToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (animate) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: const Cubic(0.22, 1, 0.36, 1),
        );
      } else {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  DateTime get _today => DateTime.now();

  CoachMessageV2? get _pinned {
    CoachMessageV2? pin;
    for (final m in _messages) {
      if (!m.isUser && m.pinnedActiveOn(_today)) pin = m;
    }
    return pin;
  }

  // ── actions ─────────────────────────────────────────────────────────────
  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _sending) return;
    Haptics.tap();
    _draft.clear();
    setState(() {
      _optimistic.add(CoachMessageV2(
        id: 'tmp-${DateTime.now().microsecondsSinceEpoch}',
        isUser: true,
        content: t,
        createdAt: DateTime.now(),
        category: 'reply',
        needsAttention: false,
        readAt: null,
        acknowledgedAt: null,
        pinnedUntil: null,
        card: null,
        receipts: const [],
        proposal: null,
      ));
      _sending = true;
    });
    _scrollToBottom();
    try {
      await SupabaseService.instance.coachTurn(t);
      if (!mounted) return;
      setState(() => _sending = false);
      await _load(silent: true); // pulls the persisted turn (both sides)
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      Haptics.error();
      _toast("Couldn't reach your trainer — try again.");
    }
  }

  Future<void> _acknowledge(CoachMessageV2 m) async {
    Haptics.tap();
    setState(() {
      final i = _messages.indexWhere((x) => x.id == m.id);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(acknowledgedAt: DateTime.now());
      }
    });
    try {
      await SupabaseService.instance.acknowledgeCoachMessage(m.id);
    } catch (_) {
      Haptics.error();
      _toast("Couldn't save that — try again.");
    }
  }

  Future<void> _resolveProposal(CoachMessageV2 m, bool accept) async {
    final p = m.proposal;
    if (p == null) return;
    Haptics.success();
    try {
      await SupabaseService.instance
          .resolveCoachProposal(p.id, accept: accept, kind: p.kind);
      await _load(silent: true);
    } catch (_) {
      Haptics.error();
      _toast("Couldn't apply that — try again.");
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _header(),
          if (_search)
            Expanded(child: _searchView())
          else ...[
            if (_pinned != null) _pinnedNote(_pinned!),
            Expanded(child: _threadView()),
            _composer(),
          ],
        ],
      ),
    );
  }

  // ── header ────────────────────────────────────────────────────────────────
  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surface)),
      ),
      child: Row(
        children: [
          Stack(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: AppColors.border, borderRadius: BorderRadius.circular(13)),
                child: const Icon(Icons.person, size: 22, color: AppColors.textMuted),
              ),
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.page, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 11),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Coach',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: AppColors.textPrimary)),
                SizedBox(height: 2),
                Text('Knows every set you have ever done',
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 10.5,
                        color: AppColors.textMuted)),
              ],
            ),
          ),
          Pressable(
            onTap: () => setState(() {
              _search = !_search;
              _query = '';
            }),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: _search ? AppColors.border : AppColors.surface,
                  shape: BoxShape.circle),
              child: Icon(_search ? Icons.close : Icons.search,
                  size: 18,
                  color: _search ? AppColors.textPrimary : AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  // ── pinned note ─────────────────────────────────────────────────────────
  Widget _pinnedNote(CoachMessageV2 m) {
    final resolved = m.acknowledged;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: resolved ? AppColors.surface : AppColors.accent.withValues(alpha: 0.07),
        border: Border.all(
            color: resolved ? AppColors.border : AppColors.accent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pressable(
            onTap: () => setState(() => _pinnedExpanded = !_pinnedExpanded),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Icon(resolved ? Icons.check_circle : Icons.push_pin,
                    size: 15, color: AppColors.accent),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    _pinnedExpanded ? _pinnedHeadline(m) : m.content,
                    maxLines: _pinnedExpanded ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 11.5,
                        height: 1.4,
                        color: AppColors.textPrimary),
                  ),
                ),
                Icon(_pinnedExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: AppColors.textDim),
              ],
            ),
          ),
          if (_pinnedExpanded)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 8),
              child: Text(m.content,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 11,
                      height: 1.55,
                      color: AppColors.textMuted)),
            ),
        ],
      ),
    );
  }

  String _pinnedHeadline(CoachMessageV2 m) {
    if (m.acknowledged) return 'Noted — nothing else needs you right now.';
    return switch (m.category) {
      'decision' => 'A decision is waiting below',
      'morning_note' => "Today's note from your coach",
      _ => 'Pinned by your coach',
    };
  }

  // ── thread ────────────────────────────────────────────────────────────────
  Widget _threadView() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _load);
    }
    final all = [..._messages, ..._optimistic];
    if (all.isEmpty) return _emptyThread();

    // Flatten into render items with day dividers + the unread mark.
    final items = <Widget>[];
    DateTime? lastDay;
    for (var i = 0; i < all.length; i++) {
      final m = all[i];
      final day = DateTime(m.createdAt.year, m.createdAt.month, m.createdAt.day);
      if (lastDay == null || day != lastDay) {
        items.add(_dayDivider(_dayLabel(day)));
        lastDay = day;
      }
      if (m.id == _unreadId) items.add(_unreadDivider());
      final prev = i > 0 ? all[i - 1] : null;
      final grouped = prev != null &&
          prev.isUser == m.isUser &&
          !m.isUser &&
          m.eyebrowNone;
      items.add(m.isUser ? _userBubble(m) : _trainerBubble(m, grouped));
    }
    if (_sending) items.add(_typingBubble());

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: items,
    );
  }

  Widget _emptyThread() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_outline, size: 34, color: AppColors.textFaint),
            const SizedBox(height: 14),
            const Text('Your coach will write here.',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: AppColors.textMuted)),
            const SizedBox(height: 6),
            const Text('Notes arrive before training days and after sessions. Ask anything below.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 11.5,
                    height: 1.5,
                    color: AppColors.textFaint)),
          ],
        ),
      ),
    );
  }

  Widget _dayDivider(String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Expanded(child: Divider(color: AppColors.border, height: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(label.toUpperCase(),
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 9.5,
                      letterSpacing: 0.9,
                      color: AppColors.textMuted)),
            ),
            const Expanded(child: Divider(color: AppColors.border, height: 1)),
          ],
        ),
      );

  Widget _unreadDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Divider(color: AppColors.warn.withValues(alpha: 0.35), height: 1)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('UNREAD',
                  style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 9.5,
                      letterSpacing: 0.8,
                      color: AppColors.warn)),
            ),
            Expanded(child: Divider(color: AppColors.warn.withValues(alpha: 0.35), height: 1)),
          ],
        ),
      );

  Widget _userBubble(CoachMessageV2 m) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.13),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(4),
                  ),
                ),
                child: Text(m.content,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 12.5,
                        height: 1.5,
                        color: AppColors.textPrimary)),
              ),
            ),
          ],
        ),
      );

  Widget _trainerBubble(CoachMessageV2 m, bool grouped) {
    final eb = _eyebrowFor(m);
    final warn = m.needsAttention;
    final showActions = _actionsFor(m);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Opacity(
            opacity: grouped ? 0 : 1,
            child: Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                  color: AppColors.border, borderRadius: BorderRadius.circular(9)),
              child: const Icon(Icons.person, size: 15, color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eb != null) ...[
                  Row(
                    children: [
                      Icon(eb.$2, size: 13, color: warn ? AppColors.warn : AppColors.accent),
                      const SizedBox(width: 7),
                      Text(eb.$1.toUpperCase(),
                          style: TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontWeight: FontWeight.w700,
                              fontSize: 9.5,
                              letterSpacing: 0.8,
                              color: warn ? AppColors.warn : AppColors.accent)),
                      const Spacer(),
                      Text(_time(m.createdAt),
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 9.5,
                              color: AppColors.inactiveFill)),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
                  decoration: BoxDecoration(
                    color: warn ? AppColors.warn.withValues(alpha: 0.11) : AppColors.surface,
                    border: Border.all(
                        color: warn ? AppColors.warn.withValues(alpha: 0.6) : AppColors.border),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18),
                      bottomRight: Radius.circular(18),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.content,
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily,
                              fontSize: 12.5,
                              height: 1.6,
                              color: Color(0xFFDDD4CE))),
                      if (m.card?.hasStats ?? false) ...[
                        const SizedBox(height: 12),
                        _statCard(m.card!),
                      ],
                      if (m.card?.hasChart ?? false) ...[
                        const SizedBox(height: 12),
                        _chartCard(m.card!),
                      ],
                      if (m.receipts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _receipts(m.receipts),
                      ],
                      if (showActions != null) ...[
                        const SizedBox(height: 13),
                        showActions,
                      ],
                      if (_resolvedText(m) != null) ...[
                        const SizedBox(height: 12),
                        _resolvedStrip(_resolvedText(m)!),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(CoachCardV2 card) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: AppColors.border,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < card.stats.length; i++) ...[
                if (i > 0) const SizedBox(width: 1),
                Expanded(
                  child: Container(
                    color: AppColors.page,
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(card.stats[i].value,
                            style: TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: i == 0 ? AppColors.accent : AppColors.textPrimary)),
                        const SizedBox(height: 4),
                        Text(card.stats[i].label,
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 8.5,
                                height: 1.3,
                                color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chartCard(CoachCardV2 card) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 9),
      decoration: BoxDecoration(
          color: AppColors.page, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            width: double.infinity,
            child: CustomPaint(painter: _SparklinePainter(card.chartPoints)),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(card.chartStart ?? '',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 9, color: AppColors.textDim)),
              Text(card.chartEnd ?? '',
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily, fontSize: 9, color: AppColors.warn)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _receipts(List<ReceiptV2> receipts) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final r in receipts)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: AppColors.page,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(13)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_iconFor(r.icon), size: 12.5, color: AppColors.accentDeep),
                const SizedBox(width: 5),
                Text(r.label,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 10,
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
      ],
    );
  }

  /// Actions under a note: a pending proposal → accept/reject; otherwise an
  /// unacknowledged note that needs a nod → Got it / Ask something.
  Widget? _actionsFor(CoachMessageV2 m) {
    final p = m.proposal;
    if (p != null && p.pending) {
      final accept = p.actionLabels.isNotEmpty ? p.actionLabels[0] : 'Apply';
      final reject = p.actionLabels.length > 1 ? p.actionLabels[1] : 'Hold for now';
      return Row(children: [
        _actionButton(accept, true, () => _resolveProposal(m, true)),
        const SizedBox(width: 7),
        _actionButton(reject, false, () => _resolveProposal(m, false)),
      ]);
    }
    final wantsNod = (m.needsAttention || m.pinnedActiveOn(_today)) && !m.acknowledged;
    if (wantsNod) {
      return Row(children: [
        _actionButton('Got it', true, () => _acknowledge(m)),
        const SizedBox(width: 7),
        _actionButton('Ask something', false, () {
          if (_search) setState(() => _search = false);
          _draft.clear();
          FocusScope.of(context).requestFocus(_composerFocus);
        }),
      ]);
    }
    return null;
  }

  Widget _actionButton(String label, bool primary, VoidCallback onTap) {
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary ? AppColors.accent : AppColors.page,
            border: Border.all(color: primary ? AppColors.accent : AppColors.borderStrong),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: primary ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 11.5,
                  color: primary ? AppColors.onAccent : AppColors.textSecondary)),
        ),
      ),
    );
  }

  String? _resolvedText(CoachMessageV2 m) {
    final p = m.proposal;
    if (p != null && !p.pending) {
      return p.status == 'confirmed' ? 'Applied to your week' : 'Holding for now';
    }
    if (m.acknowledged && m.proposal == null && (m.needsAttention || m.pinnedUntil != null)) {
      return 'Noted at ${_time(m.acknowledgedAt!)}';
    }
    return null;
  }

  Widget _resolvedStrip(String text) => Container(
        margin: const EdgeInsets.only(top: 0),
        padding: const EdgeInsets.only(top: 11),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle, size: 15, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 11,
                      height: 1.4,
                      color: AppColors.accent)),
            ),
          ],
        ),
      );

  Widget _typingBubble() => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                  color: AppColors.border, borderRadius: BorderRadius.circular(9)),
              child: const Icon(Icons.person, size: 15, color: AppColors.textMuted),
            ),
            const SizedBox(width: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: const _TypingDots(),
            ),
          ],
        ),
      );

  // ── composer ──────────────────────────────────────────────────────────────
  Widget _composer() {
    const quick = [
      ('Is this weight right?', 'Is this weight right for me?'),
      ('My knee hurts', 'My left knee hurts'),
      ('Move a session?', 'Can I move a session this week?'),
      ('What is RIR?', 'What does two reps in reserve mean?'),
    ];
    return Padding(
      padding: EdgeInsets.only(
          left: 14,
          right: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom > 0 ? 8 : 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 2),
              children: [
                for (final (label, question) in quick)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Pressable(
                      onTap: _sending ? null : () => _send(question),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                        decoration: BoxDecoration(
                            color: AppColors.surface,
                            border: Border.all(color: AppColors.border),
                            borderRadius: BorderRadius.circular(18)),
                        child: Text(label,
                            style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w500,
                                fontSize: 11,
                                color: AppColors.textSecondary)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(15, 6, 6, 6),
            decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(24)),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _draft,
                    focusNode: _composerFocus,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _send,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 12.5,
                        color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                      hintText: 'Ask your trainer anything',
                      hintStyle: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 12.5,
                          color: AppColors.textDim),
                    ),
                  ),
                ),
                Pressable(
                  onTap: () => _send(_draft.text),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _draft.text.trim().isEmpty ? AppColors.border : AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.arrow_upward,
                        size: 18,
                        color: _draft.text.trim().isEmpty
                            ? AppColors.textDim
                            : AppColors.onAccent),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── search ────────────────────────────────────────────────────────────────
  Widget _searchView() {
    final q = _query.trim().toLowerCase();
    final notes = _messages.where((m) => !m.isUser).toList().reversed.toList();
    final results = q.isEmpty
        ? notes
        : notes.where((m) => m.content.toLowerCase().contains(q)).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                const Icon(Icons.search, size: 17, color: AppColors.textDim),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    autofocus: true,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 12.5,
                        color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: 'bench, shoulder, deload, August…',
                      hintStyle: TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontSize: 12.5,
                          color: AppColors.textDim),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
                (q.isEmpty
                        ? 'Everything your trainer has told you'
                        : '${results.length} of ${notes.length} messages')
                    .toUpperCase(),
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 10,
                    letterSpacing: 0.7,
                    color: AppColors.textDim)),
          ),
          if (results.isEmpty)
            Expanded(child: _searchEmpty(q))
          else
            Expanded(
              child: ListView.separated(
                itemCount: results.length,
                separatorBuilder: (_, _) => const SizedBox(height: 7),
                itemBuilder: (_, i) => _searchResult(results[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchResult(CoachMessageV2 m) {
    final eb = _eyebrowFor(m);
    final tag = eb?.$1 ?? 'Note';
    return Pressable(
      onTap: () => setState(() => _search = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(tag.toUpperCase(),
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 9.5,
                        letterSpacing: 0.7,
                        color: m.needsAttention ? AppColors.warn : AppColors.accent)),
                const Spacer(),
                Text(_shortDate(m.createdAt),
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 9.5,
                        color: AppColors.textDim)),
              ],
            ),
            const SizedBox(height: 6),
            Text(m.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 12,
                    height: 1.5,
                    color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _searchEmpty(String q) => Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off, size: 26, color: AppColors.borderStrong),
              const SizedBox(height: 9),
              Text('Nothing about "$q" yet',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      color: AppColors.textMuted)),
              const SizedBox(height: 6),
              const SizedBox(
                width: 230,
                child: Text(
                    'Every message is kept, so this only means it has not come up.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontSize: 11,
                        height: 1.5,
                        color: AppColors.textDim)),
              ),
            ],
          ),
        ),
      );

  // ── mapping helpers ─────────────────────────────────────────────────────
  (String, IconData)? _eyebrowFor(CoachMessageV2 m) => switch (m.category) {
        'morning_note' => ('Before you train', Icons.wb_twilight),
        'session_debrief' => ('Session debrief', Icons.done_all),
        'decision' => ('This needs a decision', Icons.trending_flat),
        'missed_session' => ('Missed session', Icons.event_busy),
        'weekly_review' => ('Week in review', Icons.insights),
        'plan_updated' => ('Plan updated', Icons.auto_fix_high),
        _ => null,
      };

  IconData _iconFor(String name) => switch (name) {
        'history' => Icons.history,
        'healing' => Icons.healing,
        'local_fire_department' => Icons.local_fire_department,
        'fitness_center' => Icons.fitness_center,
        'calendar_month' => Icons.calendar_month,
        'trending_flat' => Icons.trending_flat,
        'event' => Icons.event,
        'swap_horiz' => Icons.swap_horiz,
        'block' => Icons.block,
        'insights' => Icons.insights,
        _ => Icons.check_circle_outline,
      };

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return _weekday(day.weekday);
    return '${day.day} ${_month(day.month)}';
  }

  String _shortDate(DateTime d) => '${d.day} ${_month(d.month)}';

  String _time(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m ${d.hour < 12 ? 'am' : 'pm'}';
  }

  static String _weekday(int w) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][(w - 1) % 7];
  static String _month(int m) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ][(m - 1) % 12];
}

extension on CoachMessageV2 {
  /// True when this message carries no eyebrow (used for avatar grouping).
  bool get eyebrowNone => const {
        'morning_note',
        'session_debrief',
        'decision',
        'missed_session',
        'weekly_review',
        'plan_updated',
      }.contains(category) ==
      false;
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Builder(builder: (context) {
              final phase = (_c.value + i * 0.18) % 1.0;
              final up = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
              return Transform.translate(
                offset: Offset(0, -3 * up),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.textMuted.withValues(alpha: 0.25 + 0.75 * up),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> points;
  _SparklinePainter(this.points);
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final lo = points.reduce((a, b) => a < b ? a : b);
    final hi = points.reduce((a, b) => a > b ? a : b);
    final range = (hi - lo).abs() < 0.001 ? 1.0 : hi - lo;
    Offset at(int i) {
      final x = size.width * (i / (points.length - 1));
      final y = size.height - (size.height - 8) * ((points[i] - lo) / range) - 4;
      return Offset(x, y);
    }

    // baseline
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()..color = const Color(0xFF241F1D),
    );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.textMuted
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(at(points.length - 1), 4, Paint()..color = AppColors.warn);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.points != points;
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 38, color: AppColors.textFaint),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 18),
            OutlinedButton(onPressed: () { Haptics.tap(); onRetry(); }, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
