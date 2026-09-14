import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';

/// Account screen: identity, target-language preference, sign out, and a
/// safe delete-account flow (data first, reauth when Firebase demands it).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final settings = context.watch<SettingsController>();
    final user = auth.user;
    final language = languageForCode(settings.settings.targetLanguage);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const SizedBox(height: 12),
          CircleAvatar(
            radius: 40,
            backgroundImage: user?.photoURL == null ? null : NetworkImage(user!.photoURL!),
            child: user?.photoURL == null
                ? const Icon(Icons.person_rounded, size: 44)
                : null,
          ),
          const SizedBox(height: 12),
          Text(
            user?.displayName?.isNotEmpty == true ? user!.displayName! : 'Your account',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (user?.email != null)
            Text(
              user!.email!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
            ),
          const SizedBox(height: 16),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: const Text('Translate into'),
            subtitle: Text(language == null
                ? settings.settings.targetLanguage
                : '${language.flag}  ${language.name}'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pickLanguage(context, settings),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text('Sign Out'),
            onTap: () => _signOut(context),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
            title: Text('Delete Account',
                style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('Permanently removes your account and all translation history'),
            onTap: () => _deleteAccount(context),
          ),
        ],
      ),
    );
  }

  void _pickLanguage(BuildContext context, SettingsController controller) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scrollController) => ListView(
          controller: scrollController,
          children: [
            for (final language in kTargetLanguages)
              ListTile(
                leading: Text(language.flag, style: const TextStyle(fontSize: 24)),
                title: Text(language.nativeName),
                subtitle: language.nativeName == language.name ? null : Text(language.name),
                trailing: controller.settings.targetLanguage == language.code
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  controller.setTargetLanguage(language.code);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
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
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
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
        messenger.showSnackBar(const SnackBar(content: Text('Your account was deleted.')));
      case DeleteAccountResult.needsReauth:
        messenger.showSnackBar(const SnackBar(
            content: Text('Account deletion canceled — sign-in confirmation is required.')));
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
