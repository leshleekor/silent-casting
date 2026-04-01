# Silent Casting

Silent Casting은 GitHub 저장소의 `skills/` 디렉토리를 로컬로 동기화한 뒤, Claude Code와 Codex가 항상 최신 로컬 Skills를 읽게 만드는 스크립트 모음이다.

## 무엇을 해주나

- source repo를 `SKILLS_SYNC_DIR/repo`에 clone 또는 update한다.
- `skills/` 트리를 Claude/Codex가 읽는 로컬 Skills 디렉토리로 복사한다.
- 원하면 `SessionStart` hook을 등록해 실행 직전에 자동 동기화한다.
- 동기화에 실패해도 마지막으로 성공한 로컬 Skills가 있으면 그대로 유지한다.

## 준비물

- macOS 또는 Linux
- `bash`, `git`
- `python3` (`--bootstrap` 사용 시 필요)
- Claude Code 또는 Codex
- 루트에 `skills/` 디렉토리가 있는 Git 저장소

## Skills 저장소 구조

Silent Casting 자체는 Skill 콘텐츠를 포함하지 않는다. 동기화 대상은 별도의 skills 저장소여야 한다.

```text
your-skills-repo/
├─ skills/
│  ├─ common/
│  │  └─ logging/SKILL.md
│  ├─ backend/
│  │  └─ api-review/SKILL.md
│  └─ frontend/
│     └─ accessibility-check/SKILL.md
└─ manifest.json
```

- 각 Skill은 자체 디렉토리 안에 `SKILL.md`를 가진다.
- `skills/` 아래 구조가 Claude/Codex 설치 디렉토리로 그대로 복사된다.
- `manifest.json`은 선택 사항이다. 있으면 로컬 캐시에 복사하고, 없어도 동기화 자체는 가능하다.

## 빠른 시작

아래 순서는 Silent Casting을 동기화 도구로 설치하고, 별도의 skills 저장소를 source repo로 연결하는 가장 빠른 방법이다.

중요: `--bootstrap`는 현재 저장소의 `scripts/run.sh` 절대경로를 사용자 설정에 기록한다. 그래서 bootstrap 후에는 이 저장소를 다른 위치로 옮기지 않는 편이 안전하다. 저장소 위치를 바꿨다면 새 위치에서 `--bootstrap`를 다시 실행하면 된다.

### 1. 이 저장소를 안정적인 경로에 clone

```bash
git clone <THIS_REPOSITORY_URL> "$HOME/tools/silent-casting"
cd "$HOME/tools/silent-casting"
```

`<THIS_REPOSITORY_URL>`에는 GitHub의 `Code` 버튼에서 복사한 이 저장소의 clone URL을 넣으면 된다.

### 2. source skills 저장소 정보 설정

```bash
export SKILLS_GIT_URL="git@github.com:your-org/your-skills-repo.git"
export SKILLS_BRANCH="main"
export SKILLS_SYNC_DIR="$HOME/.company-skills"
```

이미 source skills 저장소 안에서 작업 중이라면 아래처럼 현재 원격 정보를 그대로 써도 된다.

```bash
export SKILLS_GIT_URL="$(git remote get-url origin)"
export SKILLS_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@')"
export SKILLS_SYNC_DIR="$HOME/.company-skills"
```

기본 설치 경로는 아래다.

- Claude Code: `~/.claude/skills`
- Codex: `~/.agents/skills`

필요하면 아래처럼 덮어쓸 수 있다.

```bash
export CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
export CODEX_SKILLS_DIR="$HOME/.agents/skills"
```

### 3. 사용하는 대상만 bootstrap

Claude Code만 쓴다면:

```bash
bash scripts/run.sh --bootstrap --target claude
```

Codex만 쓴다면:

```bash
bash scripts/run.sh --bootstrap --target codex
```

둘 다 쓴다면:

```bash
bash scripts/run.sh --bootstrap --target all
```

`--bootstrap`는 사용자 설정에 관리용 hook을 등록한다. 같은 명령을 다시 실행해도 이 프로젝트가 관리하는 hook만 갱신하므로, source repo URL·브랜치·설치 경로가 바뀌었을 때 다시 실행해도 된다.

