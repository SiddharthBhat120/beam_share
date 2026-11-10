import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/platform_bridge.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _rename(BuildContext context) async {
    final app = AppScope.read(context).app;
    final ctrl = TextEditingController(text: app.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null) await app.setDeviceName(name);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).app;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Device name'),
                    subtitle: Text(app.deviceName),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _rename(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('Save received files to'),
                    subtitle: Text(app.receiveDir),
                    trailing: PlatformBridge.isWindows ? const Icon(Icons.edit_outlined) : null,
                    onTap: PlatformBridge.isWindows
                        ? () async {
                            final dir = await FilePicker.getDirectoryPath();
                            if (dir != null) await app.setReceiveDir(dir);
                          }
                        : null,
                  ),
                  if (PlatformBridge.canHostHotspot) ...[
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.wifi_tethering_rounded),
                      title: const Text('Offline mode'),
                      subtitle: const Text('Create a private Wi-Fi when sharing, so no router or internet is needed'),
                      value: app.offlineMode,
                      onChanged: app.setOfflineMode,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Appearance', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                          ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                          ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                        ],
                        selected: {app.themeMode},
                        onSelectionChanged: (s) => app.setThemeMode(s.first),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.fingerprint_rounded),
                title: const Text('Security key'),
                subtitle: Text(
                  '${app.identity.fingerprint.substring(0, 16).replaceAllMapped(RegExp(r'.{4}'), (m) => '${m[0]} ').trim()}...\n'
                  'Shared through the QR code. All transfers are encrypted (TLS).',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                isThreeLine: true,
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: Text('Beam Share 1.0.0 · offline · original quality · verified',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }
}
