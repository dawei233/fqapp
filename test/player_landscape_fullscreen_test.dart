import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/widgets/desktop_video_chrome.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

final _messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 记录播放页下发的系统栏会话请求（`PlayerSystemBars`）。
class _SystemBarLog {
  final List<Map<Object?, Object?>> requests = [];

  List<bool?> get enabled =>
      requests.map((arguments) => arguments['enabled'] as bool?).toList();

  void install() {
    _messenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/system_bars'),
      (call) async {
        final arguments = call.arguments;
        if (call.method == 'setImmersive' && arguments is Map) {
          requests.add(arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => _messenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/system_bars'),
        null,
      ),
    );
  }
}

/// 记录 `SystemChannels.platform` 的调用。
///
/// 既用来断言转向请求，也让「点全屏 → 转向 → 系统栏」这条串行链在测试宿主
/// 里跑得完（未接 mock 的平台通道在 FakeAsync 区里不会返回）。
List<List<String>> _installPlatformLog() {
  final orientations = <List<String>>[];
  _messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemChrome.setPreferredOrientations') {
      final arguments = call.arguments;
      if (arguments is List) {
        orientations.add(arguments.map((value) => '$value').toList());
      }
    }
    return null;
  });
  addTearDown(
    () => _messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return orientations;
}

