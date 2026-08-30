import 'package:flutter/material.dart';

import '../../../constants/constants.dart';
import '../../../constants/style.dart';
import '../../../ui/device.dart';

class AccountIconColorSelector extends StatefulWidget {
  final String selectedIcon;
  final int selectedColor;
  final Function(String) onIconChanged;
  final Function(int) onColorChanged;

  const AccountIconColorSelector({
    required this.selectedIcon,
    required this.selectedColor,
    required this.onIconChanged,
    required this.onColorChanged,
    super.key,
  });

  @override
  State<AccountIconColorSelector> createState() =>
      _AccountIconColorSelectorState();
}

class _AccountIconColorSelectorState extends State<AccountIconColorSelector> {
  bool showAccountIcons = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            "ICON AND COLOR",
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const SizedBox(height: Sizes.xl),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(Sizes.borderRadius * 10),
            onTap: () => setState(() => showAccountIcons = true),
            child: Ink(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accountColorListTheme[widget.selectedColor],
              ),
              padding: const EdgeInsets.all(Sizes.lg),
              child: Icon(
                accountIconList[widget.selectedIcon],
                size: 48,
                color: white,
              ),
            ),
          ),
        ),
        const SizedBox(height: Sizes.sm),
        Text("CHOOSE ICON", style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: Sizes.md),
        if (showAccountIcons) const Divider(color: grey2),
        if (showAccountIcons)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Sizes.lg,
              vertical: Sizes.sm,
            ),
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: TextButton(
                    onPressed: () => setState(() => showAccountIcons = false),
                    child: Text(
                      "Done",
                      style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ),
                ),
                GridView.builder(
                  itemCount: accountIconList.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                  ),
                  itemBuilder: (context, index) {
                    IconData accountIconData = accountIconList.values.elementAt(
                      index,
                    );
                    String accountIconName = accountIconList.keys.elementAt(
                      index,
                    );
                    final isSelected =
                        accountIconList[widget.selectedIcon] == accountIconData;
                    return GestureDetector(
                      onTap: () => widget.onIconChanged(accountIconName),
                      child: Container(
                        margin: const EdgeInsets.all(Sizes.xs),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(context).colorScheme.secondary
                              : Theme.of(context).colorScheme.surface,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          accountIconData,
                          color: isSelected
                              ? white
                              : Theme.of(context).colorScheme.primary,
                          size: 24,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        const Divider(height: 1, color: grey2),
        const SizedBox(height: Sizes.md),
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: Sizes.lg),
            separatorBuilder: (context, index) =>
                const SizedBox(width: Sizes.lg),
            itemCount: accountColorListTheme.length,
            itemBuilder: (context, index) {
              Color color = accountColorListTheme[index];
              final isSelected =
                  accountColorListTheme[widget.selectedColor] == color;
              return GestureDetector(
                onTap: () => widget.onColorChanged(index),
                child: Container(
                  height: isSelected ? 38 : 32,
                  width: isSelected ? 38 : 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    border: isSelected
                        ? Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 3,
                          )
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: Sizes.sm),
        Text(
          "CHOOSE COLOR",
          style: Theme.of(context).textTheme.labelMedium!.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
