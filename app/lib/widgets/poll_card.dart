import 'package:material_ui/material_ui.dart';

import '../models/models.dart';

/// Poll inside a message bubble: vote, change or retract the vote, see the results.
///
/// Before voting the options are choices; after voting (or once the poll is closed) they show the
/// results. In a single-choice poll tapping another option changes the vote; in a multiple-choice
/// poll the options are ticked and sent with "Vote".
class PollCard extends StatefulWidget {
  const PollCard({
    super.key,
    required this.question,
    required this.poll,
    required this.foreground,
    required this.onVote,
    this.nameOf,
  });

  final String question;
  final Poll poll;
  final Color foreground;

  /// Sends the chosen option indexes; an empty list retracts the vote.
  final Future<void> Function(List<int> options) onVote;

  /// Resolves voter ids to names (public polls).
  final String Function(String userId)? nameOf;

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  final Set<int> _draft = {}; // multiple choice: ticked but not sent yet
  bool _busy = false;
  bool _changing = false; // multiple choice: re-voting

  Poll get _poll => widget.poll;
  bool get _showResults => (_poll.voted && !_changing) || _poll.closed;

  Future<void> _send(List<int> options) async {
    setState(() => _busy = true);
    try {
      await widget.onVote(options);
      _draft.clear();
      _changing = false;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(e.toString().replaceFirst('Exception: ', '')),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _tap(int i) {
    if (_busy || _poll.closed) return;
    if (_poll.multiple) {
      if (_showResults) return;
      setState(() => _draft.contains(i) ? _draft.remove(i) : _draft.add(i));
      return;
    }
    if (_poll.myVotes.length == 1 && _poll.myVotes.first == i) return; // already my answer
    _send([i]);
  }

  void _showVoters(int i) {
    final option = _poll.options[i];
    final ids = option.voterIds ?? const [];
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(option.text),
        content: SizedBox(
          width: 320,
          child: ids.isEmpty
              ? const Text('Nobody voted for this option yet')
              : ListView(shrinkWrap: true, children: [
                  for (final id in ids)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(widget.nameOf?.call(id) ?? 'Member'),
                    ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = widget.foreground;
    final meta = fg.withValues(alpha: 0.7);
    final poll = _poll;
    final total = poll.options.fold<int>(0, (a, o) => a + o.votes);
    final kind = [
      poll.anonymous ? 'Anonymous poll' : 'Public poll',
      if (poll.multiple) 'multiple answers',
      if (poll.closed) 'closed',
    ].join(' · ');

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 340),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(poll.closed ? Icons.lock_outline : Icons.poll_outlined, size: 16, color: meta),
            const SizedBox(width: 6),
            Flexible(child: Text(kind, style: TextStyle(fontSize: 12, color: meta))),
          ]),
          const SizedBox(height: 6),
          Text(widget.question, style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (var i = 0; i < poll.options.length; i++) _option(i, poll.options[i], total, fg, meta, theme),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text(
                poll.totalVoters == 0
                    ? 'No votes yet'
                    : '${poll.totalVoters} ${poll.totalVoters == 1 ? 'person' : 'people'} voted',
                style: TextStyle(fontSize: 12, color: meta),
              ),
            ),
            if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            if (!_busy && poll.multiple && !_showResults)
              TextButton(
                onPressed: _draft.isEmpty ? null : () => _send(_draft.toList()..sort()),
                child: const Text('Vote'),
              ),
            if (!_busy && poll.voted && !poll.closed && _showResults) ...[
              if (poll.multiple)
                TextButton(
                  onPressed: () => setState(() {
                    _changing = true;
                    _draft
                      ..clear()
                      ..addAll(poll.myVotes);
                  }),
                  child: const Text('Change'),
                ),
              TextButton(onPressed: () => _send(const []), child: const Text('Retract')),
            ],
          ]),
        ]),
      ),
    );
  }

  Widget _option(int i, PollOption o, int total, Color fg, Color meta, ThemeData theme) {
    final mine = _poll.myVotes.contains(i);
    final share = total == 0 ? 0.0 : o.votes / total;
    final selectable = !_poll.closed && !_busy;

    if (!_showResults) {
      final ticked = _poll.multiple ? _draft.contains(i) : false;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: selectable ? () => _tap(i) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(
              _poll.multiple
                  ? (ticked ? Icons.check_box : Icons.check_box_outline_blank)
                  : Icons.radio_button_unchecked,
              size: 20,
              color: ticked ? theme.colorScheme.primary : meta,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(o.text, style: TextStyle(color: fg))),
          ]),
        ),
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: selectable && !_poll.multiple ? () => _tap(i) : null,
      onLongPress: _poll.anonymous ? null : () => _showVoters(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SizedBox(
              width: 40,
              child: Text('${(share * 100).round()}%',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            Expanded(child: Text(o.text, style: TextStyle(color: fg))),
            if (mine) Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
            if (!_poll.anonymous)
              InkWell(
                onTap: () => _showVoters(i),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('${o.votes}', style: TextStyle(color: meta, fontSize: 12, decoration: TextDecoration.underline)),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('${o.votes}', style: TextStyle(color: meta, fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: share,
                minHeight: 6,
                color: mine ? theme.colorScheme.primary : meta,
                backgroundColor: fg.withValues(alpha: 0.12),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
