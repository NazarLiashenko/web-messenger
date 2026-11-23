import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../models/models.dart';
import '../state/invites_controller.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import 'user_profile_screen.dart';

/// Find users by username (prefix) or exact email.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<AppUser> _results = [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      setState(() => _results = []);
      return;
    }
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<ApiClient>().get('/api/users/search', query: {'q': q});
      if (seq != _seq || !mounted) return;
      setState(() => _results = (data['users'] as List).map((j) => AppUser.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    } on ApiException catch (e) {
      if (seq == _seq && mounted) setState(() => _error = e.message);
    } finally {
      if (seq == _seq && mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _q,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Username or email', border: InputBorder.none, filled: false),
          onChanged: _onChanged,
          onSubmitted: (_) => _search(),
        ),
        bottom: _loading ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
      ),
      body: _error != null
          ? ErrorRetry(message: _error!, onRetry: _search)
          : _results.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _q.text.trim().isEmpty
                          ? 'Search people by their username or by their exact email address.'
                          : (_loading ? '' : 'No users found'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(children: [
                  for (final u in _results)
                    ListTile(
                      leading: UserAvatar(user: u, showOnline: true),
                      title: Text(u.username),
                      subtitle: u.about.isEmpty ? null : Text(u.about, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: RelationButton(user: u, onChanged: _search),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserProfileScreen(userId: u.id, initial: u)));
                        _search();
                      },
                    ),
                ]),
    );
  }
}

/// "Message" / "Invite" / "Invited" / "Accept" depending on the relationship with the user.
class RelationButton extends StatelessWidget {
  const RelationButton({super.key, required this.user, this.onChanged, this.expanded = false});
  final AppUser user;
  final VoidCallback? onChanged;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final invites = context.read<InvitesController>();
    // Captured up front: realtime events can rebuild/unmount this button while a request is running.
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;

    Future<void> act(Future<void> Function() fn) async {
      try {
        await fn();
      } catch (e) {
        messenger.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(e.toString(), style: TextStyle(color: scheme.onErrorContainer)),
          backgroundColor: scheme.errorContainer,
        ));
      }
      onChanged?.call();
    }

    void openChat(String chatId) => nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));

    Widget btn(Widget b) => expanded ? SizedBox(width: double.infinity, child: b) : b;

    if (user.chatId != null) {
      return btn(FilledButton.tonalIcon(
          onPressed: () => openChat(user.chatId!), icon: const Icon(Icons.chat_outlined), label: const Text('Message')));
    }
    final inv = user.invite;
    if (inv != null && !inv.incoming) {
      return btn(OutlinedButton.icon(
        onPressed: () => act(() => invites.cancel(inv.id)),
        icon: const Icon(Icons.hourglass_top),
        label: const Text('Invited · Cancel'),
      ));
    }
    if (inv != null && inv.incoming) {
      return btn(FilledButton.icon(
        onPressed: () => act(() async {
          final match = invites.incoming.where((i) => i.id == inv.id).firstOrNull;
          if (match != null) {
            openChat((await invites.accept(match)).id);
          } else {
            final chat = await invites.send(user.id); // auto-accepts their invite
            if (chat != null) openChat(chat.id);
          }
        }),
        icon: const Icon(Icons.check),
        label: const Text('Accept invite'),
      ));
    }
    return btn(FilledButton.icon(
      onPressed: () => act(() async {
        final chat = await invites.send(user.id);
        if (chat != null) {
          openChat(chat.id);
        } else {
          messenger.showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating, content: Text('Invitation sent to ${user.username}')));
        }
      }),
      icon: const Icon(Icons.person_add_alt_1),
      label: const Text('Invite'),
    ));
  }
}
