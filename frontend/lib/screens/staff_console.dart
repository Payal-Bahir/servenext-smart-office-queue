import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';

typedef Json = Map<String, dynamic>;

class StaffConsole extends StatefulWidget {
  const StaffConsole({super.key});

  @override
  State<StaffConsole> createState() => _StaffConsoleState();
}

class _StaffConsoleState extends State<StaffConsole> {
  Timer? _timer;
  Json? _dash;
  Json? _queue;
  int? _deptId;
  String? _error;
  bool _busy = false;

  Json get _staff => Api.staff!;
  bool get _isAdmin => _staff['role'] == 'admin';

  @override
  void initState() {
    super.initState();
    _deptId = _staff['department_id'] as int?;
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final dash = Json.from(await Api.get('/api/admin/dashboard', auth: true) as Map);
      final depts = dash['departments'] as List;
      _deptId ??= (depts.first as Map)['id'] as int;
      final q = Json.from(await Api.get('/api/admin/queue?department_id=$_deptId', auth: true) as Map);
      if (!mounted) return;
      setState(() {
        _dash = dash;
        _queue = q;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message.contains('log in') || e.message.contains('login')) {
        _logout();
        return;
      }
      setState(() => _error = e.message);
    }
  }

  void _logout() {
    _timer?.cancel();
    Api.logout();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: error ? cs.error : null,
    ));
  }

  Future<void> _act(Future<dynamic> Function() fn, {String Function(Json)? message}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await fn();
      if (message != null && r is Map) _toast(message(Json.from(r)));
    } on ApiException catch (e) {
      _toast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  // ---------------------------------------------------------------- actions

  Future<void> _callNext() => _act(
        () => Api.post('/api/admin/departments/$_deptId/call-next', auth: true),
        message: (t) => 'Now serving ${t['token_number']}',
      );

  Future<void> _complete(Json t) => _act(
        () => Api.post('/api/admin/tokens/${t['id']}/complete', auth: true),
        message: (r) => '${r['token_number']} completed',
      );

  Future<void> _noShow(Json t) => _act(
        () => Api.post('/api/admin/tokens/${t['id']}/no-show', auth: true),
        message: (r) => r['status'] == 'cancelled'
            ? '${r['token_number']} cancelled (second no-show)'
            : '${r['token_number']} moved to the end of the queue',
      );

  Future<void> _togglePriority(Json t) => _act(
        () => Api.post('/api/admin/tokens/${t['id']}/priority',
            body: {'priority': t['is_priority'] != true}, auth: true),
        message: (r) => r['is_priority'] == true
            ? '${r['token_number']} is now PRIORITY'
            : '${r['token_number']} is a normal token again',
      );

  Future<void> _setPaused(bool paused) => _act(
        () => Api.post('/api/admin/departments/$_deptId/pause', body: {'paused': paused}, auth: true),
        message: (_) => paused ? 'Department paused' : 'Department resumed',
      );

  Future<void> _transfer(Json t) async {
    final depts = (_dash!['departments'] as List)
        .map((d) => Json.from(d as Map))
        .where((d) => d['id'] != t['department_id'])
        .toList();
    final target = await showDialog<Json>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Transfer ${t['token_number']} to...'),
        children: [
          for (final d in depts)
            SimpleDialogOption(
              onPressed: d['is_paused'] == true ? null : () => Navigator.pop(ctx, d),
              child: Text('${d['name']}${d['is_paused'] == true ? '  (paused)' : ''}'),
            ),
        ],
      ),
    );
    if (target == null) return;
    await _act(
      () => Api.post('/api/admin/tokens/${t['id']}/transfer',
          body: {'department_id': target['id']}, auth: true),
      message: (r) => 'Transferred - new token ${r['token_number']}',
    );
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${_staff['full_name']}  (${_isAdmin ? 'Admin' : 'Staff'})'),
          actions: [
            IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
            IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: 'Logout'),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
            Tab(icon: Icon(Icons.queue), text: 'Queue'),
          ]),
        ),
        body: _dash == null || _queue == null
            ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
            : TabBarView(children: [_dashboardTab(), _queueTab()]),
      ),
    );
  }

  Widget _centered(List<Widget> children) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(padding: const EdgeInsets.all(16), children: children),
        ),
      );

  // ---- dashboard tab ----
  Widget _dashboardTab() {
    final totals = Json.from(_dash!['totals'] as Map);
    final depts = (_dash!['departments'] as List).map((d) => Json.from(d as Map)).toList();
    Widget tile(String label, String value, IconData icon, Color color) => Card(
          child: SizedBox(
            width: 150,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                Icon(icon, color: color),
                const SizedBox(height: 6),
                Text(value, style: Theme.of(context).textTheme.headlineSmall),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        );
    return _centered([
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      Text(_isAdmin ? 'All departments - today' : 'My department - today',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.center, children: [
        tile('Waiting', '${totals['waiting']}', Icons.hourglass_bottom, Colors.orange),
        tile('Currently serving', '${totals['serving']}', Icons.support_agent, Colors.blue),
        tile('Completed', '${totals['completed']}', Icons.check_circle, Colors.green),
        tile('No-shows', '${totals['no_shows']}', Icons.person_off, Colors.red),
        tile('Avg waiting time', '${totals['avg_wait_minutes']} min', Icons.timer, Colors.purple),
      ]),
      const SizedBox(height: 16),
      Text('By department', style: Theme.of(context).textTheme.titleMedium),
      for (final d in depts)
        Builder(
          builder: (tabCtx) => Card(
            child: ListTile(
              title: Text('${d['name']}${d['is_paused'] == true ? '  (PAUSED)' : ''}'),
              subtitle: Text('Waiting ${d['waiting']}  •  Serving ${d['serving']}  •  '
                  'Completed ${d['completed']}  •  No-shows ${d['no_shows']}  •  '
                  'Avg wait ${d['avg_wait_minutes']} min'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                setState(() => _deptId = d['id'] as int);
                DefaultTabController.of(tabCtx).animateTo(1);
                _refresh();
              },
            ),
          ),
        ),
    ]);
  }

  // ---- queue tab ----
  Widget _queueTab() {
    final dept = Json.from(_queue!['department'] as Map);
    final serving = _queue!['serving'] == null ? null : Json.from(_queue!['serving'] as Map);
    final waiting = (_queue!['waiting'] as List).map((t) => Json.from(t as Map)).toList();
    final paused = dept['is_paused'] == true;
    final depts = (_dash!['departments'] as List).map((d) => Json.from(d as Map)).toList();

    return _centered([
      if (_isAdmin)
        Wrap(spacing: 8, children: [
          for (final d in depts)
            ChoiceChip(
              label: Text(d['code'] as String),
              selected: d['id'] == _deptId,
              onSelected: (_) {
                setState(() => _deptId = d['id'] as int);
                _refresh();
              },
            ),
        ]),
      Card(
        child: SwitchListTile(
          title: Text(dept['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(paused
              ? 'PAUSED - visitors cannot take new tokens'
              : 'Active  •  avg service ${dept['avg_service_minutes']} min'),
          value: !paused,
          onChanged: _busy ? null : (active) => _setPaused(!active),
          secondary: Icon(paused ? Icons.pause_circle : Icons.play_circle,
              color: paused ? Colors.orange : Colors.green),
        ),
      ),
      _servingCard(serving),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: (_busy || serving != null || paused || waiting.isEmpty) ? null : _callNext,
        icon: const Icon(Icons.campaign),
        label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12), child: Text('Call next token')),
      ),
      const SizedBox(height: 16),
      Text('Waiting (${waiting.length})', style: Theme.of(context).textTheme.titleMedium),
      if (waiting.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Queue is empty')),
      for (final t in waiting) _waitingTile(t),
    ]);
  }

  Widget _servingCard(Json? t) {
    if (t == null) {
      return const Card(
          child: ListTile(
              leading: Icon(Icons.hourglass_empty), title: Text('Nobody is being served')));
    }
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('NOW SERVING', style: TextStyle(fontSize: 12, letterSpacing: 1.5)),
          Text('${t['token_number']}${t['is_priority'] == true ? '  ★' : ''}',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
          Text('${t['visitor_name']}'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: _busy ? null : () => _complete(t),
                icon: const Icon(Icons.check),
                label: const Text('Complete')),
            OutlinedButton.icon(
                onPressed: _busy ? null : () => _noShow(t),
                icon: const Icon(Icons.person_off),
                label: const Text('No show')),
            OutlinedButton.icon(
                onPressed: _busy ? null : () => _transfer(t),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Transfer')),
          ]),
        ]),
      ),
    );
  }

  Widget _waitingTile(Json t) {
    final prio = t['is_priority'] == true;
    final noShow = (t['no_show_count'] as int) > 0;
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text('${t['position']}')),
        title: Text('${t['token_number']}  ${t['visitor_name']}'
            '${prio ? '  ★ PRIORITY' : ''}'),
        subtitle: Text('Est. wait ~${t['estimated_wait_minutes']} min'
            '${noShow ? '  •  1 no-show' : ''}'
            '${(t['transferred_from'] ?? '') != '' ? '  •  from ${t['transferred_from']}' : ''}'),
        trailing: Wrap(children: [
          IconButton(
            tooltip: prio ? 'Remove priority' : 'Make priority',
            icon: Icon(prio ? Icons.star : Icons.star_border, color: prio ? Colors.amber : null),
            onPressed: _busy ? null : () => _togglePriority(t),
          ),
          IconButton(
            tooltip: 'Transfer to another department',
            icon: const Icon(Icons.swap_horiz),
            onPressed: _busy ? null : () => _transfer(t),
          ),
        ]),
      ),
    );
  }
}
