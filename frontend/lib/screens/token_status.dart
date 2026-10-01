import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';

/// Live view of one token. Polls the server every 3 seconds, so position and
/// estimated wait update whenever the queue changes (call, no-show, priority, cancel...).
class TokenStatusScreen extends StatefulWidget {
  final int tokenId;
  const TokenStatusScreen({super.key, required this.tokenId});

  @override
  State<TokenStatusScreen> createState() => _TokenStatusScreenState();
}

class _TokenStatusScreenState extends State<TokenStatusScreen> {
  Map<String, dynamic>? _t;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await Api.token(widget.tokenId);
      if (!mounted) return;
      setState(() {
        _t = t;
        _error = null;
      });
      final status = t['status'];
      if (status == 'completed' || status == 'cancelled') {
        _timer?.cancel();
        await _clearSaved();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _clearSaved() async {
    final p = await SharedPreferences.getInstance();
    if (p.getInt('active_token_id') == widget.tokenId) await p.remove('active_token_id');
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel token?'),
        content: const Text('You will lose your place in the queue.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel token')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final t = await Api.cancelToken(widget.tokenId);
      await _clearSaved();
      if (mounted) setState(() => _t = t);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: const Text('Your token')),
      body: t == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('Reconnecting... ($_error)',
                            style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    _header(t),
                    const SizedBox(height: 16),
                    _body(t),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _header(Map<String, dynamic> t) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        child: Column(children: [
          Text(t['department_name'] as String),
          const SizedBox(height: 4),
          Text(t['token_number'] as String,
              style: Theme.of(context)
                  .textTheme
                  .displayMedium
                  ?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 2)),
          const SizedBox(height: 6),
          Text(t['visitor_name'] as String),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            Chip(label: Text((t['status'] as String).toUpperCase())),
            if (t['is_priority'] == true)
              const Chip(avatar: Icon(Icons.star, size: 16), label: Text('PRIORITY')),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Icon(icon),
              const SizedBox(height: 8),
              Text(value, style: Theme.of(context).textTheme.headlineMedium),
              Text(label, textAlign: TextAlign.center),
            ]),
          ),
        ),
      );

  Widget _body(Map<String, dynamic> t) {
    switch (t['status'] as String) {
      case 'waiting':
        final mins = t['estimated_wait_minutes'] as int;
        return Column(children: [
          Row(children: [
            _stat('Position in queue', '${t['position']}', Icons.format_list_numbered),
            _stat('Estimated wait', mins == 0 ? '< 1 min' : '~$mins min', Icons.timer_outlined),
          ]),
          Text('${t['people_ahead']} ahead of you'
              '${(t['now_serving'] as String).isNotEmpty ? '  •  Now serving ${t['now_serving']}' : ''}'),
          if (t['department_paused'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('This department is temporarily paused. Your place is kept.'),
            ),
          if ((t['no_show_count'] as int) > 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('You were marked as no-show once. One more and the token is cancelled.'),
            ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _cancel,
            icon: const Icon(Icons.close),
            label: const Text('Cancel token'),
          ),
        ]);
      case 'serving':
        return Card(
          color: Colors.green.shade100,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Column(children: [
              Icon(Icons.notifications_active, size: 48, color: Colors.green),
              SizedBox(height: 8),
              Text("It's your turn!",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              Text('Please go to the service counter now.'),
            ]),
          ),
        );
      case 'completed':
        return _endCard(Icons.check_circle, Colors.green, 'Service completed. Thank you!');
      default:
        final reason = t['cancel_reason'];
        return _endCard(
            Icons.cancel,
            Colors.red,
            reason == 'no_show_twice'
                ? 'Token cancelled after two no-shows.'
                : 'Token cancelled.');
    }
  }

  Widget _endCard(IconData icon, Color color, String text) => Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: () => Navigator.pop(context), child: const Text('Back to services')),
          ]),
        ),
      );
}
