import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_settings.dart';
import '../../services/auth/auth_controller.dart';
import '../../services/firestore/session_repository.dart';
import '../../services/storage/settings_store.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';
import '../../widgets/components/app_bottom_nav.dart' show bottomNavClearance;
import '../../widgets/components/glass_card.dart';
import '../../widgets/components/language_selector_sheet.dart';
import '../../widgets/components/profile_menu_tile.dart';
import '../settings/privacy_policy_screen.dart';
import '../subscription/subscription_card.dart';

/// Profile: identity, translation preferences, privacy & data, appearance,
/// about, and the account actions. All behavior (sign-out, safe delete with
/// reauth, history wipe, language sync) is the existing controller logic.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final controller = context.watch<SettingsController>();
    final settings = controller.settings;
    final language = languageForCode(settings.targetLanguage);
    final theme = Theme.of(context);
    final user = auth.user;

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomNavClearance(context)),
      children: [
        Text('Profile',
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 18),

        // ── Identity ────────────────────────────────────────────────────────
        Center(
          child: Column(
            children: [
              _Avatar(
                photoUrl: user?.photoURL,
                displayName: user?.displayName,
                email: user?.email,
              ),
              const SizedBox(height: 12),
              Text(
                user?.displayName?.isNotEmpty == true
                    ? user!.displayName!
                    : 'Your account',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              if (user?.email != null)
                Text(
                  user!.email!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        // ── Plan ────────────────────────────────────────────────────────────
        const _SectionLabel('Plan'),
        const SubscriptionCard(),
        const SizedBox(height: 16),

        // ── Translation ─────────────────────────────────────────────────────
        const _SectionLabel('Translation'),
        AppGlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              ProfileMenuTile(
                icon: Icons.language_rounded,
                title: 'Target Language',
                subtitle: language == null
                    ? settings.targetLanguage
                    : '${language.flag}  ${language.name}',
                onTap: () => showLanguageSelectorSheet(context),
              ),
              _ToggleTile(
                icon: Icons.volume_up_outlined,
                title: 'Read translations aloud',
                subtitle: "Adds a speaker button using your device's voice",
                value: settings.autoSpeak,
                onChanged: (value) =>
                    controller.update((s) => s.copyWith(autoSpeak: value)),
              ),
              _ToggleTile(
                icon: Icons.nightlight_outlined,
                title: 'Continue listening in background',
                subtitle: 'Keeps translating when the app is not on screen. '
                    'A notification stays visible the whole time.',
                value: settings.continueInBackground,
                onChanged: (value) => controller
                    .update((s) => s.copyWith(continueInBackground: value)),
              ),
              _ToggleTile(
                icon: Icons.subtitles_outlined,
                title: 'Show original speech',
                subtitle: 'Display what was said, under the translation',
                value: settings.showOriginalText,
                onChanged: (value) =>
                    controller.update((s) => s.copyWith(showOriginalText: value)),
              ),
              _ToggleTile(
                icon: Icons.schedule_rounded,
                title: 'Show timestamps',
                value: settings.showTimestamps,
                onChanged: (value) =>
                    controller.update((s) => s.copyWith(showTimestamps: value)),
              ),
              _ToggleTile(
                icon: Icons.label_outline_rounded,
                title: 'Show language labels',
                value: settings.showLanguageLabels,
                onChanged: (value) =>
                    controller.update((s) => s.copyWith(showLanguageLabels: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── Privacy & Data ──────────────────────────────────────────────────
        const _SectionLabel('Privacy & Data'),
        AppGlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              ProfileMenuTile(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy Policy',
                subtitle: 'When the microphone is used, what is stored',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
                ),
              ),
              ProfileMenuTile(
                icon: Icons.delete_outline_rounded,
                title: 'Delete History',
                subtitle: 'Remove all saved translation sessions',
                onTap: () => _deleteHistory(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── Appearance ──────────────────────────────────────────────────────
        const _SectionLabel('Appearance'),
        AppGlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ProfileMenuTile(
            icon: Icons.format_size_rounded,
            title: 'Text Size',
            subtitle: settings.textSize.label,
            onTap: () => _pickTextSize(context, controller),
          ),
        ),
        const SizedBox(height: 16),

        // ── About ───────────────────────────────────────────────────────────
        const _SectionLabel('About'),
        const AppGlassCard(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ProfileMenuTile(
            icon: Icons.info_outline_rounded,
            title: 'Sayvo',
            subtitle: 'Different languages. A closer world.',
          ),
        ),
        const SizedBox(height: 16),

        // ── Account actions ─────────────────────────────────────────────────
        AppGlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              ProfileMenuTile(
                icon: Icons.logout_rounded,
                title: 'Sign Out',
                onTap: () => _signOut(context),
              ),
              ProfileMenuTile(
                icon: Icons.delete_forever_rounded,
                title: 'Delete Account',
                subtitle: 'Permanently removes your account and all history',
                danger: true,
                onTap: () => _deleteAccount(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _pickTextSize(BuildContext context, SettingsController controller) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final size in AppTextSize.values)
              ListTile(
                title: Text(size.label, textScaler: TextScaler.linear(size.scale)),
                trailing: controller.settings.textSize == size
                    ? const Icon(Icons.check_rounded, color: AppColors.electricCyan)
                    : null,
                onTap: () {
                  controller.setTextSize(size);
                  Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteHistory(BuildContext context) async {
    final auth = context.read<AuthController>();
    final sessions = context.read<SessionRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete all saved translation history?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    final uid = auth.uid;
    if (uid == null) return;
    try {
      await sessions.deleteAllSessions(uid);
      messenger.showSnackBar(const SnackBar(content: Text('History deleted')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not delete history. Please try again.')));
    }
  }

  Future<void> _signOut(BuildContext context) async {
    final auth = context.read<AuthController>();
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Sign Out')),
        ],
      ),
    );
    if (confirmed != true) return;
    await auth.signOut();
    // AuthGate swaps the root to SignIn; unwind pushed screens.
    navigator.popUntil((route) => route.isFirst);
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final auth = context.read<AuthController>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
            'This permanently deletes your account and ALL translation history. '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var result = await auth.deleteAccount();
    if (result == DeleteAccountResult.needsReauth && context.mounted) {
      final reauthed = await _reauthenticate(context, auth);
      if (reauthed) result = await auth.deleteAccount();
    }

    switch (result) {
      case DeleteAccountResult.deleted:
        // AuthGate swaps to SignIn on the auth state change.
        navigator.popUntil((route) => route.isFirst);
        messenger.showSnackBar(
            const SnackBar(content: Text('Your account was deleted.')));
      case DeleteAccountResult.needsReauth:
        messenger.showSnackBar(const SnackBar(
            content:
                Text('Account deletion canceled — sign-in confirmation is required.')));
      case DeleteAccountResult.failed:
        messenger.showSnackBar(SnackBar(
            content: Text(auth.errorMessage ?? 'Could not delete the account.')));
    }
  }

  /// Firebase requires a recent sign-in before destructive actions.
  Future<bool> _reauthenticate(BuildContext context, AuthController auth) async {
    if (auth.primaryProviderId == 'password') {
      final controller = TextEditingController();
      final password = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Confirm your password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
      if (password == null || password.isEmpty) return false;
      return auth.reauthenticateWithPassword(password);
    }
    return auth.reauthenticateWithProvider();
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  const _Avatar({this.photoUrl, this.displayName, this.email});

  final String? photoUrl;
  final String? displayName;
  final String? email;

  String get _initials {
    final source = displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : (email ?? '');
    if (source.isEmpty) return '?';
    final parts = source.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return (parts.first.characters.first + parts.last.characters.first)
          .toUpperCase();
    }
    return source.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: photoUrl == null ? AppColors.primaryGradient : null,
        border: Border.all(color: AppColors.glassBorderStrong, width: 2),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryBlue.withValues(alpha: 0.35),
            blurRadius: 28,
          ),
        ],
        image: photoUrl == null
            ? null
            : DecorationImage(image: NetworkImage(photoUrl!), fit: BoxFit.cover),
      ),
      child: photoUrl == null
          ? Center(
              child: Text(
                _initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
            )
          : null,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // One semantics node: screen readers announce title + state together,
    // like the SwitchListTile this replaces.
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: ProfileMenuTile(
          icon: icon,
          title: title,
          subtitle: subtitle,
          onTap: () => onChanged(!value),
          trailing: ExcludeSemantics(
            child: Switch(value: value, onChanged: onChanged),
          ),
        ),
      ),
    );
  }
}
