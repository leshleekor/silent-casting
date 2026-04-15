# Silent Casting

Silent Casting은 GitHub 저장소의 `skills/` 디렉토리를 로컬로 동기화한 뒤, Claude Code와 Codex가 항상 최신 로컬 Skills를 읽을 수 있도록 돕는 스크립트 모음입니다.

## 제공 기능

- source repo를 `SKILLS_SYNC_DIR/repo`에 clone 또는 update하고, cache repo를 source repo의 mirror 상태로 유지합니다.
- `skills/` 트리를 Claude/Codex가 읽는 로컬 Skills 디렉토리로 복사합니다.
- `profiles.json`과 `selection.json`을 사용해 필요한 Skill만 선택적으로 동기화할 수 있습니다.
- 설치 대상 디렉토리 루트를 교체하지 않고, Silent Casting이 관리하는 Skill ID 경로만 갱신합니다.
- Silent Casting이 관리하지 않는 기존 다른 Skills는 보존합니다.
- 원하면 `SessionStart` hook을 등록해 실행 직전에 자동으로 동기화합니다.
- 동기화에 실패하더라도 Silent Casting의 마지막 성공 상태가 있으면 기존 로컬 Skills를 그대로 유지합니다.

## 준비물

- macOS 또는 Linux
- `bash`, `git`
- `python3` (`--bootstrap` 또는 선택적 동기화 사용 시 필요)
- Claude Code 또는 Codex
- 루트에 `skills/` 디렉토리가 있는 Git 저장소

## Skills 저장소 구조

Silent Casting 자체에는 Skill 콘텐츠가 포함되어 있지 않습니다. 동기화 대상은 별도의 skills 저장소여야 합니다.

```text
your-skills-repo/
├─ skills/
│  ├─ common/
│  │  └─ logging/SKILL.md
│  ├─ backend/
│  │  └─ api-review/SKILL.md
│  └─ frontend/
│     └─ accessibility-check/SKILL.md
├─ profiles.json
└─ manifest.json
```

- 각 Skill은 자체 디렉토리 안에 `SKILL.md`를 가집니다.
- `skills/` 아래 구조는 Claude/Codex 설치 디렉토리로 그대로 복사됩니다.
- `profiles.json`은 역할별 Skill 묶음과 기본 선택 규칙을 정의하는 선택 파일입니다.
- `manifest.json`은 선택 사항입니다. 있으면 로컬 캐시에 복사되며, 없어도 동기화 자체는 가능합니다.

### `profiles.json` 예시

```json
{
  "version": 1,
  "mandatory": ["common/logging"],
  "default_profiles": ["backend"],
  "profiles": {
    "backend": {
      "include": ["backend/*", "common/review-basics"],
      "exclude": ["backend/legacy-*"]
    },
    "frontend": {
      "include": ["frontend/*", "common/review-basics"]
    }
  }
}
```

### 로컬 `selection.json` 예시

기본 경로는 `$SKILLS_SYNC_DIR/selection.json`입니다.

```json
{
  "version": 1,
  "profiles": ["backend"],
  "include": ["common/security-extended"],
  "exclude": ["backend/legacy-*"]
}
```

## 빠른 시작

아래 순서는 Silent Casting을 동기화 도구로 설치하고, 별도의 skills 저장소를 source repo로 연결하는 가장 빠른 방법입니다.

중요: `--bootstrap`는 현재 저장소의 `scripts/run.sh` 절대경로를 사용자 설정에 기록합니다. 따라서 bootstrap 이후에는 이 저장소를 다른 위치로 옮기지 않는 편이 안전합니다. 저장소 위치를 변경했다면 새 위치에서 `--bootstrap`를 다시 실행하시면 됩니다.

### 1. 이 저장소를 안정적인 경로에 clone

```bash
git clone https://github.com/leshleekor/silent-casting.git "$HOME/tools/silent-casting"
cd "$HOME/tools/silent-casting"
```

### 2. source skills 저장소 정보 설정

```bash
export SKILLS_GIT_URL="git@github.com:your-org/your-skills-repo.git"
export SKILLS_BRANCH="main"
export SKILLS_SYNC_DIR="$HOME/.company-skills"
```

이미 source skills 저장소 안에서 작업 중이라면 아래처럼 현재 원격 정보를 그대로 사용하셔도 됩니다.

```bash
export SKILLS_GIT_URL="$(git remote get-url origin)"
export SKILLS_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@')"
export SKILLS_SYNC_DIR="$HOME/.company-skills"
```

