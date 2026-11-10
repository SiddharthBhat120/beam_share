import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../main.dart';
import '../services/platform_bridge.dart';
import '../util/format.dart';
import '../widgets/common.dart';

/// "✅ N files verified, 0 errors".
class FinishScreen extends StatelessWidget {
  const FinishScreen({super.key});

  void _done(BuildContext context) {
    AppScope.read(context).transfers.stopSession();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).transfers;
    final s = t.summary!;
    final cs = Theme.of(context).colorScheme;
    final ok = s.success;
    final color = s.cancelled ? cs.outline : (ok ? BeamColors.success : BeamColors.danger);
    final icon = s.cancelled ? Icons.block_rounded : (ok ? Icons.check_rounded : Icons.priority_high_rounded);
    final title = s.cancelled ? 'Transfer cancelled' : (ok ? 'All done!' : 'Finished with errors');
    final sent = t.role == 'sender';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done(context);
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                children: [
                  Center(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.4, end: 1),
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.elasticOut,
                      builder: (context, v, child) => Transform.scale(scale: v, child: child),
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 30)],
                        ),
                        child: Icon(icon, color: Colors.white, size: 72),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Text(
                    '${ok ? '✅' : '⚠️'} ${plural(s.filesVerified, 'file')} verified, '
                    '${plural(s.filesFailed, 'error')}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${sent ? 'Sent to' : 'Received from'} ${t.peer?.name ?? 'the other device'}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      StatTile(label: 'Size', value: formatBytes(s.bytes), icon: Icons.data_usage_rounded),
                      const SizedBox(width: 10),
                      StatTile(label: 'Time', value: formatDuration(s.duration), icon: Icons.timer_outlined),
                      const SizedBox(width: 10),
                      StatTile(
                          label: 'Average', value: formatSpeed(s.averageBytesPerSecond), icon: Icons.speed_rounded),
                    ],
                  ),
                  if (s.reconnects > 0 || s.resentPieces > 0) ...[
                    const SizedBox(height: 14),
                    InfoBanner(
                      text: [
                        if (s.reconnects > 0) 'Resumed after ${plural(s.reconnects, 'connection drop')}.',
                        if (s.resentPieces > 0) 'Re-sent ${plural(s.resentPieces, 'damaged piece')} automatically.',
                      ].join(' '),
                    ),
                  ],
                  if (s.errors.isNotEmpty && !s.cancelled) ...[
                    const SizedBox(height: 14),
                    Card(
                      child: ExpansionTile(
                        shape: const Border(),
                        leading: const Icon(Icons.error_outline_rounded, color: BeamColors.danger),
                        title: Text('Details (${s.errors.length})'),
                        children: [
                          for (final e in s.errors.take(200))
                            ListTile(dense: true, title: Text(e, style: const TextStyle(fontSize: 13))),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (!sent && s.destination != null && s.filesVerified > 0) ...[
                    FilledButton.icon(
                      onPressed: () => PlatformBridge.openFolder(s.destination!),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Open folder'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  OutlinedButton(onPressed: () => _done(context), child: const Text('Done')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
