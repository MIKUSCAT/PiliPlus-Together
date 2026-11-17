import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/play_pause_btn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class _PlayerStream extends Fake implements PlayerStream {
  _PlayerStream(this.playing);
  @override
  final Stream<bool> playing;
}

class _Player extends Fake implements Player {
  final changes = StreamController<bool>.broadcast();
  @override
  final state = PlayerState();
  @override
  late final stream = _PlayerStream(changes.stream);

  void setPlaying(bool playing) {
    state.playing = playing;
    changes.add(playing);
  }
}

class _Controller extends Fake implements PlPlayerController {
  _Controller(this.videoPlayerController);
  @override
  final _Player videoPlayerController;
  @override
  final syncedPlayingIntent = RxnBool();
  int taps = 0;
  @override
  Future<void> onDoubleTapCenter() async => taps++;
}

void main() {
  testWidgets(
    'pause remains available while waiting, then restores local controls',
    (tester) async {
      final native = _Player();
      final player = _Controller(native)..syncedPlayingIntent.value = true;
      addTearDown(native.changes.close);
      addTearDown(player.syncedPlayingIntent.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayOrPauseButton(plPlayerController: player),
        ),
      );
      AnimatedIcon icon() =>
          tester.widget<AnimatedIcon>(find.byType(AnimatedIcon));

      // The room intends to play, although native playback has stopped to wait.
      expect(native.state.playing, isFalse);
      expect(icon().semanticLabel, '暂停');
      expect(icon().progress.value, 1);
      await tester.tap(find.byType(PlayOrPauseButton));
      expect(player.taps, 1);

      // A manual room pause updates immediately without any new native event.
      player.syncedPlayingIntent.value = false;
      await tester.pumpAndSettle();
      expect(icon().semanticLabel, '播放');
      expect(icon().progress.value, 0);

      // Leaving the room restores the native player's usual play/pause display.
      player.syncedPlayingIntent.value = null;
      native.setPlaying(true);
      await tester.pumpAndSettle();
      expect(icon().semanticLabel, '暂停');
      native.setPlaying(false);
      await tester.pumpAndSettle();
      expect(icon().semanticLabel, '播放');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
