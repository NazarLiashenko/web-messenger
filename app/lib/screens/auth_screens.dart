import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/app_config.dart';
import '../core/validators.dart';
import '../state/auth_controller.dart';
import '../widgets/common.dart';

/// Shared layout for the auth screens.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, this.subtitle, required this.children, this.showBack = true});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        actions: [
          IconButton(
            tooltip: 'Server settings',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () => showServerSettings(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(title, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(subtitle!, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 24),
                ...children,
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/* ============================== LOGIN ============================== */

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthController>();
      if (auth.notice != null) {
        showMessage(context, auth.notice!);
        auth.notice = null;
      }
    });
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    final auth = context.read<AuthController>();
    try {
      await auth.login(_email.text, _password.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'EMAIL_NOT_VERIFIED') {
        showMessage(context, e.message, error: false);
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => VerifyEmailScreen(email: _email.text.trim())));
      } else {
        setState(() => _error = e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Welcome back 👋',
      subtitle: 'Log in with your email and password.',
      showBack: false,
      children: [
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(children: [
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email)),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                validator: validateEmail,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ]),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => ForgotPasswordScreen(initialEmail: _email.text))),
            child: const Text('Forgot password?'),
          ),
        ),
        if (_error != null) _ErrorBox(_error!),
        const SizedBox(height: 8),
        BusyButton(onPressed: _submit, label: 'Log in'),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text("Don't have an account?"),
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterScreen())),
            child: const Text('Sign up'),
          ),
        ]),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.error_outline, color: scheme.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: scheme.onErrorContainer))),
      ]),
    );
  }
}

/* ============================== REGISTER ============================== */

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  String? _error;

  // Server-side errors / live availability shown under the fields.
  String? _emailTaken;
  String? _usernameTaken;
  Timer? _debounce;
  final _emailKey = GlobalKey<FormFieldState<String>>();
  final _usernameKey = GlobalKey<FormFieldState<String>>();

  void _revalidate() {
    if (_email.text.isNotEmpty) _emailKey.currentState?.validate();
    if (_username.text.isNotEmpty) _usernameKey.currentState?.validate();
  }

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _checkAvailability() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final email = _email.text.trim();
      final username = _username.text.trim();
      try {
        final r = await context.read<AuthController>().checkAvailability(
              email: validateEmail(email) == null ? email : null,
              username: validateUsername(username) == null ? username : null,
            );
        if (!mounted) return;
        setState(() {
          _emailTaken = r['emailAvailable'] == false ? 'This email is already registered' : null;
          _usernameTaken = r['usernameAvailable'] == false ? 'This username is already taken' : null;
        });
        _revalidate();
      } catch (_) {
        // Availability is a convenience; the server checks again on submit.
      }
    });
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    try {
      final sent = await context.read<AuthController>().register(
            email: _email.text,
            username: _username.text,
            password: _password.text,
          );
      if (!mounted) return;
      if (!sent) showMessage(context, 'Account created, but the email could not be sent. Use "Resend code".');
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => VerifyEmailScreen(email: _email.text.trim())));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == 'EMAIL_TAKEN') {
          _emailTaken = e.message;
        } else if (e.code == 'USERNAME_TAKEN') {
          _usernameTaken = e.message;
        } else {
          _error = e.message;
        }
      });
      _revalidate();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Create account',
      subtitle: 'Pick a unique username — others can find you by it.',
      children: [
        Form(
          key: _form,
          child: Column(children: [
            TextFormField(
              controller: _email,
              key: _emailKey,
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email)),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_emailTaken != null) setState(() => _emailTaken = null);
                _checkAvailability();
              },
              validator: (v) => validateEmail(v) ?? _emailTaken,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _username,
              key: _usernameKey,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person_outline),
                helperText: '3–32 characters: letters, digits, "_" and "."',
              ),
              textInputAction: TextInputAction.next,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_.]'))],
              onChanged: (_) {
                if (_usernameTaken != null) setState(() => _usernameTaken = null);
                _checkAvailability();
              },
              validator: (v) => validateUsername(v) ?? _usernameTaken,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              textInputAction: TextInputAction.next,
              validator: validateStrongPassword,
            ),
            const SizedBox(height: 10),
            PasswordChecklist(password: _password.text),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: const InputDecoration(labelText: 'Confirm password', prefixIcon: Icon(Icons.lock_outline)),
              validator: (v) => v != _password.text ? 'Passwords do not match' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        if (_error != null) _ErrorBox(_error!),
        BusyButton(onPressed: isStrongPassword(_password.text) ? _submit : null, label: 'Create account'),
      ],
    );
  }
}

/* ============================== VERIFY EMAIL ============================== */

class CodeField extends StatelessWidget {
  const CodeField({super.key, required this.controller, this.onCompleted, this.errorText});
  final TextEditingController controller;
  final VoidCallback? onCompleted;
  final String? errorText;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 6,
        style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.bold),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(counterText: '', hintText: '••••••', errorText: errorText),
        onChanged: (v) {
          if (v.length == 6) onCompleted?.call();
        },
        validator: (v) => (v ?? '').length != 6 ? 'Enter the 6-digit code' : null,
      );
}

