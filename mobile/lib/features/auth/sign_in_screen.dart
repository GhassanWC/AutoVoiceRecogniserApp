import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_controller.dart';
import 'auth_widgets.dart';
import 'forgot_password_screen.dart';
import 'sign_up_screen.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await context.read<AuthController>().signInWithEmail(_email.text, _password.text);
    // Success navigates via AuthGate; failure shows errorMessage below.
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return AuthScaffold(
      showBack: false,
      title: 'Welcome back',
      subtitle: 'Sign in to translate the world around you.',
      children: [
        AuthErrorText(auth.errorMessage),
        SocialSignInButtons(
          busy: auth.busy,
          onGoogle: () => context.read<AuthController>().signInWithGoogle(),
          onApple: () => context.read<AuthController>().signInWithApple(),
        ),
        const SizedBox(height: 18),
        const OrDivider(),
        const SizedBox(height: 18),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
                validator: (value) => (value == null || !value.contains('@'))
                    ? 'Enter a valid email address'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (value) =>
                    (value == null || value.isEmpty) ? 'Enter your password' : null,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => const ForgotPasswordScreen()),
                  ),
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: 4),
              BusyFilledButton(busy: auth.busy, onPressed: _submit, label: 'Sign In'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const SignUpScreen()),
          ),
          child: const Text("Don't have an account? Sign Up"),
        ),
      ],
    );
  }
}
