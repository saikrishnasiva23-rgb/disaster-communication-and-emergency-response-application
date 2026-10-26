import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/backend_config.dart';
import '../models/ai_priority_result.dart';
import '../models/audit_event.dart';
import '../models/emergency_message.dart';
import '../models/rescue_case.dart';
import '../models/sos_packet.dart';
import '../services/ai_priority_service.dart';
import '../services/bluetooth_rescue_service.dart';
import '../state/audit_log_state.dart';
import '../state/auth_state.dart';
import '../state/emergency_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';
import '../widgets/emergency_card.dart';
import '../widgets/priority_badge.dart';
import '../widgets/quick_action_card.dart';
import '../widgets/section_header.dart';
import '../widgets/state_views.dart';
import '../widgets/status_badge.dart';
import 'blockchain_log_screen.dart';
import 'rescue_dashboard_screen.dart';
import 'role_selection_screen.dart';
import 'settings_screen.dart';

/// Rescue Team home on Android: Bluetooth receiver status, real case
/// counts, SOS alerts received over Bluetooth, received messages and the
/// optional online request list.
///
/// Every subscription, HTTP call, audit event and navigation target is
/// unchanged by the redesign -- only the presentation changed. The online
/// request list deliberately keeps its original raw-JSON field extraction
/// (rather than routing through RescueCase.fromBackendJson) so the exact
/// values shown do not shift as a side effect of a UI-only pass; missing
/// values are shown as missing, never filled in.
class RescueHomeScreen extends StatefulWidget {
  const RescueHomeScreen({super.key});

  @override
  State<RescueHomeScreen> createState() => _RescueHomeScreenState();
}

