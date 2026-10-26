import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'affected_home_screen.dart';
import 'rescue_auth_screen.dart';

/// A subtle, one-time entrance animation on the app's first screen --
/// icon scales/fades in, then the title and the two role cards fade and
/// slide up in a slight stagger. Kept restrained on purpose: one run,
/// under a second, no looping or bouncing after it settles.
///
/// Phase 3 UI redesign: the two plain ElevatedButtons are now large
/// professional role cards (icon, title, description, ripple) per the
/// master prompt's section 4 -- the underlying navigation
/// (Navigator.push -> AffectedHomeScreen / RescueAuthScreen) is
/// byte-for-byte the same as before.
class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _staggered({
    required double start,
    required double end,
    required Widget child,
  }) {
    final fade = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, end, curve: Curves.easeOut),
    );
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(fade);

    return FadeTransition(
      opacity: fade,
      child: SlideTransition(position: slide, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _controller,
                    curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack),
                  ),
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _controller,
                      curve: const Interval(0.0, 0.35),
                    ),
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: AppColors.emergency.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.emergency,
                        size: 52,
                        color: AppColors.emergency,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                _staggered(
                  start: 0.15,
                  end: 0.5,
                  child: Column(
                    children: [
                      Text(
                        "Emergency Response Network",
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Choose your role to continue",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 36),

                _staggered(
                  start: 0.3,
                  end: 0.7,
                  child: _RoleCard(
                    icon: Icons.person,
                    title: "Affected Person",
                    description:
                        "Request emergency assistance, send SOS alerts and "
                        "share your location.",
                    accentColor: AppColors.emergency,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AffectedHomeScreen(),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                _staggered(
                  start: 0.45,
                  end: 0.9,
                  child: _RoleCard(
                    icon: Icons.shield,
                    title: "Rescue Team",
                    description:
                        "Receive emergency alerts, monitor affected people "
                        "and manage rescue operations.",
                    accentColor: AppColors.navy,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const RescueAuthScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Color accentColor;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: accentColor),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
