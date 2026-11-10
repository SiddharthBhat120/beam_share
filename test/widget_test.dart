import 'package:beam_share/app/theme.dart';
import 'package:beam_share/services/platform_bridge.dart';
import 'package:beam_share/util/format.dart';
import 'package:beam_share/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('format', () {
    test('bytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1536), '1.50 KB');
      expect(formatBytes(5 * 1024 * 1024 * 1024), '5.00 GB');
      expect(formatBytes(123 * 1024 * 1024), '123 MB');
    });
    test('durations and counts', () {
      expect(formatDuration(const Duration(seconds: 42)), '42 s');
      expect(formatDuration(const Duration(seconds: 125)), '2 min 05 s');
      expect(formatDuration(const Duration(minutes: 62)), '1 h 02 min');
      expect(formatCount(1234567), '1,234,567');
      expect(plural(1, 'file'), '1 file');
      expect(plural(1003, 'file'), '1,003 files');
    });
  });

  test('Wi-Fi QR for the iPhone camera escapes special characters', () {
    expect(PlatformBridge.wifiQrData('DIRECT-bs-PC', 'abc123'), 'WIFI:T:WPA;S:DIRECT-bs-PC;P:abc123;;');
    expect(PlatformBridge.wifiQrData('My;Net', r'p:a\ss'), r'WIFI:T:WPA;S:My\;Net;P:p\:a\\ss;;');
  });

  testWidgets('action card and progress ring render in dark mode', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Column(children: [
          ActionCard(
            title: 'Send',
            subtitle: 'Files',
            icon: Icons.arrow_upward,
            gradient: BeamColors.sendGradient,
            onTap: () => tapped = true,
          ),
          const ProgressRing(value: 0.42, child: Text('42%')),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    await tester.tap(find.text('Send'));
    expect(tapped, isTrue);
  });
}
