import 'dart:math' as math;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/watch_together.dart';
import 'package:PiliPlus/services/watch_together/client.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

typedef ConfigureWatchTogether = Future<void> Function({
  required String serverUrl,
  required String nickname,
});

/// Uses the same Material theme, spacing and image component as the video
/// panels. All actions are injected so layouts can be tested without a player.
class WatchTogetherPanel extends StatefulWidget {
  const WatchTogetherPanel({
    super.key,
    required this.client,
    required this.onCreate,
    required this.onJoin,
    required this.onConfigure,
    required this.onLeave,
    required this.onResynchronize,
    required this.onResume,
    required this.onOpenVideo,
    this.video,
  });

  final WatchTogetherClient client;
  final WatchVideo? video;
  final Future<void> Function() onCreate;
  final Future<void> Function(String code) onJoin;
  final ConfigureWatchTogether onConfigure;
  final Future<void> Function() onLeave;
  final Future<void> Function() onResynchronize;
  final Future<void> Function() onResume;
  final VoidCallback onOpenVideo;

  @override
  State<WatchTogetherPanel> createState() => _WatchTogetherPanelState();
}

class _WatchTogetherPanelState extends State<WatchTogetherPanel> {
  final _message = TextEditingController();
  final _scroll = ScrollController();
  bool _working = false;
  String? _actionError;
  String? _lastRoomCode;
  String? _lastMessageId;

