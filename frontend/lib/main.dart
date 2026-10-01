import 'package:flutter/material.dart';

import 'screens/staff_login.dart';
import 'screens/visitor_home.dart';

void main() => runApp(const ServeNextApp());

class ServeNextApp extends StatelessWidget {
  const ServeNextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ServeNext',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.confirmation_number_outlined, size: 72, color: cs.primary),
                  const SizedBox(height: 12),
                  Text('ServeNext',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineLarge),
                  const SizedBox(height: 4),
                  Text('Get your token. Track your turn live.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    icon: const Icon(Icons.person),
                    label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Text('I am a visitor - get a token')),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const VisitorHome())),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.badge_outlined),
                    label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Text('Staff / Admin login')),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const StaffLogin())),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
