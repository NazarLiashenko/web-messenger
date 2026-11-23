import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/app_config.dart';
import 'core/notification_service.dart';
import 'core/push_service.dart';
import 'core/session_store.dart';
import 'core/socket_service.dart';
import 'screens/auth_screens.dart';
import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'state/auth_controller.dart';
import 'state/chats_controller.dart';
import 'state/invites_controller.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = await AppConfig.load();
  final api = ApiClient(config, SessionStore());
  final socket = SocketService(api);
  final notifications = NotificationService();
  final push = PushService(api);
  await Future.wait([notifications.init(), push.init()]);
  final auth = AuthController(api, socket, push, notifications);
  final chats = ChatsController(api, socket, notifications, '');
  final invites = InvitesController(api, socket, notifications, chats);

  // Changing the server invalidates the session on the old one.
  config.addListener(() {
    if (auth.status == AuthStatus.signedIn) auth.logout();
  });

  // Reset per-account state whenever the signed-in user changes; close open screens on logout.
  String? currentUser;
  auth.addListener(() {
    final id = auth.status == AuthStatus.signedIn ? auth.user?.id : null;
    if (id == currentUser) return;
    currentUser = id;
    chats.reset(id);
    invites.reset();
    if (id == null) navigatorKey.currentState?.popUntil((r) => r.isFirst);
  });

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: config),
      Provider.value(value: api),
      ChangeNotifierProvider.value(value: socket),
      Provider.value(value: notifications),
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider.value(value: chats),
      ChangeNotifierProvider.value(value: invites),
    ],
    child: const MessengerApp(),
  ));

  unawaited(auth.restore());
}

class MessengerApp extends StatefulWidget {
  const MessengerApp({super.key});
  @override
  State<MessengerApp> createState() => _MessengerAppState();
}

class _MessengerAppState extends State<MessengerApp> with WidgetsBindingObserver {
  late final NotificationService _notifications = context.read<NotificationService>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notifications.onTap = _openPayload;
    context.read<AuthController>().push.onOpen = _openPayload;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notifications.appInForeground = state == AppLifecycleState.resumed;
    final socket = context.read<SocketService>();
    final auth = context.read<AuthController>();
    if (state == AppLifecycleState.resumed && auth.status == AuthStatus.signedIn && !socket.connected) {
      socket.reconnect();
    }
  }

  /// Opens the chat / invites screen from a tapped notification.
  void _openPayload(String payload) {
    final nav = navigatorKey.currentState;
    if (nav == null || context.read<AuthController>().status != AuthStatus.signedIn) return;
    if (payload.startsWith('chat:')) {
      final chatId = payload.substring(5);
      nav.popUntil((r) => r.isFirst);
      HomeScreen.tabNotifier.value = 0;
      nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
    } else if (payload == 'invites') {
      nav.popUntil((r) => r.isFirst);
      HomeScreen.tabNotifier.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3949AB);
    return MaterialApp(
      title: 'Messenger',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: const _AuthGate(),
    );
  }
}

/// Switches between the login flow and the signed-in app.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    switch (auth.status) {
      case AuthStatus.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.signedOut:
        return const LoginScreen();
      case AuthStatus.signedIn:
        return HomeScreen(key: ValueKey(auth.user!.id));
    }
  }
}
