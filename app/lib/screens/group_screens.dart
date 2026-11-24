import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/chat_navigation.dart';
import '../core/format.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/chats_controller.dart';
import '../state/invites_controller.dart';
import '../widgets/common.dart';
import 'user_profile_screen.dart';

/* ============================== PEOPLE PICKER ============================== */

/// Pick several people: your contacts (people you have 1:1 chats with) plus a search by username / email.
class PeoplePicker extends StatefulWidget {
  const PeoplePicker({super.key, required this.selected, required this.onChanged, this.exclude = const {}});

  final Map<String, AppUser> selected;
  final ValueChanged<Map<String, AppUser>> onChanged;

  /// Ids that cannot be picked (e.g. people already in the group).
  final Set<String> exclude;

  @override
  State<PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<PeoplePicker> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<AppUser> _results = [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
    setState(() {});
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

  void _toggle(AppUser u) {
    final next = Map<String, AppUser>.of(widget.selected);
    if (next.remove(u.id) == null) next[u.id] = u;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context
        .watch<ChatsController>()
        .active
        .where((c) => !c.isGroup && c.peer != null)
        .map((c) => c.peer!)
        .toList()
      ..sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));
    final searching = _q.text.trim().isNotEmpty;
    final list = (searching ? _results : contacts).where((u) => !widget.exclude.contains(u.id)).toList();

    Widget tile(AppUser u) => CheckboxListTile(
          value: widget.selected.containsKey(u.id),
          onChanged: (_) => _toggle(u),
          secondary: UserAvatar(user: u, showOnline: true),
          title: Text(u.username),
          subtitle: u.about.isEmpty ? null : Text(u.about, maxLines: 1, overflow: TextOverflow.ellipsis),
        );

    return Column(children: [
      if (widget.selected.isNotEmpty)
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final u in widget.selected.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InputChip(
                    avatar: UserAvatar(user: u, radius: 12),
                    label: Text(u.username),
                    onDeleted: () => _toggle(u),
                  ),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: TextField(
          controller: _q,
          onChanged: _onChanged,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search by username or email',
            isDense: true,
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : null,
          ),
        ),
      ),
      Expanded(
        child: _error != null
            ? ErrorRetry(message: _error!, onRetry: _search)
            : list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        searching
                            ? (_loading ? '' : 'No users found')
                            : 'Search people by username or email.\nYour contacts appear here.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(children: [
                    if (!searching) const SectionHeader('Your contacts'),
                    for (final u in list) tile(u),
                  ]),
      ),
    ]);
  }
}

/* ============================== CREATE GROUP ============================== */

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});
  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _title = TextEditingController();
  Map<String, AppUser> _selected = {};
  bool _busy = false;
  String? _titleError;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'Give the group a name');
      return;
    }
    setState(() {
      _busy = true;
      _titleError = null;
    });
    final nav = Navigator.of(context);
    try {
      final (chat, failed) = await context.read<ChatsController>().createGroup(title, _selected.keys.toList());
      if (!mounted) return;
      if (failed.isNotEmpty) showMessage(context, 'Some invitations were not sent: ${failed.join('; ')}');
      nav.pop();
      ChatNavigation.open(nav.context, chat.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.field == 'title') {
        setState(() => _titleError = e.message);
      } else {
        showMessage(context, e);
      }
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _busy ? null : _create,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create'),
            ),
          ),
        ],
      ),
      body: ReadableWidth(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(children: [
              ValueListenableBuilder(
                valueListenable: _title,
                builder: (_, v, _) => GroupAvatar(title: v.text, radius: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _title,
                  autofocus: true,
                  maxLength: 64,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: 'Group name', errorText: _titleError, counterText: ''),
                  onSubmitted: (_) => _create(),
                ),
              ),
            ]),
          ),
          Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Everyone you pick gets an invitation and joins the group after accepting it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: PeoplePicker(selected: _selected, onChanged: (s) => setState(() => _selected = s))),
        ]),
      ),
    );
  }
}

/* ============================== ADD MEMBERS ============================== */

class AddMembersScreen extends StatefulWidget {
  const AddMembersScreen({super.key, required this.chat, required this.exclude});
  final Chat chat;
  final Set<String> exclude;
  @override
  State<AddMembersScreen> createState() => _AddMembersScreenState();
}

class _AddMembersScreenState extends State<AddMembersScreen> {
  Map<String, AppUser> _selected = {};
  bool _busy = false;

