import 'dart:async';

import 'package:flutter/services.dart';

import 'platform_channel.dart';

/// 播放页全屏的窗口级系统栏会话。
///
/// targetSdk 36 起 edge-to-edge 被强制，Flutter 的
/// `SystemUiMode.immersiveSticky`（legacy `SYSTEM_UI_FLAG_*`）会被系统忽略
/// （`SystemChrome.setEnabledSystemUIMode` 文档明说 target 36 上其它模式
/// 「will NOT work」），所以全屏改走原生 `WindowInsetsControllerCompat` ——
/// 与阅读器同一条路径，见 `lib/services/reader_device.dart`
/// 「Android 16 enforces edge-to-edge; hide bars through WindowInsetsController
/// without switching the window back to a legacy full-screen layout.」
///
/// 原生侧 `ReaderSystemBarsSession` 按 session 归属：`enter()` 领取独占，
/// `exit()` 只在仍是持有者时还原。播放页与阅读页共用同一个原生会话实例
/// （`fqapp/system_bars` 与 `fqapp/reader` 两个入口、同一个对象），所以：
///
/// * 播放页 push 出去的阅读页把系统栏接管过去后，播放页 dispose 时的
///   `exit()` 会被原生判成「不是持有者」而忽略，不会关掉阅读页的沉浸式；
/// * 反过来，阅读页的 `close()` 也不会关掉播放页的全屏。
///
/// 没有原生桥时（Windows 桌面、单元测试未 mock 通道）回退 Flutter 的
/// `SystemChrome`，与接入本服务之前的行为一致。
///
/// 下发**不等原生回执**：宿主没有实现这个通道时（桌面、未接桥的测试宿主）
/// 平台消息可能一直不返回，而这条请求挂在播放页的 `_systemUiUpdates` 串行
/// 链上 —— 等下去会把之后的系统栏与转向请求一起卡住，系统栏也可能再也撤不
/// 掉（`setPreferredOrientations` 的同类风险见 `video_player_chrome.dart` 里
/// issue #59 的注释）。消息在 `invokeMethod` 里同步投递，先后顺序仍由调用
/// 顺序决定，串行链的语义不变。
class PlayerSystemBars {
  static const _channel = AppMethodChannel('fqapp/system_bars');
  static int _nextSession = 0;

  /// 一次播放页全屏会话的归属标识。**同一实例的 enter/exit 必须用同一个
  /// id**：原生按 id 校验持有者，换 id 会让退出全屏时的还原被忽略
  /// （小白条撤不掉）。
  final String session =
      'player-${DateTime.now().microsecondsSinceEpoch}-${_nextSession++}';

  /// 进入沉浸式全屏：状态栏、导航栏与 caption bar 一起隐藏，滑动边缘临时
  /// 唤出后自动再隐藏。
  Future<void> enter() => _send(enabled: true);

  /// 退出沉浸式：还原进入之前记录的系统栏可见性与 cutout 模式。
  Future<void> exit() => _send(enabled: false);

  Future<void> _send({required bool enabled}) {
    final pending = _channel.invokeMethod<void>('setImmersive', {
      'session': session,
      'enabled': enabled,
      'showStatusBar': false,
    });
    unawaited(
      pending.catchError((Object error) {
        if (error is MissingPluginException) {
          // 没有原生桥：退回 legacy 路径，与接入前同一处调用、同一顺序。
          return _legacy(enabled);
        }
        // Activity 未就绪或正在重建：**不**改回 legacy，避免与当前页面
        // 持有的会话抢窗口状态；下一次进全屏或原生 focus reapply 会重新下发。
      }),
    );
    return Future<void>.value();
  }

  Future<void> _legacy(bool enabled) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(
        enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } catch (_) {}
  }
}
