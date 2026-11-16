import 'package:flutter/material.dart';

import 'app_dialog.dart';

/// Owns the input controller until the dialog route has finished exiting.
class PlaylistNameDialog extends StatefulWidget {
  const PlaylistNameDialog({
    super.key,
    required this.title,
    this.initialValue = '',
  });

  final String title;
  final String initialValue;

  @override
  State<PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<PlaylistNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? value]) {
    final name = (value ?? _controller.text).trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: widget.title,
      description: widget.initialValue.isEmpty
          ? '给歌单一个容易识别的名字，稍后仍可重命名。'
          : '修改后会立即同步到本地歌单。',
      icon: widget.initialValue.isEmpty
          ? Icons.playlist_add_rounded
          : Icons.edit_outlined,
      width: 450,
      actions: <Widget>[
        TextButton(
          key: const ValueKey('cancel-playlist-name'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save-playlist-name'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
      child: AppTextField(
        key: const ValueKey('playlist-name-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        textInputAction: TextInputAction.done,
        labelText: '歌单名称',
        hintText: '例如：通勤、深夜、收藏',
        onSubmitted: _submit,
      ),
    );
  }
}