  Future<void> _invite() async {
    setState(() => _busy = true);
    final invites = context.read<InvitesController>();
    final errors = <String>[];
    var sent = 0;
    for (final u in _selected.values) {
      try {
        await invites.inviteToGroup(widget.chat.id, u.id);
        sent++;
      } catch (e) {
        errors.add('${u.username}: ${e is ApiException ? e.message : e}');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (errors.isEmpty) {
      showMessage(context, sent == 1 ? 'Invitation sent' : '$sent invitations sent', error: false);
      Navigator.pop(context, true);
    } else {
      showMessage(context, errors.join('\n'));
      setState(() => _selected.removeWhere((id, _) => !errors.any((e) => e.startsWith('${_selected[id]!.username}:'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Invite to ${widget.chat.name}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _busy || _selected.isEmpty ? null : _invite,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_selected.isEmpty ? 'Invite' : 'Invite (${_selected.length})'),
            ),
          ),
        ],
      ),
      body: ReadableWidth(
        child: PeoplePicker(
          selected: _selected,
          exclude: widget.exclude,
          onChanged: (s) => setState(() => _selected = s),
        ),
      ),
    );
  }
}

/* ============================== GROUP INFO ============================== */

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.chatId});
  final String chatId;
  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  List<Invite>? _invites;
  String? _invitesError;

  @override
  void initState() {
    super.initState();
    _loadInvites();
  }

  Future<void> _loadInvites() async {
    try {
      final list = await context.read<InvitesController>().groupInvites(widget.chatId);
      if (mounted) {
        setState(() {
          _invites = list;
          _invitesError = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _invitesError = e.message);
    }
  }

  Future<void> _rename(Chat chat) async {
    final ctrl = TextEditingController(text: chat.title);
    final title = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Group name'),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty || title.trim() == chat.title || !mounted) return;
    try {
      await context.read<ChatsController>().renameGroup(chat.id, title.trim());
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _remove(Chat chat, AppUser member) async {
    final ok = await _confirm('Remove ${member.username}?', '${member.username} will no longer see this group.', 'Remove');
    if (!ok || !mounted) return;
    try {
      await context.read<ChatsController>().removeMember(chat.id, member.id);
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _leave(Chat chat) async {
    final ok = await _confirm(
      'Leave "${chat.name}"?',
      chat.iAmOwner && chat.members.length > 1
          ? 'You are the owner. Ownership passes to the member who joined first.'
          : 'You will stop receiving messages from this group.',
      'Leave',
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await context.read<ChatsController>().leaveGroup(chat.id);
      ChatNavigation.close(chat.id);
      nav.popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error),
              onPressed: () => Navigator.pop(d, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatsController>().byId(widget.chatId);
    final me = context.read<AuthController>().user?.id;
    final theme = Theme.of(context);
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('You are not a member of this group')));
    }
    final pending = (_invites ?? const <Invite>[]);
    final members = [...chat.members]..sort((a, b) {
        if (a.isOwner != b.isOwner) return a.isOwner ? -1 : 1;
        return a.username.toLowerCase().compareTo(b.username.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Group info')),
      body: ReadableWidth(
        child: RefreshIndicator(
          onRefresh: _loadInvites,
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
            Center(child: GroupAvatar(title: chat.name, radius: 48)),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Flexible(
                child: Text(chat.name,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (chat.iAmOwner)
                IconButton(tooltip: 'Rename group', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(chat)),
            ]),
            Center(
              child: Text('${chat.members.length} ${chat.members.length == 1 ? 'member' : 'members'}',
                  style: TextStyle(color: theme.colorScheme.outline)),
            ),
            const SizedBox(height: 16),
            SectionHeader('Members'),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.person_add_alt_1, color: theme.colorScheme.onPrimaryContainer),
              ),
              title: const Text('Invite people'),
              onTap: () async {
                final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(
                  builder: (_) => AddMembersScreen(
                    chat: chat,
                    exclude: {...chat.members.map((m) => m.id), ...pending.map((i) => i.to?.id ?? '')},
                  ),
                ));
                if (sent == true) _loadInvites();
              },
            ),
            for (final m in members)
              ListTile(
                leading: UserAvatar(user: m, showOnline: true),
                title: Text(m.id == me ? '${m.username} (you)' : m.username),
                subtitle: Text(formatLastSeen(m)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (m.isOwner) Chip(label: const Text('Owner'), visualDensity: VisualDensity.compact, side: BorderSide.none),
                  if (chat.iAmOwner && m.id != me)
                    PopupMenuButton<String>(
                      tooltip: 'Member actions',
                      onSelected: (_) => _remove(chat, m),
                      itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove from group'))],
                    ),
                ]),
                onTap: m.id == me
                    ? null
                    : () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => UserProfileScreen(userId: m.id, initial: m))),
              ),
            if (_invitesError != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(_invitesError!, style: TextStyle(color: theme.colorScheme.error))),
            if (pending.isNotEmpty) ...[
              const SizedBox(height: 8),
              SectionHeader('Pending invitations'),
              for (final i in pending)
                ListTile(
                  leading: UserAvatar(user: i.to),
                  title: Text(i.to?.username ?? ''),
                  subtitle: Text('invited by ${i.from?.id == me ? 'you' : i.from?.username} · ${formatChatTime(i.createdAt)}'),
                  trailing: i.from?.id == me
                      ? TextButton(
                          onPressed: () async {
                            try {
                              await context.read<InvitesController>().cancel(i.id);
                              _loadInvites();
                            } catch (e) {
                              if (context.mounted) showMessage(context, e);
                            }
                          },
                          child: const Text('Cancel'),
                        )
                      : null,
                ),
            ],
            const SizedBox(height: 16),
            const Divider(),
            ListTile(
              leading: Icon(Icons.logout, color: theme.colorScheme.error),
              title: Text('Leave group', style: TextStyle(color: theme.colorScheme.error)),
              onTap: () => _leave(chat),
            ),
          ]),
        ),
      ),
    );
  }
}
