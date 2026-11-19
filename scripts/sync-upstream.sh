#!/usr/bin/env bash
# sync-upstream.sh — перенос обновлений вендора Aliuyanfeng/dsh-soul на нашу ветку ru.
#
# Что делает (по шагам, без сюрпризов):
#   1. проверяет, что мы в клоне форка и находимся на ветке `ru`, дерево чистое;
#   2. `git fetch upstream` (remote `upstream` добавляется автоматически, если его нет);
#   3. печатает список файлов, которые вендор изменил между прошлым и новым `upstream/main`;
#   4. если в этом списке есть НАШИ точки правок — печатает явное предупреждение по файлам;
#   5. `git rebase upstream/main` (мы на `ru`);
#   6. после успешного rebase гоняет `node scripts/verify-config.mjs` (+ `verify-client` с --full);
#   7. НИЧЕГО НЕ ПУШИТ — push делает человек или workflow `.github/workflows/sync-upstream.yml`.
#
# Коды выхода:
#   0 — rebase и проверки прошли;
#   1 — конфликт rebase / упавшая проверка / грязное дерево / не та ветка (с пояснением);
#   2 — ошибки окружения (нет git, нет node, не репозиторий).
#
# Использование:
#   ./scripts/sync-upstream.sh            # rebase + verify-config
#   ./scripts/sync-upstream.sh --full     # rebase + verify-config + verify-client
#   ./scripts/sync-upstream.sh --check    # только посмотреть, что изменил вендор (без rebase)
#   ./scripts/sync-upstream.sh --help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

UPSTREAM_URL="${DSH_SOUL_UPSTREAM_URL:-https://github.com/Aliuyanfeng/dsh-soul.git}"
WORK_BRANCH="${DSH_SOUL_WORK_BRANCH:-ru}"

# Наши точки правок (слой A). Любое изменение этих файлов вендором = ручной разбор при rebase.
TOUCH_POINTS=(
  "lib/config.mjs"
  "lib/prompt-ru.mjs"
  "index.mjs"
  "client/index.mjs"
  "locale/ru.json"
  "scripts/verify-config.mjs"
)

MODE="sync"
for arg in "$@"; do
  case "$arg" in
    --full) MODE="full" ;;
    --check) MODE="check" ;;
    -h|--help)
      # печатаем только вводный комментарий (до первой строки кода)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "✗ неизвестный аргумент: $arg (см. --help)" >&2
      exit 2
      ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; }

# ── окружение ────────────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || { fail "нет git в PATH"; exit 2; }

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  fail "это не git-репозиторий: $SCRIPT_DIR/.."
  exit 2
fi
cd "$REPO_ROOT"

if ! git remote get-url upstream >/dev/null 2>&1; then
  say "· remote upstream отсутствует — добавляю $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL" || { fail "не удалось добавить remote upstream"; exit 2; }
fi
say "· репозиторий : $REPO_ROOT"
say "· upstream    : $(git remote get-url upstream)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "$WORK_BRANCH" ]; then
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "мы на ветке '$BRANCH' (нужна '$WORK_BRANCH'), а в дереве есть незакоммиченные изменения — переключиться нельзя."
    fail "Закоммить или убери изменения, затем повтори."
    exit 1
  fi
  say "· переключаюсь на ветку $WORK_BRANCH (были на $BRANCH)"
  git checkout "$WORK_BRANCH" || { fail "не удалось переключиться на $WORK_BRANCH"; exit 1; }
fi

# rebase требует чистого дерева по ОТСЛЕЖИВАЕМЫМ файлам; неотслеживаемые не мешают
DIRTY="$(git status --porcelain --untracked-files=no)"
if [ -n "$DIRTY" ]; then
  fail "рабочее дерево грязное — rebase не запускаю:"
  printf '%s\n' "$DIRTY" | sed 's/^/    /' >&2
  fail "Закоммить или спрячь изменения (git stash), затем повтори."
  exit 1
fi

# ── fetch ───────────────────────────────────────────────────────────────────
PREV_UPSTREAM="$(git rev-parse --verify --quiet refs/remotes/upstream/main || true)"
say "· git fetch upstream"
if ! git fetch upstream --prune; then
  fail "git fetch upstream не удался (сеть / доступ к github.com?)"
  exit 2
fi
NEW_UPSTREAM="$(git rev-parse refs/remotes/upstream/main)"

if [ -n "$PREV_UPSTREAM" ]; then
  say "· upstream/main: ${PREV_UPSTREAM:0:12} → ${NEW_UPSTREAM:0:12}"
else
  say "· upstream/main: ${NEW_UPSTREAM:0:12} (первый fetch в этом клоне)"
fi

