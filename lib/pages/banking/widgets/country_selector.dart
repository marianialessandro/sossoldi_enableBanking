import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import '../../../constants/style.dart';
import '../../../ui/device.dart';

const List<({String name, String code})> kEbCountries = [
  (name: "Austria", code: "AT"),
  (name: "Belgium", code: "BE"),
  (name: "Bulgaria", code: "BG"),
  (name: "Croatia", code: "HR"),
  (name: "Cyprus", code: "CY"),
  (name: "Czechia", code: "CZ"),
  (name: "Denmark", code: "DK"),
  (name: "Estonia", code: "EE"),
  (name: "Finland", code: "FI"),
  (name: "France", code: "FR"),
  (name: "Germany", code: "DE"),
  (name: "Greece", code: "GR"),
  (name: "Hungary", code: "HU"),
  (name: "Iceland", code: "IS"),
  (name: "Ireland", code: "IE"),
  (name: "Italy", code: "IT"),
  (name: "Latvia", code: "LV"),
  (name: "Liechtenstein", code: "LI"),
  (name: "Lithuania", code: "LT"),
  (name: "Luxembourg", code: "LU"),
  (name: "Malta", code: "MT"),
  (name: "Netherlands", code: "NL"),
  (name: "Norway", code: "NO"),
  (name: "Poland", code: "PL"),
  (name: "Portugal", code: "PT"),
  (name: "Romania", code: "RO"),
  (name: "Slovakia", code: "SK"),
  (name: "Slovenia", code: "SI"),
  (name: "Spain", code: "ES"),
  (name: "Sweden", code: "SE"),
];

class CountrySelector extends StatelessWidget {
  const CountrySelector({
    required this.scrollController,
    required this.onSelected,
    super.key,
  });

  final ScrollController scrollController;
  final void Function(String countryCode) onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppBar(title: const Text("Country")),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              child: Container(
                color: Theme.of(context).colorScheme.surface,
                child: ListView.separated(
                  itemCount: kEbCountries.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, color: grey1),
                  itemBuilder: (context, i) {
                    final country = kEbCountries[i];
                    return ListTile(
                      onTap: () {
                        Navigator.pop(context);
                        onSelected(country.code);
                      },
                      leading: CountryFlag.fromCountryCode(
                        country.code,
                        theme: const ImageTheme(
                          width: 32,
                          height: 24,
                          shape: RoundedRectangle(4),
                        ),
                      ),
                      title: Text(country.name),
                      trailing: Text(
                        country.code,
                        style: Theme.of(context).textTheme.labelLarge!.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: Sizes.sm),
        ],
      ),
    );
  }
}
