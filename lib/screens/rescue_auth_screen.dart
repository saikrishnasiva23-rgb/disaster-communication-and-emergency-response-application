import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/audit_event.dart';
import '../services/auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/rescue_platform.dart';
import '../state/audit_log_state.dart';
import '../state/auth_state.dart';
import 'rescue_command_center_screen.dart';
import 'rescue_home_screen.dart';

/// Gates access to the Rescue Team dashboard. On first run (no stored
/// credential) it collects a new Rescue ID/password and stores them via
/// AuthService (flutter_secure_storage) -- never a literal comparison in
/// source. On later runs it requires the real password.
class RescueAuthScreen extends StatefulWidget {
  const RescueAuthScreen({super.key});

  @override
  State<RescueAuthScreen> createState() => _RescueAuthScreenState();
}

class _RescueAuthScreenState extends State<RescueAuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _checkingSetup = true;
  bool _needsSetup = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkSetupState();
  }

  Future<void> _checkSetupState() async {
    final hasCredentials = await AuthService.instance.hasCredentials();
    if (!mounted) return;
    setState(() {
      _needsSetup = !hasCredentials;
      _checkingSetup = false;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    final id = _idController.text.trim();
    final password = _passwordController.text;

    try {
      if (_needsSetup) {
        await AuthService.instance.setCredentials(id, password);
      } else {
        final ok = await AuthService.instance.verify(id, password);
        if (!ok) {
          setState(() {
            _error = "Incorrect Rescue ID or password.";
            _submitting = false;
          });
          return;
        }
      }

      if (!mounted) return;

      // The Windows console uploads its stored SOS to the cloud backend when
      // online, with the same Rescue Team account (held in memory only).
      if (RescuePlatform.isWindowsRescueConsole) {
        CloudSyncService.instance
          ..setCredentials(id, password)
          ..start();
      }

      context.read<AuthState>().login(id);
      context.read<AuditLogState>().addEvent(
            AuditEvent(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              type: AuditEventType.rescueAuthenticated,
              actorId: id,
              timestamp: DateTime.now(),
              details: _needsSetup
                  ? 'Rescue Team credentials created and authenticated'
                  : 'Rescue Team authenticated',
            ),
          );

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => RescuePlatform.isWindowsRescueConsole
              ? const RescueCommandCenterScreen()
              : const RescueHomeScreen(),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSetup) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _needsSetup ? "Set Up Rescue Access" : "Rescue Team Login",
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_needsSetup)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    "No Rescue Team credentials exist on this device yet. "
                    "Create a Rescue ID and password -- they are stored in "
                    "this device's encrypted secure storage, not in the "
                    "app's source code.",
                  ),
                ),

              TextFormField(
                controller: _idController,
                decoration: const InputDecoration(
                  labelText: "Rescue ID",
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value == null || value.trim().isEmpty)
                        ? "Rescue ID is required"
                        : null,
              ),

              const SizedBox(height: 16),

              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Password",
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.length < 4)
                    ? "Password must be at least 4 characters"
                    : null,
              ),

              if (_needsSetup) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: "Confirm Password",
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value != _passwordController.text
                      ? "Passwords do not match"
                      : null,
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],

              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_needsSetup ? "Create & Continue" : "Login"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
