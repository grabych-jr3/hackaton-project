import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';
import '../place/place_labels.dart';
import '../place/status_chip.dart';

class RewardsScreen extends ConsumerStatefulWidget {
  const RewardsScreen({super.key});

  @override
  ConsumerState<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends ConsumerState<RewardsScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Live countdown for active vouchers.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(gameCatalogProvider);
    final game = ref.watch(gameProvider);
    final now = ref.watch(gameClockProvider)();

    return Scaffold(
      appBar: AppBar(title: const Text('Nagrody')),
      body: switch ((catalog, game)) {
        (AsyncData(value: final c), AsyncData(value: final g)) =>
          _content(context, c, g, now),
        (AsyncError(:final error), _) || (_, AsyncError(:final error)) =>
          Center(child: Text('Nie udało się wczytać nagród: $error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _content(BuildContext context, GameCatalog c, GameState g, DateTime now) {
    final theme = Theme.of(context);
    final offers = c.verifiedOffers;
    VoucherOffer? offerById(String id) => c.offers.where((o) => o.id == id).firstOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const Align(alignment: Alignment.centerLeft, child: DemoBadge()),
        const SizedBox(height: 12),
        Semantics(
          label: 'Twoje saldo: ${g.points} punktów',
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.mint100,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.mint300),
            ),
            child: Row(
              children: [
                const Icon(Icons.stars_outlined, color: AppColors.primary, size: 36),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Twoje saldo', style: theme.textTheme.labelLarge),
                    Text('${g.points} pkt',
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w800)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Voucher działa 2 godziny od aktywacji — więcej voucherów tam, gdzie mniej ludzi.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (g.vouchers.isNotEmpty) ...[
          const SizedBox(height: 20),
          Semantics(header: true, child: Text('Moje vouchery', style: theme.textTheme.titleMedium)),
          const SizedBox(height: 8),
          for (final v in g.vouchers) _VoucherTile(v, offerById(v.offerId), now),
        ],
        const SizedBox(height: 20),
        Semantics(header: true, child: Text('Oferty partnerów', style: theme.textTheme.titleMedium)),
        Text('Tylko miejsca ze sprawdzoną dostępnością',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
        const SizedBox(height: 8),
        for (final o in offers)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(o.partner, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(o.discount),
                        const SizedBox(height: 4),
                        const StatusChip(
                          StatusStyle('Dostępność sprawdzona', Icons.verified_outlined,
                              AppColors.ok, AppColors.mint100),
                          dense: true,
                        ),
                        const SizedBox(height: 4),
                        Text('${o.cost} pkt',
                            style: theme.textTheme.labelLarge?.copyWith(color: AppColors.primary)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: g.points >= o.cost ? () => _activate(o) : null,
                    child: Text(g.points >= o.cost ? 'Aktywuj' : 'Za mało pkt'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _activate(VoucherOffer offer) async {
    final ok = await ref.read(gameProvider.notifier).activate(offer);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Voucher aktywowany: ${offer.partner}. Ważny 2 godziny.'
          : 'Za mało punktów.'),
    ));
  }
}

class _VoucherTile extends StatelessWidget {
  const _VoucherTile(this.voucher, this.offer, this.now);

  final Voucher voucher;
  final VoucherOffer? offer;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = voucher.isActive(now);
    final left = formatCountdown(voucher.remaining(now));
    return Card(
      color: active ? AppColors.background : AppColors.surface,
      child: ListTile(
        leading: Icon(active ? Icons.confirmation_number_outlined : Icons.timer_off_outlined,
            color: active ? AppColors.primary : AppColors.unknown),
        title: Text(offer != null ? '${offer!.partner} · ${offer!.discount}' : voucher.offerId),
        subtitle: Text(voucher.code,
            style: theme.textTheme.titleMedium
                ?.copyWith(letterSpacing: 1.5, fontWeight: FontWeight.w700)),
        trailing: active
            ? Semantics(
                label: 'Pozostało $left',
                excludeSemantics: true,
                child: Text(left,
                    style: theme.textTheme.titleMedium?.copyWith(color: AppColors.primary)),
              )
            : const StatusChip(
                StatusStyle('Wygasł', Icons.timer_off_outlined, AppColors.unknown,
                    AppColors.surface),
                dense: true,
              ),
      ),
    );
  }
}
