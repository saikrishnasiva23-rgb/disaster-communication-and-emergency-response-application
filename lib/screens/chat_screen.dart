import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ble_device_info.dart';
import '../models/emergency_message.dart';
import '../services/affected_peripheral_service.dart';
import '../services/ble_central_service.dart';
import '../state/emergency_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/state_views.dart';
import '../widgets/status_badge.dart';

/// Messages to the Rescue Team.
///
/// Without [device], messages go to a Rescue Team device connected to this
/// phone (AffectedPeripheralService). With [device] (diagnostics only) they
/// go over the legacy direct link. A message is shown as "Sent" only after
/// the Bluetooth write succeeded -- there is no read receipt, so nothing is
/// ever shown as delivered or read.
class ChatScreen extends StatefulWidget {
  final BleDeviceInfo? device;

  const ChatScreen({super.key, this.device});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();

  /// Ids being written now / whose write failed.
  final Set<String> _sending = {};
  final Set<String> _failed = {};

  bool get _legacy => widget.device != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _transmit(EmergencyMessage message) async {
    setState(() {
      _sending.add(message.id);
      _failed.remove(message.id);
    });
    var ok = false;
    try {
      if (_legacy) {
        await BleCentralService.instance.sendBytes(utf8.encode(message.toWireBytes()));
      } else {
        await AffectedPeripheralService.instance.sendMessage(message);
      }
      ok = true;
    } catch (e) {
      debugPrint('Message ${message.id} not sent: $e');
    }
    if (!mounted) return;
    setState(() {
      _sending.remove(message.id);
      if (ok) {
        message.delivered = true;
      } else {
        _failed.add(message.id);
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final message = EmergencyMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      senderId: 'me',
      text: text,
      timestamp: DateTime.now(),
      fromLocalUser: true,
    );
    context.read<EmergencyState>().addMessage(message);
    _controller.clear();
    await _transmit(message);
  }

  @override
  Widget build(BuildContext context) {
    final messages = context.watch<EmergencyState>().messages;

    return Scaffold(
      appBar: AppBar(
        title: Text(_legacy ? widget.device!.name : 'Messages'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (!_legacy)
              ValueListenableBuilder<AffectedLinkStatus>(
                valueListenable: AffectedPeripheralService.instance.status,
                builder: (context, link, _) => link.rescueLinks > 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpacing.page, AppSpacing.sm, AppSpacing.page, 0),
                        child: AppNotice(
                          message: 'Rescue Team not connected. Use Send SOS for help.',
                          icon: Icons.info_outline,
                          color: context.status.warning,
                        ),
                      ),
              ),
            Expanded(
              child: messages.isEmpty
                  ? const AppEmptyView(
                      icon: Icons.chat_bubble_outline,
                      title: 'No messages yet',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: AppSpacing.md),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final m = messages[index];
                        return _Bubble(
                          message: m,
                          sending: _sending.contains(m.id),
                          failed: _failed.contains(m.id),
                          onRetry: () => _transmit(m),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            _composer(context),
          ],
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    return ValueListenableBuilder<AffectedLinkStatus>(
      valueListenable: AffectedPeripheralService.instance.status,
      builder: (context, link, _) {
        final enabled = _legacy || link.rescueLinks > 0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: enabled ? (_) => _send() : null,
                  decoration: const InputDecoration(hintText: 'Type a message'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton.filled(
                tooltip: 'Send message',
                onPressed: enabled ? _send : null,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.sending,
    required this.failed,
    required this.onRetry,
  });

  final EmergencyMessage message;
  final bool sending;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = message.fromLocalUser;
    final time = TimeOfDay.fromDateTime(message.timestamp.toLocal()).format(context);
    final bubbleColor = mine ? AppColors.brand : theme.colorScheme.surfaceContainer;
    final textColor = mine ? Colors.white : theme.colorScheme.onSurface;

    final (String state, StatusTone tone) = !mine
        ? (message.senderId, StatusTone.neutral)
        : sending
            ? ('Sending', StatusTone.neutral)
            : failed
                ? ('Not sent', StatusTone.danger)
                : message.delivered
                    ? ('Sent', StatusTone.success)
                    : ('Not sent', StatusTone.danger);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: AppSpacing.sm),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(AppRadius.lg),
                  topRight: const Radius.circular(AppRadius.lg),
                  bottomLeft: Radius.circular(mine ? AppRadius.lg : 4),
                  bottomRight: Radius.circular(mine ? 4 : AppRadius.lg),
                ),
              ),
              child: Text(message.text, style: TextStyle(color: textColor, fontSize: 15)),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$time · ', style: theme.textTheme.bodySmall),
                Text(
                  state,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tone.color(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (mine && failed && !sending)
                  TextButton(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    ),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
