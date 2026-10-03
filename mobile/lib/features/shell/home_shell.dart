import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';

/// Modern floating glassmorphic bottom navigation with highlighted center action button.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final currentIndex = navigationShell.currentIndex;

    return Scaffold(
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                height: 68,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceGlass,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: AppColors.border, width: 1.2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NavItem(
                      icon: Icons.map_outlined,
                      activeIcon: Icons.map_rounded,
                      label: 'Mapa',
                      isSelected: currentIndex == 0,
                      onTap: () => _onTabSelected(0),
                    ),
                    _NavItem(
                      icon: Icons.card_giftcard_outlined,
                      activeIcon: Icons.card_giftcard_rounded,
                      label: 'Nagrody',
                      isSelected: currentIndex == 1,
                      onTap: () => _onTabSelected(1),
                    ),
                    _CenterScanButton(
                      isSelected: currentIndex == 2,
                      onTap: () => _onTabSelected(2),
                    ),
                    _NavItem(
                      icon: Icons.grid_view_outlined,
                      activeIcon: Icons.grid_view_rounded,
                      label: 'Kolekcja',
                      isSelected: currentIndex == 3,
                      onTap: () => _onTabSelected(3),
                    ),
                    _NavItem(
                      icon: Icons.person_outline,
                      activeIcon: Icons.person_rounded,
                      label: 'Profil',
                      isSelected: currentIndex == 4,
                      onTap: () => _onTabSelected(4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onTabSelected(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: _FocusableTab(
        label: label,
        isSelected: isSelected,
        onTap: onTap,
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.mint100 : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    isSelected ? activeIcon : icon,
                    size: 22,
                    color: isSelected ? AppColors.primary : AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? AppColors.primary : AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ),
    );
  }
}

/// Keyboard-focusable tap target with a visible focus ring (WCAG 2.4.7)
/// and screen-reader semantics. Enter/Space activate via InkWell.
class _FocusableTab extends StatefulWidget {
  const _FocusableTab({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.child,
    this.circle = false,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Widget child;
  final bool circle;

  @override
  State<_FocusableTab> createState() => _FocusableTabState();
}

class _FocusableTabState extends State<_FocusableTab> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.circle ? null : BorderRadius.circular(20);
    return Semantics(
      container: true,
      button: true,
      selected: widget.isSelected,
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
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: radius,
                border: _focused
                    ? Border.all(color: AppColors.primary, width: 2.5)
                    : null,
              ),
              child: Center(widthFactor: 1, heightFactor: 1, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class _CenterScanButton extends StatelessWidget {
  const _CenterScanButton({
    required this.isSelected,
    required this.onTap,
  });

  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _FocusableTab(
      label: 'Złap',
      isSelected: isSelected,
      onTap: onTap,
      circle: true,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primaryBright, AppColors.primaryDark],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: isSelected ? Colors.white : AppColors.primaryBright,
            width: isSelected ? 2.5 : 1.5,
          ),
        ),
        child: const Icon(
          Icons.camera_alt_rounded,
          color: Color(0xFF090D12),
          size: 26,
        ),
      ),
    );
  }
}
