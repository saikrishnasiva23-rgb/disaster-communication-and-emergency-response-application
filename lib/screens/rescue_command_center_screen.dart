import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/backend_config.dart';
import '../models/affected_device_connection.dart';
import '../models/ai_priority_result.dart';
import '../models/audit_event.dart';
import '../models/emergency_message.dart';
import '../models/rescue_case.dart';
import '../services/cloud_sync_service.dart';
import '../services/rescue_workflow.dart';
import '../services/windows_ble_central_service.dart';
import '../state/audit_log_state.dart';
import '../state/auth_state.dart';
import '../state/emergency_state.dart';
import '../theme/app_colors.dart';
import '../widgets/priority_badge.dart';
import '../widgets/section_header.dart';
import '../widgets/state_views.dart';
import 'blockchain_log_screen.dart';
import 'network_log_screen.dart';
import 'rescue_dashboard_screen.dart';
import 'role_selection_screen.dart';
import 'settings_screen.dart';

/// The Rescue Team's Windows command center -- the primary Rescue Team UI.
///
/// Windows is BLE CENTRAL ONLY (WindowsBleCentralService): it scans for the
/// shared rescue service, connects to each affected phone independently,
/// subscribes to its SOS notifications and writes ACK/STATUS back. Every
/// value on this screen comes from those real BLE events or from a real
/// HTTP request -- no placeholder devices, counters or alerts.
class RescueCommandCenterScreen extends StatefulWidget {
  const RescueCommandCenterScreen({super.key});

  @override
  State<RescueCommandCenterScreen> createState() =>
      _RescueCommandCenterScreenState();
}

