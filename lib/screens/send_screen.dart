import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../main.dart';
import '../models/picked_item.dart';
import '../services/platform_bridge.dart';
import '../util/format.dart';
import 'share_screen.dart';

/// Step 1 of sending: choose what to send.
class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final List<PickedItem> _items = [];
  bool _picking = false;

  Future<void> _pick(Future<List<PickedItem>> Function() picker) async {
    setState(() => _picking = true);
    try {
      final picked = await picker();
      // Ignore exact duplicates (same file picked twice).
      final seen = _items.map((i) => i.path ?? i.uri ?? i.relativePath).toSet();
      setState(() => _items.addAll(picked.where((i) => i.isDir || seen.add(i.path ?? i.uri ?? i.relativePath))));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open picker: $e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Groups items by their top-level name, so a folder with 2,000 files is
  /// one row instead of 2,000.
  List<_Group> get _groups {
    final map = <String, _Group>{};
    for (final i in _items) {
      final key = i.relativePath.contains('/') || i.isDir ? 'dir:${i.topLevel}' : 'file:${i.path ?? i.uri}';
      final g = map.putIfAbsent(key, () => _Group(key, i.topLevel, i.isDir || i.relativePath.contains('/')));
      g.items.add(i);
    }
    return map.values.toList();
  }

  int get _fileCount => _items.where((i) => !i.isDir).length;
  int get _bytes => _items.fold(0, (s, i) => s + (i.isDir ? 0 : i.size));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose what to send')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  _PickButton(
                    icon: Icons.photo_library_rounded,
                    label: 'Photos &\nvideos',
                    onTap: _picking ? null : () => _pick(PlatformBridge.pickMedia),
                  ),
                  const SizedBox(width: 12),
                  _PickButton(
                    icon: Icons.description_rounded,
                    label: 'Files',
                    onTap: _picking ? null : () => _pick(PlatformBridge.pickFiles),
                  ),
                  const SizedBox(width: 12),
                  _PickButton(
                    icon: Icons.folder_rounded,
                    label: 'Folder',
                    onTap: _picking ? null : () => _pick(PlatformBridge.pickFolder),
                  ),
                ],
              ),
            ),
            if (_picking) const LinearProgressIndicator(),
            Expanded(
              child: groups.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_circle_outline_rounded, size: 64, color: cs.outline),
                            const SizedBox(height: 12),
                            Text('Nothing selected yet',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Text('Pick as many files as you like. Thousands are fine.',
                                textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final g = groups[i];
                        final files = g.items.where((e) => !e.isDir).length;
                        final size = g.items.fold<int>(0, (s, e) => s + (e.isDir ? 0 : e.size));
                        return Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: CircleAvatar(
                              backgroundColor: cs.primary.withValues(alpha: 0.12),
                              child: Icon(g.isFolder ? Icons.folder_rounded : _iconFor(g.name), color: cs.primary),
                            ),
                            title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(g.isFolder ? '${plural(files, 'file')} · ${formatBytes(size)}' : formatBytes(size)),
                            trailing: IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => setState(() => _items.removeWhere(g.items.contains)),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            _BottomBar(
              fileCount: _fileCount,
              bytes: _bytes,
              onClear: _items.isEmpty ? null : () => setState(_items.clear),
              onNext: _fileCount == 0 && !_items.any((i) => i.isDir)
                  ? null
                  : () {
                      final t = AppScope.of(context).transfers;
                      t.setItems(List.of(_items));
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareScreen()));
                    },
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String name) {
    final ext = name.split('.').last.toLowerCase();
    const images = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'webp', 'dng', 'raw', 'cr2', 'nef', 'arw'};
    const videos = {'mp4', 'mov', 'mkv', 'avi', 'm4v', '3gp', 'webm'};
    const audio = {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'};
    if (images.contains(ext)) return Icons.image_rounded;
    if (videos.contains(ext)) return Icons.movie_rounded;
    if (audio.contains(ext)) return Icons.music_note_rounded;
    if (ext == 'apk') return Icons.android_rounded;
    if (ext == 'pdf') return Icons.picture_as_pdf_rounded;
    return Icons.insert_drive_file_rounded;
  }
}

class _Group {
  _Group(this.key, this.name, this.isFolder);
  final String key;
  final String name;
  final bool isFolder;
  final List<PickedItem> items = [];
}

class _PickButton extends StatelessWidget {
  const _PickButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(gradient: BeamColors.sendGradient, shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white),
                ),
                const SizedBox(height: 10),
                Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w600, color: onTap == null ? cs.outline : cs.onSurface)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.fileCount, required this.bytes, required this.onNext, required this.onClear});
  final int fileCount;
  final int bytes;
  final VoidCallback? onNext;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(plural(fileCount, 'file'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text(formatBytes(bytes), style: TextStyle(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          if (onClear != null) TextButton(onPressed: onClear, child: const Text('Clear')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Next'),
          ),
        ],
      ),
    );
  }
}
