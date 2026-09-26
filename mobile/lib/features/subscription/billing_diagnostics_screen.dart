import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/billing/billing_diagnostics.dart';
import '../../services/billing/subscription_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/plans.dart';
import '../../widgets/components/app_background.dart';
import '../../widgets/components/glass_card.dart';

/// TEMPORARY screen showing exactly how far the last purchase got.
///
/// A TestFlight build has no console, so a purchase that never reaches the
/// backend is indistinguishable from one the backend refused. This puts the
/// whole path on screen — which step said no, and what the store or the
/// callable actually reported — so the failing line can be identified rather
/// than guessed at. Delete it once billing is settled.
class BillingDiagnosticsScreen extends StatefulWidget {
  const BillingDiagnosticsScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const BillingDiagnosticsScreen(),
        ),
      );

  @override
  State<BillingDiagnosticsScreen> createState() =>
      _BillingDiagnosticsScreenState();
}

class _BillingDiagnosticsScreenState extends State<BillingDiagnosticsScreen> {
  String? _backendResult;
  bool _backendOk = false;
  bool _testing = false;

  /// Calls a harmless, read-only callable in the region billing uses. It
  /// proves the project, the region, auth, App Check and the deployment in
  /// one go — everything the purchase path needs before Apple is involved.
  Future<void> _testBackend() async {
    setState(() {
      _testing = true;
      _backendResult = null;
    });
    final buffer = StringBuffer();
    try {
      final app = Firebase.app();
      buffer.writeln('projectId: ${app.options.projectId}');
      final functions = FirebaseFunctions.instanceFor(
        app: app,
        region: SubscriptionService.functionsRegion,
      );
      final result =
          await functions.httpsCallable('getEntitlement').call<Object?>();
      final data = result.data;
      buffer.writeln('callable: getEntitlement OK');
      buffer.write('plan: ${data is Map ? data['plan'] : 'unknown'}');
      _backendOk = app.options.projectId == 'live-translator-b9501';
    } on FirebaseFunctionsException catch (e) {
      _backendOk = false;
      buffer.writeln('callable FAILED');
      buffer.writeln('code: ${e.code}');
      buffer.writeln('message: ${e.message ?? 'none'}');
      buffer.write('details: ${e.details ?? 'none'}');
    } catch (e) {
      _backendOk = false;
      buffer.write('${e.runtimeType}: $e');
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _backendResult = buffer.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    final subscriptions = context.read<SubscriptionService>();
    final projectId = SubscriptionService.firebaseProjectId();
    final projectOk = projectId == 'live-translator-b9501';

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  const BackButton(color: AppColors.textPrimary),
                  Expanded(
                    child: Text('Billing Diagnostics',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: 'Copy all',
                    icon: const Icon(Icons.copy_rounded,
                        color: AppColors.textSecondary),
                    onPressed: () => _copyAll(subscriptions, projectId),
                  ),
                ],
              ),
              Expanded(
                child: ValueListenableBuilder<BillingDiagnostics>(
                  valueListenable: subscriptions.diagnostics,
                  builder: (context, diagnostics, _) => ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                    children: [
                      _Section(title: 'Where it stopped', children: [
                        Text(
                          diagnostics.stoppedAt,
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ]),
                      _Section(title: 'Connection', children: [
                        _Row('Firebase project', projectId,
                            good: projectOk, bad: !projectOk),
                        const _Row('Functions region',
                            SubscriptionService.functionsRegion),
                      ]),
                      _Section(title: 'Purchase path', children: [
                        _Row('Purchase listener attached',
                            _yesNo(diagnostics.listenerAttached),
                            good: diagnostics.listenerAttached,
                            bad: !diagnostics.listenerAttached),
                        _Row('Purchase requested',
                            _yesNo(diagnostics.buyRequested)),
                        if (diagnostics.buyProductId != null)
                          _Row('Requested product', diagnostics.buyProductId!),
                        if (diagnostics.buyError != null)
                          _Row('Store refused the request',
                              diagnostics.buyError!,
                              bad: true),
                        _Row('Purchase received',
                            _yesNo(diagnostics.purchaseReceived),
                            good: diagnostics.purchaseReceived,
                            bad: diagnostics.buyRequested &&
                                !diagnostics.purchaseReceived),
                        _Row('Purchase status',
                            diagnostics.purchaseStatus ?? '—'),
                        _Row('Product ID', diagnostics.productId ?? '—'),
                        _Row(
                          'Purchase ID exists',
                          diagnostics.purchaseIdExists == null
                              ? '—'
                              : _yesNo(diagnostics.purchaseIdExists!),
                          bad: diagnostics.purchaseIdExists == false,
                        ),
                      ]),
                      _Section(title: 'Verification', children: [
                        _Row('verifySubscriptionPurchase called',
                            _yesNo(diagnostics.callableCalled),
                            good: diagnostics.callableCalled,
                            bad: diagnostics.purchaseReceived &&
                                !diagnostics.callableCalled),
                        _Row('Callable result',
                            diagnostics.callableResult ?? '—',
                            good: diagnostics.callableResult == 'success',
                            bad: diagnostics.callableResult == 'failure'),
                        _Row('Error code', diagnostics.errorCode ?? '—'),
                        _Row('Error message', diagnostics.errorMessage ?? '—'),
                        _Row('Error details', diagnostics.errorDetails ?? '—'),
                        if (diagnostics.clientReason != null)
                          _Row('Why it was not called',
                              diagnostics.clientReason!,
                              bad: true),
                      ]),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _testing ? null : _testBackend,
                        icon: _testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.cloud_sync_rounded),
                        label: const Text('Test Backend Connection'),
                      ),
                      if (_backendResult != null) ...[
                        const SizedBox(height: 10),
                        _Section(
                          title: _backendOk
                              ? 'Connected to live-translator-b9501'
                              : 'Backend test result',
                          children: [
                            SelectableText(
                              _backendResult!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Expected product ids:\n'
                        '${kAllProductIds.toList().join('\n')}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copyAll(SubscriptionService subscriptions, String projectId) {
    final d = subscriptions.diagnostics.value;
    final text = StringBuffer()
      ..writeln('Firebase project: $projectId')
      ..writeln('Functions region: ${SubscriptionService.functionsRegion}')
      ..writeln('Listener attached: ${_yesNo(d.listenerAttached)}')
      ..writeln('Purchase requested: ${_yesNo(d.buyRequested)} '
          '(${d.buyProductId ?? '—'})')
      ..writeln('Buy error: ${d.buyError ?? 'none'}')
      ..writeln('Purchase received: ${_yesNo(d.purchaseReceived)}')
      ..writeln('Purchase status: ${d.purchaseStatus ?? '—'}')
      ..writeln('Product ID: ${d.productId ?? '—'}')
      ..writeln('Purchase ID exists: '
          '${d.purchaseIdExists == null ? '—' : _yesNo(d.purchaseIdExists!)}')
      ..writeln('Callable called: ${_yesNo(d.callableCalled)}')
      ..writeln('Callable result: ${d.callableResult ?? '—'}')
      ..writeln('Error code: ${d.errorCode ?? '—'}')
      ..writeln('Error message: ${d.errorMessage ?? '—'}')
      ..writeln('Error details: ${d.errorDetails ?? '—'}')
      ..writeln('Client reason: ${d.clientReason ?? '—'}')
      ..writeln('Stopped at: ${d.stoppedAt}')
      ..write('Backend test: ${_backendResult ?? 'not run'}');
    Clipboard.setData(ClipboardData(text: text.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied.')),
    );
  }
}

String _yesNo(bool value) => value ? 'yes' : 'no';

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppGlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textTertiary,
                  )),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.good = false, this.bad = false});
  final String label;
  final String value;
  final bool good;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final color = bad
        ? AppColors.danger
        : good
            ? AppColors.electricCyan
            : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