class _RescueCommandCenterScreenState extends State<RescueCommandCenterScreen>
    with SingleTickerProviderStateMixin {
  final WindowsBleCentralService _central = WindowsBleCentralService.instance;

  List<dynamic> _backendRequests = [];
  bool _backendLoading = true;

  /// Real outcome of the last backend request -- null until one finishes.
  bool? _backendReachable;

  List<AffectedDeviceConnection> _devices = [];
  String? _scanError;
  bool _scanStarting = true;

  StreamSubscription<InboundSos>? _sosSubscription;
  StreamSubscription<EmergencyMessage>? _messageSubscription;
  StreamSubscription<List<AffectedDeviceConnection>>? _devicesSubscription;
  StreamSubscription<AckResult>? _ackSubscription;

  /// Keeps "last seen 12 s ago" honest without a rebuild per BLE event.
  Timer? _clockTicker;

  late final AnimationController _newAlertFlash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  String? _highlightCaseId;

  @override
  void initState() {
    super.initState();

    _devices = _central.currentDevices;
    _devicesSubscription = _central.devices.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    _sosSubscription = _central.onSosReceived.listen(_onSosReceived);
    _messageSubscription = _central.onMessageReceived.listen(_onMessageReceived);
    _ackSubscription = _central.onAckResult.listen(_onAckResult);

    _clockTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });

    _startScan();
    _fetchBackendRequests();
  }

  @override
  void dispose() {
    _sosSubscription?.cancel();
    _messageSubscription?.cancel();
    _devicesSubscription?.cancel();
    _ackSubscription?.cancel();
    _clockTicker?.cancel();
    _newAlertFlash.dispose();
    // Stops scanning only -- already-connected phones stay connected.
    _central.stopScan();
    super.dispose();
  }

  String get _rescueId => context.read<AuthState>().rescueId ?? 'rescue_team';

  // ---------------------------------------------------------------------------
  // Real events
  // ---------------------------------------------------------------------------

  /// The console service already stored this SOS, created its case and
  /// recorded the audit entry before this fires -- the screen only
  /// highlights it.
  void _onSosReceived(InboundSos inbound) {
    if (!mounted) return;
    final packet = inbound.packet;
    final rescueCase = context
        .read<EmergencyState>()
        .rescueCases
        .where((c) => c.id == packet.id)
        .firstOrNull;
    final level = rescueCase?.aiPriority?.level.name.toUpperCase() ?? 'UNKNOWN';

    setState(() => _highlightCaseId = packet.id);
    _newAlertFlash.forward(from: 0);

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        backgroundColor: AppColors.emergencyDark,
        content: Text(
          'NEW SOS from ${packet.displayName}'
          '${packet.hopCount > 0 ? ' (via ${packet.relayedByName ?? 'relay'})' : ''} -- '
          '$level priority',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ));
  }

  /// ACK delivery is tracked (and audited) by the console service; the
  /// case card reads it from EmergencyState.
  void _onAckResult(AckResult result) {
    if (mounted) setState(() {});
  }

  void _onMessageReceived(EmergencyMessage message) {
    if (!mounted) return;
    context.read<EmergencyState>().addMessage(message);
    context.read<AuditLogState>().addEvent(AuditEvent(
      id: '${message.id}_received',
      type: AuditEventType.messageReceived,
      actorId: _rescueId,
      timestamp: DateTime.now(),
      details: 'Message ${message.id} received over BLE from ${message.senderId}',
    ));
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _startScan() async {
    setState(() {
      _scanStarting = true;
      _scanError = null;
    });
    final failure = await _central.startScan();
    if (!mounted) return;
    setState(() {
      _scanStarting = false;
      _scanError = failure == null ? null : (_central.lastScanError ?? 'Scan failed.');
    });
  }

  void _advance(RescueCase rescueCase) {
    final newStatus = RescueWorkflow.advance(
      emergencyState: context.read<EmergencyState>(),
      auditLog: context.read<AuditLogState>(),
      actorId: _rescueId,
      rescueCase: rescueCase,
    );
    if (newStatus == null) return;

    // Routed back to the origin phone along the path the SOS took -- also
    // through relay phones -- and queued for cloud sync.
    _central.sendStatusUpdate(
      rescueCase.sourceAddress ?? '',
      rescueCase.id,
      RescueWorkflow.statusLabel(newStatus),
    );
  }

  Future<void> _fetchBackendRequests() async {
    setState(() => _backendLoading = true);
    try {
      final response = await http
          .get(Uri.parse(BackendConfig.rescueRequestsListEndpoint))
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _backendRequests = (data is Map && data['requests'] is List)
              ? data['requests'] as List
              : [];
          _backendReachable = true;
        });
      } else {
        setState(() => _backendReachable = false);
      }
    } catch (_) {
      if (mounted) setState(() => _backendReachable = false);
    } finally {
      if (mounted) setState(() => _backendLoading = false);
    }
  }

  Future<void> _viewLocation(double latitude, double longitude) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude',
    );
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open a map for this location.')),
      );
    }
  }

  void _logout() {
    // BLE keeps receiving and storing SOS; uploads pause until next login.
    CloudSyncService.instance
      ..stop()
      ..clearCredentials();
    context.read<AuthState>().logout();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const RoleSelectionScreen()),
      (route) => false,
    );
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final emergencyState = context.watch<EmergencyState>();
    final bleCases = emergencyState.rescueCases
        .where((c) => c.source == RescueCaseSource.ble)
        .toList();
    final messages = emergencyState.messages;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rescue Command Center'),
        actions: [
          IconButton(
            tooltip: 'Rescue status list',
            icon: const Icon(Icons.track_changes),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RescueDashboardScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Tamper-evident event log',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BlockchainLogScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Network log (BLE / relay / sync steps)',
            icon: const Icon(Icons.lan_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NetworkLogScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final header = _header(context, bleCases);
          final devicesPanel = _devicesPanel(context);
          final emergencyPanel = _emergencyPanel(context, bleCases);
          final messagesPanel = _messagesPanel(context, messages);
          final backendPanel = _backendPanel(context);

          if (constraints.maxWidth >= 1050) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: header,
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 400,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 8, 12, 24),
                          children: [devicesPanel],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 20, 24),
                          children: [
                            emergencyPanel,
                            const SizedBox(height: 20),
                            messagesPanel,
                            const SizedBox(height: 12),
                            backendPanel,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              header,
              const SizedBox(height: 16),
              devicesPanel,
              const SizedBox(height: 20),
              emergencyPanel,
              const SizedBox(height: 20),
              messagesPanel,
              const SizedBox(height: 12),
              backendPanel,
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, List<RescueCase> bleCases) {
    final connected = _devices.where((d) => d.isConnected).length;
    final ready = _devices.where((d) => d.isConnected && d.gattReady).length;
    final active =
        bleCases.where((c) => c.status != RescueStatus.rescued).length;
    final scanning = _central.isScanning;

    final bluetoothValue = _scanStarting
        ? 'Starting...'
        : scanning
            ? 'Active'
            : 'Off';
    final bluetoothColor = scanning
        ? AppColors.success
        : (_scanStarting ? AppColors.offline : AppColors.emergency);

    final backendValue = _backendReachable == null
        ? 'Checking...'
        : (_backendReachable! ? 'Online' : 'Unreachable');
    final backendColor = _backendReachable == true
        ? AppColors.success
        : (_backendReachable == null ? AppColors.offline : AppColors.warning);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.shield, color: AppColors.navy, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RESCUE COMMAND CENTER',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                  ),
                  Text(
                    'Rescue Team ONLINE -- signed in as $_rescueIdOrBlank',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _MetricTile(
              icon: Icons.bluetooth,
              label: 'Bluetooth (BLE central)',
              value: bluetoothValue,
              color: bluetoothColor,
              caption: scanning ? 'Scanning for affected phones' : _scanError,
            ),
            _MetricTile(
              icon: Icons.devices,
              label: 'Connected devices',
              value: '$connected',
              color: connected > 0 ? AppColors.success : AppColors.offline,
              caption: '$ready GATT ready',
            ),
            _MetricTile(
              icon: Icons.sos,
              label: 'Emergency requests',
              value: '$active',
              color: active > 0 ? AppColors.emergency : AppColors.offline,
              caption: '${bleCases.length} received over BLE',
            ),
            _MetricTile(
              icon: Icons.psychology_alt,
              label: 'AI priority',
              value: 'Rule-based',
              color: AppColors.success,
              caption: 'Local classifier on this console',
            ),
            _MetricTile(
              icon: Icons.cloud_outlined,
              label: 'Backend (optional)',
              value: backendValue,
              color: backendColor,
              caption: 'Not needed for BLE',
            ),
            ValueListenableBuilder<CloudSyncStatus>(
              valueListenable: CloudSyncService.instance.status,
              builder: (context, sync, _) => _MetricTile(
                icon: Icons.cloud_sync,
                label: 'Cloud sync',
                value: _syncLabel(sync.phase),
                color: _syncColor(sync.phase),
                caption: '${sync.pending} pending - ${sync.synced} synced'
                    '${sync.conflicts > 0 ? ' - ${sync.conflicts} conflict' : ''}'
                    '${sync.lastError != null && sync.phase != CloudSyncPhase.upToDate ? '\n${sync.lastError}' : ''}',
              ),
            ),
          ],
        ),
      ],
    );
  }

  String get _rescueIdOrBlank =>
      context.read<AuthState>().rescueId ?? 'Rescue Team';

  static String _syncLabel(CloudSyncPhase phase) => switch (phase) {
        CloudSyncPhase.notConfigured => 'Not signed in',
        CloudSyncPhase.idle => 'Idle',
        CloudSyncPhase.offline => 'Offline (queued)',
        CloudSyncPhase.authenticating => 'Signing in...',
        CloudSyncPhase.syncing => 'Syncing...',
        CloudSyncPhase.upToDate => 'Up to date',
        CloudSyncPhase.authFailed => 'Login failed',
        CloudSyncPhase.error => 'Error',
      };

  static Color _syncColor(CloudSyncPhase phase) => switch (phase) {
        CloudSyncPhase.upToDate => AppColors.success,
        CloudSyncPhase.syncing || CloudSyncPhase.authenticating || CloudSyncPhase.idle =>
          AppColors.info,
        CloudSyncPhase.offline || CloudSyncPhase.notConfigured => AppColors.offline,
        CloudSyncPhase.authFailed || CloudSyncPhase.error => AppColors.warning,
      };

  Widget _devicesPanel(BuildContext context) {
    final sorted = [..._devices]..sort(_deviceOrder);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Affected devices',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_central.isScanning)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Tooltip(
                message: 'Connect automatically to every phone in range. '
                    'Turn off (or press Disconnect on a phone) to force a relay path.',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Auto-connect', style: TextStyle(fontSize: 12)),
                    Switch(
                      value: _central.autoConnect,
                      onChanged: (v) => setState(() => _central.autoConnect = v),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _scanStarting ? null : _startScan,
                icon: const Icon(Icons.radar, size: 18),
                label: const Text('Rescan'),
              ),
            ],
          ),
        ),
        if (_scanError != null)
          _NoticeCard(
            color: AppColors.emergency,
            icon: Icons.bluetooth_disabled,
            title: 'Bluetooth scanning unavailable',
            body: _scanError!,
            action: OutlinedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          )
        else if (sorted.isEmpty)
          _NoticeCard(
            color: AppColors.info,
            icon: Icons.bluetooth_searching,
            title: _scanStarting
                ? 'Starting Bluetooth scan...'
                : 'Scanning -- no affected phones found yet',
            body: 'On each phone, open Affected Person and keep the screen on. '
                'Phones (and relay phones) appear here by name as soon as they '
                'are in range.',
          )
        else
          for (final device in sorted)
            _DeviceTile(
              device: device,
              onConnect: () => _central.connect(device.address),
              onDisconnect: () => _central.disconnect(device.address),
            ),
      ],
    );
  }

  static int _deviceOrder(AffectedDeviceConnection a, AffectedDeviceConnection b) {
    int rank(AffectedDeviceConnection d) {
      switch (d.state) {
        case AffectedConnectionState.connected:
          return d.gattReady ? 0 : 1;
        case AffectedConnectionState.connecting:
          return 2;
        case AffectedConnectionState.discovered:
          return 3;
        case AffectedConnectionState.connectionFailed:
        case AffectedConnectionState.bluetoothDisabled:
        case AffectedConnectionState.permissionError:
          return 4;
        case AffectedConnectionState.disconnected:
          return 5;
      }
    }

    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.displayName.compareTo(b.displayName);
  }

  Widget _emergencyPanel(BuildContext context, List<RescueCase> bleCases) {
    int count(RescueStatus s) => bleCases.where((c) => c.status == s).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Emergency requests'),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _CountChip('Pending', count(RescueStatus.pending), AppColors.warning),
              _CountChip('Assigned', count(RescueStatus.assigned), AppColors.info),
              _CountChip('In progress', count(RescueStatus.inProgress), AppColors.info),
              _CountChip('Rescued', count(RescueStatus.rescued), AppColors.success),
            ],
          ),
        ),
        if (bleCases.isEmpty)
          const _NoticeCard(
            color: AppColors.offline,
            icon: Icons.inbox_outlined,
            title: 'No emergency requests yet',
            body: 'An SOS appears here the instant a connected phone sends '
                'one over Bluetooth -- no internet needed.',
          )
        else
          for (final rescueCase in bleCases)
            AnimatedBuilder(
              animation: _newAlertFlash,
              builder: (context, child) {
                final highlight = rescueCase.id == _highlightCaseId
                    ? (1 - _newAlertFlash.value)
                    : 0.0;
                return _EmergencyRequestCard(
                  rescueCase: rescueCase,
                  highlight: highlight,
                  onAdvance: () => _advance(rescueCase),
                  onOpenMap: rescueCase.hasLocation
                      ? () => _viewLocation(
                            rescueCase.latitude!,
                            rescueCase.longitude!,
                          )
                      : null,
                );
              },
            ),
      ],
    );
  }

  Widget _messagesPanel(BuildContext context, List<EmergencyMessage> messages) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'Emergency messages (BLE) -- ${messages.length}'),
        if (messages.isEmpty)
          const _NoticeCard(
            color: AppColors.offline,
            icon: Icons.chat_bubble_outline,
            title: 'No messages yet',
            body: 'Messages from connected phones appear here.',
          )
        else
          Card(
            child: Column(
              children: [
                for (final m in messages.reversed.take(20))
                  ListTile(
                    dense: true,
                    leading: Icon(
                      m.fromLocalUser ? Icons.north_east : Icons.south_west,
                      color: m.fromLocalUser ? AppColors.info : AppColors.emergency,
                    ),
                    title: Text(m.text),
                    subtitle: Text('${m.senderId} -- ${_clock(m.timestamp)}'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _backendPanel(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.cloud_outlined),
        title: Text('Network (backend) requests -- ${_backendRequests.length}'),
        subtitle: const Text('Optional secondary channel; BLE works without it.'),
        trailing: IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _backendLoading ? null : _fetchBackendRequests,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (_backendLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: AppLoadingView(message: 'Loading backend requests...'),
            )
          else if (_backendReachable == false)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'The backend server is not reachable. Bluetooth SOS reception '
                'is unaffected.',
              ),
            )
          else if (_backendRequests.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No backend rescue requests.'),
            )
          else
            for (final request in _backendRequests)
              if (request is Map) _backendRequestTile(request),
        ],
      ),
    );
  }

  Widget _backendRequestTile(Map request) {
    final latitude = double.tryParse(request['latitude']?.toString() ?? '');
    final longitude = double.tryParse(request['longitude']?.toString() ?? '');
    final priority = request['priority_level']?.toString() ?? 'Low';

    return ListTile(
      leading: PriorityBadge(level: aiPriorityFromString(priority)),
      title: Text(
        '${request['emergency_type'] ?? 'Unknown'} -- ${request['name'] ?? 'Unknown'}',
      ),
      subtitle: Text(
        '${request['message'] ?? ''}\nStatus: ${request['status'] ?? 'Pending'}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Open map',
        icon: const Icon(Icons.map_outlined),
        onPressed: (latitude == null || longitude == null)
            ? null
            : () => _viewLocation(latitude, longitude),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Widgets
// -----------------------------------------------------------------------------

String _clock(DateTime t) {
  final local = t.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second ${local.hour < 12 ? 'AM' : 'PM'}';
}

String _ago(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds} s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  return _clock(t);
}

({String label, Color color}) _priorityStyle(AiPriorityLevel? level) {
  switch (level) {
    case AiPriorityLevel.critical:
      return (label: 'CRITICAL', color: AppColors.priorityCritical);
    case AiPriorityLevel.high:
      return (label: 'HIGH', color: AppColors.priorityHigh);
    case AiPriorityLevel.medium:
      return (label: 'MEDIUM', color: AppColors.priorityMedium);
    case AiPriorityLevel.low:
      return (label: 'LOW', color: AppColors.priorityLow);
    case AiPriorityLevel.unknown:
    case null:
      return (label: 'UNKNOWN', color: AppColors.offline);
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.caption,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 220,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.14),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: muted)),
                    Row(
                      children: [
                        Icon(Icons.circle, size: 9, color: color),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: color,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (caption != null)
                      Text(
                        caption!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: muted),
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

class _CountChip extends StatelessWidget {
  const _CountChip(this.label, this.count, this.color);

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(body, style: const TextStyle(fontSize: 12.5)),
                  if (action != null) ...[
                    const SizedBox(height: 8),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One affected phone's independent connection slot.
class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.onConnect,
    required this.onDisconnect,
  });

  final AffectedDeviceConnection device;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    final String stateLabel;
    final Color color;
    switch (device.state) {
      case AffectedConnectionState.connected:
        stateLabel = 'CONNECTED';
        color = AppColors.success;
        break;
      case AffectedConnectionState.connecting:
        stateLabel = 'CONNECTING...';
        color = AppColors.warning;
        break;
      case AffectedConnectionState.discovered:
        stateLabel = 'NEARBY';
        color = AppColors.info;
        break;
      case AffectedConnectionState.disconnected:
        stateLabel = 'DISCONNECTED';
        color = AppColors.offline;
        break;
      case AffectedConnectionState.connectionFailed:
      case AffectedConnectionState.bluetoothDisabled:
      case AffectedConnectionState.permissionError:
        stateLabel = 'CONNECTION FAILED';
        color = AppColors.emergency;
        break;
    }

    final connected = device.isConnected;
    final connecting = device.state == AffectedConnectionState.connecting;

    final details = <String>[
      if (device.rssi != null) 'Signal ${device.rssi} dBm',
      if (device.lastSeenAt != null) 'Last seen ${_ago(device.lastSeenAt!)}',
      if (device.gattReady && device.payloadSize != null)
        '${device.payloadSize} B/frame',
    ];
    final sosLine = device.sosCount == 0
        ? 'No SOS received yet'
        : '${device.sosCount} SOS received -- last at '
            '${_clock(device.lastSosAt ?? DateTime.now())}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 5)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.smartphone, color: color, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    device.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15.5),
                  ),
                ),
                Tooltip(
                  message: 'BLE address: ${device.address}'
                      '${device.senderId != null ? '\nDevice id: ${device.senderId}' : ''}',
                  child: Icon(Icons.info_outline, size: 17, color: muted),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Pill(text: stateLabel, color: color),
                if (connected)
                  _Pill(
                    text: device.gattReady ? 'GATT READY' : 'SETTING UP...',
                    color: device.gattReady ? AppColors.success : AppColors.warning,
                  ),
                if (device.isRelay)
                  const _Pill(text: 'RELAY PHONE', color: Colors.purple),
                if (device.linkState != null)
                  _Pill(text: 'LINK: ${device.linkState}', color: AppColors.offline),
              ],
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(details.join('  |  '),
                  style: TextStyle(fontSize: 12, color: muted)),
            ],
            const SizedBox(height: 2),
            Text(sosLine, style: TextStyle(fontSize: 12, color: muted)),
            if (device.lastError != null && !device.gattReady) ...[
              const SizedBox(height: 6),
              Text(
                'Reason: ${device.lastError}',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.emergencyDark),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: connected
                  ? OutlinedButton.icon(
                      onPressed: onDisconnect,
                      icon: const Icon(Icons.link_off, size: 18),
                      label: const Text('Disconnect'),
                    )
                  : connecting
                      ? TextButton.icon(
                          onPressed: onDisconnect,
                          icon: const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          label: const Text('Cancel'),
                        )
                      : FilledButton.icon(
                          onPressed: onConnect,
                          icon: const Icon(Icons.link, size: 18),
                          label: Text(
                            device.state ==
                                    AffectedConnectionState.connectionFailed
                                ? 'Retry connect'
                                : 'Connect',
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// One received SOS -- never merged with another phone's request.
class _EmergencyRequestCard extends StatelessWidget {
  const _EmergencyRequestCard({
    required this.rescueCase,
    required this.highlight,
    required this.onAdvance,
    required this.onOpenMap,
  });

  final RescueCase rescueCase;

  /// 0..1 flash intensity for a just-arrived SOS.
  final double highlight;
  final VoidCallback onAdvance;
  final VoidCallback? onOpenMap;

  @override
  Widget build(BuildContext context) {
    final c = rescueCase;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final priority = _priorityStyle(c.aiPriority?.level);
    final rescued = c.status == RescueStatus.rescued;

    final statusColor = switch (c.status) {
      RescueStatus.pending => AppColors.warning,
      RescueStatus.assigned => AppColors.info,
      RescueStatus.inProgress => AppColors.info,
      RescueStatus.rescued => AppColors.success,
    };

    final (String ackText, Color ackColor, IconData ackIcon) =
        switch (c.ackDelivery) {
      AckDelivery.sent => (
          'ACK delivered to phone',
          AppColors.success,
          Icons.mark_email_read
        ),
      AckDelivery.sending => (
          'Sending ACK...',
          AppColors.warning,
          Icons.schedule_send
        ),
      AckDelivery.failed => (
          'ACK could not be delivered',
          AppColors.emergency,
          Icons.error_outline
        ),
      AckDelivery.notApplicable => ('No ACK channel', AppColors.offline, Icons.remove),
    };

    final cardColor = Color.lerp(
      Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
      AppColors.emergency.withValues(alpha: 0.25),
      highlight,
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: cardColor,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: priority.color, width: 6)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: priority.color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${priority.label} PRIORITY',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'AI: local rule-based',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                const Spacer(),
                Icon(Icons.schedule, size: 15, color: muted),
                const SizedBox(width: 4),
                Text(_clock(c.receivedAt),
                    style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.sos, color: AppColors.emergency),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (c.isRelayed) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.alt_route, size: 16, color: AppColors.info),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Original sender: ${c.name}  |  Relayed through: '
                      '${c.relayedByName ?? 'relay phone'} '
                      '(${c.hopCount} hop${c.hopCount == 1 ? '' : 's'}'
                      '${c.relayPath.length > 1 ? ', path of ${c.relayPath.length} relays' : ''})',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.info),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              c.message.isEmpty ? 'No message provided.' : c.message,
              style: TextStyle(
                fontSize: 15,
                fontStyle: c.message.isEmpty ? FontStyle.italic : FontStyle.normal,
                color: c.message.isEmpty ? muted : null,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _InfoLine(
                  icon: c.hasLocation ? Icons.place : Icons.location_off,
                  text: c.hasLocation
                      ? '${c.latitude!.toStringAsFixed(5)}, '
                          '${c.longitude!.toStringAsFixed(5)}'
                      : 'Location unavailable',
                  color: c.hasLocation ? null : AppColors.warning,
                ),
                _InfoLine(icon: Icons.category_outlined, text: c.emergencyType),
                _InfoLine(
                  icon: Icons.bluetooth,
                  text: 'via BLE from ${c.sourceDeviceName ?? 'unknown link'}',
                ),
                _InfoLine(
                  icon: Icons.person_outline,
                  text: 'Sender estimate: ${c.senderPriority}',
                ),
              ],
            ),
            if (c.aiPriority != null) ...[
              const SizedBox(height: 6),
              Text(
                'Priority factors: ${c.aiPriority!.reason}',
                style: TextStyle(fontSize: 11.5, color: muted),
              ),
            ],
            const SizedBox(height: 4),
            SelectableText(
              'Request ID: ${c.id}',
              style: TextStyle(fontSize: 11, color: muted),
            ),
            const Divider(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Pill(
                  text: RescueWorkflow.statusLabel(c.status),
                  color: statusColor,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(ackIcon, size: 16, color: ackColor),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(ackText,
                          style: TextStyle(fontSize: 12, color: ackColor)),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: onOpenMap,
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('OPEN MAP'),
                ),
                FilledButton.icon(
                  onPressed: rescued ? null : onAdvance,
                  icon: Icon(rescued ? Icons.check : Icons.arrow_forward, size: 18),
                  label: Text(RescueWorkflow.actionLabel(c.status)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.navy,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 5),
        Flexible(
          child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ),
      ],
    );
  }
}