/// 与 `test/player_split_layout_test.dart:380-394` 同形的 mount：**直接用横屏
/// 窗口挂载**，全程不点竖屏胶囊 —— 这样才覆盖「未进全屏就转横」的真实路径。
Future<FakeNativePlayer> _mount(
  WidgetTester tester, {
  Size window = const Size(900, 420),
  EdgeInsets padding = EdgeInsets.zero,
  Size videoSize = const Size(1080, 1920),
  PlayerLayoutMode mode = PlayerLayoutMode.immersive,
  double textScale = 1,
  bool withPanel = false,
  bool landscapeLockEnabled = false,
  List<EpisodeVariant> qualityVariants = const [],
  String? currentQualityUrl,
  bool openFullScreen = false,
}) async {
  await tester.binding.setSurfaceSize(window);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // setSurfaceSize 只改渲染尺寸，MediaQuery 仍是 800×600；横竖屏判据读设备
  // 朝向，必须让两者一致。
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final player = FakeNativePlayer(
    width: videoSize.width.toInt(),
    height: videoSize.height.toInt(),
  )..isPlaying = true;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(padding: padding, textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: VideoPlayerChrome(
        player: player,
        title: '横屏全屏入口测试',
        episodes: [
          for (var i = 0; i < 12; i++)
            Chapter(itemId: '${i + 1}', title: '第${i + 1}集', volumeName: ''),
        ],
        currentIndex: 0,
        playingIndex: 0,
        playing: true,
        duration: player.duration,
        shortSeries: true,
        layoutMode: mode,
        landscapeLockEnabled: landscapeLockEnabled,
        openFullScreen: openFullScreen,
        qualityVariants: qualityVariants,
        currentQualityUrl: currentQualityUrl,
        splitPanel: withPanel
            ? const ColoredBox(
                key: ValueKey('fake-split-panel'),
                color: Colors.blueGrey,
              )
            : null,
        onSelectEpisode: (index) async {},
        onError: (error) => throw error,
        child: const ColoredBox(color: Colors.black),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return player;
}

final _fullscreenButton = find.byKey(const ValueKey('landscape-fullscreen'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.5});
    // 竖屏形态按窗口宽高判；默认测试窗口 800×600 是横屏，这里统一钉成手机
    // 竖屏，要横屏的用例自己 setSurfaceSize。
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(400, 888);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets(
    'a landscape window offers the fullscreen entry and tapping it enters it',
    (tester) async {
      // 横屏整屏态：`_information`（含「全屏观看」胶囊）被 `!landscape`
      // 一刀切掉，此前没有任何全屏出口。
      final bars = _SystemBarLog()..install();
      final orientations = _installPlatformLog();
      await _mount(tester, window: const Size(900, 420));

      expect(_fullscreenButton, findsOneWidget);
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(bars.requests, isEmpty);

      await tester.tap(_fullscreenButton);
      await tester.pumpAndSettle();

      expect(bars.enabled, [true]);
      expect(orientations.last, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      // 同一颗钮变成退出全屏：出口双向可见。
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);

      await tester.tap(_fullscreenButton);
      await tester.pumpAndSettle();
      expect(bars.enabled, [true, false]);
      expect(find.byTooltip('全屏'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the landscape entry mirrors the immersive state', (
    tester,
  ) async {
    _installPlatformLog();
    await _mount(tester, window: const Size(900, 420), openFullScreen: true);

    // 进页即全屏：底条入口直接显示「退出全屏」。
    expect(_fullscreenButton, findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rotating to landscape without the pill still reaches fullscreen',
    (tester) async {
      // 核心缺口：用户没点过竖屏胶囊、只是把设备横过来，此前无法进沉浸态。
      final bars = _SystemBarLog()..install();
      _installPlatformLog();
      await _mount(tester, window: const Size(900, 420));
      expect(bars.requests, isEmpty);
      expect(
        find.byKey(const ValueKey('player-fullscreen-pill')),
        findsNothing,
      );
      expect(_fullscreenButton, findsOneWidget);

      await tester.tap(_fullscreenButton);
      await tester.pumpAndSettle();

      // 原生会话领取成功：这就是隐藏手势导航条的那条路径。
      expect(bars.enabled, [true]);
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the landscape chrome still auto-hides after fullscreen (#59)', (
    tester,
  ) async {
    _installPlatformLog();
    await _mount(tester, window: const Size(900, 420));
    await tester.pump(const Duration(seconds: 4));
    // 未全屏时横屏底条照常 3 秒收起（既有行为）。
    expect(_fullscreenButton, findsNothing);
    await tester.tap(find.byKey(const ValueKey('video-surface')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_fullscreenButton, findsOneWidget);

    await tester.tap(_fullscreenButton);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    // 进全屏后控件仍按时收起：收起计时排在系统 UI 请求之前。
    expect(_fullscreenButton, findsNothing);
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('video-surface')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_fullscreenButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open episode drawer takes the entry off screen', (
    tester,
  ) async {
    _installPlatformLog();
    await _mount(tester, window: const Size(900, 420));

    // 面板打开：底条整体离屏（showChrome = !_panelOpen && !_overlayOpen）。
    await tester.tap(find.byKey(const ValueKey('landscape-episodes')));
    // 抽屉里有循环 Lottie，固定时长 pump（勿 settle）。
    await tester.pump(const Duration(milliseconds: 250));
    expect(_fullscreenButton, findsNothing);
    await tester.tap(find.byKey(const ValueKey('story-drawer-close')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_fullscreenButton, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear screen hides the landscape entry with the bar', (
    tester,
  ) async {
    _installPlatformLog();
    // 清屏入口只在竖屏底栏：「先在竖屏清屏，再把设备转横」是真实路径。
    await _mount(tester, window: const Size(400, 888));
    await tester.tap(find.byKey(const ValueKey('player-clear-screen')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(900, 420));
    await tester.pump();
    expect(_fullscreenButton, findsNothing);
    expect(find.byKey(const ValueKey('landscape-play')), findsNothing);
    // 横屏没有全屏出口也不能是死局：清屏态仍留着「恢复」文案出口。
    expect(find.text('恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locked landscape screen hides the entry with the bar', (
    tester,
  ) async {
    _installPlatformLog();
    // 锁按钮的门是「横屏且处于全屏态」（`_landscapeLockShown` 看 `_isLandscape`
    // = `_fullScreen && 窗口宽>高`），所以这里进页即全屏再挂横屏窗口。
    await _mount(
      tester,
      window: const Size(900, 420),
      landscapeLockEnabled: true,
      openFullScreen: true,
    );
    expect(find.byKey(const ValueKey('landscape-lock')), findsOneWidget);
    expect(_fullscreenButton, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('landscape-lock')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('video-surface')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_fullscreenButton, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a split compact bar keeps its own entry, never both', (
    tester,
  ) async {
    _installPlatformLog();
    await _mount(
      tester,
      window: const Size(407, 904),
      padding: const EdgeInsets.only(top: 39, bottom: 16),
      mode: PlayerLayoutMode.split,
      withPanel: true,
    );
    expect(find.byKey(const ValueKey('compact-fullscreen')), findsOneWidget);
    expect(_fullscreenButton, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the entry survives 2.5x text on a short landscape window', (
    tester,
  ) async {
    _installPlatformLog();
    // 控制行是固定 40dp 高：文字版在 2.5× 下会溢出，图标版与字号解耦。
    await _mount(tester, window: const Size(794, 361), textScale: 2.5);
    expect(_fullscreenButton, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(_fullscreenButton);
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the right cluster stays inside a 640x360 window', (
    tester,
  ) async {
    _installPlatformLog();
    const variants = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k', height: 1080),
      EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k', height: 720),
    ];
    await _mount(
      tester,
      window: const Size(640, 360),
      qualityVariants: variants,
      currentQualityUrl: 'u720',
    );
    expect(_fullscreenButton, findsOneWidget);
    final quality = tester.getRect(
      find.byKey(const ValueKey('landscape-quality')),
    );
    final entry = tester.getRect(_fullscreenButton);
    expect(quality.right, lessThanOrEqualTo(entry.left));
    // 右簇（含 +16 padding）不溢出窗口。
    expect(entry.right, lessThanOrEqualTo(640));
    expect(quality.left, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('windows desktop does not render the mobile bar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _mount(tester, window: const Size(900, 420));
    expect(find.byType(DesktopVideoChrome), findsOneWidget);
    expect(_fullscreenButton, findsNothing);
    expect(tester.takeException(), isNull);
    // 复位必须发生在测试体之内：debug 变量由框架在测试体结束时校验。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the portrait pill wording is unchanged', (tester) async {
    _installPlatformLog();
    await _mount(tester, window: const Size(400, 888));
    // 竖屏胶囊仍写「全屏观看」：新按钮只有 tooltip，不会撞上既有的
    // `find.text('全屏观看')` 断言。
    expect(find.text('全屏观看'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-fullscreen-pill')),
      findsOneWidget,
    );
    expect(_fullscreenButton, findsNothing);
    expect(find.byTooltip('全屏'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
