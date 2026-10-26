import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../models/ai_priority_result.dart';
import '../services/affected_identity_service.dart';
import '../services/affected_peripheral_service.dart';
import '../services/mesh/android_peripheral_transport.dart';
import '../services/native_bridge.dart';
import '../services/relay_service.dart';
import '../services/sos_service.dart';
import '../state/audit_log_state.dart';
import '../state/ble_state.dart';
import '../state/emergency_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/hold_sos_button.dart';
import '../widgets/priority_badge.dart';
import '../widgets/quick_action_card.dart';
import '../widgets/section_header.dart';
import '../widgets/status_badge.dart';
import 'activity_screen.dart';
import 'ai_alert_screen.dart';
import 'chat_screen.dart';
import 'emergency_contacts.dart';
import 'hospitals_screen.dart';
import 'map_screen.dart';
import 'nearby_devices.dart';
import 'relief_camps_screen.dart';
import 'request_rescue_screen.dart';
import 'settings_screen.dart';

/// Affected Person: Home (SOS), Nearby, Messages and Settings.
///
/// This widget owns the phone's emergency link for as long as the affected
/// screens are open: it starts advertising + scanning on entry and stops
/// them on exit. Every status shown comes from a real source --
/// AffectedPeripheralService.status for the link, SosService.current for
/// the request (only "Received" after the Rescue Team's real ACK), and
/// Geolocator for location.
class AffectedHomeScreen extends StatefulWidget {
  const AffectedHomeScreen({super.key});

  @override
  State<AffectedHomeScreen> createState() => _AffectedHomeScreenState();
}

class _AffectedHomeScreenState extends State<AffectedHomeScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    NativeBridge.setKeepScreenOn(true);
    AffectedPeripheralService.instance.start();
    _restoreRelayMode();
  }

  /// Relay forwarding is ON unless the user turned it off (remembered).
  Future<void> _restoreRelayMode() async {
    final saved = await RelayService.instance.savedPreference();
    if (!mounted) return;
    await RelayService.instance.setForwarding(saved);
    AffectedPeripheralService.instance.refresh();
  }

  @override
  void dispose() {
    NativeBridge.setKeepScreenOn(false);
    // Stops advertising AND scanning; the relay choice is kept.
    AffectedPeripheralService.instance.stop();
    super.dispose();
  }

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.radar_outlined, Icons.radar, 'Nearby'),
    (Icons.chat_bubble_outline, Icons.chat_bubble, 'Messages'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  void _select(int index) => setState(() => _tab = index);

  @override
  Widget build(BuildContext context) {
    final pages = [
      _HomeTab(onOpenNearby: () => _select(1)),
      const NearbyDevicesScreen(),
      const ChatScreen(),
      const SettingsScreen(showRelayOption: true),
    ];
    final body = IndexedStack(index: _tab, children: pages);

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 840) {
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in _destinations)
                      NavigationRailDestination(
                        icon: Icon(d.$1),
                        selectedIcon: Icon(d.$2),
                        label: Text(d.$3),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _select,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.$1),
                selectedIcon: Icon(d.$2),
                label: d.$3,
              ),
          ],
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Home tab
// ---------------------------------------------------------------------------

class _HomeTab extends StatefulWidget {
  const _HomeTab({required this.onOpenNearby});

  final VoidCallback onOpenNearby;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  /// Wire value -> chip label. The wire values are what the Rescue Team
  /// console and the cloud backend understand ('General Emergency' = OTHER).
  static const _emergencyTypes = <String, String>{
    'General Emergency': 'Other',
    'Medical Emergency': 'Medical',
    'Fire Emergency': 'Fire',
    'Flood Emergency': 'Flood',
    'Earthquake': 'Earthquake',
    'Cyclone': 'Cyclone',
    'Landslide': 'Landslide',
    'Trapped Person': 'Trapped',
  };

  final TextEditingController _messageController = TextEditingController();
  String _emergencyType = 'General Emergency';

  String? _deviceName;
  bool? _locationServiceEnabled;
  LocationPermission? _locationPermission;