/// Resend button with a cooldown.
class ResendButton extends StatefulWidget {
  const ResendButton({super.key, required this.onResend});
  final Future<void> Function() onResend;
  @override
  State<ResendButton> createState() => _ResendButtonState();
}

class _ResendButtonState extends State<ResendButton> {
  int _wait = 30;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start(30);
  }

  void _start(int s) {
    _wait = s;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: _wait > 0
            ? null
            : () async {
                try {
                  await widget.onResend();
                  if (context.mounted) showMessage(context, 'A new code was sent', error: false);
                  _start(30);
                } on ApiException catch (e) {
                  if (context.mounted) showMessage(context, e);
                  final retry = e.data['retryAfter'];
                  if (retry is int) _start(retry);
                }
              },
        child: Text(_wait > 0 ? 'Resend code in ${_wait}s' : 'Resend code'),
      );
}

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});
  final String email;
  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AuthController>().verifyEmail(widget.email, _code.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Check your email',
      subtitle: 'We sent a 6-digit confirmation code to ${widget.email}.',
      children: [
        Form(key: _form, child: CodeField(controller: _code, onCompleted: _submit, errorText: _error)),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirm email'),
        ),
        const SizedBox(height: 8),
        ResendButton(onResend: () => context.read<AuthController>().resendVerification(widget.email)),
      ],
    );
  }
}

/* ============================== PASSWORD RECOVERY ============================== */

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});
  final String initialEmail;
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _form = GlobalKey<FormState>();

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    try {
      await context.read<AuthController>().forgotPassword(_email.text);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ResetPasswordScreen(email: _email.text.trim())));
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Reset password',
      subtitle: "Enter your account email and we'll send you a recovery code.",
      children: [
        Form(
          key: _form,
          child: TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email)),
            validator: validateEmail,
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(height: 24),
        BusyButton(onPressed: _submit, label: 'Send recovery code'),
      ],
    );
  }
}

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, required this.email});
  final String email;
  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _codeError;
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  Future<void> _submit() async {
    setState(() {
      _codeError = null;
      _error = null;
    });
    if (!_form.currentState!.validate()) return;
    try {
      await context.read<AuthController>().resetPassword(widget.email, _code.text, _password.text);
      if (!mounted) return;
      showMessage(context, 'Password changed. Log in with your new password.', error: false);
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => e.field == 'code' ? _codeError = e.message : _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'New password',
      subtitle: 'If an account exists for ${widget.email}, we sent it a 6-digit code.',
      children: [
        Form(
          key: _form,
          child: Column(children: [
            CodeField(controller: _code, errorText: _codeError),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password', prefixIcon: Icon(Icons.lock_outline)),
              validator: validateStrongPassword,
            ),
            const SizedBox(height: 10),
            PasswordChecklist(password: _password.text),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm new password', prefixIcon: Icon(Icons.lock_outline)),
              validator: (v) => v != _password.text ? 'Passwords do not match' : null,
            ),
          ]),
        ),
        const SizedBox(height: 20),
        if (_error != null) _ErrorBox(_error!),
        BusyButton(onPressed: _submit, label: 'Change password'),
        ResendButton(onResend: () => context.read<AuthController>().forgotPassword(widget.email)),
      ],
    );
  }
}

/* ============================== SERVER SETTINGS ============================== */

Future<void> showServerSettings(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _ServerSettingsSheet(),
  );
}

class _ServerSettingsSheet extends StatefulWidget {
  const _ServerSettingsSheet();
  @override
  State<_ServerSettingsSheet> createState() => _ServerSettingsSheetState();
}

class _ServerSettingsSheetState extends State<_ServerSettingsSheet> {
  late final _url = TextEditingController(text: context.read<AppConfig>().serverUrl);
  String? _status;
  bool _ok = false;
  bool _testing = false;

  Future<bool> _test() async {
    setState(() {
      _testing = true;
      _status = null;
    });
    final url = AppConfig.normalize(_url.text);
    try {
      final res = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 6), receiveTimeout: const Duration(seconds: 6)))
          .get('$url/api/health');
      _ok = res.data is Map && res.data['ok'] == true;
      _status = _ok ? 'Connected ✓' : 'Not a Messenger server';
    } catch (_) {
      _ok = false;
      _status = 'Cannot reach $url';
    }
    if (mounted) setState(() => _testing = false);
    return _ok;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Server', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Android emulator: http://10.0.2.2:3000 · Real device: http://<your PC LAN IP>:3000 · '
            'or a public tunnel URL (https://….trycloudflare.com).'),
        const SizedBox(height: 16),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Server URL',
            prefixIcon: const Icon(Icons.link),
            helperText: _status,
            helperStyle: TextStyle(color: _ok ? Colors.green : Theme.of(context).colorScheme.error),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _testing ? null : _test,
              child: _testing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Test'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _testing
                  ? null
                  : () async {
                      await context.read<AppConfig>().setServerUrl(_url.text);
                      if (context.mounted) Navigator.pop(context);
                    },
              child: const Text('Save'),
            ),
          ),
        ]),
      ]),
    );
  }
}