기본 설치 경로는 아래와 같습니다.

- Claude Code: `~/.claude/skills`
- Codex: `~/.agents/skills`

필요하면 아래처럼 덮어쓸 수 있습니다.

```bash
export CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
export CODEX_SKILLS_DIR="$HOME/.agents/skills"
```

### 3. 대상별 bootstrap 실행

Claude Code만 사용하는 경우:

```bash
bash scripts/run.sh --bootstrap --target claude
```

Codex만 사용하는 경우:

```bash
bash scripts/run.sh --bootstrap --target codex
```

둘 다 사용하는 경우:

```bash
bash scripts/run.sh --bootstrap --target all
```

`--bootstrap`는 사용자 설정에 관리용 hook을 등록합니다. 같은 명령을 다시 실행하더라도 이 프로젝트가 관리하는 hook만 갱신하므로, source repo URL·브랜치·설치 경로가 바뀌었을 때 다시 실행하셔도 됩니다. 기존 cache repo가 있더라도 source repo URL이 바뀌면 cache의 `origin`도 새 URL로 갱신됩니다.

### 4. 설치 확인

동기화가 끝나면 아래와 비슷한 구조가 생성됩니다. `state/` 안의 파일은 선택한 target에 따라 달라질 수 있습니다.

```text
$HOME/.company-skills/
├─ repo/
├─ manifest.json
└─ state/
   ├─ claude-last-sync.env
   └─ codex-last-sync.env
```

선택한 target에 따라 아래 위치를 확인하시면 됩니다.

- Claude Code: `~/.claude/skills/<category>/<skill-name>/SKILL.md`
- Codex: `~/.agents/skills/<category>/<skill-name>/SKILL.md`
- 마지막 동기화 정보: `$SKILLS_SYNC_DIR/state/*-last-sync.env`

## 선택적 동기화

`profiles.json`이 source repo에 있으면 Silent Casting은 전체 Skill 복사 대신 선택 규칙을 계산해 필요한 Skill만 설치합니다.

선택 우선순위는 아래와 같습니다.

1. CLI 옵션
2. 환경 변수
3. 로컬 `selection.json`
4. `profiles.json`의 `default_profiles`

지원 옵션은 아래와 같습니다.

```bash
bash scripts/run.sh --target codex \
  --profile backend \
  --include common/security-extended \
  --exclude backend/legacy-* \
  --print-selection
```

지원 환경 변수는 아래와 같습니다.

```bash
export SKILLS_PROFILE="backend,devops"
export SKILLS_INCLUDE="common/security-extended"
export SKILLS_EXCLUDE="backend/legacy-*"
export SKILLS_SELECTION_FILE="$HOME/.company-skills/selection.json"
```

지속적으로 유지할 개인 설정은 `selection.json`에 두는 편이 가장 명확합니다. `--bootstrap`은 bootstrap 시점의 CLI 선택 옵션과 환경 변수 선택값을 hook 명령에 고정 저장합니다. 이후 선택 규칙을 바꾸려면 `selection.json`을 수정하거나 새 선택 옵션으로 `--bootstrap`을 다시 실행하세요.

### 선택 결과 미리 보기

실제 복사 전에 최종 선택 결과만 확인하려면 아래처럼 실행합니다.

```bash
bash scripts/run.sh --target codex --print-selection
```

이 명령은 사용된 프로필, include/exclude, 최종 선택된 Skill ID 목록을 출력하고 종료합니다.

### 기존 Skills와의 공존 방식

Silent Casting은 설치 대상 디렉토리 루트를 이동하거나 교체하지 않습니다.

- 기존에 이미 있던 다른 Skills는 그대로 유지합니다.
- Silent Casting이 이전에 설치한 Skill ID만 추적해서 갱신하거나 제거합니다.
- 이번 sync 결과에서 빠진 Skill은, 과거에 Silent Casting이 설치했던 Skill인 경우에만 제거합니다.
- 동기화는 선택된 Skill ID 경로 단위로만 수행되며, `~/.claude/skills` 또는 `~/.agents/skills` 전체를 삭제하지 않습니다.

다만 같은 Skill ID 경로를 Silent Casting이 다시 관리하게 되면, 해당 경로의 내용은 Silent Casting 기준으로 갱신됩니다. 대상 Skill ID의 부모 경로가 symlink이면 대상 디렉토리 밖을 건드릴 수 있으므로 동기화를 중단합니다.

