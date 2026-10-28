import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/player_system_bars.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/desktop_video_chrome.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';

final _messenger =
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// 原生 `ReaderSystemBarsSession` 的最小镜像：一个 `owner`、一份「进入沉浸式
/// 之前」的懒快照、以及「非 owner 的 close 被静默忽略」。
///
/// 它的权威单测在
/// `android/app/src/test/java/com/fqapp/fqapp/ReaderSystemBarsSessionTest.kt`；
/// 这里的用途是让 Dart 侧证明两个通道（`fqapp/system_bars` / `fqapp/reader`）
/// 说的是同一套协议、共用同一个 owner —— 也就是 #176 补丁依赖的那条不变量。
class _NativeSystemBars {
  static const statusBars = 1;
  static const navigationBars = 2;
  static const captionBar = 4;
  static const allBars = statusBars | navigationBars | captionBar;

  int visible = allBars;
  String? owner;
  int? _original;
  final List<MethodCall> calls = [];
  final List<String> opened = [];
  final List<String> closes = [];

  bool get hidden => visible & navigationBars == 0;
  bool get barsVisible => visible != 0;

  void open(String session) {
    owner = session;
    opened.add(session);
    _original ??= visible;
    visible = 0;
  }

  void close(String session) {
    closes.add(session);
    if (owner != session) return;
    final original = _original;
    if (original != null) visible = original;
    _original = null;
    owner = null;
  }

  Future<Object?> _handle(String channel, MethodCall call) async {
    calls.add(call);
    final arguments = call.arguments;
    final session = arguments is Map ? arguments['session'] as String? : null;
    switch (call.method) {
      case 'setImmersive':
        if (session == null) return null;
        if ((arguments as Map)['enabled'] == true) {
          open(session);
        } else {
          close(session);
        }
      case 'suspend':
      case 'stop':
        if (session != null) close(session);
    }
    return null;
  }

  void install() {
    for (final channel in const ['fqapp/system_bars', 'fqapp/reader']) {
      _messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (call) => _handle(channel, call),
      );
    }
  }

  void uninstall() {
    for (final channel in const ['fqapp/system_bars', 'fqapp/reader']) {
      _messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
  }
}

/// 记录 `SystemChannels.platform` 上的调用。
///
/// 既用来断言 legacy 兜底（`SystemChrome.setEnabledSystemUIMode` 的取值），
/// 也让「退出全屏 = 先请求转向、再交还系统栏」这条串行链在 widget 测试宿主
/// 里能跑完：未接 mock 的平台通道在 `testWidgets` 的 FakeAsync 区里不会返回，
/// 链会永远悬着（既有播放器测试同样都装了这层 mock）。
class _PlatformLog {
  final List<MethodCall> calls = [];

  List<Object?> get uiModes => calls
      .where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode')
      .map((call) => call.arguments)
      .toList();

  List<List<String>> get orientations => calls
      .where((call) => call.method == 'SystemChrome.setPreferredOrientations')
      .map((call) => (call.arguments as List).map((value) => '$value').toList())
      .toList();

  void install() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
  }
}

Widget _app(Widget home) => MaterialApp(home: home);

Widget _player(
  FakeNativePlayer player, {
  bool openFullScreen = false,
  bool shortSeries = false,
}) => VideoPlayerChrome(
  player: player,
  shortSeries: shortSeries,
  openFullScreen: openFullScreen,
  episodes: [
    Chapter(itemId: '1', title: '第一集', volumeName: ''),
    Chapter(itemId: '2', title: '第二集', volumeName: ''),
  ],
  currentIndex: 0,
  duration: player.duration,
  playing: true,
  onSelectEpisode: (index) async {},
  onError: (error) => throw error,
  child: const ColoredBox(color: Colors.black),
);

/// 「详情 → 原著」的中转页；阅读页从这里 push，与真实栈形同形。
Widget _detailRoute(GlobalKey<NavigatorState> navigator) => Scaffold(
  body: Center(
    child: TextButton(
      onPressed: () => navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => _reader()),
      ),
      child: const Text('在原著中阅读'),
    ),
  ),
);

