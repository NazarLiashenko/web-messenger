import 'package:material_ui/material_ui.dart';

import '../screens/chat_screen.dart';
import '../screens/home_screen.dart';

/// Opens chats in the right place for the current layout.
///
/// Wide windows (web / desktop / tablets in landscape) show the chat next to the chat list,
/// narrow ones (phones) push it as a full-screen page — the original mobile behaviour.
class ChatNavigation {
  ChatNavigation._();

  /// Width from which the two-pane layout is used.
  static const wideBreakpoint = 900.0;

  /// Chat shown in the detail pane of the wide layout.
  static final selected = ValueNotifier<String?>(null);

  static bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wideBreakpoint;

  static void open(BuildContext context, String chatId) {
    final nav = Navigator.of(context, rootNavigator: true);
    if (isWide(context)) {
      nav.popUntil((r) => r.isFirst);
      HomeScreen.tabNotifier.value = 0; // the chat pane lives on the Chats tab
      selected.value = chatId;
    } else {
      nav.push(chatRoute(chatId));
    }
  }

  static Route<void> chatRoute(String chatId) => MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId));

  static void close(String chatId) {
    if (selected.value == chatId) selected.value = null;
  }
}