  @override
  void dispose() {
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _actionError = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final keyboard = math.min(
          MediaQuery.viewInsetsOf(context).bottom,
          math.max(0.0, constraints.maxHeight - 180),
        );
        return AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.fromLTRB(12, 12, 12, keyboard + 12),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            clipBehavior: Clip.antiAlias,
            child: AnimatedBuilder(
              animation: widget.client,
              builder: (context, _) {
                final client = widget.client;
                final room = client.room;
                final compact =
                    client.joined &&
                    room != null &&
                    constraints.maxHeight - keyboard - 24 < 170;
                if (compact) {
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: _composer(theme, compact: true),
                  );
                }
                final lastMessageId = room?.messages.lastOrNull?.id;
                if (_lastRoomCode != room?.code) {
                  _lastRoomCode = room?.code;
                  _lastMessageId = lastMessageId;
                } else if (lastMessageId != _lastMessageId) {
                  final nearBottom =
                      !_scroll.hasClients || _scroll.position.extentAfter < 100;
                  _lastMessageId = lastMessageId;
                  if (nearBottom) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _scroll.hasClients) {
                        _scroll.animateTo(
                          _scroll.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                        );
                      }
                    });
                  }
                }
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 4,
                        top: 4,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '一起看',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (_working || client.busy)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          IconButton(
                            tooltip: '连接设置',
                            onPressed: _working ? null : _showSettings,
                            icon: const Icon(Icons.settings_outlined, size: 21),
                          ),
                          IconButton(
                            tooltip: '收起',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.close, size: 21),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        children: [
                          if (_actionError ?? client.error case final error?)
                            _notice(
                              error,
                              theme.colorScheme.errorContainer,
                              theme.colorScheme.onErrorContainer,
                            ),
                          if (client.joined && room != null)
                            ..._roomContent(room, theme)
                          else
                            ..._welcomeContent(theme),
                        ],
                      ),
                    ),
                    if (client.joined && room != null) _composer(theme),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _notice(String text, Color background, Color foreground) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: Style.mdRadius,
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: foreground)),
    ),
  );

  List<Widget> _welcomeContent(ThemeData theme) {
    final configured = widget.client.serverUrl.isNotEmpty;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: theme.colorScheme.secondaryContainer,
              child: Icon(
                Icons.group_outlined,
                size: 32,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text('和另一个人一起看', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '同步播放、暂停和进度，等彼此一起继续',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
      if (widget.video case final video?) ...[
        _videoTile(video, theme),
        const SizedBox(height: 20),
      ],
      if (!configured) ...[
        Text(
          '先填写你们使用的一起看服务地址，之后就能通过房间码相互邀请。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _showSettings,
          icon: const Icon(Icons.link),
          label: const Text('设置一起看服务'),
        ),
      ] else ...[
        FilledButton.icon(
          onPressed: _working || widget.client.busy
              ? null
              : () => _run(widget.onCreate),
          icon: const Icon(Icons.add),
          label: const Text('创建双人房间'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _working || widget.client.busy ? null : _showJoin,
          icon: const Icon(Icons.meeting_room_outlined),
          label: const Text('输入房间码加入'),
        ),
        if (widget.client.savedSession != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _working ? null : () => _run(_resumeRoom),
            icon: const Icon(Icons.history, size: 18),
            label: const Text('返回上次的房间'),
          ),
        ],
      ],
    ];
  }

  List<Widget> _roomContent(WatchRoom room, ThemeData theme) {
    final client = widget.client;
    final members = room.members;
    final status = client.connected ? room.status : '连接暂时断开，正在重连';
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _member(members.isEmpty ? null : members.first, theme),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Icon(
                Icons.link,
                color: theme.colorScheme.outline,
                size: 22,
              ),
            ),
            Expanded(
              child: _member(members.length < 2 ? null : members[1], theme),
            ),
          ],
        ),
      ),
      Center(
        child: Text(
          status,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: client.connected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Center(
        child: OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(
                text:
                    '一起来 PiliPlus 看视频\n房间码：${room.displayCode}\n服务地址：${client.serverUrl}',
              ),
            );
            if (mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('邀请信息已复制'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          },
          icon: const Icon(Icons.copy_outlined, size: 16),
          label: Text('房间码  ${room.displayCode}'),
        ),
      ),
      for (final member in members)
        if (member.error case final error?) ...[
          const SizedBox(height: 8),
          _notice(
            '${member.name}：$error',
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.onSurfaceVariant,
          ),
        ],
      const SizedBox(height: 12),
      if (room.video case final video?)
        _videoTile(
          video,
          theme,
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenVideo();
          },
        )
      else
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('选一个视频，一起看吧', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '进入视频播放页后，会自动同步给对方',
            style: TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).pop(),
        ),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: _working ? null : () => _run(widget.onResynchronize),
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('重新同步'),
          ),
          TextButton.icon(
            onPressed: _working ? null : () => _run(widget.onLeave),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('退出一起看'),
          ),
        ],
      ),
      Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      if (room.messages.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Text(
            '说句话，陪对方等一会儿',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        )
      else
        for (final message in room.messages) _chatBubble(message, theme),
    ];
  }

  Widget _member(WatchMember? member, ThemeData theme) {
    final me = member?.id == widget.client.session?.memberId;
    final name = member?.name ?? '等另一个人';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: member == null
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.secondaryContainer,
          child: member == null
              ? Icon(
                  Icons.person_add_alt_outlined,
                  color: theme.colorScheme.outline,
                )
              : Text(
                  name.characters.first,
                  style: TextStyle(
                    fontSize: 22,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            me ? '$name（我）' : name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          member?.status ?? '分享房间码邀请',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _videoTile(WatchVideo video, ThemeData theme, {VoidCallback? onTap}) =>
      Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: Style.mdRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                NetworkImgLayer(
                  src: video.cover,
                  width: 80,
                  height: 50,
                  getPlaceHolder: () => SizedBox(
                    width: 80,
                    height: 50,
                    child: Icon(
                      Icons.ondemand_video,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        video.kind == 'pgc' ? '番剧 / 影视' : '当前视频',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onTap != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.chevron_right, size: 20),
                  ),
              ],
            ),
          ),
        ),
      );

  Widget _chatBubble(WatchMessage message, ThemeData theme) {
    final me = message.memberId == widget.client.session?.memberId;
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: math.min(320, MediaQuery.sizeOf(context).width * 0.68),
        ),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: me
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: Style.mdRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!me) ...[
              Text(
                message.name,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 3),
            ],
            Text(
              message.text,
              style: TextStyle(
                fontSize: 14,
                color: me
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(ThemeData theme, {bool compact = false}) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (compact)
          IconButton(
            tooltip: '收起',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, size: 20),
          ),
        Expanded(
          child: TextField(
            controller: _message,
            enabled: widget.client.connected,
            maxLength: 500,
            textInputAction: TextInputAction.send,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: widget.client.connected ? '说点什么…' : '重新连接后可以发送',
              counterText: '',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _sendMessage(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '发送',
          onPressed:
              widget.client.connected &&
                  !_working &&
                  _message.text.trim().isNotEmpty
              ? _sendMessage
              : null,
          icon: Icon(
            Icons.send_outlined,
            color: _message.text.trim().isEmpty
                ? null
                : theme.colorScheme.primary,
          ),
        ),
      ],
    ),
  );

  Future<void> _sendMessage() => _run(() async {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    await widget.client.command('chat', {'text': message});
    _message.clear();
  });

  Future<void> _resumeRoom() async {
    await widget.onResume();
    if (mounted &&
        widget.client.connected &&
        widget.client.room?.video != null) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _showSettings() => showDialog<void>(
    context: context,
    builder: (_) => _WatchSettingsDialog(
      client: widget.client,
      onConfigure: widget.onConfigure,
    ),
  );

  Future<void> _showJoin() async {
    final joined = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WatchJoinDialog(onJoin: widget.onJoin),
    );
    if (joined == true && mounted && widget.client.room?.video != null) {
      Navigator.of(context).pop();
    }
  }
}

