import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/pages/watch_together/view.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fontPath = Platform.environment['PILIPLUS_QA_FONT'];
  setUpAll(() async {
    if (fontPath != null && File(fontPath).existsSync()) {
      final bytes = await File(fontPath).readAsBytes();
      await (FontLoader(
        'PiliQA',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });

  Future<void> mount(
    WidgetTester tester,
    PreviewWatchClient client, {
    Size size = const Size(390, 700),
    Brightness brightness = Brightness.light,
    double scale = 1,
    double keyboard = 0,
    Future<void> Function(String)? onJoin,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          brightness: brightness,
          colorSchemeSeed: const Color(0xFFFB7299),
          fontFamily: fontPath == null ? null : 'PiliQA',
        ),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('panel-preview'),
              child: WatchTogetherPanel(
                client: client,
                video: sampleVideo,
                onCreate: () async {},
                onJoin: onJoin ?? (_) async {},
                onConfigure: ({required serverUrl, required nickname}) async {},
                onLeave: () async {},
                onResynchronize: () async {},
                onResume: () async {},
                onOpenVideo: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['PILIPLUS_QA_DIR'];
    if (output == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('panel-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('welcome follows the app theme and exposes both room actions', (
    tester,
  ) async {
    await mount(tester, PreviewWatchClient());
    expect(find.text('创建双人房间'), findsOneWidget);
    expect(find.text('输入房间码加入'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'welcome-light');
  });

  testWidgets('first use offers connection settings without unusable buttons', (
    tester,
  ) async {
    await mount(tester, PreviewWatchClient(server: ''));
    expect(find.text('设置一起看服务'), findsOneWidget);
    expect(find.text('创建双人房间'), findsNothing);
    await tester.tap(find.text('设置一起看服务'));
    await tester.pumpAndSettle();
    expect(find.text('服务地址'), findsOneWidget);
    expect(find.text('房间昵称'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byType(TextField).first,
      'https://watch.example.com',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('一起看连接设置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'waiting room shows one person, invitation and no layout errors',
    (tester) async {
      final json = roomJson();
      (json['members'] as List).removeLast();
      await mount(
        tester,
        PreviewWatchClient(previewRoom: WatchRoom.fromJson(json)),
      );
      expect(find.text('等另一个人加入'), findsOneWidget);
      expect(find.textContaining('ABCD EFGH'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'waiting-light');
    },
  );

  for (final scenario in [
    (name: 'room-dark', size: const Size(390, 700), scale: 1.0, keyboard: 0.0),
    (
      name: 'room-landscape',
      size: const Size(480, 360),
      scale: 1.0,
      keyboard: 0.0,
    ),
    (
      name: 'room-large-text',
      size: const Size(320, 568),
      scale: 1.8,
      keyboard: 0.0,
    ),
    (
      name: 'room-keyboard',
      size: const Size(390, 700),
      scale: 1.0,
      keyboard: 280.0,
    ),
    (
      name: 'room-small-large-text-keyboard',
      size: const Size(320, 360),
      scale: 2.0,
      keyboard: 240.0,
    ),
  ]) {
    testWidgets('${scenario.name} remains usable without overflow', (
      tester,
    ) async {
      final json = roomJson(playing: true);
      json['messages'] = [
        {
          'id': '1',
          'memberId': 'b',
          'name': '小雨',
          'text': '等我拿点零食，我们一起看～',
          'sentAtMs': 100000,
        },
        {
          'id': '2',
          'memberId': 'a',
          'name': '小明',
          'text': '好呀，我在这里等你',
          'sentAtMs': 100001,
        },
      ];
      await mount(
        tester,
        PreviewWatchClient(previewRoom: WatchRoom.fromJson(json)),
        size: scenario.size,
        brightness: Brightness.dark,
        scale: scenario.scale,
        keyboard: scenario.keyboard,
      );
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, scenario.name);
    });
  }

  testWidgets(
    'invalid room code stays in the dialog and explains how to fix it',
    (tester) async {
      await mount(
        tester,
        PreviewWatchClient(),
        onJoin: (code) async {
          if (code.length != 8) throw const FormatException('请输入 8 位房间码');
        },
      );
      await tester.tap(find.text('输入房间码加入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123');
      await tester.tap(find.text('加入'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入 8 位房间码'), findsWidgets);
      expect(find.text('加入一起看'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
