import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../models/models.dart';
import '../state/invites_controller.dart';
import '../widgets/common.dart';
import 'search_screen.dart';

/// Another user's public profile.
class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, required this.userId, this.initial});
  final String userId;
  final AppUser? initial;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late AppUser? _user = widget.initial;
  String? _error;
  late final InvitesController _invites = context.read<InvitesController>();

  @override
  void initState() {
    super.initState();
    _load();
    _invites.addListener(_load); // refresh the button when an invite is accepted / declined
  }

  @override
  void dispose() {
    _invites.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<ApiClient>().get('/api/users/${widget.userId}');
      if (mounted) setState(() => _user = AppUser.fromJson(Map<String, dynamic>.from(data['user'] as Map)));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _user;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: u == null
          ? (_error != null ? ErrorRetry(message: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator()))
          : ListView(padding: const EdgeInsets.all(24), children: [
              Center(child: UserAvatar(user: u, radius: 64)),
              const SizedBox(height: 16),
              Center(child: Text(u.username, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
              const SizedBox(height: 4),
              Center(
                child: Text(formatLastSeen(u),
                    style: TextStyle(color: u.online ? Colors.green : theme.colorScheme.outline)),
              ),
              const SizedBox(height: 24),
              RelationButton(user: u, onChanged: _load, expanded: true),
              const SizedBox(height: 24),
              Card.outlined(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('About'),
                  subtitle: Text(u.about.isEmpty ? 'Nothing here yet' : u.about),
                ),
              ),
            ]),
    );
  }
}
