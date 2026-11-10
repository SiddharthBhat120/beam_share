import 'package:flutter/material.dart';
import 'package:transfer_core/transfer_core.dart';

import '../app/theme.dart';
import '../main.dart';
import '../services/permissions.dart';
import '../services/platform_bridge.dart';
import '../state/transfer_controller.dart';
import '../widgets/common.dart';
import 'scan_screen.dart';
import 'stage_navigation.dart';

/// Receive: scan the sender's QR code, or wait until a nearby sender taps us.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> with StageNavigation {
  bool _showMyCode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Permissions.ensureNetwork();
      await transfers.startHosting(asRole: 'receiver');
    });
  }

  @override
  void dispose() {
    if (transfers.stage != Stage.transferring && transfers.stage != Stage.finished) {
      transfers.stopSession();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    if (!await Permissions.ensureCamera()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Camera permission is needed to scan.'),
          action: SnackBarAction(label: 'Settings', onPressed: Permissions.openSettings),
        ));
      }
      return;
    }
    if (!mounted) return;
    final code = await Navigator.push<PairingInfo>(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (code != null) await transfers.connectWithCode(code, asRole: 'receiver');
  }

  Future<void> _enterCode() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'BEAM1:...', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Connect')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await transfers.connectWithCode(PairingInfo.decode(text), asRole: 'receiver');
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That is not a Beam Share code.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).app;
    final t = AppScope.of(context).transfers;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: t,
          builder: (context, _) {
            final busy = t.stage == Stage.connecting;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    if (t.error != null) ...[
                      InfoBanner(text: t.error!, error: true, onClose: t.clearError),
                      const SizedBox(height: 12),
                    ],
                    if (PlatformBridge.isMobile) ...[
                      FilledButton.icon(
                        onPressed: busy ? null : _scan,
                        style: FilledButton.styleFrom(
                            backgroundColor: BeamColors.teal, minimumSize: const Size.fromHeight(64)),
                        icon: const Icon(Icons.qr_code_scanner_rounded, size: 28),
                        label: const Text('Scan QR code', style: TextStyle(fontSize: 18)),
                      ),
                      const SizedBox(height: 28),
                    ],
                    Center(
                      child: _showMyCode && t.myCode != null
                          ? QrCard(data: t.myCode!.encode(), size: 220)
                          : RadarPulse(
                              child: busy
                                  ? const CircularProgressIndicator()
                                  : CircleAvatar(
                                      radius: 38,
                                      backgroundColor: BeamColors.teal,
                                      child: Icon(platformIcon(PlatformBridge.platformName),
                                          color: Colors.white, size: 38),
                                    ),
                            ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      busy ? (t.status ?? 'Connecting...') : 'Waiting for a sender',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _showMyCode
                          ? 'Scan this with the sending device'
                          : 'Visible to nearby devices as "${app.deviceName}"',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    if (t.stage == Stage.waiting && t.status != null) ...[
                      const SizedBox(height: 6),
                      Text(t.status!, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: t.myCode == null ? null : () => setState(() => _showMyCode = !_showMyCode),
                          icon: Icon(_showMyCode ? Icons.radar_rounded : Icons.qr_code_2_rounded),
                          label: Text(_showMyCode ? 'Hide my code' : 'Show my code'),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy ? null : _enterCode,
                          icon: const Icon(Icons.keyboard_rounded),
                          label: const Text('Paste code'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.folder_open_rounded),
                        title: const Text('Files are saved to'),
                        subtitle: Text(app.receiveDir, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    ),
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
