import 'package:flutter/material.dart';
import 'package:transfer_core/transfer_core.dart';

import '../app/theme.dart';
import '../main.dart';
import '../state/transfer_controller.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'finish_screen.dart';

/// Live progress: speed, time left, files verified, pause/resume/cancel.
class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  late final TransferController _t = AppScope.read(context).transfers;
  bool _left = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _t.removeListener(_onChange);
    _t.addListener(_onChange);
  }

  @override
  void dispose() {
    _t.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted || _left) return;
    if (_t.stage == Stage.finished) {
      _left = true;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const FinishScreen()));
    }
  }

  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop the transfer?'),
        content: const Text('Files that are already verified are kept. Unfinished files are removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: BeamColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (ok == true) _t.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmCancel();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: ListenableBuilder(
            listenable: _t,
            builder: (context, _) => Text(
              _t.role == 'sender' ? 'Sending to ${_t.peer?.name ?? '...'}' : 'Receiving from ${_t.peer?.name ?? '...'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _t,
            builder: (context, _) {
              final p = _t.progress;
              final sending = _t.role == 'sender';
              final colors = sending
                  ? const [BeamColors.indigo, BeamColors.violet]
                  : const [BeamColors.teal, BeamColors.cyan];
              final phase = p?.phase ?? TransferPhase.connecting;
              final paused = phase == TransferPhase.paused;
              final percent = ((p?.fraction ?? 0) * 100).clamp(0, 100);
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      if (phase == TransferPhase.reconnecting) ...[
                        const InfoBanner(text: 'Connection lost. Reconnecting and resuming...'),
                        const SizedBox(height: 16),
                      ],
                      if (paused) ...[
                        const InfoBanner(text: 'Paused'),
                        const SizedBox(height: 16),
                      ],
                      Center(
                        child: ProgressRing(
                          value: p?.fraction ?? 0,
                          colors: colors,
                          size: 230,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${percent.toStringAsFixed(percent < 10 ? 1 : 0)}%',
                                  style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, letterSpacing: -1)),
                              Text(
                                p == null ? 'Starting...' : '${formatBytes(p.doneBytes)} of ${formatBytes(p.totalBytes)}',
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          StatTile(
                              label: 'Speed',
                              value: p == null || paused ? '--' : formatSpeed(p.bytesPerSecond),
                              icon: Icons.speed_rounded),
                          const SizedBox(width: 10),
                          StatTile(
                              label: 'Time left',
                              value: paused ? '--' : formatDuration(p?.eta),
                              icon: Icons.timer_outlined),
                          const SizedBox(width: 10),
                          StatTile(
                              label: 'Verified',
                              value: p == null ? '--' : '${formatCount(p.filesDone)}/${formatCount(p.filesTotal)}',
                              icon: Icons.verified_rounded),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (p?.currentFile != null)
                        Row(
                          children: [
                            Icon(Icons.insert_drive_file_outlined, size: 18, color: cs.onSurfaceVariant),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(p!.currentFile!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: cs.onSurfaceVariant)),
                            ),
                          ],
                        ),
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                              onPressed: phase == TransferPhase.transferring || paused
                                  ? (paused ? _t.resume : _t.pause)
                                  : null,
                              icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                              label: Text(paused ? 'Resume' : 'Pause'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(foregroundColor: BeamColors.danger),
                              onPressed: _confirmCancel,
                              icon: const Icon(Icons.close_rounded),
                              label: const Text('Cancel'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text('Keep both devices close and the screen on for the best speed.',
                          textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
