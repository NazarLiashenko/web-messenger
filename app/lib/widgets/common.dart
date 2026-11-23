import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/validators.dart';
import '../models/models.dart';

/// Shows an error (or any message) in a snackbar.
void showMessage(BuildContext context, Object messageOrError, {bool error = true}) {
  final text = switch (messageOrError) {
    ApiException e => e.message,
    String s => s,
    PlatformException e when e.code.contains('camera') =>
      'Camera access was denied. You can allow it in the system settings.',
    PlatformException e when e.code.contains('photo') || e.code.contains('storage') =>
      'Access to photos was denied. You can allow it in the system settings.',
    PlatformException e => e.message ?? 'The device could not complete this action',
    _ => messageOrError.toString().replaceFirst('Exception: ', ''),
  };
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text, style: TextStyle(color: error ? scheme.onErrorContainer : null)),
      backgroundColor: error ? scheme.errorContainer : null,
      behavior: SnackBarBehavior.floating,
    ));
}

/// Profile picture with a default image when the user has none, plus an optional online dot.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.user, this.radius = 24, this.showOnline = false});

  final AppUser? user;
  final double radius;
  final bool showOnline;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final url = api.absoluteUrl(user?.avatarUrl);
    final scheme = Theme.of(context).colorScheme;
    final avatar = url == null
        ? DefaultAvatar(radius: radius)
        : ClipOval(
            child: CachedNetworkImage(
              imageUrl: url,
              cacheKey: user?.avatarUrl?.split('?').first, // signature changes daily, image doesn't
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              placeholder: (_, _) => DefaultAvatar(radius: radius),
              errorWidget: (_, _, _) => DefaultAvatar(radius: radius),
            ),
          );
    if (!showOnline || !(user?.online ?? false)) return avatar;
    final dot = radius * 0.55;
    return Stack(children: [
      avatar,
      Positioned(
        right: 0,
        bottom: 0,
        child: Container(
          width: dot,
          height: dot,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.surface, width: 2),
          ),
        ),
      ),
    ]);
  }
}

/// The default profile image shown until the user uploads their own.
class DefaultAvatar extends StatelessWidget {
  const DefaultAvatar({super.key, required this.radius});
  final double radius;

  @override
  Widget build(BuildContext context) => ClipOval(
        child: Image.asset('assets/default_avatar.png', width: radius * 2, height: radius * 2, fit: BoxFit.cover),
      );
}

/// Live checklist of the password strength rules.
class PasswordChecklist extends StatelessWidget {
  const PasswordChecklist({super.key, required this.password});
  final String password;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final passed = passwordRules.where((r) => r.test(password)).length;
    final strength = passed / passwordRules.length;
    final color = strength < 0.6 ? scheme.error : (strength < 1 ? Colors.orange : Colors.green);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(value: password.isEmpty ? 0 : strength, color: color, minHeight: 6),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          for (final r in passwordRules)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(r.test(password) ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 16, color: r.test(password) ? Colors.green : scheme.outline),
              const SizedBox(width: 4),
              Text(r.label, style: Theme.of(context).textTheme.bodySmall),
            ]),
        ],
      ),
    ]);
  }
}

/// Banner shown while the realtime connection is down.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      child: connected
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.tertiaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Connecting…', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
    );
  }
}

/// Centered error with a retry button.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ]),
        ),
      );
}

/// Button that shows a spinner while its async action runs.
class BusyButton extends StatefulWidget {
  const BusyButton({super.key, required this.onPressed, required this.label, this.tonal = false});
  final Future<void> Function()? onPressed;
  final String label;
  final bool tonal;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _busy
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(widget.label);
    final onPressed = widget.onPressed == null || _busy ? null : _run;
    return widget.tonal
        ? FilledButton.tonal(onPressed: onPressed, child: child)
        : FilledButton(onPressed: onPressed, child: child);
  }
}
