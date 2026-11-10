import 'package:flutter/material.dart';

import '../main.dart';
import '../state/transfer_controller.dart';
import '../util/format.dart';
import 'transfer_screen.dart';

/// Shared by the Share and Receive screens: opens the transfer screen when a
/// transfer starts and shows the "Accept?" dialog for nearby senders.
mixin StageNavigation<T extends StatefulWidget> on State<T> {
  TransferController? _transfers;
  bool _openedTransfer = false;
  bool _dialogOpen = false;

  TransferController get transfers => _transfers!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_transfers == null) {
      _transfers = AppScope.read(context).transfers;
      _transfers!.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _transfers?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (transfers.stage == Stage.transferring && !_openedTransfer) {
      _openedTransfer = true;
      if (_dialogOpen) Navigator.of(context).pop();
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const TransferScreen()));
      return;
    }
    final req = transfers.request;
    if (req != null && !_dialogOpen) {
      _dialogOpen = true;
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.download_rounded, size: 36),
          title: Text('${req.device.name} wants to send you files'),
          content: Text(req.files == null
              ? 'Accept the transfer?'
              : '${plural(req.files!, 'file')} · ${formatBytes(req.bytes ?? 0)}\n\nOnly accept from devices you know.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
          ],
        ),
      ).then((accept) {
        _dialogOpen = false;
        if (accept != null) transfers.answerRequest(accept);
      });
    }
  }
}
