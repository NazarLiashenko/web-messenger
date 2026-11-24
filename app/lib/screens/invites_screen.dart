import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../models/models.dart';
import '../state/invites_controller.dart';
import '../widgets/common.dart';
import '../core/chat_navigation.dart';
import 'search_screen.dart';
import 'user_profile_screen.dart';

/// Pending invitations: received (accept / decline) and sent (cancel).
class InvitesScreen extends StatelessWidget {
  const InvitesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<InvitesController>();
    final empty = ctrl.incoming.isEmpty && ctrl.outgoing.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Invitations'),
        actions: [
          IconButton(
            tooltip: 'Invite someone',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: ctrl.load,
        child: ctrl.error != null && empty
            ? ListView(children: [SizedBox(height: 400, child: ErrorRetry(message: ctrl.error!.message, onRetry: ctrl.load))])
            : empty
                ? ListView(children: [
                    const SizedBox(height: 120),
                    Icon(Icons.mark_email_read_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 16),
                    const Center(child: Text('No pending invitations')),
                  ])
                : ListView(children: [
                    if (ctrl.incoming.isNotEmpty) const _Header('Received'),
                    for (final i in ctrl.incoming) _InviteTile(invite: i),
                    if (ctrl.outgoing.isNotEmpty) const _Header('Sent'),
                    for (final i in ctrl.outgoing) _InviteTile(invite: i),
                  ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _InviteTile extends StatefulWidget {
  const _InviteTile({required this.invite});
  final Invite invite;
  @override
  State<_InviteTile> createState() => _InviteTileState();
}

class _InviteTileState extends State<_InviteTile> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.read<InvitesController>();
    final i = widget.invite;
    return ListTile(
      leading: UserAvatar(user: i.user, showOnline: true),
      title: Text(i.user.username),
      subtitle: Text(i.incoming ? 'wants to chat · ${formatChatTime(i.createdAt)}' : 'invited ${formatChatTime(i.createdAt)}'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserProfileScreen(userId: i.user.id, initial: i.user))),
      trailing: _busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : i.incoming
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton.outlined(
                    tooltip: 'Decline',
                    icon: const Icon(Icons.close),
                    onPressed: () => _run(() => ctrl.decline(i)),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Accept',
                    icon: const Icon(Icons.check),
                    onPressed: () => _run(() async {
                      // The tile may be removed by the realtime event before the request returns,
                      // so grab the navigator first.
                      final nav = Navigator.of(context);
                      final chat = await ctrl.accept(i);
                      if (nav.mounted) ChatNavigation.open(nav.context, chat.id);
                    }),
                  ),
                ])
              : TextButton(onPressed: () => _run(() => ctrl.cancel(i.id)), child: const Text('Cancel')),
    );
  }
}
