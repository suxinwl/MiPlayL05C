import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 与客户端视觉风格一致的通用弹窗。
class AppDialog extends StatelessWidget {
  /// 创建通用弹窗。
  const AppDialog({
    super.key,
    required this.title,
    required this.child,
    this.description,
    this.icon = Icons.auto_awesome_rounded,
    this.actions = const <Widget>[],
    this.width = 460,
  });

  /// 弹窗标题。
  final String title;

  /// 标题下方的辅助说明。
  final String? description;

  /// 标题左侧图标。
  final IconData icon;

  /// 弹窗主体。
  final Widget child;

  /// 底部操作区。
  final List<Widget> actions;

  /// 弹窗最大宽度。
  final double width;

  @override
  Widget build(BuildContext context) {
    final availableHeight = MediaQuery.sizeOf(context).height - 48;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: availableHeight.clamp(320, 820),
        ),
        child: DecoratedBox(
          decoration: appDialogDecoration(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: AppColors.accentSoft,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: AppColors.accentBorder),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        icon,
                        size: 20,
                        color: AppColors.accentStrong,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          if (description != null) ...<Widget>[
                            const SizedBox(height: 5),
                            Text(
                              description!,
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                child,
                if (actions.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  const Divider(height: 1, color: AppColors.border),
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 10,
                    runSpacing: 8,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 带统一标签、边框和计数器样式的文本输入框。
class AppTextField extends StatelessWidget {
  /// 创建文本输入框。
  const AppTextField({
    super.key,
    required this.controller,
    required this.labelText,
    this.hintText,
    this.autofocus = false,
    this.maxLength,
    this.textInputAction,
    this.onSubmitted,
  });

  /// 输入控制器。
  final TextEditingController controller;

  /// 字段标签。
  final String labelText;

  /// 空值提示。
  final String? hintText;

  /// 是否自动获得焦点。
  final bool autofocus;

  /// 最大字符数。
  final int? maxLength;

  /// 键盘动作。
  final TextInputAction? textInputAction;

  /// 提交回调。
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      maxLength: maxLength,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        prefixIcon: const Icon(Icons.edit_rounded, size: 18),
      ),
    );
  }
}

/// 与表单控件风格一致的下拉选择框。
class AppSelectField<T> extends StatelessWidget {
  /// 创建下拉选择框。
  const AppSelectField({
    super.key,
    required this.value,
    required this.labelText,
    required this.items,
    required this.onChanged,
    this.prefixIcon = Icons.tune_rounded,
    this.fieldKey,
  });

  /// 当前选中值。
  final T value;

  /// 字段标签。
  final String labelText;

  /// 可选项目。
  final List<DropdownMenuItem<T>> items;

  /// 选择变化回调。
  final ValueChanged<T?> onChanged;

  /// 左侧图标。
  final IconData prefixIcon;

  /// 下拉框自身的测试或自动化 Key。
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      key: fieldKey ?? ValueKey<Object>('$labelText::$value'),
      initialValue: value,
      isExpanded: true,
      icon: const Icon(Icons.expand_more_rounded, size: 20),
      decoration: InputDecoration(
        labelText: labelText,
        prefixIcon: Icon(prefixIcon, size: 18),
      ),
      items: items,
      onChanged: onChanged,
    );
  }
}

/// 通用弹窗中的可点击列表项。
class AppChoiceTile extends StatelessWidget {
  /// 创建选择项。
  const AppChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.enabled = true,
    this.selected = false,
  });

  /// 左侧图标。
  final IconData icon;

  /// 主标题。
  final String title;

  /// 辅助说明。
  final String? subtitle;

  /// 右侧内容。
  final Widget? trailing;

  /// 点击回调。
  final VoidCallback? onTap;

  /// 是否可选。
  final bool enabled;

  /// 是否处于选中状态。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? AppColors.textPrimary : AppColors.textDisabled;
    return Material(
      color: selected ? AppColors.accentSoft : AppColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.tile),
        side: BorderSide(
          color: selected ? AppColors.accentBorder : AppColors.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        hoverColor: AppColors.surfaceHover,
        focusColor: AppColors.accent.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 19,
                color: enabled
                    ? AppColors.accentStrong
                    : AppColors.textDisabled,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
