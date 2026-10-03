import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// On wide web screens renders the app inside a 412x915 phone frame,
/// so judges and the demo video see the mobile layout. On phones it is a no-op.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});

  final Widget child;

  static const _phoneSize = Size(412, 915);

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= _phoneSize.width + 48) return child;

        final height = constraints.maxHeight.clamp(0.0, _phoneSize.height);
        return ColoredBox(
          color: const Color(0xFF06090D),
          child: Center(
            child: Container(
              width: _phoneSize.width,
              height: height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(36),
                border: Border.all(color: AppColors.border, width: 6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x3300E599),
                    blurRadius: 50,
                    spreadRadius: -10,
                    offset: Offset(0, 20),
                  ),
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 40,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: Size(_phoneSize.width, height),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