## 사용 방법

### Claude Code

bootstrap을 마쳤다면 평소처럼 Claude Code를 실행하시면 됩니다. `SessionStart` hook이 먼저 실행되면서 최신 Skills를 동기화합니다.

### Codex

Codex도 bootstrap을 마쳤다면 평소처럼 실행하시면 됩니다.

Hook 대신 wrapper를 사용하고 싶다면 아래처럼 실행하실 수 있습니다.

```bash
bash scripts/run-codex-with-sync.sh
```

Codex 옵션도 그대로 넘길 수 있습니다.

```bash
bash scripts/run-codex-with-sync.sh --help
```

주의: wrapper는 현재 셸의 환경 변수를 사용합니다. 즉, `SKILLS_GIT_URL`, `SKILLS_BRANCH`, `SKILLS_SYNC_DIR`가 현재 셸에 export되어 있거나 셸 시작 파일에 고정값으로 들어 있어야 합니다. 반면 hook은 bootstrap 시점의 값을 설정 파일에 기록해 둡니다.

## manifest 생성 방법

source skills repo에서 `manifest.json`을 만들고 싶다면 `scripts/generate-manifest.sh`를 사용할 수 있습니다.

예를 들어 별도 skills 저장소를 대상으로 생성할 때는 다음과 같이 실행합니다.

```bash
SKILLS_DIR="/path/to/your-skills-repo/skills" \
bash /path/to/silent-casting/scripts/generate-manifest.sh
```

기본 출력 파일은 `SKILLS_DIR`의 상위 디렉토리에 있는 `manifest.json`입니다. 필요하면 `OUTPUT_FILE`로 경로를 직접 지정할 수 있습니다.

## 현재 상태를 확인하는 위치

- source repo 로컬 cache: `$SKILLS_SYNC_DIR/repo`
- 캐시된 manifest: `$SKILLS_SYNC_DIR/manifest.json`
- 로컬 선택 설정: `$SKILLS_SYNC_DIR/selection.json`
- 마지막 동기화 정보: `$SKILLS_SYNC_DIR/state/*.env`
- Claude Code 설치 대상: `~/.claude/skills`
- Codex 설치 대상: `~/.agents/skills`

## 자주 발생하는 문제

### `SKILLS_GIT_URL is required`

현재 셸에 `SKILLS_GIT_URL`이 없거나, wrapper 실행 전에 환경 변수를 다시 불러오지 않은 상태입니다.

### Git clone 또는 fetch 실패

- source repo 접근 권한이 있는지 확인합니다.
- SSH 또는 토큰 설정을 확인합니다.
- 네트워크 오류가 발생하더라도 Silent Casting의 이전 성공 상태가 있으면 그것을 계속 사용합니다.
- 첫 설치처럼 Silent Casting 성공 상태가 아직 없으면 실패로 종료합니다.

### cache repo에 남아 있는 파일이 동기화에 영향을 주는 경우

`$SKILLS_SYNC_DIR/repo`는 source repo의 작업 복사본이 아니라 cache mirror로 취급됩니다. 동기화 때 source repo에 없는 untracked 파일은 제거되므로, 수동으로 유지해야 하는 파일은 cache repo 안에 두지 말고 `$SKILLS_SYNC_DIR/selection.json`처럼 cache 밖에 두세요.

### `unknown profile name` 또는 패턴 불일치 오류

- `profiles.json`에 정의된 프로필 이름인지 확인합니다.
- `include` 또는 `exclude`에 적은 Skill ID나 패턴이 실제 `skills/` 구조와 일치하는지 확인합니다.
- 선택 계산이 실패하면 Silent Casting은 기존 로컬 Skills를 유지합니다.

### bootstrap 이후 저장소 위치를 옮긴 경우

hook에 저장된 `scripts/run.sh` 절대경로가 바뀌었을 가능성이 높습니다. 새 위치에서 `bash scripts/run.sh --bootstrap --target ...`를 다시 실행해 주시면 됩니다.

### Claude만 또는 Codex만 사용할 때 반대편 디렉토리도 필요한가요

아닙니다.

- Claude만 사용하면 `--target claude`입니다.
- Codex만 사용하면 `--target codex`입니다.
- 둘 다 사용할 때만 `--target all`입니다.

## 문서

- 동기화 진입점: [scripts/run.sh](scripts/run.sh)
- Codex wrapper: [scripts/run-codex-with-sync.sh](scripts/run-codex-with-sync.sh)
