import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An alert dialog with the native look and feel.
///
/// It uses [Platform] to check whether to return an iOS or an Android dialog.
///
/// The Android variant uses [AlertDialog] while the iOS variant uses [CupertinoAlertDialog].
///
/// Being the actions used in dialogs quite different between the two platforms, the [actions] property maps to the
/// appropriate widget, [TextButton] on Android and [CupertinoDialogAction] on iOS.
class AdaptiveDialog extends StatelessWidget {
  /// [List] of actions, mapped to [TextButton] on Android and to [CupertinoDialogAction] on iOS.
  final List<AdaptiveDialogAction>? actions;

  /// The title of the dialog.
  final Widget? title;

  /// The content of the dialog.
  final Widget? content;
  final bool scrollable;

  const AdaptiveDialog({
    super.key,
    this.actions,
    this.title,
    this.content,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    return Theme.of(context).platform == TargetPlatform.android
        ? _AndroidDialog(
            actions: actions,
            title: title,
            content: content,
            scrollable: scrollable,
          )
        : _CupertinoDialog(actions: actions, title: title, content: content);
  }
}

/// A convenience class for a generic dialog action.
///
/// Used to map a generic action to the platform specific Widget.
class AdaptiveDialogAction {
  /// The child of the action, usually a [Text].
  final Widget child;

  /// Callback to be executed when the action is pressed.
  final VoidCallback? onPressed;

  /// Only used on iOS. When `true` the action [Text] will be [CupertinoColors.systemRed].
  final bool isDestructiveAction;

  /// Only used on iOS. When `true` the action [Text] will be bold.
  final bool isDefaultAction;
  final FocusNode? focusNode;
  final bool autofocus;

  AdaptiveDialogAction({
    required this.child,
    this.onPressed,
    this.isDestructiveAction = false,
    this.isDefaultAction = false,
    this.focusNode,
    this.autofocus = false,
  });
}

class _AndroidDialog extends StatelessWidget {
  final List<AdaptiveDialogAction>? actions;
  final Widget? title;
  final Widget? content;
  final bool scrollable;

  const _AndroidDialog({
    this.actions,
    this.title,
    this.content,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final buttons =
        actions
            ?.map(
              (action) => TextButton(
                onPressed: action.onPressed,
                focusNode: action.focusNode,
                autofocus: action.autofocus,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: action.child,
              ),
            )
            .toList() ??
        <Widget>[];
    return AlertDialog(
      scrollable: scrollable,
      title: title,
      content: scrollable
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [?content, ...buttons],
            )
          : content,
      actions: scrollable ? null : buttons,
    );
  }
}

class _CupertinoDialog extends StatelessWidget {
  final List<AdaptiveDialogAction>? actions;
  final Widget? title;
  final Widget? content;

  const _CupertinoDialog({this.actions, this.title, this.content});

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: title,
      content: content,
      actions: actions != null
          ? actions!
                .map((action) => _FocusableCupertinoAction(action: action))
                .toList()
          : [],
    );
  }
}

class _FocusableCupertinoAction extends StatefulWidget {
  final AdaptiveDialogAction action;
  const _FocusableCupertinoAction({required this.action});
  @override
  State<_FocusableCupertinoAction> createState() =>
      _FocusableCupertinoActionState();
}

class _FocusableCupertinoActionState extends State<_FocusableCupertinoAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    focusNode: widget.action.focusNode,
    autofocus: widget.action.autofocus,
    enabled: widget.action.onPressed != null,
    onShowFocusHighlight: (value) => setState(() => _focused = value),
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.action.onPressed?.call();
          return null;
        },
      ),
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: _focused
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: CupertinoDialogAction(
          isDestructiveAction: widget.action.isDestructiveAction,
          isDefaultAction: widget.action.isDefaultAction,
          onPressed: widget.action.onPressed,
          child: widget.action.child,
        ),
      ),
    ),
  );
}
