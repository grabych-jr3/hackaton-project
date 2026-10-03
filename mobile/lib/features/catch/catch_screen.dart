import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/places_repository.dart';
import '../game/game_models.dart';
import '../game/game_providers.dart';
import '../place/status_chip.dart';

const currentLocationLabel = 'Obecna lokalizacja';

/// Modern minimalist AR Camera & Barrier Scanner screen.
class CatchScreen extends ConsumerStatefulWidget {
  const CatchScreen({super.key});

  @override
  ConsumerState<CatchScreen> createState() => _CatchScreenState();
}

class _CatchScreenState extends ConsumerState<CatchScreen> with SingleTickerProviderStateMixin {
  bool _isCameraMode = true;
  String? _placeId;
  bool _hasSteps = false;
  int _steps = 1;
  CurbRange _curb = CurbRange.none;
  PassageWidth _passage = PassageWidth.none;
  bool _noRamp = false;
  bool _uneven = false;
  bool _obstacles = false;
  bool _sending = false;

  late AnimationController _animController;
  late Animation<double> _bobAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _bobAnimation = Tween<double>(begin: -6.0, end: 6.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  /// Respect the system "reduce motion" setting (WCAG 2.3.3).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animController.stop();
    } else if (!_animController.isAnimating) {
      _animController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  BarrierReport get _report => BarrierReport(
        placeId: _placeId,
        steps: _hasSteps ? _steps : 0,
        curb: _curb,
        passage: _passage,
        noRamp: _noRamp,
        uneven: _uneven,
        obstacles: _obstacles,
      );

  void _reset() => setState(() {
        _hasSteps = false;
        _steps = 1;
        _curb = CurbRange.none;
        _passage = PassageWidth.none;
        _noRamp = _uneven = _obstacles = false;
      });

  Future<void> _submit([bool isAiScan = false]) async {
    setState(() => _sending = true);

    // If simulated AI scan from camera, populate sensible defaults if empty
    final reportToSend = isAiScan && _report.isEmpty
        ? BarrierReport(
            placeId: _placeId,
            steps: 0,
            curb: CurbRange.low,
            passage: PassageWidth.wide,
            noRamp: false,
            uneven: false,
            obstacles: false,
          )
        : _report;

    final result = await ref.read(gameProvider.notifier).submitReport(reportToSend);
    if (!mounted) return;
    setState(() => _sending = false);
    if (result == null) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: const BorderSide(color: AppColors.borderHighlight),
        ),
        title: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.mint100,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary),
              ),
              child: Text(result.species.emoji, style: const TextStyle(fontSize: 48)),
            ),
            const SizedBox(height: 12),
            Text(
              'Złapano: ${result.species.name}!',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                '${result.species.rarity.label} · +${result.points} pkt',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Zgłoszenie niezweryfikowane — trafi na mapę po potwierdzeniu przez innych użytkowników.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(160, 46),
              backgroundColor: AppColors.primary,
              foregroundColor: const Color(0xFF090D12),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Odbierz punkty'),
          ),
        ],
      ),
    );

    if (mounted) _reset();
  }

  @override
  Widget build(BuildContext context) {
    final points = ref.watch(gameProvider).value?.points;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Skaner AR & Złap'),
        actions: [
          // Mode Switcher Pill (AR Camera vs Manual Survey)
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ModeTab(
                  icon: Icons.camera_alt_rounded,
                  label: 'Kamera',
                  isSelected: _isCameraMode,
                  onTap: () => setState(() => _isCameraMode = true),
                ),
                _ModeTab(
                  icon: Icons.checklist_rounded,
                  label: 'Ankieta',
                  isSelected: !_isCameraMode,
                  onTap: () => setState(() => _isCameraMode = false),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _isCameraMode
          ? _buildMinimalistCameraView(points)
          : _buildManualSurveyView(points),
    );
  }

  /// Minimalist & Concise AR Camera Scanner UI
  Widget _buildMinimalistCameraView(int? points) {
    final places = ref.watch(placesProvider).value ?? const [];

    return Stack(
      children: [
        // 1. Simulated Clean Camera Viewfinder Background
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.2),
                radius: 1.2,
                colors: [
                  Color(0xFF141E28),
                  Color(0xFF0A1017),
                  Color(0xFF05080C),
                ],
              ),
            ),
            child: ExcludeSemantics(
              child: CustomPaint(
                painter: _CameraGridPainter(),
              ),
            ),
          ),
        ),

        // 2. Minimalist Top Status Island (Location & Points)
        Positioned(
          top: 12,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Location Dropdown Selector
              Flexible(
                child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceGlass,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: _placeId,
                        isExpanded: true,
                        dropdownColor: AppColors.surfaceElevated,
                        icon: const Icon(Icons.arrow_drop_down, color: AppColors.primary),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.my_location, size: 14, color: AppColors.primary),
                                SizedBox(width: 6),
                                Flexible(
                                  child: Text(currentLocationLabel,
                                      style: TextStyle(fontSize: 12),
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ),
                          ),
                          for (final p in places.take(6))
                            DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                p.name,
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _placeId = v),
                      ),
                    ),
                  ),
                ),
              ),
              ),
              const SizedBox(width: 8),
              // Points Badge
              if (points != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.mint100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primary),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.stars_rounded, color: AppColors.primary, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        '$points pkt',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // 3. Sleek AI Live Detection HUD Tags (Minimalist Floating Pills)
        Positioned(
          top: 64,
          left: 16,
          right: 16,
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              const DemoBadge(),
              _AiTag(
                icon: Icons.check_circle_outline,
                label: 'Brak schodów',
                isOk: true,
              ),
              _AiTag(
                icon: Icons.height,
                label: 'Krawężnik: <3cm',
                isOk: true,
              ),
            ],
          ),
        ),

        // 4. Central AR Viewfinder Reticle & Creature
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Decorative reticle + animated creature: hidden from screen readers.
              ExcludeSemantics(
                child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Corner Brackets
                    const _CornerBrackets(),
                    // Animated Bobbing Creature
                    AnimatedBuilder(
                      animation: _bobAnimation,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, _bobAnimation.value),
                        child: child,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withValues(alpha: 0.25),
                                  blurRadius: 24,
                                  spreadRadius: 8,
                                ),
                              ],
                            ),
                            child: const Text('🐉', style: TextStyle(fontSize: 64)),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceElevated.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.primary),
                            ),
                            child: const Text(
                              'Smok Wawelski',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Nakieruj na przejście lub barierę',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),

        // 5. Minimalist Bottom Controls & Shutter Button
        Positioned(
          left: 20,
          right: 20,
          bottom: 96,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Minimal Quick-Tap Barrier Tags
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _QuickPill(
                    label: 'Schody',
                    isSelected: _hasSteps,
                    onTap: () => setState(() => _hasSteps = !_hasSteps),
                  ),
                  _QuickPill(
                    label: 'Krawężnik >7cm',
                    isSelected: _curb == CurbRange.high,
                    onTap: () => setState(() => _curb =
                        _curb == CurbRange.high ? CurbRange.none : CurbRange.high),
                  ),
                  _QuickPill(
                    label: 'Brak rampy',
                    isSelected: _noRamp,
                    onTap: () => setState(() => _noRamp = !_noRamp),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Big Minimalist Shutter / Scan Button
              _FocusTap(
                label: _sending
                    ? 'Wysyłanie zgłoszenia…'
                    : 'Zrób zdjęcie, zgłoś barierę i złap stworka',
                circle: true,
                onTap: _sending ? null : () => _submit(true),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.primaryBright, AppColors.primaryDark],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.5),
                        blurRadius: 18,
                        spreadRadius: 2,
                      ),
                    ],
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: Center(
                    child: _sending
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Color(0xFF090D12),
                            ),
                          )
                        : const Icon(
                            Icons.camera_alt_rounded,
                            color: Color(0xFF090D12),
                            size: 30,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Detailed Manual Survey Fallback
  Widget _buildManualSurveyView(int? points) {
    final theme = Theme.of(context);
    final places = ref.watch(placesProvider).value ?? const [];

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
        );

    Widget choices<T>(List<(T, String)> options, T value, ValueChanged<T> onChanged) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (v, label) in options)
              ChoiceChip(
                label: Text(label),
                selected: v == value,
                selectedColor: AppColors.mint100,
                backgroundColor: AppColors.surfaceElevated,
                side: BorderSide(color: v == value ? AppColors.primary : AppColors.border),
                labelStyle: TextStyle(
                  color: v == value ? AppColors.primary : AppColors.text,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (_) => setState(() => onChanged(v)),
              ),
          ],
        );

    Widget check(String label, bool value, ValueChanged<bool> onChanged) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(label, style: const TextStyle(color: AppColors.text)),
          value: value,
          activeColor: AppColors.primary,
          checkColor: const Color(0xFF090D12),
          onChanged: (v) => setState(() => onChanged(v ?? false)),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            const DemoBadge(),
            if (points != null)
              Text(
                'Saldo: $points pkt',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: const Row(
            children: [
              Icon(Icons.fact_check_outlined, color: AppColors.primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Zgłoś barierę w ankiecie i złap stworka. Im dokładniejsze zgłoszenie, tym rzadszy stworek.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        section('Miejsce'),
        DropdownButtonFormField<String?>(
          initialValue: _placeId,
          isExpanded: true,
          dropdownColor: AppColors.surfaceElevated,
          decoration: const InputDecoration(labelText: 'Gdzie jest bariera?'),
          items: [
            const DropdownMenuItem(value: null, child: Text(currentLocationLabel)),
            for (final p in places)
              DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _placeId = v),
        ),
        section('Bariery'),
        check('Schody', _hasSteps, (v) => _hasSteps = v),
        if (_hasSteps)
          Row(
            children: [
              const SizedBox(width: 16),
              const Text('Liczba stopni:', style: TextStyle(color: AppColors.textMuted)),
              IconButton(
                tooltip: 'Mniej stopni',
                onPressed: _steps > 1 ? () => setState(() => _steps--) : null,
                icon: const Icon(Icons.remove_circle_outline, color: AppColors.primary),
              ),
              Text('$_steps',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              IconButton(
                tooltip: 'Więcej stopni',
                onPressed: () => setState(() => _steps++),
                icon: const Icon(Icons.add_circle_outline, color: AppColors.primary),
              ),
            ],
          ),
        check('Brak podjazdu / rampy', _noRamp, (v) => _noRamp = v),
        check('Nierówna nawierzchnia', _uneven, (v) => _uneven = v),
        check('Przeszkody na drodze', _obstacles, (v) => _obstacles = v),
        section('Krawężnik'),
        choices<CurbRange>(
          const [
            (CurbRange.none, 'Brak'),
            (CurbRange.low, '0–3 cm'),
            (CurbRange.mid, '3–7 cm'),
            (CurbRange.high, '> 7 cm'),
          ],
          _curb,
          (v) => _curb = v,
        ),
        section('Szerokość przejścia'),
        choices<PassageWidth>(
          const [
            (PassageWidth.none, 'Brak danych'),
            (PassageWidth.wide, '> 90 cm'),
            (PassageWidth.medium, '70–90 cm'),
            (PassageWidth.narrow, '< 70 cm'),
          ],
          _passage,
          (v) => _passage = v,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: AppColors.primary,
            foregroundColor: const Color(0xFF090D12),
          ),
          onPressed: _report.isEmpty || _sending || points == null ? null : () => _submit(false),
          icon: const Icon(Icons.send_rounded),
          label: const Text('Wyślij zgłoszenie i złap'),
        ),
      ],
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _FocusTap(
      label: 'Tryb: $label',
      selected: isSelected,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.mint100 : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: isSelected ? AppColors.primary : AppColors.textMuted),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? AppColors.primary : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiTag extends StatelessWidget {
  const _AiTag({
    required this.icon,
    required this.label,
    required this.isOk,
  });

  final IconData icon;
  final String label;
  final bool isOk;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: isOk ? AppColors.primary : AppColors.bad),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: isOk ? AppColors.primary : AppColors.bad,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickPill extends StatelessWidget {
  const _QuickPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _FocusTap(
      label: 'Bariera: $label',
      selected: isSelected,
      toggled: isSelected,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary : AppColors.surfaceElevated.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? AppColors.primaryBright : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: isSelected ? const Color(0xFF090D12) : AppColors.text,
          ),
        ),
      ),
    );
  }
}

