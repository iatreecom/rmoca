/// Where notes are synced: a folder inside a GitHub repository branch.
class SyncSettings {
  const SyncSettings({
    this.owner = '',
    this.repo = '',
    this.branch = 'main',
    this.folder = '',
    this.token = '',
    this.apiBaseUrl = 'https://api.github.com',
    this.autoSync = true,
    this.deviceName = 'device',
  });

  final String owner;
  final String repo;
  final String branch;

  /// Folder inside the repository, without leading/trailing slashes.
  /// Empty means the repository root.
  final String folder;
  final String token;

  /// `https://api.github.com`, or `https://HOST/api/v3` for GitHub Enterprise.
  final String apiBaseUrl;
  final bool autoSync;

  /// Used to name conflict copies so you can tell where they came from.
  final String deviceName;

  bool get isConfigured =>
      owner.isNotEmpty &&
      repo.isNotEmpty &&
      branch.isNotEmpty &&
      token.isNotEmpty;

  /// Identifies the sync target; when it changes the sync history is reset.
  String get targetKey => '$apiBaseUrl|$owner/$repo@$branch:$folder';

  String get displayTarget =>
      '$owner/$repo${folder.isEmpty ? '' : '/$folder'} ($branch)';

  static String normalizeFolder(String folder) => folder
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != '.')
      .join('/');

  SyncSettings copyWith({
    String? owner,
    String? repo,
    String? branch,
    String? folder,
    String? token,
    String? apiBaseUrl,
    bool? autoSync,
    String? deviceName,
  }) => SyncSettings(
    owner: owner ?? this.owner,
    repo: repo ?? this.repo,
    branch: branch ?? this.branch,
    folder: folder ?? this.folder,
    token: token ?? this.token,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    autoSync: autoSync ?? this.autoSync,
    deviceName: deviceName ?? this.deviceName,
  );
}