# ── что изменил вендор ──────────────────────────────────────────────────────
# Две разные «дельты» и обе полезны:
#   • есть прошлый upstream/main (обычный повторный запуск) → показываем прирост с прошлого fetch;
#   • прошлого нет (первый fetch в клоне / свежий CI) → показываем всё, что вендор сделал
#     относительно НАШЕЙ базы (merge-base), иначе список был бы пустым именно тогда,
#     когда он нужнее всего.
CHANGED=""
CHANGED_SCOPE=""
if [ -n "$PREV_UPSTREAM" ] && [ "$PREV_UPSTREAM" != "$NEW_UPSTREAM" ]; then
  CHANGED="$(git diff --name-only "$PREV_UPSTREAM".."$NEW_UPSTREAM")"
  CHANGED_SCOPE="с прошлого fetch"
elif [ -z "$PREV_UPSTREAM" ]; then
  BASE="$(git merge-base HEAD "$NEW_UPSTREAM" 2>/dev/null || true)"
  if [ -n "$BASE" ] && [ "$BASE" != "$NEW_UPSTREAM" ]; then
    CHANGED="$(git diff --name-only "$BASE".."$NEW_UPSTREAM")"
    CHANGED_SCOPE="относительно нашей базы ${BASE:0:12}"
  fi
fi

if [ -n "$CHANGED" ]; then
  say ""
  say "Изменения вендора ($CHANGED_SCOPE, $(printf '%s\n' "$CHANGED" | grep -c . ) файлов):"
  printf '%s\n' "$CHANGED" | sed 's/^/    /'

  TOUCHED=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    for point in "${TOUCH_POINTS[@]}"; do
      if [ "$file" = "$point" ]; then
        TOUCHED+=("$file")
        break
      fi
    done
  done <<EOF
$CHANGED
EOF

  if [ "${#TOUCHED[@]}" -gt 0 ]; then
    say ""
    warn "вендор задел НАШИ точки правок (слой A) — при rebase возможен конфликт:"
    printf '    %s\n' "${TOUCHED[@]}"
    warn "после rebase проверь вручную: enum языка, promptTextOf/commandMessages, LANGUAGE_OPTIONS,"
    warn "NAV_LABELS, а также ожидания scripts/verify-config.mjs (в т.ч. счётчик блоков tables/replyLength)."
  else
    say ""
    say "✓ наших точек правок вендор не касался — конфликтов быть не должно."
  fi
elif [ -n "$PREV_UPSTREAM" ]; then
  say ""
  say "✓ upstream/main не изменился с прошлого fetch."
fi

if [ "$MODE" = "check" ]; then
  say ""
  say "· режим --check: rebase и проверки не запускаю."
  exit 0
fi

# ── rebase ──────────────────────────────────────────────────────────────────
say ""
say "· git rebase upstream/main (ветка $WORK_BRANCH)"
BEFORE_HEAD="$(git rev-parse HEAD)"
if ! git rebase upstream/main; then
  echo >&2
  fail "КОНФЛИКТ rebase: ветка $WORK_BRANCH не перенесена на ${NEW_UPSTREAM:0:12}."
  echo >&2
  fail "Конфликтующие файлы:"
  git diff --name-only --diff-filter=U | sed 's/^/    /' >&2 || true
  echo >&2
  fail "Как разобрать:"
  fail "  1) поправь файлы (наши точки — см. предупреждение выше), затем: git add <файлы>"
  fail "  2) git rebase --continue"
  fail "  3) повтори: node scripts/verify-config.mjs"
  fail "Откат в исходное состояние: git rebase --abort"
  fail "Ничего не запушено."
  exit 1
fi

AFTER_HEAD="$(git rev-parse HEAD)"
if [ "$BEFORE_HEAD" = "$AFTER_HEAD" ]; then
  say "· rebase не потребовался: $WORK_BRANCH уже содержит ${NEW_UPSTREAM:0:12}"
else
  say "· rebase готов: $WORK_BRANCH ${BEFORE_HEAD:0:12} → ${AFTER_HEAD:0:12}"
fi

# ── проверки ────────────────────────────────────────────────────────────────
command -v node >/dev/null 2>&1 || { fail "нет node в PATH — проверки не запустить (нужен Node ≥ 20)"; exit 2; }

say ""
say "· node scripts/verify-config.mjs"
if ! node scripts/verify-config.mjs; then
  echo >&2
  fail "rebase применён, но verify-config упал — НЕ пушь ветку, пока не почини."
  fail "Частая причина: вендор поменял структуру PROMPT_TEXT/COMMAND_MESSAGES или клиентских словарей,"
  fail "а ожидания scripts/verify-config.mjs остались под два языка (zh/en)."
  exit 1
fi

if [ "$MODE" = "full" ]; then
  say ""
  say "· node scripts/verify-client.mjs"
  if ! node scripts/verify-client.mjs; then
    echo >&2
    fail "verify-client упал — НЕ пушь ветку, пока не почини."
    exit 1
  fi
fi

# ── итог ────────────────────────────────────────────────────────────────────
say ""
say "✓ Синхронизация с вендором завершена. Локальная ветка $WORK_BRANCH готова."
say "  Пуш (вручную, осознанно): git push --force-with-lease origin $WORK_BRANCH"
say "  Скрипт сам ничего не пушит."
exit 0