ReaderPage _reader() => ReaderPage(
  bookId: 'player-system-bars',
  title: '接力测试',
  chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '正文')],
  startIndex: 0,
  readerStore: MemoryReaderStore(),
  chapterCache: MemoryChapterCache(),
  chapterLoader: (_) async =>
      List.generate(45, (index) => '第 $index 段阅读正文。').join('\n\n'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // ── A 组：服务契约 ────────────────────────────────────────────────────
  group('PlayerSystemBars', () {
    test(
      'enter and exit share one owner id and never ask for the status bar',
      () async {
        final native = _NativeSystemBars()..install();
        addTearDown(native.uninstall);
        final bars = PlayerSystemBars();

        await bars.enter();
        await bars.exit();

        expect(native.calls.map((call) => call.method), [
          'setImmersive',
          'setImmersive',
        ]);
        final arguments = native.calls
            .map((call) => (call.arguments as Map).cast<String, Object?>())
            .toList();
        expect(arguments[0]['session'], arguments[1]['session']);
        expect(arguments[0]['session'], startsWith('player-'));
        expect(arguments[0]['enabled'], isTrue);
        expect(arguments[1]['enabled'], isFalse);
        expect(
          arguments.map((value) => value['showStatusBar']),
          everyElement(false),
        );
        // 每个实例一个 session id：两个播放页不能互相顶掉对方的归属。
        expect(PlayerSystemBars().session, isNot(bars.session));
      },
    );

    test(
      'a missing native bridge falls back to the legacy system ui modes',
      () async {
        final platform = _PlatformLog()..install();
        // 宿主没有这个原生桥时引擎回一个空响应（`MissingPluginException`）。
        // 只能用低层 handler 复现：`setMockMethodCallHandler` 会把返回值包成
        // 「成功」信封，而未接 mock 的通道在测试宿主里根本不会返回。
        const name = 'fqapp/system_bars';
        _messenger.setMockMessageHandler(name, (message) async => null);
        addTearDown(() => _messenger.setMockMessageHandler(name, null));
        final bars = PlayerSystemBars();

        await bars.enter();
        await bars.exit();
        await pumpEventQueue();

        expect(platform.uiModes, [
          'SystemUiMode.immersiveSticky',
          'SystemUiMode.edgeToEdge',
        ]);
      },
    );

    test(
      'a platform failure neither falls back nor steals the session',
      () async {
        final platform = _PlatformLog()..install();
        final attempts = <String>[];
        const channel = MethodChannel('fqapp/system_bars');
        _messenger.setMockMethodCallHandler(channel, (call) async {
          attempts.add(call.method);
          throw PlatformException(code: 'NO_ACTIVITY');
        });
        addTearDown(() => _messenger.setMockMethodCallHandler(channel, null));
        final bars = PlayerSystemBars();

        await bars.enter();
        await bars.exit();

        expect(attempts, ['setImmersive', 'setImmersive']);
        expect(
          platform.calls,
          isEmpty,
          reason: 'Activity 未就绪时改回 legacy 会与当前持有者抢窗口状态',
        );
      },
    );

    test(
      'the reader hand-off converges to hidden in both arrival orders',
      () async {
        final native = _NativeSystemBars()..install();
        addTearDown(native.uninstall);
        final bars = PlayerSystemBars();
        final reader = ReaderDevice();

        // 顺序甲：阅读页先交还（owner 归零 → 还原），播放页随后重新领取。
        await bars.enter();
        await reader.setImmersive(true);
        expect(native.hidden, isTrue);
        await reader.close();
        expect(native.barsVisible, isTrue, reason: '持有者离开时必须还原');
        await bars.enter();
        expect(native.owner, bars.session);
        expect(native.hidden, isTrue);

        // 顺序乙：播放页先重新领取，阅读页的 stop 后到 → 非 owner 的 close 被忽略。
        await bars.exit();
        expect(native.barsVisible, isTrue);
        await bars.enter();
        final late = ReaderDevice();
        await late.setImmersive(true);
        await bars.enter();
        await late.close();
        expect(native.owner, bars.session);
        expect(native.hidden, isTrue);

        // 退出全屏：恢复路径有配对的 show，系统栏完整回到进入前的状态。
        await bars.exit();
        expect(native.owner, isNull);
        expect(native.visible, _NativeSystemBars.allBars);
      },
    );
  });

  // ── B 组：播放页接线 ──────────────────────────────────────────────────
  group('VideoPlayerChrome fullscreen', () {
    testWidgets('the fullscreen pill opens one native session and closes it', (
      tester,
    ) async {
      final native = _NativeSystemBars()..install();
      addTearDown(native.uninstall);
      _PlatformLog().install();
      await tester.binding.setSurfaceSize(const Size(400, 888));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final player = FakeNativePlayer();

      await tester.pumpWidget(_app(_player(player, shortSeries: true)));
      await tester.pumpAndSettle();
      expect(native.owner, isNull);

      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pumpAndSettle();
      final session = native.owner;
      expect(session, startsWith('player-'));
      expect(native.hidden, isTrue);

      await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
      await tester.pumpAndSettle();
      expect(native.owner, isNull);
      expect(native.barsVisible, isTrue);
      expect(native.opened, [session]);
      expect(native.closes, contains(session));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await player.dispose();
    });

    testWidgets('entering fullscreen from the page start takes the session', (
      tester,
    ) async {
      final native = _NativeSystemBars()..install();
      addTearDown(native.uninstall);
      _PlatformLog().install();
      final player = FakeNativePlayer();

      await tester.pumpWidget(_app(_player(player, openFullScreen: true)));
      await tester.pumpAndSettle();

      final session = native.owner;
      expect(session, startsWith('player-'));
      expect(native.hidden, isTrue);

      // dispose 用同一个 session 交还：换 id 会被原生判成非 owner 而忽略。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(native.owner, isNull);
      expect(native.barsVisible, isTrue);
      expect(native.closes.last, session);
      await player.dispose();
    });

    testWidgets(
      'fullscreen keeps the chrome auto-hidden on the native path (#59)',
      (tester) async {
        final native = _NativeSystemBars()..install();
        addTearDown(native.uninstall);
        _PlatformLog().install();
        await tester.binding.setSurfaceSize(const Size(400, 888));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final player = FakeNativePlayer()..isPlaying = true;

        await tester.pumpWidget(_app(_player(player, shortSeries: true)));
        await tester.pumpAndSettle();
        expect(find.text('全屏观看'), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        expect(find.text('全屏观看'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('player-fullscreen-pill')));
        await tester.pump();
        expect(native.hidden, isTrue);
        await tester.pump(const Duration(seconds: 4));
        // 原生路径生效时控件仍然按时收起：收起计时排在系统 UI 请求之前。
        expect(find.text('全屏观看'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('video-surface')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('全屏观看'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await player.dispose();
      },
    );

    testWidgets(
      'a reader visit keeps the bars hidden and returns the session',
      (tester) async {
        final native = _NativeSystemBars()..install();
        addTearDown(native.uninstall);
        _PlatformLog().install();
        final navigator = GlobalKey<NavigatorState>();
        final player = FakeNativePlayer();

        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: _player(player)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('全屏'));
        await tester.pumpAndSettle();
        final playerSession = native.owner;
        expect(playerSession, startsWith('player-'));
        expect(native.hidden, isTrue);

        // 播放页全屏 → 详情（播放页被盖住，不释放自己的会话）。
        navigator.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => _detailRoute(navigator)),
        );
        await tester.pumpAndSettle();
        expect(native.owner, playerSession);
        expect(native.hidden, isTrue);

        // 原著 → 阅读页：阅读器默认进沉浸态，接管同一个会话。
        await tester.tap(find.text('在原著中阅读'));
        await tester.pumpAndSettle();
        expect(native.owner, isNot(playerSession));
        expect(native.hidden, isTrue);
        expect(native.opened, hasLength(2));

        // 阅读页返回：它按 owner 交还，系统栏回到可见。
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(native.owner, isNull);
        expect(native.barsVisible, isTrue);

        // 回到播放页：重新领取同一个会话，全屏态不再让小白条复现。
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(native.owner, playerSession);
        expect(native.hidden, isTrue);

        // 退出全屏（返回键语义）：完整还原。
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(native.owner, isNull);
        expect(native.visible, _NativeSystemBars.allBars);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await player.dispose();
      },
    );

    testWidgets(
      'windows desktop keeps the legacy path and the desktop chrome',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final platform = _PlatformLog()..install();
        final attempts = <String>[];
        // 模仿 `lib/services/desktop_platform.dart` 的 Windows 适配层：白名单外
        // 的通道一律 MissingPluginException，`fqapp/reader` 直通 no-op。
        PlatformChannels.invoke = (channel, method, arguments) async {
          attempts.add('$channel/$method');
          if (channel == 'fqapp/reader') return null;
          throw MissingPluginException('$channel/$method');
        };
        final player = FakeNativePlayer();
        addTearDown(() async {
          PlatformChannels.invoke = null;
          await player.dispose();
        });

        await tester.pumpWidget(_app(_player(player, openFullScreen: true)));
        await tester.pumpAndSettle();
        expect(find.byType(DesktopVideoChrome), findsOneWidget);
        expect(attempts, contains('fqapp/system_bars/setImmersive'));
        expect(platform.uiModes, ['SystemUiMode.immersiveSticky']);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(platform.uiModes, [
          'SystemUiMode.immersiveSticky',
          'SystemUiMode.edgeToEdge',
        ]);
        // 桌面没有原生桥，播放页只走 legacy 兜底，且不碰阅读页的通道。
        expect(
          attempts.where((call) => call.startsWith('fqapp/reader/')),
          isEmpty,
        );
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