class _RescueHomeScreenState extends State<RescueHomeScreen>
    with SingleTickerProviderStateMixin {
  List<dynamic> rescueRequests = [];

  bool isLoading = true;
  bool bluetoothReady = false;

  /// True while startRescueMode is in flight (initState starts it), so
  /// the status card shows "Starting" instead of a premature "Not active".
  bool _bluetoothStarting = true;

  /// The last request-list fetch failed (network error or non-200), so an
  /// empty list is shown as "can't reach" rather than "no requests".
  bool _backendUnavailable = false;

  /// Received messages beyond the latest few are collapsed by default.
  bool _showAllMessages = false;
  static const int _collapsedMessageCount = 5;

  StreamSubscription<SosPacket>? _sosSubscription;
  StreamSubscription<EmergencyMessage>? _messageSubscription;

  /// Drives a brief highlight on the "SOS Alerts" header when its count
  /// grows -- a cue that a real SOS just arrived, not a decorative loop.
  /// Starts completed (value 1) so the header is not highlighted before
  /// any SOS has arrived.
  late final AnimationController _newAlertFlash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );
  int _lastBleCaseCount = 0;

  @override
  void initState() {
    super.initState();

    fetchRescueRequests();
    startBluetoothRescueMode();

    // A BLE-received SOS becomes a typed RescueCase, gets a local AI
    // priority estimate (the backend model can't be reached for a device
    // with no network at all, which is exactly the scenario BLE exists
    // for), and shows up below.
    _sosSubscription =
        BluetoothRescueService.instance.onSosReceived.listen((packet) {
      if (!mounted) return;

      final rescueCase = RescueCase.fromSosPacket(packet)
        ..aiPriority = AiPriorityService.classifyLocally(packet);

      context.read<EmergencyState>().upsertRescueCase(rescueCase);

      context.read<AuditLogState>().addEvent(
            AuditEvent(
              id: '${packet.id}_received',
              type: AuditEventType.sosReceived,
              actorId: context.read<AuthState>().rescueId ?? 'rescue_team',
              timestamp: DateTime.now(),
              details: 'SOS ${packet.id} received over BLE from '
                  '${packet.senderId}',
            ),
          );
    });

    _messageSubscription =
        BluetoothRescueService.instance.onMessageReceived.listen((message) {
      if (!mounted) return;

      context.read<EmergencyState>().addMessage(message);

      context.read<AuditLogState>().addEvent(
            AuditEvent(
              id: '${message.id}_received',
              type: AuditEventType.messageReceived,
              actorId: context.read<AuthState>().rescueId ?? 'rescue_team',
              timestamp: DateTime.now(),
              details: 'Message ${message.id} received over BLE from '
                  '${message.senderId}',
            ),
          );
    });
  }

  Future<void> startBluetoothRescueMode() async {
    final success =
        await BluetoothRescueService.instance.startRescueMode();

    if (!mounted) return;

    setState(() {
      bluetoothReady = success;
      _bluetoothStarting = false;
    });
  }

  void _retryBluetooth() {
    setState(() => _bluetoothStarting = true);
    startBluetoothRescueMode();
  }

  Future<void> fetchRescueRequests() async {
    try {
      final response = await http.get(
        Uri.parse(BackendConfig.rescueRequestsListEndpoint),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          rescueRequests = data["requests"] ?? [];
          isLoading = false;
          _backendUnavailable = false;
        });
      } else {
        setState(() {
          isLoading = false;
          _backendUnavailable = true;
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
        _backendUnavailable = true;
      });

      _showMessage("Can't reach the server. Bluetooth alerts still work.");
    }
  }

  void _reloadRequests() {
    setState(() {
      isLoading = true;
    });

    fetchRescueRequests();
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  Future<void> _viewLocation(double latitude, double longitude) async {
    final uri = Uri.parse(
      "https://www.google.com/maps/search/?api=1&query=$latitude,$longitude",
    );

    bool launched;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No maps/browser handler: reported below instead of an unhandled
      // async error.
      launched = false;
    }

    if (!launched) {
      _showMessage("Could not open maps.");
    }
  }

  void _logout() {
    context.read<AuthState>().logout();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const RoleSelectionScreen()),
      (route) => false,
    );
  }

  void _openMenuItem(String value) {
    switch (value) {
      case 'status':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const RescueDashboardScreen(),
          ),
        );
        break;
      case 'log':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const BlockchainLogScreen(),
          ),
        );
        break;
      case 'settings':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const SettingsScreen(),
          ),
        );
        break;
    }
  }

  @override
  void dispose() {
    _sosSubscription?.cancel();
    _messageSubscription?.cancel();
    _newAlertFlash.dispose();
    BluetoothRescueService.instance.stopRescueMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final emergencyState = context.watch<EmergencyState>();
    final bleCases = emergencyState.rescueCases
        .where((c) => c.source == RescueCaseSource.ble)
        .toList();

    if (bleCases.length > _lastBleCaseCount) {
      // Deferred to after this build completes -- starting the
      // animation here directly would mutate state mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _newAlertFlash.forward(from: 0);
      });
    }
    _lastBleCaseCount = bleCases.length;

    // Real counts only -- computed from the actual rescueCases list and
    // the actual backend response, never a placeholder number.
    final backendStatuses = rescueRequests
        .map((r) => r["status"]?.toString().toLowerCase() ?? "pending")
        .toList();
    final pendingCount = bleCases
            .where((c) => c.status == RescueStatus.pending)
            .length +
        backendStatuses.where((s) => s == "pending").length;
    final activeCount = bleCases
            .where(
              (c) =>
                  c.status == RescueStatus.assigned ||
                  c.status == RescueStatus.inProgress,
            )
            .length +
        backendStatuses
            .where(
              (s) => s == "assigned" || s == "in_progress" || s == "inprogress",
            )
            .length;
    final rescuedCount =
        bleCases.where((c) => c.status == RescueStatus.rescued).length +
            backendStatuses.where((s) => s == "rescued").length;
    final totalCount = bleCases.length + rescueRequests.length;

    // Messages received from affected phones, newest first.
    final received = emergencyState.messages
        .where((m) => !m.fromLocalUser)
        .toList()
        .reversed
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Rescue Team"),
        actions: [
          IconButton(
            onPressed: _reloadRequests,
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh",
          ),
          PopupMenuButton<String>(
            tooltip: "More options",
            onSelected: _openMenuItem,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'status',
                child: ListTile(
                  leading: Icon(Icons.track_changes),
                  title: Text("Rescue Status"),
                ),
              ),
              PopupMenuItem(
                value: 'log',
                child: ListTile(
                  leading: Icon(Icons.receipt_long),
                  title: Text("Event Log"),
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text("Settings"),
                ),
              ),
            ],
          ),
          IconButton(
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            tooltip: "Log out",
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final bottomInset = MediaQuery.paddingOf(context).bottom;

            final alerts = _alertsSection(context, bleCases);
            final side = [
              ..._messagesSection(context, received, emergencyState.rescueCases),
              const SizedBox(height: AppSpacing.xl),
              ..._requestsSection(context),
            ];

            return ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.md,
                AppSpacing.page,
                AppSpacing.xl + bottomInset,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _receiverCard(context),
                        const SizedBox(height: AppSpacing.md),
                        _metrics(
                          context,
                          total: totalCount,
                          pending: pendingCount,
                          active: activeCount,
                          rescued: rescuedCount,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: alerts,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xl),
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: side,
                                ),
                              ),
                            ],
                          )
                        else ...[
                          ...alerts,
                          const SizedBox(height: AppSpacing.xl),
                          ...side,
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Status + metrics
  // -------------------------------------------------------------------------

  /// Reflects only what BluetoothRescueService reports: whether rescue
  /// mode started. It does not know about individual connections, so none
  /// are claimed here.
  Widget _receiverCard(BuildContext context) {
    final theme = Theme.of(context);
    final (String title, String? subtitle, StatusTone tone, IconData icon) =
        _bluetoothStarting
            ? ('Starting', null, StatusTone.neutral, Icons.bluetooth)
            : bluetoothReady
                ? ('Ready', 'Waiting for SOS', StatusTone.success,
                    Icons.bluetooth_searching)
                : ('Not active', 'Turn on Bluetooth and allow access',
                    StatusTone.warning, Icons.bluetooth_disabled);
    final color = tone.color(context);

    return AppCard(
      semanticLabel: 'Bluetooth: $title',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          IconBadge(icon: icon, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bluetooth', style: theme.textTheme.bodySmall),
                Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
                if (subtitle != null)
                  Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (_bluetoothStarting)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (!bluetoothReady)
            TextButton(
              onPressed: _retryBluetooth,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  Widget _metrics(
    BuildContext context, {
    required int total,
    required int pending,
    required int active,
    required int rescued,
  }) {
    final s = context.status;
    final tiles = [
      _MetricTile(
        label: 'Total',
        count: total,
        icon: Icons.inbox_outlined,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      _MetricTile(
        label: 'Pending',
        count: pending,
        icon: Icons.hourglass_empty,
        color: s.warning,
      ),
      _MetricTile(
        label: 'Active',
        count: active,
        icon: Icons.directions_run,
        color: s.info,
      ),
      _MetricTile(
        label: 'Rescued',
        count: rescued,
        icon: Icons.check_circle_outline,
        color: s.success,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Four across when they fit at the current font size, else 2 x 2
        // (never a lone tile on a second row).
        final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
        final fitsFour = constraints.maxWidth >= (4 * 72 + 30) * scale;
        return ResponsiveTileGrid(
          minTileWidth: 60,
          maxColumns: fitsFour ? 4 : 2,
          children: tiles,
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // SOS alerts (Bluetooth)
  // -------------------------------------------------------------------------

  List<Widget> _alertsSection(BuildContext context, List<RescueCase> bleCases) {
    final flashColor = context.status.warning.withValues(alpha: 0.22);
    return [
      AnimatedBuilder(
        animation: _newAlertFlash,
        builder: (context, child) => Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: Color.lerp(
              flashColor,
              flashColor.withValues(alpha: 0),
              _newAlertFlash.value,
            ),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: child,
        ),
        child: SectionHeader(
          title: "SOS Alerts",
          trailing: _CountPill(count: bleCases.length, label: 'SOS alerts'),
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      if (bleCases.isEmpty)
        const AppCard(
          padding: EdgeInsets.zero,
          child: AppEmptyView(
            icon: Icons.sos,
            title: "No SOS yet",
            subtitle: "New alerts appear here",
          ),
        )
      else
        for (final rescueCase in bleCases)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: EmergencyCard(
              rescueCase: rescueCase,
              trailing: _mapButton(
                hasLocation: rescueCase.hasLocation,
                onPressed: rescueCase.hasLocation
                    ? () => _viewLocation(
                          rescueCase.latitude!,
                          rescueCase.longitude!,
                        )
                    : null,
              ),
            ),
          ),
    ];
  }

  Widget _mapButton({required bool hasLocation, VoidCallback? onPressed}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(hasLocation ? Icons.map_outlined : Icons.location_off_outlined),
        label: Text(hasLocation ? "View on Map" : "No location"),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Messages
  // -------------------------------------------------------------------------

  List<Widget> _messagesSection(
    BuildContext context,
    List<EmergencyMessage> received,
    List<RescueCase> cases,
  ) {
    final collapsible = received.length > _collapsedMessageCount;
    final visible = _showAllMessages || !collapsible
        ? received
        : received.take(_collapsedMessageCount).toList();
    final divider = Theme.of(context).colorScheme.outlineVariant;

    return [
      SectionHeader(
        title: "Messages",
        trailing: _CountPill(count: received.length, label: 'messages'),
      ),
      const SizedBox(height: AppSpacing.xs),
      if (received.isEmpty)
        const AppCard(
          padding: EdgeInsets.zero,
          child: AppEmptyView(
            icon: Icons.chat_bubble_outline,
            title: "No messages yet",
          ),
        )
      else
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0) Divider(height: 1, color: divider),
                _MessageTile(
                  message: visible[i],
                  sender: _senderName(visible[i], cases),
                ),
              ],
              if (collapsible) ...[
                Divider(height: 1, color: divider),
                TextButton(
                  onPressed: () =>
                      setState(() => _showAllMessages = !_showAllMessages),
                  child: Text(
                    _showAllMessages
                        ? "Show less"
                        : "Show all (${received.length})",
                  ),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  /// The original sender's name when one of the received SOS came from the
  /// same device; otherwise the sender id the message carried.
  String _senderName(EmergencyMessage message, List<RescueCase> cases) {
    for (final c in cases) {
      if (c.senderId != null && c.senderId == message.senderId) return c.name;
    }
    return message.senderId;
  }

  // -------------------------------------------------------------------------
  // Online requests (optional backend)
  // -------------------------------------------------------------------------

  List<Widget> _requestsSection(BuildContext context) {
    return [
      SectionHeader(
        title: "Online Requests",
        trailing: isLoading
            ? null
            : _CountPill(count: rescueRequests.length, label: 'online requests'),
      ),
      const SizedBox(height: AppSpacing.xs),
      if (isLoading)
        const AppCard(
          padding: EdgeInsets.zero,
          child: AppLoadingView(message: "Loading requests..."),
        )
      else if (rescueRequests.isEmpty)
        AppCard(
          padding: EdgeInsets.zero,
          child: _backendUnavailable
              ? AppErrorView(
                  message: "Can't reach the server",
                  onRetry: _reloadRequests,
                )
              : const AppEmptyView(
                  icon: Icons.inbox_outlined,
                  title: "No online requests",
                ),
        )
      else ...[
        if (_backendUnavailable)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppNotice(
              message: "Couldn't refresh. Showing last list.",
              icon: Icons.cloud_off_outlined,
              color: context.status.warning,
              action: TextButton(
                onPressed: _reloadRequests,
                child: const Text("Retry"),
              ),
            ),
          ),
        for (final request in rescueRequests)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: _requestCard(context, request),
          ),
      ],
    ];
  }

  /// Label, tone and icon for a backend status string. Unknown values are
  /// shown as they are (neutral), never relabelled as a known status.
  (String, StatusTone, IconData) _backendStatus(String raw) {
    switch (raw.toLowerCase()) {
      case 'pending':
        return EmergencyCard.describeStatus(RescueStatus.pending);
      case 'assigned':
        return EmergencyCard.describeStatus(RescueStatus.assigned);
      case 'in_progress':
      case 'inprogress':
        return EmergencyCard.describeStatus(RescueStatus.inProgress);
      case 'rescued':
        return EmergencyCard.describeStatus(RescueStatus.rescued);
      default:
        return (raw, StatusTone.neutral, Icons.info_outline);
    }
  }

  Widget _requestCard(BuildContext context, dynamic request) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final emergencyType = request["emergency_type"]?.toString() ?? "Unknown";
    final name = request["name"]?.toString() ?? "Unknown";
    final people = request["number_of_people"]?.toString() ?? "Unknown";
    final injured = request["injured"]?.toString() ?? "Unknown";
    final message = request["message"]?.toString() ?? "";
    final status = request["status"]?.toString() ?? "Pending";
    // Missing priority / score are left out rather than shown as an
    // invented "Low" / "0%".
    final priorityRaw = request["priority_level"]?.toString();
    final confidence = request["priority_score"]?.toString();
    final level = priorityRaw == null ? null : aiPriorityFromString(priorityRaw);

    final latitude = double.tryParse(request["latitude"]?.toString() ?? '');
    final longitude = double.tryParse(request["longitude"]?.toString() ?? '');
    final hasLocation = latitude != null && longitude != null;

    final accent = level == null
        ? context.status.neutral
        : PriorityBadge.colorOf(context, level);
    final (statusLabel, statusTone, statusIcon) = _backendStatus(status);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(
                icon: EmergencyCard.iconForType(emergencyType),
                color: accent,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      emergencyType,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'From $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              if (level != null) ...[
                const SizedBox(width: AppSpacing.sm),
                PriorityBadge(level: level),
              ],
            ],
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              CaseMetaItem(icon: Icons.group_outlined, label: 'People: $people'),
              CaseMetaItem(icon: Icons.healing_outlined, label: 'Injured: $injured'),
              CaseMetaItem(
                icon: Icons.location_on_outlined,
                label: hasLocation
                    ? '${request["latitude"]}, ${request["longitude"]}'
                    : 'No location',
              ),
              CaseMetaItem(icon: Icons.tag, label: 'Request ${request["id"]}'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusBadge(label: statusLabel, tone: statusTone, icon: statusIcon),
              if (confidence != null)
                Text('$confidence% confidence', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _mapButton(
            hasLocation: hasLocation,
            onPressed: latitude != null && longitude != null
                ? () => _viewLocation(latitude, longitude)
                : null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
  });

  final String label;
  final int count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $count',
      excludeSemantics: true,
      child: AppCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$count',
              style: theme.textTheme.titleLarge?.copyWith(color: color),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
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

/// A neutral count pill for section headers.
class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, required this.label});

  final int count;

  /// What is being counted, for screen readers.
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$count $label',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 28),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(
          '$count',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium,
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.sender});

  final EmergencyMessage message;
  final String sender;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(
            icon: Icons.chat_bubble_outline,
            color: context.status.info,
            size: 36,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        sender,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      EmergencyCard.formatTime(context, message.timestamp),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(message.text, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
