import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transfer_core/transfer_core.dart';

import '../app/theme.dart';
import '../main.dart';
import '../services/permissions.dart';
import '../services/platform_bridge.dart';
import '../state/transfer_controller.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'scan_screen.dart';
import 'stage_navigation.dart';

/// Step 2 of sending: show a QR code and the list of nearby receivers.
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> with StageNavigation {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Permissions.ensureNetwork();
      await transfers.startHosting(asRole: 'sender');
    });
  }

  @override
  void dispose() {
    if (transfers.stage != Stage.transferring && transfers.stage != Stage.finished) {
      transfers.stopSession(keepItems: true);
    }
    super.dispose();
  }

  Future<void> _scanReceiver() async {
    if (!await Permissions.ensureCamera()) return;
    if (!mounted) return;
    final code = await Navigator.push<PairingInfo>(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code != null) await transfers.connectWithCode(code, asRole: 'sender');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: AppScope.of(context).transfers,
          builder: (context, _) {
            final t = AppScope.of(context).transfers;
            final code = t.myCode;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  children: [
                    Text('${plural(t.itemFileCount, 'file')} · ${formatBytes(t.itemBytes)}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 16),
                    if (t.error != null) ...[
                      InfoBanner(text: t.error!, error: true, onClose: t.clearError),
                      const SizedBox(height: 12),
                    ],
                    Center(
                      child: code == null || t.stage == Stage.connecting
                          ? SizedBox(
                              height: 272,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const CircularProgressIndicator(),
                                  const SizedBox(height: 16),
                                  Text(t.status ?? '', textAlign: TextAlign.center),
                                ],
                              ),
                            )
                          : QrCard(data: code.encode(), size: 240),
                    ),
                    const SizedBox(height: 14),
                    Text('On the other device: open Beam Share › Receive › Scan',
                        textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                    if (code != null && t.stage == Stage.waiting) ...[
                      const SizedBox(height: 10),
                      _NetworkLine(text: t.status ?? '', offline: t.hotspot != null),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('Copy code'),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: code.encode()));
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Code copied. Paste it on the other device.')));
                            },
                          ),
                          if (PlatformBridge.isMobile)
                            TextButton.icon(
                              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                              label: const Text("Scan receiver's code"),
                              onPressed: _scanReceiver,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Text('Nearby devices',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 10),
                        if (t.stage == Stage.waiting)
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (t.nearby.isEmpty)
                      Text('Devices on the same Wi-Fi that are on the Receive screen appear here.',
                          style: TextStyle(color: cs.onSurfaceVariant))
                    else
                      ...t.nearby.map((d) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: BeamColors.teal.withValues(alpha: 0.15),
                                  child: Icon(platformIcon(d.platform), color: BeamColors.teal),
                                ),
                                title: Text(d.name),
                                subtitle: const Text('Tap to send'),
                                trailing: const Icon(Icons.send_rounded),
                                onTap: t.stage == Stage.waiting ? () => t.connectToNearby(d) : null,
                              ),
                            ),
                          )),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NetworkLine extends StatelessWidget {
  const _NetworkLine({required this.text, required this.offline});
  final String text;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(offline ? Icons.wifi_tethering_rounded : Icons.wifi_rounded, size: 18, color: cs.primary),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: TextStyle(color: cs.onSurfaceVariant), textAlign: TextAlign.center)),
      ],
    );
  }
}
