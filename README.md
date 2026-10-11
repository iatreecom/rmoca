# rmoca

Git 저장소와 동기화되는 깔끔한 메모 앱입니다. Flutter로 만들었고 **macOS · iOS · Android · Windows**에서 동작합니다.

- **쉬운 편집 (블록 모드)**: 렌더링된 화면 그대로 블록을 눌러 고치고, `/` 또는 + 버튼으로 제목·체크리스트·표·콜아웃·코드·수식·다이어그램·사진·그림을 넣습니다. 표는 칸 단위로 편집. 마크다운 원문 편집도 언제든 전환
- **마크다운 메모** (Obsidian 호환): `[[위키링크]]`, `![[임베드]]`, 백링크, `#태그`, 속성(frontmatter), 콜아웃, `==형광펜==`, 코드 문법 강조, 표, 체크리스트(눌러서 체크), 목차, 일일 노트·캘린더, 템플릿, 그래프 뷰, 빠른 이동(Ctrl/⌘+K)
- **수식·다이어그램·이미지**: LaTeX(`align`, `\tag`, `\newcommand`, `\ce` 포함), Mermaid 28종(앱에서 직접 렌더링), base64/`data:` 이미지, SVG(CSS 포함), HTML `<img>`, 갤러리·카메라 사진 넣기
- **펜 필기** (Samsung Notes 스타일): 펜·만년필·연필·붓·형광펜, 필압, 획/부분 지우개, 올가미 선택(이동·크기·색·복제), 도형 자동 보정, 줄·모눈·점 종이, 확대/축소, 손바닥 무시
- **태블릿**: 넓은 화면에서 목록과 메모를 나란히(분할 보기), 글자 크기 조절, 키보드 단축키
- **Git 동기화**: GitHub, GitLab, Gitea·Forgejo, Bitbucket, 사내·개인 서버 등 **HTTPS로 접근되는 모든 git 서버**. 저장소와 경로(폴더)를 지정하면 여러 기기의 메모가 하나의 저장소로 모입니다
- **오프라인 우선**: 모든 메모와 첨부 이미지는 기기에 먼저 저장되고, 온라인이 되면 자동으로 동기화. 원격 이미지도 미리 받아 보관
- **버전 기록**: 메모의 이전 내용을 기기에 보관하고 변경 내용 비교·복원
- **검색과 정리**: 본문 전체 검색(미리보기 문장, `#태그`, `"구문"`), 폴더 트리, 폴더 색, 즐겨찾기, 정렬, 휴지통(30일), 여러 개 선택
- **공유**: 텍스트, `.md` 파일, HTML 웹 페이지로 내보내기
- **라이트/다크 모드**, 강조색 선택

전체 기능 목록과 단축키는 [docs/FEATURES.md](docs/FEATURES.md)를 보세요. 동기화하는 저장소는 그대로 Obsidian 보관함으로 열 수 있습니다.

## 사용 방법

앱의 **설정 → Git 저장소**에서 서버 종류를 고릅니다.

### GitHub (API 방식)

