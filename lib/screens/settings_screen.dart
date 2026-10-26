import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../services/affected_identity_service.dart';
import '../services/affected_peripheral_service.dart';
import '../services/relay_service.dart';
import '../state/auth_state.dart';
import '../state/theme_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/status_badge.dart';
import 'blockchain_log_screen.dart';
import 'legacy_rescue_link_screen.dart';
import 'network_log_screen.dart';

/// Settings. Every row here is connected to something real: the saved
/// theme, the relay preference, the device identity, the location
/// permission. Diagnostics are kept in their own section.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.showRelayOption = false});

  /// Affected-person phones: show the "Relay nearby alerts" switch.
  final bool showRelayOption;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  String? _deviceName;
  bool? _locationOn;
  LocationPermission? _permission;
  bool _relayBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.showRelayOption) _loadDeviceName();
    _checkLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The user may change location settings in the system app and come back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkLocation();
  }

  Future<void> _loadDeviceName() async {
    try {
      final name = await AffectedIdentityService.getDisplayName();
      if (mounted) setState(() => _deviceName = name);
    } catch (_) {}
  }

  Future<void> _checkLocation() async {
    bool on;
    LocationPermission? permission;
    try {
      on = await Geolocator.isLocationServiceEnabled();
      permission = await Geolocator.checkPermission();
    } catch (_) {
      on = false;
    }
    if (!mounted) return;
    setState(() {
      _locationOn = on;
      _permission = permission;
    });
  }

  Future<void> _fixLocation() async {
    try {
      if (_locationOn == false) {
        await Geolocator.openLocationSettings();
      } else if (_permission == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
      } else {
        await Geolocator.requestPermission();
      }
    } catch (_) {}
    await _checkLocation();
  }

  Future<void> _setRelay(bool on) async {
    setState(() => _relayBusy = true);
    try {
      await RelayService.instance.setForwarding(on);
      AffectedPeripheralService.instance.refresh();
    } finally {
      if (mounted) setState(() => _relayBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final rescueId = context.watch<AuthState>().rescueId;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.sm,
          AppSpacing.page,
          AppSpacing.xl + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const _Heading('Appearance'),
          _Group(children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Theme', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('System'),
                          icon: Icon(Icons.brightness_auto_outlined),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Light'),
                          icon: Icon(Icons.light_mode_outlined),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Dark'),
                          icon: Icon(Icons.dark_mode_outlined),
                        ),
                      ],
                      selected: {theme.mode},
                      onSelectionChanged: (s) => theme.setMode(s.first),
                    ),
                  ),
                ],
              ),
            ),
          ]),
          if (widget.showRelayOption) ...[
            const _Heading('Emergency'),
            _Group(children: [
              ValueListenableBuilder<AffectedLinkStatus>(
                valueListenable: AffectedPeripheralService.instance.status,
                builder: (context, link, _) => SwitchListTile(
                  secondary: const Icon(Icons.alt_route),
                  title: const Text('Relay nearby alerts'),
                  subtitle: const Text('Pass on SOS from nearby phones'),
                  value: link.relayForwarding,
                  onChanged: _relayBusy ? null : _setRelay,
                ),
              ),
            ]),
          ],
          const _Heading('Profile'),
          _Group(children: [
            if (widget.showRelayOption)
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: const Text('This device'),
                subtitle: Text(_deviceName ?? 'Loading...'),
              ),
            if (rescueId != null)
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Rescue ID'),
                subtitle: Text(rescueId),
              ),
            if (!widget.showRelayOption && rescueId == null)
              const ListTile(
                leading: Icon(Icons.person_outline),
                title: Text('Not signed in'),
              ),
          ]),
          const _Heading('Location'),
          _Group(children: [_locationTile(context)]),
          const _Heading('Diagnostics'),
          _Group(children: [
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Network Log'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NetworkLogScreen()),
              ),
            ),
            const Divider(indent: AppSpacing.lg, endIndent: AppSpacing.lg),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Event Log'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BlockchainLogScreen()),
              ),
            ),
            if (widget.showRelayOption && !kIsWeb && Platform.isAndroid) ...[
              const Divider(indent: AppSpacing.lg, endIndent: AppSpacing.lg),
              ListTile(
                leading: const Icon(Icons.bluetooth_searching),
                title: const Text('Legacy rescue phone link'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LegacyRescueLinkScreen()),
                ),
              ),
            ],
          ]),
          const _Heading('About'),
          const _Group(children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Disaster Response'),
              subtitle: Text('Version 1.0.0'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _locationTile(BuildContext context) {
    final checked = _locationOn != null;
    final denied = _permission == LocationPermission.denied ||
        _permission == LocationPermission.deniedForever;
    final (String label, StatusTone tone, String? action) = !checked
        ? ('Checking...', StatusTone.neutral, null)
        : _locationOn == false
            ? ('Off', StatusTone.danger, 'Turn on')
            : denied
                ? ('Permission needed', StatusTone.warning, 'Allow')
                : ('On', StatusTone.success, null);
    return ListTile(
      leading: const Icon(Icons.location_on_outlined),
      title: const Text('Location'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: StatusBadge(label: label, tone: tone),
        ),
      ),
      trailing: action == null
          ? null
          : TextButton(onPressed: _fixLocation, child: Text(action)),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.lg, 0, AppSpacing.sm),
      child: Semantics(
        header: true,
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
              ),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
