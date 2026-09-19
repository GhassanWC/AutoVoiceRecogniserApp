import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';

import '../../services/billing/entitlement_controller.dart';
import '../../services/billing/subscription_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/plans.dart';
import '../../widgets/components/app_background.dart';
import '../../widgets/components/app_error_banner.dart';
import '../../widgets/components/glass_card.dart';
import '../../widgets/components/gradient_button.dart';
import '../settings/privacy_policy_screen.dart';

/// The Sayvo subscription paywall.
///
/// Every price on this screen comes from the STORE's localized product data,
/// never from a price written into the app, so what is shown always matches
/// what Apple or Google will actually charge in the user's own currency.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PaywallScreen()),
      );

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  SayvoPlan _selected = kRecommendedPlan;
  bool _busy = false;
  bool _loading = true;
  String? _error;
  StreamSubscription<PurchaseResult>? _results;

  SubscriptionService get _subscriptions => context.read<SubscriptionService>();

  bool get _isApple => _subscriptions.store == BillingStore.apple;

  @override
  void initState() {
    super.initState();
    _subscriptions.listen();
    _results = _subscriptions.results.listen(_onPurchaseResult);
    unawaited(_load());
  }

  Future<void> _load() async {
    final ok = await _subscriptions.loadProducts();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!ok) {
        _error = 'Subscriptions are not available on this device right now.';
      }
    });
  }

  Future<void> _onPurchaseResult(PurchaseResult result) async {
    if (!mounted) return;
    switch (result.outcome) {
      case PurchaseOutcome.success:
        // The store confirmed it; the SERVER decides the entitlement, so
        // refresh from it before telling the user anything.
        await context.read<EntitlementController>().refresh();
        if (!mounted) return;
        setState(() => _busy = false);
        Navigator.of(context).maybePop();
      case PurchaseOutcome.pending:
        setState(() {
          _busy = false;
          _error = 'Your purchase is pending approval. Sayvo will unlock as '
              'soon as it completes.';
        });
      case PurchaseOutcome.cancelled:
        setState(() => _busy = false);
      case PurchaseOutcome.failed:
      case PurchaseOutcome.unavailable:
        setState(() {
          _busy = false;
          _error = result.message ?? 'That purchase could not be completed.';
        });
    }
  }

  Future<void> _buy() async {
    final product = _subscriptions.productFor(_selected);
    if (product == null) {
      setState(() => _error = 'That plan is not available right now.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _subscriptions.buy(product);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await _subscriptions.restorePurchases();
    if (!mounted) return;
    await context.read<EntitlementController>().refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    final entitlement = context.read<EntitlementController>().entitlement;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(entitlement.isPaid
          ? '${planDisplayName(entitlement.plan)} restored.'
          : 'No previous subscription found.'),
    ));
  }

  @override
  void dispose() {
    _results?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  const BackButton(color: AppColors.textPrimary),
                  Expanded(
                    child: Text('Sayvo Plans',
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    Text(
                      'Keep translating',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Choose the monthly plan that fits how much you talk. '
                      'Minutes count translated speech, so silent listening '
                      'never uses them.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 18),
                    if (_error != null)
                      AppErrorBanner(
                        message: _error!,
                        margin: const EdgeInsets.only(bottom: 14),
                      ),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      for (final plan in kPurchasablePlans)
                        _PlanCard(
                          plan: plan,
                          product: _subscriptions.productFor(plan),
                          selected: _selected == plan,
                          recommended: plan == kRecommendedPlan,
                          onTap: () => setState(() => _selected = plan),
                        ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.volume_off_rounded,
                            size: 15, color: AppColors.textTertiary),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'Silent listening doesn\'t use your minutes.',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    GradientButton(
                      label: 'Subscribe',
                      busy: _busy,
                      onPressed: _loading || _subscriptions.productFor(_selected) == null
                          ? null
                          : _buy,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Monthly subscription. Automatically renews until '
                      'cancelled. Cancel anytime.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _restore,
                          child: const Text('Restore Purchases'),
                        ),
                        const Text('·',
                            style: TextStyle(color: AppColors.textTertiary)),
                        TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => const PrivacyPolicyScreen()),
                          ),
                          child: const Text('Privacy Policy'),
                        ),
                      ],
                    ),
                    TextButton(
                      onPressed: () => showTermsOfUse(context),
                      child: const Text('Terms of Use'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isApple
                          ? 'Sayvo is currently operated by an independent '
                              'developer. Payments are processed securely by '
                              'Apple through the App Store.'
                          : 'Sayvo is currently operated by an independent '
                              'developer. Payments are processed securely by '
                              'Google Play.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.textTertiary, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Short in-app terms, so the paywall never links to a URL that may not exist.
void showTermsOfUse(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          Text('Terms of Use',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          const Text(
            'Sayvo subscriptions are monthly and renew automatically until '
            'cancelled. Each plan includes a set number of minutes of '
            'translated speech per billing period. Minutes are consumed only '
            'while Sayvo is translating what somebody said — listening to a '
            'silent room, waiting, and playing a translation aloud all cost '
            'nothing. Unused minutes do not carry over to the next period.\n\n'
            'Payment is charged to your store account at confirmation of '
            'purchase. Your subscription renews automatically unless it is '
            'cancelled at least 24 hours before the end of the current '
            'period. You can manage or cancel your subscription in your store '
            'account settings at any time.\n\n'
            'Live translation requires an internet connection. Audio is '
            'streamed securely for translation and is never stored.',
            style: TextStyle(height: 1.6, color: AppColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.product,
    required this.selected,
    required this.recommended,
    required this.onTap,
  });

  final SayvoPlan plan;
  final ProductDetails? product;
  final bool selected;
  final bool recommended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        selected: selected,
        label: '${planDisplayName(plan)}, ${planMinutes(plan)} minutes of '
            'translated speech a month',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: selected
                    ? AppColors.primaryBlue.withValues(alpha: 0.16)
                    : AppColors.glassFill,
                border: Border.all(
                  color: selected
                      ? AppColors.primaryBlue.withValues(alpha: 0.65)
                      : AppColors.glassBorder,
                  width: selected ? 1.6 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected
                        ? AppColors.electricCyan
                        : AppColors.textTertiary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(planDisplayName(plan),
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                            ),
                            if (recommended) ...[
                              const SizedBox(width: 8),
                              const _RecommendedChip(),
                            ],
                          ],
                        ),
                        Text('${planMinutes(plan)} min translated speech / month',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // The store's localized price, verbatim.
                  Text(
                    product?.price ?? '—',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
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

class _RecommendedChip extends StatelessWidget {
  const _RecommendedChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text('Recommended',
          style: TextStyle(
              color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
    );
  }
}

/// Small helper the rest of the app uses for the glass "plan" tiles.
class PlanSummaryCard extends StatelessWidget {
  const PlanSummaryCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AppGlassCard(child: child);
}
