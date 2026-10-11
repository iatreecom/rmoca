/// How the app talks to the repository.
enum RemoteKind {
  /// GitHub's REST API (github.com or GitHub Enterprise). Needs only a token.
  github,

  /// Git's own smart HTTP protocol: works with any git server — GitLab,
  /// Gitea/Forgejo, Bitbucket, Azure DevOps, a NAS, self-hosted servers,
  /// and GitHub too.
  git,
}

/// Where notes are synced: a folder inside a branch of a git repository.
class SyncSettings {
  const SyncSettings({
    this.kind = RemoteKind.github,
    this.owner = '',
    this.repo = '',
    this.gitUrl = '',
    this.username = '',
    this.branch = 'main',
    this.folder = '',
    this.token = '',
    this.apiBaseUrl = 'https://api.github.com',
    this.allowSelfSigned = false,
    this.authorName = '',
    this.authorEmail = '',
    this.autoSync = true,
    this.deviceName = 'device',
  });

  final RemoteKind kind;

  /// GitHub API: `owner/repo`.
  final String owner;
  final String repo;

  /// Git over HTTPS: the clone URL, e.g. `https://gitlab.com/me/notes.git`.
  final String gitUrl;

  /// Git over HTTPS: user name for basic auth (many servers accept any
  /// name together with an access token).
  final String username;
  final String branch;

  /// Folder inside the repository, without leading/trailing slashes.
  /// Empty means the repository root.
  final String folder;

  /// Access token (GitHub) or token/password (git over HTTPS).
  final String token;

  /// `https://api.github.com`, or `https://HOST/api/v3` for GitHub Enterprise.
  final String apiBaseUrl;

  /// Accept self-signed TLS certificates (home servers, company networks).
  final bool allowSelfSigned;

  /// Commit author; empty uses the device name.
  final String authorName;
  final String authorEmail;
  final bool autoSync;

  /// Used to name conflict copies so you can tell where they came from.
  final String deviceName;

  bool get isConfigured => switch (kind) {
    RemoteKind.github =>
      owner.isNotEmpty &&
          repo.isNotEmpty &&
          branch.isNotEmpty &&
          token.isNotEmpty,
    RemoteKind.git => isValidGitUrl(gitUrl) && branch.isNotEmpty,
  };

  /// Identifies the sync target; when it changes the sync history is reset.
  String get targetKey => switch (kind) {
    RemoteKind.github => '$apiBaseUrl|$owner/$repo@$branch:$folder',
    RemoteKind.git => 'git|${normalizeGitUrl(gitUrl)}@$branch:$folder',
  };

  String get displayTarget {
    final where = switch (kind) {
      RemoteKind.github => '$owner/$repo',
      RemoteKind.git =>
        normalizeGitUrl(gitUrl)
            .replaceFirst(RegExp(r'^https?://'), '')
            .replaceFirst(RegExp(r'\.git$'), ''),
    };
    return '$where${folder.isEmpty ? '' : '/$folder'} ($branch)';
  }

  String get effectiveAuthorName =>
      authorName.trim().isEmpty ? deviceName : authorName.trim();

  String get effectiveAuthorEmail => authorEmail.trim().isEmpty
      ? '${deviceName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')}@rmoca.local'
      : authorEmail.trim();

  static String normalizeFolder(String folder) => folder
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != '.')
      .join('/');

  static bool isValidGitUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty;
  }

  /// Trims, drops a trailing slash and credentials embedded in the URL.
  static String normalizeGitUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim();
    return uri.replace(userInfo: '').toString().replaceAll(RegExp(r'/+$'), '');
  }

  SyncSettings copyWith({
    RemoteKind? kind,
    String? owner,
    String? repo,
    String? gitUrl,
    String? username,
    String? branch,
    String? folder,
    String? token,
    String? apiBaseUrl,
    bool? allowSelfSigned,
    String? authorName,
    String? authorEmail,
    bool? autoSync,
    String? deviceName,
  }) => SyncSettings(
    kind: kind ?? this.kind,
    owner: owner ?? this.owner,
    repo: repo ?? this.repo,
    gitUrl: gitUrl ?? this.gitUrl,
    username: username ?? this.username,
    branch: branch ?? this.branch,
    folder: folder ?? this.folder,
    token: token ?? this.token,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
    authorName: authorName ?? this.authorName,
    authorEmail: authorEmail ?? this.authorEmail,
    autoSync: autoSync ?? this.autoSync,
    deviceName: deviceName ?? this.deviceName,
  );
}
