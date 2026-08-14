import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';

/// Change the PIN issued by the school office.
///
/// The endpoint has existed since P1 and nothing called it, which meant a
/// driver whose PIN was read out to them over the phone could never change it —
/// the office had to reset it. Not queued through the outbox: a credential
/// change must be agreed with the server before the driver believes it, or they
/// sign in tomorrow with a PIN that only ever existed on the handset.
class ChangePinScreen extends ConsumerStatefulWidget {
  const ChangePinScreen({super.key});

  @override
  ConsumerState<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends ConsumerState<ChangePinScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final api = ref.read(driverApiProvider);
    if (api == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await api.post('/pin', {
      'current_pin': _current.text,
      'pin': _next.text,
      'pin_confirmation': _confirm.text,
    });

    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _busy = false;
        _error = result.message ?? 'Could not change your PIN. Please try again.';
      });
      return;
    }

    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('PIN updated. Use the new one next time you sign in.'),
      backgroundColor: AppColors.success,
    ));
  }

  InputDecoration _decoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      appBar: AppBar(
        title: const Text('Change PIN',
            style: TextStyle(color: AppColors.textPrimary)),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.danger.withValues(alpha: 0.3)),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: AppColors.danger, fontSize: 13)),
                ),
              TextFormField(
                controller: _current,
                decoration: _decoration('Current PIN'),
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                    color: AppColors.textPrimary, letterSpacing: 4),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Enter your current PIN' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _next,
                decoration: _decoration('New PIN'),
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                    color: AppColors.textPrimary, letterSpacing: 4),
                validator: (v) =>
                    v == null || v.length < 4 ? 'Use at least 4 digits' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _confirm,
                decoration: _decoration('Confirm new PIN'),
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                    color: AppColors.textPrimary, letterSpacing: 4),
                onFieldSubmitted: (_) => _submit(),
                // Checked here as well as on the server so the driver is not
                // told about a typo only after a round trip they may not have
                // signal for.
                validator: (v) =>
                    v != _next.text ? 'The two PINs do not match' : null,
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 54,
                child: ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white),
                        )
                      : const Text('UPDATE PIN',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, letterSpacing: 1)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
