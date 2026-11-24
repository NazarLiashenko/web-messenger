import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';

import '../core/chat_navigation.dart';
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
import 'group_screens.dart';
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
    // Browser tab / app switcher title shows the number of unread chats.
    SystemChrome.setApplicationSwitcherDescription(
      ApplicationSwitcherDescription(
        label: unread > 0 ? '($unread) Messenger' : 'Messenger',
        primaryColor: Theme.of(context).colorScheme.primary.toARGB32(),
      ),
    );
    final wide = ChatNavigation.isWide(context);
    if (!wide) _moveSelectedChatToPage();

    Widget badge(int n, IconData icon) => Badge(isLabelVisible: n > 0, label: Text('$n'), child: Icon(icon));

    return ValueListenableBuilder<int>(
      valueListenable: HomeScreen.tabNotifier,
      builder: (context, tab, _) {
        if (!wide) {
          return Scaffold(
            body: IndexedStack(index: tab, children: const [ChatListTab(), InvitesScreen(), ProfileScreen()]),
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => HomeScreen.tabNotifier.value = i,
              destinations: [
                NavigationDestination(
                  icon: badge(unread, Icons.chat_bubble_outline),
                  selectedIcon: badge(unread, Icons.chat_bubble),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: badge(invites, Icons.mail_outline),
                  selectedIcon: badge(invites, Icons.mail),
                  label: 'Invites',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            ),
          );
        }

        // Wide layout: navigation rail | chat list | open chat.
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: tab,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => HomeScreen.tabNotifier.value = i,
                destinations: [
                  NavigationRailDestination(
                    icon: badge(unread, Icons.chat_bubble_outline),
                    selectedIcon: badge(unread, Icons.chat_bubble),
                    label: const Text('Chats'),
                  ),
                  NavigationRailDestination(
                    icon: badge(invites, Icons.mail_outline),
                    selectedIcon: badge(invites, Icons.mail),
                    label: const Text('Invites'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: Text('Profile'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: tab,
                  children: const [
                    _ChatsWorkspace(),
                    ReadableWidth(child: InvitesScreen()),
                    ReadableWidth(child: ProfileScreen()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The window became narrow while a chat was open in the side pane: keep it open as a page.
  void _moveSelectedChatToPage() {
    final id = ChatNavigation.selected.value;
    if (id == null) return;
    ChatNavigation.selected.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context, rootNavigator: true).push(ChatNavigation.chatRoute(id));
    });
  }
}

/// Chat list on the left, the selected chat on the right (wide windows only).
class _ChatsWorkspace extends StatelessWidget {
  const _ChatsWorkspace();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 360, child: ChatListTab()),
        const VerticalDivider(width: 1),
        Expanded(
          child: ValueListenableBuilder<String?>(
            valueListenable: ChatNavigation.selected,
            builder: (context, id, _) => id == null
                ? const _NoChatSelected()
                : ChatScreen(key: ValueKey('pane-$id'), chatId: id, embedded: true),
          ),
        ),
      ],
    );
  }
}

class _NoChatSelected extends StatelessWidget {
  const _NoChatSelected();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 72, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              'Select a chat to start messaging',
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.outline),
            ),
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
          IconButton(
            tooltip: 'New group',
            icon: const Icon(Icons.group_add_outlined),
            onPressed: () => Navigator.of(context, rootNavigator: true)
                .push(MaterialPageRoute(builder: (_) => const CreateGroupScreen())),
          ),
          IconButton(tooltip: 'Find people', icon: const Icon(Icons.search), onPressed: () => _openSearch(context)),
        ],
      ),
      body: Column(
        children: [
          ConnectionBanner(connected: connected),
          Expanded(child: body),
        ],
      ),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('No chats yet', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Find people by username or email and send them a chat invitation.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onSearch,
            icon: const Icon(Icons.person_search),
            label: const Text('Find people'),
          ),
        ],
      ),
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
      body: ReadableWidth(
        child: list.isEmpty
            ? const Center(child: Text('No archived chats'))
            : ListView(children: [for (final c in list) ChatTile(chat: c)]),
      ),
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
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(archive ? 'Chat archived' : 'Chat moved back to chats'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => ctrl.update(chat.id, archived: !archive).ignore(),
            ),
          ),
        );
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

  /// Chat actions: a context menu at the pointer (right click on web / desktop) or a bottom sheet (long press).
  Future<void> _menu(BuildContext context, {Offset? at}) async {
    if (at != null) {
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
        items: [
          PopupMenuItem(value: 'archive', child: Text(chat.archived ? 'Unarchive' : 'Archive')),
          PopupMenuItem(value: 'mute', child: Text(chat.muted ? 'Unmute notifications' : 'Mute notifications')),
        ],
      );
      if (!context.mounted) return;
      if (choice == 'archive') _toggleArchive(context);
      if (choice == 'mute') _toggleMute(context);
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
      ),
    );
  }

  /// Last message preview; in groups prefixed with the sender ("Bob: hi", "You: hi").
  String _preview(Message last, String? me) {
    final text = messagePreview(last, myId: me);
    if (!chat.isGroup || last.isSystem || last.isDeleted) return text;
    final who = last.senderId == me ? 'You' : (chat.member(last.senderId)?.username ?? 'Someone');
    return '$who: $text';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ChatsController>();
    final me = context.read<AuthController>().user?.id;
    final scheme = Theme.of(context).colorScheme;
    final last = chat.lastMessage;
    final typing = ctrl.typingLabel(chat.id);
    final unread = chat.unreadCount > 0;

    return Dismissible(
      key: ValueKey('chat-${chat.id}-${chat.archived}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.secondaryContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
            const SizedBox(width: 8),
            Text(chat.archived ? 'Unarchive' : 'Archive'),
          ],
        ),
      ),
      confirmDismiss: (_) async {
        _toggleArchive(context); // optimistic: removes the tile from this list right away
        return true;
      },
      child: GestureDetector(
        onSecondaryTapUp: (d) => _menu(context, at: d.globalPosition),
        child: ValueListenableBuilder<String?>(
          valueListenable: ChatNavigation.selected,
          builder: (context, selectedId, _) => ListTile(
            selected: selectedId == chat.id && ChatNavigation.isWide(context),
            selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
            selectedColor: scheme.onSecondaryContainer,
            leading: ChatAvatar(
              chat: chat, radius: 26, showOnline: context.watch<SocketService>().connected),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    chat.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (chat.muted) ...[const SizedBox(width: 4), Icon(Icons.volume_off, size: 16, color: scheme.outline)],
              ],
            ),
            subtitle: typing != null
                ? Text(
                    typing,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.primary, fontStyle: FontStyle.italic),
                  )
                : Row(
                    children: [
                      if (last != null && last.senderId == me && !last.isDeleted && !last.isSystem) ...[
                        StatusIcon(status: last.status, size: 16),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          last == null ? 'Say hi 👋' : _preview(last, me),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontStyle: last?.isDeleted ?? false ? FontStyle.italic : null),
                        ),
                      ),
                    ],
                  ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatChatTime(chat.lastActivityAt),
                  style: TextStyle(fontSize: 12, color: unread ? scheme.primary : scheme.outline),
                ),
                const SizedBox(height: 4),
                if (unread)
                  Badge(
                    backgroundColor: chat.muted ? scheme.outline : scheme.primary,
                    label: Text('${chat.unreadCount}'),
                  )
                else
                  const SizedBox(height: 16),
              ],
            ),
            onTap: () => ChatNavigation.open(context, chat.id),
            onLongPress: () => _menu(context),
          ),
        ),
      ),
    );
  }
}