1. [Fine-grained 토큰](https://github.com/settings/personal-access-tokens/new)을 만듭니다.
   - Repository access: 메모를 저장할 저장소 선택
   - Permissions → Repository → **Contents: Read and write**
2. 저장소에 `owner/repo` 또는 `https://github.com/owner/repo/tree/main/notes` 처럼 URL을 그대로 붙여 넣고, 브랜치와 경로(메모를 둘 폴더, 비우면 루트)를 입력합니다.
3. **연결 테스트** 후 저장하면 바로 동기화가 시작됩니다.

GitHub Enterprise는 설정 → 고급에서 API 주소를 `https://호스트/api/v3`로 바꾸면 됩니다.

### Git 서버 (HTTPS) — GitLab, Gitea, Bitbucket, 사설 서버

서버의 "Clone" 버튼에 나오는 **HTTPS 주소**와 계정을 입력합니다.

| 서버 | 사용자명 | 토큰/비밀번호 |
|---|---|---|
| GitHub | 아무 이름 (예: `git`) | 개인 액세스 토큰 (Contents 읽기/쓰기) |
| GitLab | GitLab 사용자명 또는 `oauth2` | 개인 액세스 토큰 (`write_repository`) |
| Gitea / Forgejo | 사용자명 | 액세스 토큰(저장소 쓰기) 또는 비밀번호 |
| Bitbucket | Bitbucket 사용자명 (액세스 토큰이면 `x-token-auth`) | 앱 비밀번호 또는 액세스 토큰 |
| 기타 (`git http-backend`, NAS 등) | 서버 계정 | 서버 계정 비밀번호 |

- 사내망·NAS 등 공인 인증서가 없는 서버는 **자체 서명 인증서 허용**을 켭니다.
- 커밋 작성자 이름·이메일을 정할 수 있습니다 (비우면 기기 이름).
- URL에 `https://사용자:토큰@호스트/...` 형태로 넣으면 자동으로 나눠 저장합니다.

토큰·비밀번호는 OS 보안 저장소(Keychain / Android Keystore / Windows Credential Manager)에 저장됩니다.

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

어느 방식이든 기기에 git을 설치할 필요가 없습니다.

- **GitHub 방식**은 GitHub REST API(Git Data API)를 씁니다.
- **Git 서버 방식**은 git의 smart HTTP 프로토콜을 앱이 직접 구현해 씁니다 (`lib/git/`). 최신 커밋만 얕게(shallow) 받아오고, 이후에는 이미 가진 객체를 서버에 알려 바뀐 것만 받습니다. 받은 객체는 기기에 보관합니다. 푸시할 때 그 사이 브랜치가 움직였으면 서버가 거절하고, 앱은 다시 받아서 합친 뒤 재시도합니다.

### 버전 기록

동기화와 별개로, 메모가 바뀔 때 이전 내용을 기기에 보관합니다 (편집 중에는 5분에 한 번, 다른 기기의 변경이 덮어쓸 때는 항상, 메모당 최근 50개). 메모 메뉴 → **버전 기록**에서 변경 내용을 비교하고 복원할 수 있습니다. 더 오래된 기록은 Git 저장소의 커밋 기록에 남아 있습니다.

## 그림 파일 형식

그림은 표준 SVG로 저장되어 GitHub, 브라우저 등 어디서나 볼 수 있습니다. 각 획은 채워진 `<path>`이며, 다시 편집할 수 있도록 원본 펜 좌표와 압력을 `data-points` 속성에 함께 저장합니다. 다른 프로그램에서 만든 SVG는 보기 전용으로 열립니다.

## 개발

```bash
flutter pub get
flutter test          # 동기화 엔진, GitHub API, git 프로토콜(git http-backend 사용), SVG, 화면 테스트
flutter run -d macos  # 또는 windows / ios / android
```

| 플랫폼 | 빌드 |
|---|---|
| macOS | `flutter build macos` (Mac 필요) |
| iOS | `flutter build ipa` (Mac + Xcode, 서명 필요) |
| Android | `flutter build apk` |
| Windows | `flutter build windows` (Windows 필요) |
| Linux | `flutter build linux` (개발·검증용) |

### 실제 기기에서 확인 (GitHub Actions)

`.github/workflows/devices.yml` 은 푸시할 때마다 테스트를 돌리고, Actions 탭 → **devices** → **Run workflow** 로 실행하면 앱을 실제 플랫폼에서 한 바퀴 돌며 화면을 캡처합니다.

| 작업 | 환경 |
|---|---|
| android | Android 에뮬레이터 (Pixel 7 폰, Pixel Tablet) |
| ios | iOS 시뮬레이터 (iPhone, iPad) |
| desktop | macOS, Windows 앱 |

캡처 화면은 실행 결과 페이지의 **Artifacts** 에서 내려받을 수 있습니다. 같은 테스트를 내 컴퓨터에서 돌리려면:

```bash
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart --dart-define=SCREENSHOTS=true -d <기기>
```

비공개 저장소에서는 macOS 실행 시간이 Linux의 10배로 계산되니 필요할 때만 실행하세요.

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
    remote_factory.dart       설정에 맞는 원격 저장소 선택
    github_remote.dart        GitHub Git Data API 구현
    search.dart               본문 검색
    export.dart               HTML 내보내기
    git_hash.dart             git blob SHA 계산
    settings_repository.dart  설정 / 토큰 저장
  git/                        git smart HTTP 클라이언트 (pack 파일, 델타, push)
  markdown/                   Obsidian 문법 파싱·렌더링, 링크·태그 색인, 링크 자동 수정,
                              블록 분할, 표, 줄 단위 비교
  drawing/                    획·펜 종류, 캔버스(확대/올가미/지우개), 도형 인식, SVG
  widgets/                    메모 렌더링, 블록 편집기, 블록 메뉴, 표 편집기, 문법 도움말
  screens/                    목록(분할 보기), 메모 편집기, 그림 편집기, 설정, 휴지통, 태그,
                              버전 기록, 그래프, 캘린더
  theme.dart                  라이트/다크 테마
```

## 제한 사항

- Git 서버 방식은 HTTPS(또는 HTTP)만 지원합니다. SSH 주소(`git@host:...`)는 쓸 수 없으니 HTTPS 주소를 사용하세요.
- 동기화 대상은 지정한 폴더 아래의 메모(`.md`, `.svg`), 첨부 이미지, `.rmoca/meta.json` 입니다. 다른 파일은 건드리지 않습니다.
- GitHub 방식에서 파일 수가 매우 많아 트리 응답이 잘리는 저장소는 더 작은 폴더를 지정하거나 Git 서버 방식을 쓰세요.
- 버전 기록은 기기마다 따로 보관됩니다 (동기화되지 않음).
