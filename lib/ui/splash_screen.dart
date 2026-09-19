import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The branded screen shown for the brief moment between process start and
/// [LibraryController] finishing its async load (device identity, pairing
/// store, notebooks from disk) - see the `!library.loaded` check in
/// `main.dart`'s `_AppRoot`.
///
/// On Android this is layered on top of the *native* splash screen that
/// `flutter_native_splash` generates from the same artwork (see the
/// `flutter_native_splash:` block in pubspec.yaml) - that one covers the
/// gap between tapping the icon and the Flutter engine's first frame;
/// this one covers everything after that, so there's no visible seam
/// between "native splash" and "first thing Flutter draws".
///
/// Windows desktop has no equivalent native/pre-engine splash hook (see
/// the comment on the flutter_native_splash dependency in pubspec.yaml),
/// so this is the *only* splash there - it's what covers the moment
/// between the window appearing and the app actually being ready.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  static const backgroundColor = Color(0xFF150E09);
  static const _gold = Color(0xFFD6AD54);
  static const _dimGold = Color(0xFF8A6A3A);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoFade;
  late final Animation<double> _logoScale;
  late final Animation<double> _titleFade;
  late final Animation<double> _taglineFade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..forward();
    // Logo eases in with a slight overshoot (a soft "pop") in the first
    // 60% of the timeline, title and tagline fade in staggered after it -
    // rather than everything arriving on screen at once.
    _logoFade = CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.5, curve: Curves.easeOut));
    _logoScale = CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack));
    _titleFade = CurvedAnimation(parent: _controller, curve: const Interval(0.35, 0.75, curve: Curves.easeOut));
    _taglineFade = CurvedAnimation(parent: _controller, curve: const Interval(0.55, 0.95, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SplashScreen.backgroundColor,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            children: [
              // Soft warm glow behind the logo, echoing the app-icon
              // artwork's own background glow (see the icon generator) so
              // the splash reads as the same piece of branding.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, -0.1),
                        radius: 0.9,
                        colors: [
                          SplashScreen._dimGold.withValues(alpha: 0.16 * _logoFade.value),
                          SplashScreen.backgroundColor,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: _logoFade.value,
                      child: Transform.scale(
                        scale: 0.85 + 0.15 * _logoScale.value,
                        child: Image.asset(
                          'assets/icon/app_icon_foreground.png',
                          width: 176,
                          height: 176,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Opacity(
                      opacity: _titleFade.value,
                      child: Text(
                        'Na-Pustakam',
                        style: GoogleFonts.cinzelDecorative(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: SplashScreen._gold,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Opacity(
                      opacity: _taglineFade.value,
                      child: Text(
                        'YOUR NOTEBOOK, ANYWHERE',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 3.2,
                          color: SplashScreen._dimGold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Opacity(
                      opacity: _taglineFade.value,
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation<Color>(SplashScreen._dimGold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
