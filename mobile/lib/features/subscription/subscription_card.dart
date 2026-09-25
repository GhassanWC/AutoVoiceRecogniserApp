import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/billing/entitlement_controller.dart';
import '../../services/billing/subscription_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/plans.dart';
import '../../widgets/components/glass_card.dart';
import 'paywall_screen.dart';

/// The plan block in Profile. Everything shown — plan, minutes, renewal date —
/// comes from the server's entitlement, never from a local guess.
class SubscriptionCard extends StatelessWidget {
  const SubscriptionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.watch<EntitlementController>();
    final entitlement = controller.entitlement;
    final paid = entitlement.isPaid;
    // The displayed figures fold in translated speech this device has
    // committed but not yet reported, so usage moves while somebody is
    // speaking instead of jumping when the batched report lands.
    final remaining = controller.displayedRemainingMs;
    final used = controller.displayedUsedMs;
    final total = entitlement.totalMs;
    final progress = total <= 0 ? 0.0 : (used / total).clamp(0.0, 1.0);

    return AppGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: paid ? AppColors.primaryGradient : null,
                  color: paid ? null : AppColors.glassFillStrong,
                ),
                child: Icon(
                  paid ? Icons.workspace_premium_rounded : Icons.bolt_rounded,
                  size: 20,
                  color: paid ? Colors.white : AppColors.electricCyan,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paid ? planDisplayName(entitlement.plan) : 'Free',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      paid
                          ? '${planMinutes(entitlement.plan)} min translated '
                              'speech / month'
                          : 'Free — $kFreeLifetimeMinutes min translated '
                              'speech, one time',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: AppColors.glassFillStrong,
              valueColor: AlwaysStoppedAnimation<Color>(
                remaining <= 0 ? AppColors.danger : AppColors.electricCyan,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Exactly what was spent and exactly what is left, to the second —
          // translated speech only, never microphone time.
          Text(
            '${formatSpeechDuration(used)} of ${formatSpeechDuration(total)} used',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '${formatSpeechDuration(remaining)} remaining',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textSecondary),
          ),
          if (paid && entitlement.currentPeriodEnd != null) ...[
            const SizedBox(height: 4),
            Text(
              // Real entitlement data, not a calendar assumption.
              '${entitlement.subscriptionStatus == 'active' ? 'Renews' : 'Ends'} '
              '${DateFormat.yMMMMd().format(entitlement.currentPeriodEnd!)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 14),
          if (paid)
            OutlinedButton(
              onPressed: () => context
                  .read<SubscriptionService>()
                  .openManageSubscription(productId: entitlement.storeProductId),
              child: const Text('Manage Subscription'),
            )
          else
            FilledButton(
              onPressed: () => PaywallScreen.show(context),
              child: const Text('Upgrade Sayvo'),
            ),
        ],
      ),
    );
  }
}