/// Keyboard-focusable button wrapper: InkWell (Enter/Space activation),
/// visible focus ring, 48x48 minimum target and a screen-reader label.
class _FocusTap extends StatefulWidget {
  const _FocusTap({
    required this.label,
    required this.onTap,
    required this.child,
    this.selected,
    this.toggled,
    this.circle = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;
  final bool? selected;
  final bool? toggled;
  final bool circle;

  @override
  State<_FocusTap> createState() => _FocusTapState();
}

class _FocusTapState extends State<_FocusTap> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.circle ? null : BorderRadius.circular(20);
    return Semantics(
      container: true,
      button: true,
      enabled: widget.onTap != null,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: widget.circle ? const CircleBorder() : null,
            borderRadius: radius,
            onTap: widget.onTap,
            onFocusChange: (f) => setState(() => _focused = f),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: radius,
                  border: _focused
                      ? Border.all(color: AppColors.primary, width: 2.5)
                      : null,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CornerBrackets extends StatelessWidget {
  const _CornerBrackets();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.primary, width: 2.5),
                left: BorderSide(color: AppColors.primary, width: 2.5),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.primary, width: 2.5),
                right: BorderSide(color: AppColors.primary, width: 2.5),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 8,
          left: 8,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.primary, width: 2.5),
                left: BorderSide(color: AppColors.primary, width: 2.5),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 8,
          right: 8,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.primary, width: 2.5),
                right: BorderSide(color: AppColors.primary, width: 2.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CameraGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.15)
      ..strokeWidth = 1.0;

    // Subtle center cross
    final cx = size.width / 2;
    final cy = size.height * 0.45;
    canvas.drawLine(Offset(cx - 20, cy), Offset(cx + 20, cy), paint);
    canvas.drawLine(Offset(cx, cy - 20), Offset(cx, cy + 20), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