### 4. 설치 확인

동기화가 끝나면 아래와 비슷한 구조가 생긴다. `state/` 안의 파일은 선택한 target에 따라 달라질 수 있다.

```text
$HOME/.company-skills/
├─ repo/
├─ manifest.json
└─ state/
   ├─ claude-last-sync.env
   └─ codex-last-sync.env
```

선택한 target에 따라 아래를 확인하면 된다.

- Claude Code: `~/.claude/skills/<category>/<skill-name>/SKILL.md`
- Codex: `~/.agents/skills/<category>/<skill-name>/SKILL.md`
- 마지막 동기화 정보: `$SKILLS_SYNC_DIR/state/*-last-sync.env`

## 매일 사용하는 법

### Claude Code

bootstrap을 마쳤다면 평소처럼 Claude Code를 실행하면 된다. `SessionStart` hook이 먼저 실행되면서 최신 Skills를 동기화한다.

### Codex

Codex도 bootstrap을 마쳤다면 평소처럼 실행해도 된다.

Hook 대신 wrapper를 쓰고 싶다면 아래처럼 실행할 수 있다.

```bash
bash scripts/run-codex-with-sync.sh
```

Codex 옵션도 그대로 넘길 수 있다.

```bash
bash scripts/run-codex-with-sync.sh --help
```

주의: wrapper는 현재 셸의 환경 변수를 사용한다. 즉, `SKILLS_GIT_URL`, `SKILLS_BRANCH`, `SKILLS_SYNC_DIR`가 현재 셸에 export되어 있거나 셸 시작 파일에 고정값으로 들어 있어야 한다. 반면 hook은 bootstrap 시점의 값을 설정 파일에 기록해 둔다.

## manifest 생성

source skills repo에서 `manifest.json`을 만들고 싶다면 `scripts/generate-manifest.sh`를 사용할 수 있다.

예를 들어 별도 skills 저장소를 대상으로 만들 때:

```bash
SKILLS_DIR="/path/to/your-skills-repo/skills" \
bash /path/to/silent-casting/scripts/generate-manifest.sh
```

기본 출력 파일은 `SKILLS_DIR`의 상위 디렉토리에 있는 `manifest.json`이다. 필요하면 `OUTPUT_FILE`로 경로를 직접 지정할 수 있다.

## 현재 상태를 확인하는 위치

- source repo 로컬 cache: `$SKILLS_SYNC_DIR/repo`
- 캐시된 manifest: `$SKILLS_SYNC_DIR/manifest.json`
- 마지막 동기화 정보: `$SKILLS_SYNC_DIR/state/*.env`
- Claude Code 설치 대상: `~/.claude/skills`
- Codex 설치 대상: `~/.agents/skills`

## 자주 생기는 문제

### `SKILLS_GIT_URL is required`

현재 셸에 `SKILLS_GIT_URL`이 없거나, wrapper 실행 전에 환경 변수를 다시 불러오지 않은 상태다.

### Git clone 또는 fetch 실패

- source repo 접근 권한이 있는지 확인한다.
- SSH 또는 토큰 설정을 확인한다.
- 네트워크 오류가 나더라도 이전에 성공한 로컬 Skills가 있으면 그것을 계속 사용한다.

### bootstrap 이후 저장소 위치를 옮겼다

hook에 저장된 `scripts/run.sh` 절대경로가 바뀌었을 가능성이 높다. 새 위치에서 `bash scripts/run.sh --bootstrap --target ...`를 다시 실행한다.

### Claude만 또는 Codex만 쓰는데 반대편 디렉토리도 필요한가

아니다.

- Claude만 쓰면 `--target claude`
- Codex만 쓰면 `--target codex`
- 둘 다 쓸 때만 `--target all`

## 문서

- 동기화 진입점: [scripts/run.sh](scripts/run.sh)
- Codex wrapper: [scripts/run-codex-with-sync.sh](scripts/run-codex-with-sync.sh)