  @override
  void initState() {
    super.initState();
    _loadDeviceName();
    _checkLocation();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadDeviceName() async {
    try {
      final name = await AffectedIdentityService.getDisplayName();
      if (mounted) setState(() => _deviceName = name);
    } catch (_) {
      // Shown as unknown; the SOS flow reports its own error if needed.
    }
  }

  Future<void> _checkLocation() async {
    bool enabled;
    LocationPermission? permission;
    try {
      enabled = await Geolocator.isLocationServiceEnabled();
      permission = await Geolocator.checkPermission();
    } catch (_) {
      // No platform implementation (e.g. a widget test) or a transient
      // platform error -- reported honestly as unavailable.
      enabled = false;
    }
    if (!mounted) return;
    setState(() {
      _locationServiceEnabled = enabled;
      _locationPermission = permission;
    });
  }

  Future<void> _sendSos() async {
    FocusScope.of(context).unfocus();
    await SosService.instance.send(
      emergencyState: context.read<EmergencyState>(),
      auditLog: context.read<AuditLogState>(),
      bleState: context.read<BleState>(),
      message: _messageController.text,
      emergencyType: _emergencyType,
    );
    if (mounted) _checkLocation();
  }

  void _open(Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _checkLocation,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
                AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xl + bottomInset),
            children: [
              _header(context),
              const SizedBox(height: AppSpacing.md),
              ValueListenableBuilder<AffectedLinkStatus>(
                valueListenable: AffectedPeripheralService.instance.status,
                builder: (context, link, _) => _StatusCard(link: link),
              ),
              const SizedBox(height: AppSpacing.md),
              _sosCard(context),
              ValueListenableBuilder<SosRequestState>(
                valueListenable: SosService.instance.current,
                builder: (context, request, _) => request.phase == SosRequestPhase.idle
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.md),
                        child: _RequestStatusCard(
                          request: request,
                          onTap: () => _open(const ActivityScreen()),
                        ),
                      ),
              ),
              const SizedBox(height: AppSpacing.md),
              ValueListenableBuilder<AffectedLinkStatus>(
                valueListenable: AffectedPeripheralService.instance.status,
                builder: (context, link, _) =>
                    _NearbyCard(link: link, onTap: widget.onOpenNearby),
              ),
              ValueListenableBuilder<SosRequestState>(
                valueListenable: SosService.instance.current,
                builder: (context, request, _) => request.priority == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.md),
                        child: _PriorityCard(
                          level: aiPriorityFromString(request.priority!),
                          onTap: () => _open(const AIAlertScreen()),
                        ),
                      ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const SectionHeader(title: 'Quick Actions'),
              _quickActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Stay safe', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(
                _deviceName ?? 'This device',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'SOS history',
          onPressed: () => _open(const ActivityScreen()),
          icon: const Icon(Icons.history),
        ),
      ],
    );
  }

  Widget _sosCard(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Emergency type', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final entry in _emergencyTypes.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _emergencyType == entry.key,
                  onSelected: (_) => setState(() => _emergencyType = entry.key),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _messageController,
            maxLength: 120,
            maxLines: 2,
            minLines: 1,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Message (optional)',
              hintText: 'e.g. Two people trapped on the 2nd floor',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final size = (constraints.maxWidth * 0.55).clamp(150.0, 196.0);
              return Center(
                child: ValueListenableBuilder<SosRequestState>(
                  valueListenable: SosService.instance.current,
                  builder: (context, request, _) => HoldSosButton(
                    size: size,
                    busy: request.isBusy,
                    busyLabel: 'LOCATING...',
                    onTriggered: _sendSos,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          _locationLine(context),
          ValueListenableBuilder<AffectedLinkStatus>(
            valueListenable: AffectedPeripheralService.instance.status,
            builder: (context, link, _) => link.isGattReady
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      'Saved and sent when a device connects',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _locationLine(BuildContext context) {
    final checked = _locationServiceEnabled != null;
    final enabled = _locationServiceEnabled ?? false;
    final denied = _locationPermission == LocationPermission.denied ||
        _locationPermission == LocationPermission.deniedForever;

    final (String text, StatusTone tone, IconData icon) = !checked
        ? ('Checking location...', StatusTone.neutral, Icons.location_searching)
        : !enabled
            ? ('Location off · SOS sends without GPS', StatusTone.danger, Icons.location_off)
            : denied
                ? ('Location permission needed', StatusTone.warning, Icons.location_disabled)
                : ('Location on', StatusTone.success, Icons.location_on);
    final color = tone.color(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _quickActions(BuildContext context) {
    final s = context.status;
    Widget tile(IconData icon, String title, Widget screen, Color color) => QuickActionCard(
          icon: icon,
          title: title,
          iconColor: color,
          onTap: () => _open(screen),
        );

    return ResponsiveTileGrid(children: [
      tile(Icons.my_location, 'My Location', const MapScreen(), s.info),
      tile(Icons.psychology_alt_outlined, 'AI Priority', const AIAlertScreen(), s.high),
      tile(Icons.local_hospital_outlined, 'Hospitals', const HospitalsScreen(), s.danger),
      tile(Icons.cabin_outlined, 'Relief Camps', const ReliefCampsScreen(), s.success),
      tile(Icons.contact_phone_outlined, 'Contacts', const EmergencyContactsScreen(), s.info),
      tile(Icons.assignment_outlined, 'Request Rescue', const RequestRescueScreen(), s.warning),
      tile(Icons.history, 'SOS History', const ActivityScreen(), s.neutral),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

/// Emergency status, derived only from the real link state.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.link});

  final AffectedLinkStatus link;

  Future<void> _turnOnBluetooth() async {
    await AndroidPeripheralTransport.enableBluetooth();
    await AffectedPeripheralService.instance.start();
  }

  @override
  Widget build(BuildContext context) {
    final String title;
    final String subtitle;
    final StatusTone tone;
    final IconData icon;
    var busy = false;
    Widget? action;

    switch (link.phase) {
      case AffectedLinkPhase.stopped:
      case AffectedLinkPhase.starting:
        title = 'Starting';
        subtitle = 'Getting ready...';
        tone = StatusTone.neutral;
        icon = Icons.bluetooth;
        busy = true;
      case AffectedLinkPhase.unsupported:
        title = 'Offline';
        subtitle = 'Bluetooth is not available on this device';
        tone = StatusTone.danger;
        icon = Icons.bluetooth_disabled;
      case AffectedLinkPhase.permissionDenied:
        title = 'Offline';
        subtitle = 'Allow Nearby devices permission';
        tone = StatusTone.warning;
        icon = Icons.bluetooth_disabled;
        action = TextButton(
          onPressed: AndroidPeripheralTransport.openAppSettings,
          child: const Text('Allow'),
        );
      case AffectedLinkPhase.bluetoothOff:
        title = 'Offline';
        subtitle = 'Bluetooth is off';
        tone = StatusTone.danger;
        icon = Icons.bluetooth_disabled;
        action = TextButton(onPressed: _turnOnBluetooth, child: const Text('Turn on'));
      case AffectedLinkPhase.advertiseFailed:
        title = 'Limited';
        subtitle = 'Other devices cannot find this phone';
        tone = StatusTone.warning;
        icon = Icons.bluetooth_disabled;
        action = TextButton(
          onPressed: AffectedPeripheralService.instance.start,
          child: const Text('Retry'),
        );
      case AffectedLinkPhase.advertising:
        title = 'Searching';
        subtitle = 'No device connected yet';
        tone = StatusTone.info;
        icon = Icons.bluetooth_searching;
        busy = true;
      case AffectedLinkPhase.linked:
        title = 'Connecting';
        subtitle = 'A nearby device is connecting';
        tone = StatusTone.warning;
        icon = Icons.bluetooth_searching;
        busy = true;
      case AffectedLinkPhase.gattReady:
        title = 'Connected';
        subtitle = link.rescueLinks > 0
            ? 'Rescue Team in range'
            : 'Via nearby phone · Rescue Team not in range';
        tone = StatusTone.success;
        icon = Icons.bluetooth_connected;
      case AffectedLinkPhase.stale:
        title = 'Not responding';
        subtitle = 'The connected device stopped responding';
        tone = StatusTone.warning;
        icon = Icons.link_off;
    }

    final theme = Theme.of(context);
    final color = tone.color(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          IconBadge(icon: icon, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Emergency Status', style: theme.textTheme.bodySmall),
                Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ?action,
        ],
      ),
    );
  }
}

/// Connected devices (real identified links only) and a way to the Nearby tab.
class _NearbyCard extends StatelessWidget {
  const _NearbyCard({required this.link, required this.onTap});

  final AffectedLinkStatus link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = link.peers.length;
    final rescue = link.peers.any((p) => p.isRescue);
    return AppCard(
      onTap: onTap,
      semanticLabel: 'Nearby Devices',
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          IconBadge(icon: Icons.radar, color: context.status.info),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nearby Devices', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  count == 0 ? 'No devices connected' : '$count connected',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (rescue)
            const StatusBadge(
              label: 'Rescue Team',
              tone: StatusTone.success,
              icon: Icons.shield_outlined,
            ),
          const SizedBox(width: AppSpacing.xs),
          Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// The sender's own local estimate for the latest SOS.
class _PriorityCard extends StatelessWidget {
  const _PriorityCard({required this.level, required this.onTap});

  final AiPriorityLevel level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          IconBadge(
            icon: Icons.psychology_alt_outlined,
            color: PriorityBadge.colorOf(context, level),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Current Priority', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text('Local estimate', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          PriorityBadge(level: level),
          const SizedBox(width: AppSpacing.xs),
          Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// The latest SOS request, driven by SosService.
class _RequestStatusCard extends StatelessWidget {
  const _RequestStatusCard({required this.request, required this.onTap});

  final SosRequestState request;
  final VoidCallback onTap;

  /// Short label, tone and the step reached (0-4) for each real phase.
  (String, String?, StatusTone, IconData, int) _present() {
    switch (request.phase) {
      case SosRequestPhase.locating:
        return ('Getting location...', null, StatusTone.info, Icons.my_location, 0);
      case SosRequestPhase.queued:
        return ('Saved', 'Sends when a device connects', StatusTone.warning, Icons.save_outlined, 0);
      case SosRequestPhase.sentToRelay:
        return ('Sent', 'Waiting for confirmation', StatusTone.warning, Icons.north_east, 1);
      case SosRequestPhase.relayed:
        return ('Passed to a nearby phone', 'On its way to the Rescue Team', StatusTone.info,
            Icons.alt_route, 2);
      case SosRequestPhase.receivedByRescue:
        return ('Received by Rescue Team', null, StatusTone.success, Icons.check_circle, 3);
      case SosRequestPhase.acknowledged:
        return ('Acknowledged', null, StatusTone.success, Icons.verified, 4);
      case SosRequestPhase.failed:
        return ('Not delivered', 'Try sending again', StatusTone.danger, Icons.error_outline, -1);
      case SosRequestPhase.idle:
        return ('', null, StatusTone.neutral, Icons.sos, -1);
    }
  }

  static const _steps = ['Saved', 'Sent', 'Relayed', 'Received', 'Acknowledged'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, hint, tone, icon, step) = _present();
    final color = tone.color(context);
    final spinner = request.phase == SosRequestPhase.locating ||
        request.phase == SosRequestPhase.queued ||
        request.phase == SosRequestPhase.sentToRelay ||
        request.phase == SosRequestPhase.relayed;
    final subtitle = request.rescueUpdate ?? hint;

    return AppCard(
      onTap: onTap,
      borderColor: color.withValues(alpha: 0.45),
      semanticLabel: 'SOS status: $label',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SOS Status', style: theme.textTheme.bodySmall),
                    Text(
                      label,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: color, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              if (spinner)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(subtitle, style: theme.textTheme.bodyMedium),
          ],
          if (step >= 0 && request.phase != SosRequestPhase.locating) ...[
            const SizedBox(height: AppSpacing.md),
            _StepBar(steps: _steps, reached: step, color: color),
          ],
        ],
      ),
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.steps, required this.reached, required this.color});

  final List<String> steps;
  final int reached;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idle = theme.colorScheme.outlineVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= reached ? color : idle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Step ${reached + 1} of ${steps.length} · ${steps[reached]}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
