import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../core/media_picker.dart';
import '../core/validators.dart';
import '../state/auth_controller.dart';
import '../widgets/common.dart';
import 'auth_screens.dart';

/// The signed-in user's own profile: picture, username, about, email, password.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  double? _uploadProgress;

  Future<void> _changeAvatar() async {
    final auth = context.read<AuthController>();
    final hasAvatar = auth.user?.avatarUrl != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => Navigator.pop(sheet, 'gallery')),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo'), onTap: () => Navigator.pop(sheet, 'camera')),
          if (hasAvatar)
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(sheet).colorScheme.error),
              title: const Text('Remove photo'),
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('JPEG or PNG, up to 5 MB'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice == 'remove') {
        await auth.removeAvatar();
        return;
      }
      final file = await MediaPicker.pickAvatar(choice == 'camera' ? ImageSource.camera : ImageSource.gallery);
      if (file == null) return;
      setState(() => _uploadProgress = 0);
      await auth.uploadAvatar(file.bytes, file.mime, file.fileName,
          onProgress: (p) => mounted ? setState(() => _uploadProgress = p) : null);
      if (mounted) showMessage(context, 'Profile picture updated', error: false);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _uploadProgress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final user = auth.user;
    final theme = Theme.of(context);
    if (user == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
        Center(
          child: Stack(children: [
            GestureDetector(onTap: _changeAvatar, child: UserAvatar(user: user, radius: 64)),
            if (_uploadProgress != null)
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(40),
                  child: CircularProgressIndicator(value: _uploadProgress, color: Colors.white),
                ),
              ),
            Positioned(
              right: 0,
              bottom: 0,
              child: IconButton.filled(onPressed: _changeAvatar, icon: const Icon(Icons.photo_camera, size: 20)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Center(child: Text(user.username, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold))),
        const SizedBox(height: 16),
        _Section(children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Username'),
            subtitle: Text(user.username),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editText(
              context,
              title: 'Username',
              initial: user.username,
              validator: validateUsername,
              save: (v) => auth.updateProfile(username: v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About me'),
            subtitle: Text(user.about.isEmpty ? 'Tell people something about yourself' : user.about,
                style: user.about.isEmpty ? TextStyle(color: theme.colorScheme.outline) : null),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editText(
              context,
              title: 'About me',
              initial: user.about,
              maxLines: 5,
              maxLength: 500,
              save: (v) => auth.updateProfile(about: v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: const Text('Email'),
            subtitle: Text(user.email ?? ''),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangeEmailScreen())),
          ),
        ]),
        _Section(children: [
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('Change password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(context.watch<AppConfig>().serverUrl),
          ),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text('Log out', style: TextStyle(color: theme.colorScheme.error)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('Log out?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Log out')),
                  ],
                ),
              );
              if (ok == true) await auth.logout();
            },
          ),
        ]),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Card.outlined(clipBehavior: Clip.antiAlias, child: Column(children: children)),
      );
}

/// Dialog to edit a single text field; keeps the dialog open and shows the server error on failure.
Future<void> _editText(
  BuildContext context, {
  required String title,
  required String initial,
  required Future<void> Function(String) save,
  String? Function(String?)? validator,
  int maxLines = 1,
  int? maxLength,
}) {
  final controller = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  String? serverError;
  bool busy = false;
  return showDialog(
    context: context,
    builder: (d) => StatefulBuilder(
      builder: (d, setState) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            maxLines: maxLines,
            maxLength: maxLength,
            decoration: InputDecoration(errorText: serverError),
            validator: validator,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (!formKey.currentState!.validate()) return;
                    setState(() {
                      busy = true;
                      serverError = null;
                    });
                    try {
                      await save(controller.text);
                      if (d.mounted) Navigator.pop(d);
                    } catch (e) {
                      setState(() => serverError = e.toString());
                    } finally {
                      if (d.mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  String? _currentError;

  @override
  void initState() {
    super.initState();
    _next.addListener(() => setState(() {}));
  }

  Future<void> _save() async {
    setState(() => _currentError = null);
    if (!_form.currentState!.validate()) return;
    try {
      await context.read<AuthController>().changePassword(_current.text, _next.text);
      if (!mounted) return;
      showMessage(context, 'Password changed. Other devices were logged out.', error: false);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _currentError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(24), children: [
            TextFormField(
              controller: _current,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Current password', errorText: _currentError),
              validator: (v) => (v ?? '').isEmpty ? 'Enter your current password' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
              validator: validateStrongPassword,
            ),
            const SizedBox(height: 10),
            PasswordChecklist(password: _next.text),
            const SizedBox(height: 24),
            BusyButton(onPressed: _save, label: 'Save'),
          ]),
        ),
      );
}

class ChangeEmailScreen extends StatefulWidget {
  const ChangeEmailScreen({super.key});
  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  String? _error;

  Future<void> _request() async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    try {
      await context.read<AuthController>().requestEmailChange(_email.text, _password.text);
      if (mounted) setState(() => _codeSent = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _confirm() async {
    setState(() => _error = null);
    try {
      await context.read<AuthController>().confirmEmailChange(_code.text);
      if (!mounted) return;
      showMessage(context, 'Email changed', error: false);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Change email')),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          if (!_codeSent)
            Form(
              key: _form,
              child: Column(children: [
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'New email'),
                  validator: validateEmail,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Current password'),
                  validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
                ),
              ]),
            )
          else ...[
            Text('Enter the code we sent to ${_email.text.trim()}'),
            const SizedBox(height: 16),
            CodeField(controller: _code, onCompleted: _confirm),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          BusyButton(onPressed: _codeSent ? _confirm : _request, label: _codeSent ? 'Confirm' : 'Send code'),
        ]),
      );
}
