import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class PlayOrPauseButton extends StatefulWidget {
  final PlPlayerController plPlayerController;

  const PlayOrPauseButton({
    super.key,
    required this.plPlayerController,
  });

  @override
  PlayOrPauseButtonState createState() => PlayOrPauseButtonState();
}

class PlayOrPauseButtonState extends State<PlayOrPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final StreamSubscription<bool> subscription;
  late final StreamSubscription<bool?> intentSubscription;
  late Player player;
  late bool _playing;

  @override
  void initState() {
    super.initState();
    player = widget.plPlayerController.videoPlayerController!;
    _playing =
        widget.plPlayerController.syncedPlayingIntent.value ??
        player.state.playing;
    controller = AnimationController(
      vsync: this,
      value: _playing ? 1 : 0,
      duration: const Duration(milliseconds: 200),
    );
    subscription = player.stream.playing.listen((_) => _updatePlaying());
    intentSubscription = widget.plPlayerController.syncedPlayingIntent.listen(
      (_) => _updatePlaying(),
    );
  }

  void _updatePlaying() {
    final playing =
        widget.plPlayerController.syncedPlayingIntent.value ??
        player.state.playing;
    if (!mounted || _playing == playing) return;
    setState(() => _playing = playing);
    if (playing) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  void dispose() {
    subscription.cancel();
    intentSubscription.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.plPlayerController.onDoubleTapCenter,
        child: Center(
          child: AnimatedIcon(
            semanticLabel: _playing ? '暂停' : '播放',
            progress: controller,
            icon: AnimatedIcons.play_pause,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}
