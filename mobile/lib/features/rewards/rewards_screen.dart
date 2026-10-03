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
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Nagrody & Vouchery')),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            const DemoBadge(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, size: 14, color: AppColors.primary),
                  SizedBox(width: 4),
                  Text('Model CPA Partnerów', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Balance Card with Neon Gradient Header
        Semantics(
          container: true,
          excludeSemantics: true,
          label: 'Twoje aktywne saldo: ${g.points} punktów',
          child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0E2A1F), Color(0xFF131B24)],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.4), width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x3300E599),
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primary),
                ),
                child: const Icon(Icons.stars_rounded, color: AppColors.primary, size: 36),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Twoje aktywne saldo',
                      style: theme.textTheme.labelMedium?.copyWith(color: AppColors.textMuted)),
                  const SizedBox(height: 2),
                  Text('${g.points} pkt',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      )),
                ],
              ),
            ],
          ),
        ),
        ),
        const SizedBox(height: 10),
        Text(
          'Vouchery są aktywne przez 2 godziny — więcej zniżek w spokojnych dzielnicach.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (g.vouchers.isNotEmpty) ...[
          const SizedBox(height: 24),
          Row(
            children: [
              const Icon(Icons.confirmation_number_outlined, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text('Moje aktywne vouchery',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 10),
          for (final v in g.vouchers) _VoucherTile(v, offerById(v.offerId), now),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            const Icon(Icons.storefront_outlined, color: AppColors.primary, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Oferty lokalnych partnerów',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Tylko sprawdzone obiekty bez barier architektonicznych',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
        const SizedBox(height: 12),
        for (final o in offers)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Center(
                      child: Icon(Icons.local_cafe_rounded, color: AppColors.primary, size: 24),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(o.partner,
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(o.discount, style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const StatusChip(
                              StatusStyle('Zweryfikowane', Icons.verified_rounded,
                                  AppColors.ok, AppColors.okBg),
                              dense: true,
                            ),
                            Text('${o.cost} pkt',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w800,
                                )),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    container: true,
                    button: true,
                    enabled: g.points >= o.cost,
                    excludeSemantics: true,
                    label: g.points >= o.cost
                        ? 'Aktywuj voucher ${o.partner} za ${o.cost} punktów'
                        : 'Za mało punktów na voucher ${o.partner}, potrzeba ${o.cost} punktów',
                    onTap: g.points >= o.cost ? () => _activate(o) : null,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: g.points >= o.cost ? AppColors.primary : AppColors.surfaceElevated,
                        foregroundColor: g.points >= o.cost ? const Color(0xFF090D12) : AppColors.textMuted,
                        disabledBackgroundColor: AppColors.surfaceElevated,
                        disabledForegroundColor: AppColors.textMuted,
                        minimumSize: const Size(80, 48),
                      ),
                      onPressed: g.points >= o.cost ? () => _activate(o) : null,
                      child: Text(g.points >= o.cost ? 'Aktywuj' : 'Za mało pkt'),
                    ),
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
      backgroundColor: AppColors.surfaceElevated,
      content: Text(
        ok ? 'Voucher aktywowany: ${offer.partner}. Ważny 2 godziny.' : 'Za mało punktów.',
        style: const TextStyle(color: AppColors.text),
      ),
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

    final name = offer?.partner ?? voucher.offerId;
    final spoken = active
        ? 'Voucher $name, kod ${voucher.code}, pozostało ${spokenRemaining(voucher.remaining(now))}'
        : 'Voucher $name, kod ${voucher.code}, wygasł';

    // Stable label (minute granularity) so the per-second countdown is not announced.
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: spoken,
      child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: active ? AppColors.surfaceElevated : AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active ? AppColors.primary.withValues(alpha: 0.5) : AppColors.border,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active ? AppColors.mint100 : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            active ? Icons.confirmation_number_rounded : Icons.timer_off_rounded,
            color: active ? AppColors.primary : AppColors.unknown,
            size: 24,
          ),
        ),
        title: Text(
          offer != null ? '${offer!.partner} · ${offer!.discount}' : voucher.offerId,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'KOD: ${voucher.code}',
            style: theme.textTheme.titleMedium?.copyWith(
              letterSpacing: 2.0,
              fontWeight: FontWeight.w800,
              color: active ? AppColors.primary : AppColors.textDim,
            ),
          ),
        ),
        trailing: active
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.mint100,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.primary),
                ),
                child: Text(
                  left,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              )
            : const StatusChip(
                StatusStyle('Wygasł', Icons.timer_off_outlined, AppColors.unknown,
                    AppColors.surface),
                dense: true,
              ),
      ),
    ),
    );
  }
}

/// Polish, minute-granular remaining time for screen readers.
String spokenRemaining(Duration d) {
  final totalMin = (d.inSeconds + 59) ~/ 60;
  final h = totalMin ~/ 60;
  final m = totalMin % 60;
  String plural(int n, String one, String few, String many) {
    if (n == 1) return '$n $one';
    final l10 = n % 10, l100 = n % 100;
    if (l10 >= 2 && l10 <= 4 && (l100 < 12 || l100 > 14)) return '$n $few';
    return '$n $many';
  }

  return [
    if (h > 0) plural(h, 'godzina', 'godziny', 'godzin'),
    if (m > 0 || h == 0) plural(m, 'minuta', 'minuty', 'minut'),
  ].join(' ');
}