// Text controllers belong to the dialog route, including its closing animation.
// A showDialog future completes on pop, before those widgets are disposed.
class _WatchSettingsDialog extends StatefulWidget {
  const _WatchSettingsDialog({required this.client, required this.onConfigure});
  final WatchTogetherClient client;
  final ConfigureWatchTogether onConfigure;

  @override
  State<_WatchSettingsDialog> createState() => _WatchSettingsDialogState();
}

class _WatchSettingsDialogState extends State<_WatchSettingsDialog> {
  late final _server = TextEditingController(text: widget.client.serverUrl);
  late final _name = TextEditingController(text: widget.client.nickname);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _server.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onConfigure(serverUrl: _server.text, nickname: _name.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = !widget.client.joined;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('一起看连接设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _server,
                enabled: editable && !_saving,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'https://watch.example.com',
                  helperText: '填写部署后提供的地址',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                enabled: editable && !_saving,
                maxLength: 24,
                decoration: const InputDecoration(
                  labelText: '房间昵称',
                  counterText: '',
                ),
              ),
              if (!editable)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('退出房间后可以修改连接设置', style: TextStyle(fontSize: 12)),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: !editable || _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存'),
          ),
        ],
      ),
    );
  }
}

class _WatchJoinDialog extends StatefulWidget {
  const _WatchJoinDialog({required this.onJoin});
  final Future<void> Function(String code) onJoin;

  @override
  State<_WatchJoinDialog> createState() => _WatchJoinDialogState();
}

class _WatchJoinDialogState extends State<_WatchJoinDialog> {
  final _code = TextEditingController();
  String? _error;
  bool _joining = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await widget.onJoin(_code.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _joining = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_joining,
    child: AlertDialog(
      title: const Text('加入一起看'),
      content: TextField(
        controller: _code,
        autofocus: true,
        enabled: !_joining,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: '房间码',
          hintText: '输入 8 位房间码',
          helperText: '也可以粘贴完整的邀请信息',
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _joining ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _joining ? null : _join,
          child: Text(_joining ? '正在加入…' : '加入'),
        ),
      ],
    ),
  );
}
