import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/watch_together/view.dart';
import 'package:PiliPlus/services/watch_together/service.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:material_ui/material_ui.dart';

abstract final class WatchTogetherEntry {
  static Future<void>? show(
    BuildContext context, {
    VideoDetailController? controller,
    ThemeData? theme,
  }) {
    if (!context.mounted) return null;
    final service = WatchTogetherService.instance;
    controller ??= service.currentController;
    final currentController = controller;
    service.panelOpened();
    final panel = WatchTogetherPanel(
      client: service.client,
      video: currentController?.watchVideo,
      onCreate: () => service.createRoom(currentController),
      onJoin: service.joinRoom,
      onConfigure: service.configure,
      onLeave: service.leaveRoom,
      onResynchronize: service.resynchronize,
      onResume: service.client.resume,
      onOpenVideo: service.openRoomVideo,
    );
    final result = PageUtils.showVideoBottomSheet(
      context,
      maxWidth: 512,
      child: theme == null ? panel : Theme(data: theme, child: panel),
    );
    if (result == null) {
      service.panelClosed();
      return null;
    }
    return result.whenComplete(service.panelClosed);
  }
}
