/// Client-side validation mirroring the server rules (the server re-checks everything).
class PasswordRule {
  const PasswordRule(this.label, this.test);
  final String label;
  final bool Function(String) test;
}

final passwordRules = <PasswordRule>[
  PasswordRule('At least 8 characters', (p) => p.length >= 8),
  PasswordRule('1 lowercase letter', (p) => RegExp(r'[a-z]').hasMatch(p)),
  PasswordRule('1 uppercase letter', (p) => RegExp(r'[A-Z]').hasMatch(p)),
  PasswordRule('1 digit', (p) => RegExp(r'\d').hasMatch(p)),
  PasswordRule('1 special character', (p) => RegExp(r'[^A-Za-z0-9]').hasMatch(p)),
];

bool isStrongPassword(String p) => passwordRules.every((r) => r.test(p));

String? validateEmail(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Enter your email';
  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s)) return 'Enter a valid email address';
  return null;
}

String? validateUsername(String? v) {
  final s = (v ?? '').trim();
  if (s.length < 3) return 'At least 3 characters';
  if (s.length > 32) return 'At most 32 characters';
  if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(s)) return 'Only letters, digits, "_" and "."';
  return null;
}

String? validateStrongPassword(String? v) {
  final p = v ?? '';
  if (p.isEmpty) return 'Enter a password';
  final missing = passwordRules.where((r) => !r.test(p)).map((r) => r.label.toLowerCase()).toList();
  if (missing.isEmpty) return null;
  return 'Password is too weak: needs ${missing.join(', ')}';
}
