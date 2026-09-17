import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/storage/settings_store.dart';
import '../../theme/app_colors.dart';
import '../../utils/languages.dart';

/// The one target-language picker for the whole app. Backed by the SAME
/// [kTargetLanguages] catalog the backend allowlist mirrors — never a
/// separate list. Selecting writes through [SettingsController], which also
/// syncs the signed-in profile (existing behavior, untouched).
Future<void> showLanguageSelectorSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _LanguageSheet(),
  );
}

class _LanguageSheet extends StatefulWidget {
  const _LanguageSheet();

  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = context.watch<SettingsController>().settings.targetLanguage;
    final query = _query.trim().toLowerCase();
    final languages = query.isEmpty
        ? kTargetLanguages
        : [
            for (final language in kTargetLanguages)
              if (language.name.toLowerCase().contains(query) ||
                  language.nativeName.toLowerCase().contains(query) ||
                  language.code == query)
                language,
          ];

    // Keyboard insets shrink the sheet so the list stays fully scrollable
    // above the keyboard while searching.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Translate to',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 12),
                Text('${kTargetLanguages.length} languages',
                    maxLines: 1,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: TextField(
              autofocus: false,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search languages',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: languages.isEmpty
                ? Center(
                    child: Text(
                      'No languages match "$_query"',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: languages.length,
                    itemBuilder: (context, index) => LanguageRow(
                      language: languages[index],
                      selected: languages[index].code == selected,
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        await context
                            .read<SettingsController>()
                            .setTargetLanguage(languages[index].code);
                        if (navigator.mounted) navigator.pop();
                      },
                    ),
                  ),
          ),
        ],
      ),
      ),
    );
  }
}

/// One language option: flag, English name, native name, selection glow.
/// Shared by the selector sheet and onboarding.
class LanguageRow extends StatelessWidget {
  const LanguageRow({
    super.key,
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final LanguageInfo language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${language.name}${selected ? ', selected' : ''}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: selected
                    ? AppColors.primaryBlue.withValues(alpha: 0.16)
                    : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? AppColors.primaryBlue.withValues(alpha: 0.55)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Text(language.flag, style: const TextStyle(fontSize: 26)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(language.name,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        if (language.nativeName != language.name)
                          Text(
                            language.nativeName,
                            textDirection: language.isRtl
                                ? TextDirection.rtl
                                : TextDirection.ltr,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  if (selected)
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppColors.primaryGradient,
                      ),
                      child: const Icon(Icons.check_rounded,
                          size: 16, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
