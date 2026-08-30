import 'package:flutter/material.dart';

import '../../../ui/device.dart';
import '../../../ui/widgets/default_card.dart';

class BankSyncPage extends StatelessWidget {
  const BankSyncPage({super.key});

  static const _options = [
    _BankSyncOption(
      title: 'Configure Enable Banking',
      description: 'Set up your Enable Banking credentials',
      icon: Icons.settings,
      route: '/enable-banking-setup',
    ),
    _BankSyncOption(
      title: 'Connect banks',
      description: 'Link your banks and manage connections',
      icon: Icons.account_balance,
      route: '/connect-bank',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Bank sync'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.only(top: Sizes.xl),
        physics: const BouncingScrollPhysics(),
        itemCount: _options.length,
        separatorBuilder: (context, index) => const SizedBox(height: Sizes.lg),
        itemBuilder: (context, index) {
          final option = _options[index];

          return DefaultCard(
            onTap: () => Navigator.of(context).pushNamed(option.route),
            child: Row(
              children: [
                Icon(
                  option.icon,
                  color: Theme.of(context).colorScheme.primary,
                  size: 32,
                ),
                const SizedBox(width: Sizes.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.title,
                        style: Theme.of(context).textTheme.titleLarge!.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: Sizes.xs),
                      Text(
                        option.description,
                        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BankSyncOption {
  const _BankSyncOption({
    required this.title,
    required this.description,
    required this.icon,
    required this.route,
  });

  final String title;
  final String description;
  final IconData icon;
  final String route;
}
