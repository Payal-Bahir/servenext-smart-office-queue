import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'token_status.dart';

const _prefsKey = 'active_token_id';

IconData _iconFor(String code) {
  switch (code) {
    case 'IT':
      return Icons.computer;
    case 'HR':
      return Icons.groups;
    case 'ACC':
      return Icons.account_balance_wallet;
    default:
      return Icons.apartment;
  }
}

class VisitorHome extends StatefulWidget {
  const VisitorHome({super.key});

  @override
  State<VisitorHome> createState() => _VisitorHomeState();
}

class _VisitorHomeState extends State<VisitorHome> {
  List<dynamic> _depts = [];
  String? _error;
  int? _activeTokenId;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _refresh();
    // Keep waiting counts / paused state fresh.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _activeTokenId = p.getInt(_prefsKey));
  }

  Future<void> _refresh() async {
    try {
      final d = await Api.departments();
      if (mounted) setState(() {
            _depts = d;
            _error = null;
            _loading = false;
          });
    } on ApiException catch (e) {
      if (mounted) setState(() {
            _error = e.message;
            _loading = false;
          });
    }
  }

  Future<void> _openToken(int id) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TokenStatusScreen(tokenId: id)));
    await _loadSaved();
    _refresh();
  }

  Future<void> _getToken(Map<String, dynamic> dept) async {
    final nameCtl = TextEditingController();
    final phoneCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Token for ${dept['name']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              autofocus: true,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Your name *'),
            ),
            TextField(
              controller: phoneCtl,
              keyboardType: TextInputType.phone,
              maxLength: 20,
              decoration: const InputDecoration(labelText: 'Phone (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Get token')),
        ],
      ),
    );
    if (ok != true) return;
    if (nameCtl.text.trim().isEmpty) {
      _toast('Please enter your name');
      return;
    }
    try {
      final t = await Api.createToken(dept['id'] as int, nameCtl.text.trim(), phoneCtl.text.trim());
      final p = await SharedPreferences.getInstance();
      await p.setInt(_prefsKey, t['id'] as int);
      if (!mounted) return;
      await _openToken(t['id'] as int);
    } on ApiException catch (e) {
      _toast(e.message);
      _refresh();
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select a service')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
                    ),
                  if (_activeTokenId != null)
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: ListTile(
                        leading: const Icon(Icons.confirmation_number),
                        title: const Text('You have an active token'),
                        subtitle: const Text('Tap to see your live position'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openToken(_activeTokenId!),
                      ),
                    ),
                  for (final d in _depts) _deptCard(Map<String, dynamic>.from(d as Map)),
                ],
              ),
            ),
    );
  }

  Widget _deptCard(Map<String, dynamic> d) {
    final paused = d['is_paused'] == true;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: paused ? cs.surfaceContainerHighest : cs.primaryContainer,
          child: Icon(_iconFor(d['code'] as String)),
        ),
        title: Text(d['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: paused
            ? const Text('Paused - not issuing tokens right now')
            : Text('${d['waiting']} waiting  •  ~${d['estimated_wait_minutes']} min wait'
                '${(d['now_serving'] as String).isNotEmpty ? '\nNow serving ${d['now_serving']}' : ''}'),
        isThreeLine: !paused && (d['now_serving'] as String).isNotEmpty,
        trailing: FilledButton(
          onPressed: paused ? null : () => _getToken(d),
          child: Text(paused ? 'Paused' : 'Get token'),
        ),
      ),
    );
  }
}
