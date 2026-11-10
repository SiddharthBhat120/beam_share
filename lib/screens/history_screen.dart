import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../main.dart';
import '../services/platform_bridge.dart';
import '../util/format.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).app;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          ListenableBuilder(
            listenable: app,
            builder: (context, _) => app.history.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear history',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Clear history?'),
                          content: const Text('Only the list is cleared. Your files are not touched.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
                          ],
                        ),
                      );
                      if (ok == true) await app.clearHistory();
                    },
                  ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          if (app.history.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history_rounded, size: 64, color: cs.outline),
                  const SizedBox(height: 12),
                  Text('No transfers yet', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: app.history.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final h = app.history[i];
              final color = h.sent ? BeamColors.indigo : BeamColors.teal;
              final status = h.cancelled
                  ? 'Cancelled'
                  : h.failed > 0
                      ? plural(h.failed, 'error')
                      : 'Verified';
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Icon(h.sent ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, color: color),
                  ),
                  title: Text('${h.sent ? 'Sent to' : 'Received from'} ${h.peerName}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${plural(h.files, 'file')} · ${formatBytes(h.bytes)} · ${formatDate(h.time)}\n$status'),
                  isThreeLine: true,
                  trailing: !h.sent && h.destination != null
                      ? IconButton(
                          tooltip: 'Open folder',
                          icon: const Icon(Icons.folder_open_rounded),
                          onPressed: () => PlatformBridge.openFolder(h.destination!),
                        )
                      : Icon(
                          h.success ? Icons.verified_rounded : Icons.error_outline_rounded,
                          color: h.success ? BeamColors.success : (h.cancelled ? cs.outline : BeamColors.danger),
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
