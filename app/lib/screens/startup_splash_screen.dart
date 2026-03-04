import 'package:flutter/material.dart';

class StartupSplashScreen extends StatefulWidget {
  final Widget child;
  final Duration minimumDuration;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;

  const StartupSplashScreen({
    super.key,
    required this.child,
    this.minimumDuration = const Duration(milliseconds: 1200),
    this.fadeInDuration = const Duration(milliseconds: 260),
    this.fadeOutDuration = const Duration(milliseconds: 300),
  });

  @override
  State<StartupSplashScreen> createState() => _StartupSplashScreenState();
}

class _StartupSplashScreenState extends State<StartupSplashScreen> {
  double _splashOpacity = 0;
  double _contentScale = 0.88;
  Offset _contentOffset = const Offset(0, 0.08);
  bool _hideSplash = false;

  @override
  void initState() {
    super.initState();
    _runSplashSequence();
  }

  Future<void> _runSplashSequence() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _splashOpacity = 1;
        _contentScale = 1;
        _contentOffset = Offset.zero;
      });
    });

    await Future<void>.delayed(widget.minimumDuration);
    if (!mounted) {
      return;
    }
    setState(() {
      _splashOpacity = 0;
      _contentScale = 1.08;
      _contentOffset = const Offset(0, -0.04);
    });

    await Future<void>.delayed(widget.fadeOutDuration);
    if (!mounted) {
      return;
    }
    setState(() {
      _hideSplash = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_hideSplash)
          AnimatedOpacity(
            opacity: _splashOpacity,
            duration: _splashOpacity > 0
                ? widget.fadeInDuration
                : widget.fadeOutDuration,
            curve: Curves.easeOutCubic,
            child: Scaffold(
              backgroundColor: const Color(0xFF2E7D32),
              body: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF2E7D32), Color(0xFF1B5E20)],
                  ),
                ),
                child: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: AnimatedSlide(
                        offset: _contentOffset,
                        duration: _splashOpacity > 0
                            ? widget.fadeInDuration
                            : widget.fadeOutDuration,
                        curve: Curves.easeOutCubic,
                        child: AnimatedScale(
                          scale: _contentScale,
                          duration: _splashOpacity > 0
                              ? widget.fadeInDuration
                              : widget.fadeOutDuration,
                          curve: Curves.easeOutCubic,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Image(
                                image: AssetImage("assets/images/icon.png"),
                                width: 120,
                                height: 120,
                              ),
                              SizedBox(height: 18),
                              Text(
                                "Smart Medicine Reminder",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 24),
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.8,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
