import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/sync_settings.dart';
import '../services/remote_factory.dart';

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
  late final TextEditingController _gitUrl;
  late final TextEditingController _username;
  late final TextEditingController _authorName;
  late final TextEditingController _authorEmail;
  late bool _autoSync;
  late RemoteKind _kind;
  late bool _allowSelfSigned;
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
    _gitUrl = TextEditingController(text: s.gitUrl);
    _username = TextEditingController(text: s.username);
    _authorName = TextEditingController(text: s.authorName);
    _authorEmail = TextEditingController(text: s.authorEmail);
    _autoSync = s.autoSync;
    _kind = s.kind;
    _allowSelfSigned = s.allowSelfSigned;
    _preset = _guessPreset(s.gitUrl);
  }

  @override
  void dispose() {
    for (final c in [
      _repo,
      _branch,
      _folder,
      _token,
      _api,
      _device,
      _gitUrl,
      _username,
      _authorName,
      _authorEmail,
    ]) {
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
    if (_kind == RemoteKind.git) return _buildGit();
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
      kind: RemoteKind.github,
      authorName: _authorName.text.trim(),
      authorEmail: _authorEmail.text.trim(),
    );
  }

  SyncSettings _buildGit() {
    final current = context.read<AppState>().settings;
    final url = _gitUrl.text.trim();
    // Credentials typed into the URL (https://user:token@host/…) move to
    // their own fields so they end up in the keychain, not preferences.
    final uri = Uri.tryParse(url);
    var user = _username.text.trim();
    var token = _token.text.trim();
    if (uri != null && uri.userInfo.isNotEmpty) {
      final parts = uri.userInfo.split(':');
      if (user.isEmpty) user = Uri.decodeComponent(parts.first);
      if (token.isEmpty && parts.length > 1) {
        token = Uri.decodeComponent(parts.skip(1).join(':'));
      }
    }
    return current.copyWith(
      kind: RemoteKind.git,
      gitUrl: SyncSettings.normalizeGitUrl(url),
      username: user,
      token: token,
      branch: _branch.text.trim().isEmpty ? 'main' : _branch.text.trim(),
      folder: SyncSettings.normalizeFolder(_folder.text),
      allowSelfSigned: _allowSelfSigned,
      authorName: _authorName.text.trim(),
      authorEmail: _authorEmail.text.trim(),
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
      final msg = await testRemote(s, context.read<AppState>().store.dataDir);
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

  static const _presets = <(String, String, String, String)>[
    // name, URL example, user name hint, token hint
    (
      'GitHub',
      'https://github.com/me/notes.git',
      '아무 이름 (예: git)',
      '개인 액세스 토큰 (Contents 읽기/쓰기)',
    ),
    (
      'GitLab',
      'https://gitlab.com/me/notes.git',
      'GitLab 사용자명 또는 oauth2',
      '개인 액세스 토큰 (write_repository)',
    ),
    (
      'Gitea · Forgejo',
      'https://git.example.com/me/notes.git',
      '사용자명',
      '액세스 토큰 또는 비밀번호',
    ),
    (
      'Bitbucket',
      'https://bitbucket.org/team/notes.git',
      'Bitbucket 사용자명 (토큰이면 x-token-auth)',
      '앱 비밀번호 또는 액세스 토큰',
    ),
    ('기타', 'https://서버/경로/notes.git', '사용자명', '비밀번호 또는 토큰'),
  ];
  int _preset = 0;

  int _guessPreset(String url) {
    final host = Uri.tryParse(url.trim())?.host ?? '';
    if (host.endsWith('github.com')) return 0;
    if (host.contains('gitlab')) return 1;
    if (host.contains('gitea') ||
        host.contains('forgejo') ||
        host.contains('codeberg')) {
      return 2;
    }
    if (host.contains('bitbucket')) return 3;
    return host.isEmpty ? _preset : 4;
  }

  List<Widget> _gitFields() {
    final preset = _presets[_preset];
    return [
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _presets.length; i++)
            ChoiceChip(
              label: Text(_presets[i].$1),
              selected: _preset == i,
              onSelected: (_) => setState(() => _preset = i),
            ),
        ],
      ),
      TextFormField(
        controller: _gitUrl,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: '저장소 URL (HTTPS)',
          hintText: preset.$2,
          helperText: '서버의 "Clone" 버튼에 나오는 HTTPS 주소',
          prefixIcon: const Icon(Icons.link_rounded),
        ),
        onChanged: (v) {
          final guess = _guessPreset(v);
          if (guess != _preset) setState(() => _preset = guess);
        },
        validator: (v) => SyncSettings.isValidGitUrl(v ?? '')
            ? null
            : 'https://… 형식의 저장소 주소를 입력하세요',
      ),
      TextFormField(
        controller: _username,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: '사용자명',
          hintText: preset.$3,
          prefixIcon: const Icon(Icons.person_outline_rounded),
        ),
      ),
      TextFormField(
        controller: _token,
        obscureText: !_showToken,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: '토큰 또는 비밀번호',
          helperText: '${preset.$4} · 기기의 보안 저장소에 보관됩니다',
          prefixIcon: const Icon(Icons.key_rounded),
          suffixIcon: IconButton(
            icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showToken = !_showToken),
          ),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('자체 서명 인증서 허용'),
        subtitle: const Text('사내망·NAS 등 공인 인증서가 없는 서버용. 믿을 수 있는 서버에서만 켜세요'),
        value: _allowSelfSigned,
        onChanged: (v) => setState(() => _allowSelfSigned = v),
      ),
    ];
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      icon: Icons.cloud_sync_outlined,
                      title: 'Git 저장소',
                      subtitle: '메모는 이 기기에 먼저 저장되고, 온라인일 때 지정한 저장소 폴더와 동기화됩니다.',
                      children: [
                        SegmentedButton<RemoteKind>(
                          segments: const [
                            ButtonSegment(
                              value: RemoteKind.github,
                              icon: Icon(Icons.hub_outlined),
                              label: Text('GitHub'),
                            ),
                            ButtonSegment(
                              value: RemoteKind.git,
                              icon: Icon(Icons.dns_outlined),
                              label: Text('Git 서버 (HTTPS)'),
                            ),
                          ],
                          selected: {_kind},
                          onSelectionChanged: (v) => setState(() {
                            _kind = v.first;
                            _testResult = null;
                          }),
                        ),
                        if (_kind == RemoteKind.git) ..._gitFields(),
                        if (_kind == RemoteKind.github)
                          TextFormField(
                            controller: _repo,
                            decoration: const InputDecoration(
                              labelText: '저장소',
                              hintText:
                                  'owner/repo 또는 https://github.com/owner/repo',
                              prefixIcon: Icon(Icons.source_outlined),
                            ),
                            validator: (v) => _parseRepo(v ?? '') == null
                                ? 'owner/repo 형식으로 입력하세요'
                                : null,
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _branch,
                                decoration: const InputDecoration(
                                  labelText: '브랜치',
                                  hintText: 'main',
                                  prefixIcon: Icon(Icons.call_split_rounded),
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
                                  hintText: '예: notes (비우면 루트)',
                                  prefixIcon: Icon(Icons.folder_outlined),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_kind == RemoteKind.github)
                          TextFormField(
                            controller: _token,
                            obscureText: !_showToken,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: InputDecoration(
                              labelText: 'GitHub 액세스 토큰',
                              helperText:
                                  'Fine-grained 토큰: 해당 저장소의 Contents 읽기/쓰기 권한',
                              prefixIcon: const Icon(Icons.key_rounded),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _showToken
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () =>
                                    setState(() => _showToken = !_showToken),
                              ),
                            ),
                            validator: (v) =>
                                (v ?? '').trim().isEmpty ? '토큰을 입력하세요' : null,
                          ),
                        Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: _testing ? null : _test,
                              icon: _testing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.wifi_tethering),
                              label: const Text('연결 테스트'),
                            ),
                            const SizedBox(width: 12),
                            if (_testResult != null)
                              Expanded(
                                child: Row(
                                  children: [
                                    Icon(
                                      _testOk
                                          ? Icons.check_circle_rounded
                                          : Icons.error_outline_rounded,
                                      size: 18,
                                      color: _testOk
                                          ? Colors.green.shade600
                                          : Theme.of(context).colorScheme.error,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        _testResult!,
                                        style: TextStyle(
                                          color: _testOk
                                              ? Colors.green.shade700
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .error,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.sync_rounded,
                      title: '동기화',
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('자동 동기화'),
                          subtitle: const Text(
                            '저장 후, 온라인 복귀 시, 앱을 열 때 자동으로 동기화',
                          ),
                          value: _autoSync,
                          onChanged: (v) => setState(() => _autoSync = v),
                        ),
                        TextFormField(
                          controller: _device,
                          decoration: const InputDecoration(
                            labelText: '기기 이름',
                            helperText: '충돌 사본과 커밋 메시지에 표시됩니다',
                            prefixIcon: Icon(Icons.devices_rounded),
                          ),
                        ),
                        if (_kind == RemoteKind.github)
                          TextFormField(
                            controller: _api,
                            decoration: const InputDecoration(
                              labelText: 'API 주소 (고급)',
                              helperText:
                                  'GitHub Enterprise: https://호스트/api/v3',
                              prefixIcon: Icon(Icons.dns_outlined),
                            ),
                          ),
                        TextFormField(
                          controller: _authorName,
                          decoration: const InputDecoration(
                            labelText: '커밋 작성자 이름',
                            helperText: '비우면 기기 이름을 사용합니다',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                        ),
                        TextFormField(
                          controller: _authorEmail,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: '커밋 작성자 이메일',
                            prefixIcon: Icon(Icons.alternate_email_rounded),
                          ),
                        ),
                        if (app.lastError != null)
                          Text(
                            '최근 동기화 메시지: ${app.lastError}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                    _Section(
                      icon: Icons.palette_outlined,
                      title: '화면',
                      children: [
                        Text(
                          '메모 글자 크기 ${(app.noteScale * 100).round()}%',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Slider(
                          value: app.noteScale,
                          min: AppState.noteScales.min,
                          max: AppState.noteScales.max,
                          divisions: 8,
                          label: '${(app.noteScale * 100).round()}%',
                          onChanged: app.setNoteScale,
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('쉬운 편집을 기본으로'),
                          subtitle: const Text(
                            '편집할 때 블록 단위 편집(렌더링된 화면)으로 시작합니다. 끄면 마크다운 원문 편집',
                          ),
                          value: app.easyEditing,
                          onChanged: app.setEasyEditing,
                        ),
                        SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              icon: Icon(Icons.brightness_auto_outlined),
                              label: Text('시스템'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              icon: Icon(Icons.light_mode_outlined),
                              label: Text('라이트'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              icon: Icon(Icons.dark_mode_outlined),
                              label: Text('다크'),
                            ),
                          ],
                          selected: {app.themeMode},
                          onSelectionChanged: (s) =>
                              app.setAppearance(mode: s.first),
                        ),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final c in AppState.accentColors)
                              InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => app.setAppearance(accent: c),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color:
                                          app.accent.toARGB32() == c.toARGB32()
                                          ? Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                  child: app.accent.toARGB32() == c.toARGB32()
                                      ? const Icon(
                                          Icons.check_rounded,
                                          color: Colors.white,
                                        )
                                      : null,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.draw_outlined,
                      title: '그림',
                      children: [
                        SegmentedButton<DrawingMode>(
                          segments: const [
                            ButtonSegment(
                              value: DrawingMode.file,
                              icon: Icon(Icons.insert_drive_file_outlined),
                              label: Text('SVG 파일'),
                            ),
                            ButtonSegment(
                              value: DrawingMode.embedded,
                              icon: Icon(Icons.code_rounded),
                              label: Text('메모에 넣기'),
                            ),
                          ],
                          selected: {app.drawingMode},
                          onSelectionChanged: (s) =>
                              app.setDrawingMode(s.first),
                        ),
                        Text(
                          '새 그림의 기본 저장 방식입니다. 그림을 만들 때마다 바꿀 수도 있습니다.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: t.bodySmall?.copyWith(color: scheme.outline),
                ),
              ],
              for (final child in children) ...[
                const SizedBox(height: 14),
                child,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
