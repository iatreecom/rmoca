import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/sync_settings.dart';
import '../services/github_remote.dart';

/// Configures the git repository and folder notes are synced with.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late final TextEditingController _folder;
  late final TextEditingController _token;
  late final TextEditingController _api;
  late final TextEditingController _device;
  late bool _autoSync;
  bool _showToken = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _repo = TextEditingController(
      text: s.owner.isEmpty ? '' : '${s.owner}/${s.repo}',
    );
    _branch = TextEditingController(text: s.branch);
    _folder = TextEditingController(text: s.folder);
    _token = TextEditingController(text: s.token);
    _api = TextEditingController(text: s.apiBaseUrl);
    _device = TextEditingController(text: s.deviceName);
    _autoSync = s.autoSync;
  }

  @override
  void dispose() {
    for (final c in [_repo, _branch, _folder, _token, _api, _device]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Accepts `owner/repo`, `https://github.com/owner/repo(.git)` or
  /// `git@github.com:owner/repo.git`, optionally with `/tree/branch/folder`.
  ({String owner, String repo, String? branch, String? folder})? _parseRepo(
    String input,
  ) {
    var s = input.trim();
    s = s.replaceFirst(RegExp(r'^git@[^:]+:'), '');
    s = s.replaceFirst(RegExp(r'^https?://[^/]+/'), '');
    final parts = s.split('/').where((x) => x.isNotEmpty).toList();
    if (parts.length < 2) return null;
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    String? branch;
    String? folder;
    if (parts.length >= 4 && parts[2] == 'tree') {
      branch = parts[3];
      folder = parts.skip(4).join('/');
    }
    return (owner: parts[0], repo: repo, branch: branch, folder: folder);
  }

  SyncSettings? _build() {
    final parsed = _parseRepo(_repo.text);
    if (parsed == null) return null;
    final branch = _branch.text.trim().isEmpty
        ? (parsed.branch ?? 'main')
        : _branch.text.trim();
    final folder = SyncSettings.normalizeFolder(
      _folder.text.trim().isEmpty ? (parsed.folder ?? '') : _folder.text,
    );
    final current = context.read<AppState>().settings;
    return current.copyWith(
      owner: parsed.owner,
      repo: parsed.repo,
      branch: branch,
      folder: folder,
      token: _token.text.trim(),
      apiBaseUrl: _api.text.trim().isEmpty
          ? 'https://api.github.com'
          : _api.text.trim(),
      autoSync: _autoSync,
      deviceName: _device.text.trim().isEmpty
          ? current.deviceName
          : _device.text.trim(),
    );
  }

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    final s = _build()!;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final msg = await GitHubRemote(s).testConnection();
      setState(() {
        _testOk = true;
        _testResult = msg;
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testResult = '$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final app = context.read<AppState>();
    final next = _build()!;
    if (app.settings.isConfigured && app.settings.targetKey != next.targetKey) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('동기화 위치 변경'),
          content: const Text(
            '이 기기의 메모가 새 위치의 메모와 합쳐집니다. 같은 이름의 메모 내용이 다르면 충돌 사본이 만들어집니다. 계속할까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('변경'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await app.updateSettings(next);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('동기화 설정'),
        actions: [TextButton(onPressed: _save, child: const Text('저장'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Git 저장소', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '메모는 이 기기에 먼저 저장되고, 온라인일 때 지정한 저장소 폴더와 동기화됩니다.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _repo,
              decoration: const InputDecoration(
                labelText: '저장소',
                hintText: 'owner/repo 또는 https://github.com/owner/repo',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  _parseRepo(v ?? '') == null ? 'owner/repo 형식으로 입력하세요' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _branch,
                    decoration: const InputDecoration(
                      labelText: '브랜치',
                      hintText: 'main',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _folder,
                    decoration: const InputDecoration(
                      labelText: '경로 (폴더)',
                      hintText: '예: notes (비우면 저장소 루트)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _token,
              obscureText: !_showToken,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'GitHub 액세스 토큰',
                helperText: 'Fine-grained 토큰: 해당 저장소의 Contents 읽기/쓰기 권한',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showToken ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? '토큰을 입력하세요' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('연결 테스트'),
                ),
                const SizedBox(width: 12),
                if (_testResult != null)
                  Expanded(
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        color: _testOk
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 32),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('자동 동기화'),
              subtitle: const Text('저장 후, 온라인 복귀 시, 앱을 열 때 자동으로 동기화'),
              value: _autoSync,
              onChanged: (v) => setState(() => _autoSync = v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _device,
              decoration: const InputDecoration(
                labelText: '기기 이름',
                helperText: '충돌 사본과 커밋 메시지에 표시됩니다',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('고급'),
              children: [
                TextFormField(
                  controller: _api,
                  decoration: const InputDecoration(
                    labelText: 'API 주소',
                    helperText: 'GitHub Enterprise: https://호스트/api/v3',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
            if (app.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                '최근 동기화 메시지: ${app.lastError}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
