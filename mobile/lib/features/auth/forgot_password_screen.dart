import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import 'auth_widgets.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final success = await context.read<AuthController>().sendPasswordReset(_email.text);
    if (success && mounted) setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return AuthScaffold(
      title: 'Reset your password',
      subtitle: _sent
          ? 'Check your inbox — we sent a reset link to ${_email.text.trim()}.'
          : "Enter your account's email and we'll send you a reset link.",
      children: [
        AuthErrorText(auth.errorMessage),
        if (!_sent)
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline_rounded),
                  ),
                  validator: (value) => (value == null || !value.contains('@'))
                      ? 'Enter a valid email address'
                      : null,
                ),
                const SizedBox(height: 16),
                BusyFilledButton(busy: auth.busy, onPressed: _submit, label: 'Send Reset Link'),
              ],
            ),
          )
        else
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to Sign In'),
          ),
      ],
    );
  }
}
