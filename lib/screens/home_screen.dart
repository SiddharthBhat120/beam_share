import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../main.dart';
import '../services/platform_bridge.dart';
import '../widgets/common.dart';
import 'history_screen.dart';
import 'receive_screen.dart';
import 'send_screen.dart';
import 'settings_screen.dart';

/// Home: two big buttons. That's the whole app for most people.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).app;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(gradient: BeamColors.sendGradient, shape: BoxShape.circle),
              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('Beam Share'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen())),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                ListenableBuilder(
                  listenable: app,
                  builder: (context, _) => Row(
                    children: [
                      Icon(platformIcon(PlatformBridge.platformName), size: 18, color: cs.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text('This device: ${app.deviceName}',
                            overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Text('What do you want to do?',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 20),
                ActionCard(
                  title: 'Send',
                  subtitle: 'Files, folders, photos & videos',
                  icon: Icons.arrow_upward_rounded,
                  gradient: BeamColors.sendGradient,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SendScreen())),
                ),
                const SizedBox(height: 18),
                ActionCard(
                  title: 'Receive',
                  subtitle: 'Scan a code or wait for a nearby sender',
                  icon: Icons.arrow_downward_rounded,
                  gradient: BeamColors.receiveGradient,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReceiveScreen())),
                ),
                const SizedBox(height: 36),
                const Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _Pill(icon: Icons.wifi_off_rounded, text: 'No internet needed'),
                    _Pill(icon: Icons.high_quality_rounded, text: 'Original quality'),
                    _Pill(icon: Icons.verified_rounded, text: 'Every byte verified'),
                    _Pill(icon: Icons.lock_rounded, text: 'Encrypted'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(40)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
