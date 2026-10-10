# rmoca

Git 저장소와 동기화되는 깔끔한 메모 앱입니다. Flutter로 만들었고 **macOS · iOS · Android · Windows**에서 동작합니다.

- **마크다운 메모** (Obsidian 호환): `[[위키링크]]`, `![[임베드]]`, 백링크, `#태그`, 속성(frontmatter), 콜아웃, `==형광펜==`, 수식(LaTeX), 코드 문법 강조, 표, 체크리스트(눌러서 체크), 목차, 일일 노트, 템플릿, 빠른 이동(Ctrl/⌘+K)
- **펜 필기** (Samsung Notes 스타일): 펜·만년필·연필·붓·형광펜, 필압, 획/부분 지우개, 올가미 선택(이동·크기·색·복제), 도형 자동 보정, 줄·모눈·점 종이, 확대/축소, 손바닥 무시
- **그림 저장 방식 선택**: 별도 `.svg` 파일, 또는 `.md` 메모 안에 `<svg>` 코드로 넣기
- **정리**: 폴더 트리, 폴더 색, 즐겨찾기, 정렬, 휴지통(30일), 여러 개 선택, 카드/목록 보기
- **Git 동기화**: 저장소와 경로(폴더)를 지정하면 `.md` / `.svg` 파일과 양방향 동기화
- **오프라인 우선**: 모든 메모는 기기에 먼저 저장되고, 온라인이 되면 자동으로 동기화됩니다
- **라이트/다크 모드**, 강조색 선택

전체 기능 목록과 단축키는 [docs/FEATURES.md](docs/FEATURES.md)를 보세요. 동기화하는 저장소는 그대로 Obsidian 보관함으로 열 수 있습니다.

## 사용 방법

1. GitHub에서 [Fine-grained 토큰](https://github.com/settings/personal-access-tokens/new)을 만듭니다.
   - Repository access: 메모를 저장할 저장소 선택
   - Permissions → Repository → **Contents: Read and write**
2. 앱의 **설정**에서 입력합니다.
   - 저장소: `owner/repo` 또는 `https://github.com/owner/repo/tree/main/notes` 처럼 URL을 그대로 붙여 넣어도 됩니다
   - 브랜치: 기본 `main`
   - 경로: 메모를 둘 폴더 (예: `notes`, 비우면 저장소 루트)
3. **연결 테스트** 후 저장하면 바로 동기화가 시작됩니다.

토큰은 OS 보안 저장소(Keychain / Android Keystore / Windows Credential Manager)에 저장됩니다.

## 동기화 방식

동기화는 다음 시점에 자동으로 실행됩니다: 메모 저장 몇 초 후, 네트워크 재연결 시, 앱이 다시 열릴 때, 3분마다. 상단 구름 아이콘을 누르면 즉시 동기화하고, 목록을 아래로 당겨도 됩니다.

각 파일마다 세 가지 버전의 git blob SHA를 비교합니다.

| 로컬 | 원격 | 결과 |
|---|---|---|
| 마지막 동기화와 같음 | 바뀜 | 원격 내용을 내려받음 (원격에서 삭제됐으면 로컬도 삭제) |
| 바뀜 | 마지막 동기화와 같음 | 업로드 (로컬에서 삭제했으면 원격도 삭제) |
| 바뀜 | 바뀜 (서로 다름) | 원격 버전을 원래 이름으로 두고, 이 기기의 수정본은 `이름 (충돌 기기명 날짜).md` 로 따로 저장 |
| 한쪽 삭제 | 다른 쪽 수정 | 수정본을 살림 |

한 번의 동기화에서 생긴 업로드·삭제는 **하나의 커밋**으로 올라갑니다. 그 사이 다른 기기가 먼저 푸시했다면 다시 가져와서 재시도하므로 기록을 덮어쓰지 않습니다. 어떤 경우에도 메모가 사라지지 않도록 설계했습니다.

git 동작은 GitHub REST API(Git Data API)로 처리하므로 모든 플랫폼에서 별도의 git 설치 없이 동작합니다. GitHub Enterprise는 설정 → 고급에서 API 주소를 `https://호스트/api/v3`로 바꾸면 됩니다.

## 그림 파일 형식

그림은 표준 SVG로 저장되어 GitHub, 브라우저 등 어디서나 볼 수 있습니다. 각 획은 채워진 `<path>`이며, 다시 편집할 수 있도록 원본 펜 좌표와 압력을 `data-points` 속성에 함께 저장합니다. 다른 프로그램에서 만든 SVG는 보기 전용으로 열립니다.

## 개발

```bash
flutter pub get
flutter test          # 동기화 엔진, GitHub API, SVG, 화면 테스트
flutter run -d macos  # 또는 windows / ios / android
```

| 플랫폼 | 빌드 |
|---|---|
| macOS | `flutter build macos` (Mac 필요) |
| iOS | `flutter build ipa` (Mac + Xcode, 서명 필요) |
| Android | `flutter build apk` |
| Windows | `flutter build windows` (Windows 필요) |
| Linux | `flutter build linux` (개발·검증용) |

### 구조

```
lib/
  main.dart                   앱 시작, 라우팅
  app_state.dart              메모 목록, 설정, 자동 동기화 스케줄링
  models/                     Note, SyncSettings
  services/
    local_store.dart          기기 내 파일 저장, 휴지통, 동기화 기록(sync_state.json)
    sync_engine.dart          3-way 동기화 로직
    remote.dart               원격 저장소 인터페이스
    github_remote.dart        GitHub Git Data API 구현
    git_hash.dart             git blob SHA 계산
    settings_repository.dart  설정 / 토큰 저장
  markdown/                   Obsidian 문법 파싱·렌더링, 링크·태그 색인, 링크 자동 수정
  drawing/                    획·펜 종류, 캔버스(확대/올가미/지우개), 도형 인식, SVG
  widgets/note_view.dart      메모 렌더링 (콜아웃, 임베드, 수식, 체크박스…)
  screens/                    목록, 마크다운 편집기, 그림 편집기, 설정, 휴지통, 태그
  theme.dart                  라이트/다크 테마
```

## 제한 사항

- 현재는 GitHub(및 GitHub Enterprise)만 지원합니다. GitLab / Gitea 등은 `NoteRemote` 인터페이스를 구현해 추가할 수 있습니다.
- 동기화 대상은 지정한 폴더 아래의 `.md`, `.svg` 파일입니다. 다른 파일은 건드리지 않습니다.
- 파일 수가 매우 많아 GitHub 트리 응답이 잘리는 저장소는 더 작은 폴더를 지정해야 합니다.
