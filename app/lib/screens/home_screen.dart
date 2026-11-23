import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/notification_service.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/chats_controller.dart';
import '../state/invites_controller.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';
import 'chat_screen.dart';
import 'invites_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static final tabNotifier = ValueNotifier<int>(0);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    final chats = context.read<ChatsController>();
    final invites = context.read<InvitesController>();
    final notifications = context.read<NotificationService>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HomeScreen.tabNotifier.value = 0;
      chats.load();
      invites.load();
      // App launched by tapping a notification.
      final launch = notifications.launchPayload;
      if (launch != null) {
        notifications.launchPayload = null;
        notifications.onTap?.call(launch);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final invites = context.watch<InvitesController>().incoming.length;
    final unread = context.watch<ChatsController>().unreadChats;
    return ValueListenableBuilder<int>(
      valueListenable: HomeScreen.tabNotifier,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(index: tab, children: const [ChatListTab(), InvitesScreen(), ProfileScreen()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => HomeScreen.tabNotifier.value = i,
          destinations: [
            NavigationDestination(
              icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble_outline)),
              selectedIcon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble)),
              label: 'Chats',
            ),
            NavigationDestination(
              icon: Badge(isLabelVisible: invites > 0, label: Text('$invites'), child: const Icon(Icons.mail_outline)),
              selectedIcon: Badge(isLabelVisible: invites > 0, label: Text('$invites'), child: const Icon(Icons.mail)),
              label: 'Invites',
            ),
            const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

/* ============================== CHAT LIST ============================== */

class ChatListTab extends StatelessWidget {
  const ChatListTab({super.key});

  @override
  Widget build(BuildContext context) {
    final chats = context.watch<ChatsController>();
    final connected = context.watch<SocketService>().connected;
    final list = chats.active;
    final archivedCount = chats.archived.length;

    Widget body;
    if (!chats.loaded && chats.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!chats.loaded && chats.error != null) {
      body = ErrorRetry(message: chats.error!.message, onRetry: chats.load);
    } else if (list.isEmpty && archivedCount == 0) {
      body = _EmptyChats(onSearch: () => _openSearch(context));
    } else {
      body = RefreshIndicator(
        onRefresh: chats.load,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: list.length + (archivedCount > 0 ? 1 : 0),
          itemBuilder: (context, i) {
            if (archivedCount > 0 && i == 0) {
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.archive_outlined)),
                title: const Text('Archived chats'),
                trailing: Text('$archivedCount'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ArchivedChatsScreen())),
              );
            }
            final chat = list[i - (archivedCount > 0 ? 1 : 0)];
            return ChatTile(chat: chat);
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(tooltip: 'Find people', icon: const Icon(Icons.search), onPressed: () => _openSearch(context)),
        ],
      ),
      body: Column(children: [ConnectionBanner(connected: connected), Expanded(child: body)]),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New chat',
        onPressed: () => _openSearch(context),
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  static void _openSearch(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SearchScreen()));
}

class _EmptyChats extends StatelessWidget {
  const _EmptyChats({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.forum_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('No chats yet', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('Find people by username or email and send them a chat invitation.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onSearch, icon: const Icon(Icons.person_search), label: const Text('Find people')),
          ]),
        ),
      );
}

class ArchivedChatsScreen extends StatelessWidget {
  const ArchivedChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final list = context.watch<ChatsController>().archived;
    return Scaffold(
      appBar: AppBar(title: const Text('Archived chats')),
      body: list.isEmpty
          ? const Center(child: Text('No archived chats'))
          : ListView(children: [for (final c in list) ChatTile(chat: c)]),
    );
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat});
  final Chat chat;

  Future<void> _toggleArchive(BuildContext context) async {
    final ctrl = context.read<ChatsController>();
    final messenger = ScaffoldMessenger.of(context);
    final archive = !chat.archived;
    try {
      await ctrl.update(chat.id, archived: archive);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(archive ? 'Chat archived' : 'Chat moved back to chats'),
          action: SnackBarAction(label: 'Undo', onPressed: () => ctrl.update(chat.id, archived: !archive).ignore()),
        ));
    } catch (e) {
      if (context.mounted) showMessage(context, e);
    }
  }

  Future<void> _toggleMute(BuildContext context) async {
    try {
      await context.read<ChatsController>().update(chat.id, muted: !chat.muted);
    } catch (e) {
      if (context.mounted) showMessage(context, e);
    }
  }

  void _menu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
            title: Text(chat.archived ? 'Unarchive' : 'Archive'),
            onTap: () {
              Navigator.pop(sheet);
              _toggleArchive(context);
            },
          ),
          ListTile(
            leading: Icon(chat.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
            title: Text(chat.muted ? 'Unmute notifications' : 'Mute notifications'),
            onTap: () {
              Navigator.pop(sheet);
              _toggleMute(context);
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ChatsController>();
    final me = context.read<AuthController>().user?.id;
    final scheme = Theme.of(context).colorScheme;
    final last = chat.lastMessage;
    final typing = ctrl.isTyping(chat.id);
    final unread = chat.unreadCount > 0;

    return Dismissible(
      key: ValueKey('chat-${chat.id}-${chat.archived}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.secondaryContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
          const SizedBox(width: 8),
          Text(chat.archived ? 'Unarchive' : 'Archive'),
        ]),
      ),
      confirmDismiss: (_) async {
        _toggleArchive(context); // optimistic: removes the tile from this list right away
        return true;
      },
      child: ListTile(
        leading: UserAvatar(user: chat.peer, radius: 26, showOnline: true),
        title: Row(children: [
          Flexible(child: Text(chat.peer.username, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (chat.muted) ...[const SizedBox(width: 4), Icon(Icons.volume_off, size: 16, color: scheme.outline)],
        ]),
        subtitle: typing
            ? Text('typing…', style: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic))
            : Row(children: [
                if (last != null && last.senderId == me && !last.isDeleted) ...[
                  StatusIcon(status: last.status, size: 16),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    last == null ? 'Say hi 👋' : messagePreview(last),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontStyle: last?.isDeleted ?? false ? FontStyle.italic : null),
                  ),
                ),
              ]),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(formatChatTime(chat.lastActivityAt),
              style: TextStyle(fontSize: 12, color: unread ? scheme.primary : scheme.outline)),
          const SizedBox(height: 4),
          if (unread)
            Badge(
              backgroundColor: chat.muted ? scheme.outline : scheme.primary,
              label: Text('${chat.unreadCount}'),
            )
          else
            const SizedBox(height: 16),
        ]),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id))),
        onLongPress: () => _menu(context),
      ),
    );
  }
}
