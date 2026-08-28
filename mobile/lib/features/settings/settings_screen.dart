import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_settings.dart';
import '../../services/storage/history_store.dart';
import '../../services/storage/settings_store.dart';
import '../../utils/languages.dart';
import 'privacy_policy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SettingsController>();
    final settings = controller.settings;
    final language = languageForCode(settings.targetLanguage);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Translation'),
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: const Text('My Language'),
            subtitle: Text(language == null
                ? settings.targetLanguage
                : '${language.flag}  ${language.name}'),
            onTap: () => _pickLanguage(context, controller),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.subtitles_outlined),
            title: const Text('Show original speech'),
            subtitle: const Text('Display what was said, under the translation'),
            value: settings.showOriginalText,
            onChanged: (value) =>
                controller.update((s) => s.copyWith(showOriginalText: value)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.schedule_rounded),
            title: const Text('Show timestamps'),
            value: settings.showTimestamps,
            onChanged: (value) =>
                controller.update((s) => s.copyWith(showTimestamps: value)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.label_outline_rounded),
            title: const Text('Show language labels'),
            value: settings.showLanguageLabels,
            onChanged: (value) =>
                controller.update((s) => s.copyWith(showLanguageLabels: value)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Speak translations'),
            subtitle: const Text('Read translations aloud (Earphone Mode)'),
            value: settings.autoSpeak,
            onChanged: (value) => controller.update((s) => s.copyWith(autoSpeak: value)),
          ),
          const Divider(),
          const _SectionHeader('Privacy'),
          SwitchListTile(
            secondary: const Icon(Icons.save_outlined),
            title: const Text('Save translation history'),
            subtitle: const Text('Keep conversations on this device. Off by default. '
                'Audio is never saved.'),
            value: settings.saveHistory,
            onChanged: (value) => controller.update((s) => s.copyWith(saveHistory: value)),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('Delete history'),
            onTap: () => _deleteHistory(context),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
            ),
          ),
          const Divider(),
          const _SectionHeader('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (selection) => controller.setThemeMode(selection.first),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.format_size_rounded),
            title: const Text('Text Size'),
            subtitle: Text(settings.textSize.label),
            onTap: () => _pickTextSize(context, controller),
          ),
          const Divider(),
          const _SectionHeader('Developer'),
          SwitchListTile(
            secondary: const Icon(Icons.smart_toy_outlined),
            title: const Text('Demo Mode'),
            subtitle: const Text('Generate a fake conversation — no microphone or server needed'),
            value: settings.mockMode,
            onChanged: (value) => controller.update((s) => s.copyWith(mockMode: value)),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server URL'),
            subtitle: Text(settings.serverUrl.isEmpty ? 'Default' : settings.serverUrl),
            onTap: () => _editServerUrl(context, controller),
          ),
          const SizedBox(height: 24),
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

  void _pickTextSize(BuildContext context, SettingsController controller) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final size in AppTextSize.values)
              ListTile(
                title: Text(size.label, textScaler: TextScaler.linear(size.scale)),
                trailing: controller.settings.textSize == size
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () {
                  controller.setTextSize(size);
                  Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete all saved translation history?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await HistoryStore().deleteAll();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('History deleted')));
      }
    }
  }

  Future<void> _editServerUrl(BuildContext context, SettingsController controller) async {
    final textController = TextEditingController(text: controller.settings.serverUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Server URL'),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'http://192.168.1.10:8080',
            helperText: 'Leave empty for the default (emulator loopback).',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, textController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await controller.update((s) => s.copyWith(serverUrl: result));
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
