#!/usr/bin/env bash
#
# pre-push-review.sh — локальный быстрый гейт перед `git push`.
# Layer 1 обвязки: (1) механика (lint/typecheck/тесты) + (2) opencode-ревью диффа.
#
# Подходит и для Windows (через Git Bash / husky), и для Linux/macOS.
# Стек определяется автоматически — работает с JS/TS (npm/pnpm/yarn/bun),
# Go, Python и любым проектом, где есть стандартные команды.
#
# Настройки:
#   REVIEW_MODEL   — бесплатная модель через OpenRouter (экономия токенов).
#                    Проверено рабочим на этот аккаунт: openrouter/poolside/laguna-s-2.1:free
#                    (алиас openrouter/free и deepseek-chat:free возвращали серверные ошибки).
#   REVIEW_BLOCK   — "on" (по умолч., блокировать push при [BLOCK]) | "off" (не блокировать)
#
# Установка (в корне репо):
#   mkdir -p .git/hooks && cp scripts/pre-push-review.sh .git/hooks/pre-push && chmod +x .git/hooks/pre-push
# или через husky:
#   npx husky add .husky/pre-push "bash scripts/pre-push-review.sh"

set -euo pipefail

# --- Resolve this script's real directory ---
# git hooks (husky) run us via `sh -e .husky/pre-push`, so $0 is not the script
# path. BASH_SOURCE always points at the running script regardless of invocation.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- Ensure nvm/node (and opencode) are on PATH ---
# git hooks run in a clean shell with no interactive login, so nvm's PATH
# additions are missing. Load nvm and activate the default node so both
# node and opencode resolve.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  \. "$NVM_DIR/nvm.sh"
  nvm use node >/dev/null 2>&1 || true
fi

# Load the project-root .env — ALWAYS, and its values take priority over the
# inherited environment (so OPENROUTER_REVIEW_MODEL in .env wins even when the
# shell already exports variables). Empty values are skipped so a placeholder
# .env (e.g. OPENROUTER_API_KEY=) does NOT clobber a real key from the shell.
if [ -f "./.env" ]; then
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    case "$LINE" in
      ''|'#'*) continue ;;
    esac
    KEY="${LINE%%=*}"
    VAL="${LINE#*=}"
    case "$KEY" in ''|'#'*) continue ;; esac
    # strip surrounding quotes
    VAL="${VAL%\"}"; VAL="${VAL#\"}"
    VAL="${VAL%\'}"; VAL="${VAL#\'}"
    if [ -n "$VAL" ]; then
      export "$KEY=$VAL"
    fi
  done < "./.env"
fi

REVIEW_MODEL="${REVIEW_MODEL:-${OPENROUTER_REVIEW_MODEL:-openrouter/poolside/laguna-s-2.1:free}}"
REVIEW_BLOCK="${REVIEW_BLOCK:-on}"

log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✖\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Шаг 0 — определить базу для сравнения.
# Приоритет: 1) REVIEW_BASE=<ref> (если задан)
#            2) origin/<текущая_ветка>  (самое логичное при работе в feature-ветке)
#            3) origin/main → origin/develop → origin/master (первая существующая)
# На первом пуше (базы нет) — ревью пропускается.
# ---------------------------------------------------------------------------
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
BASE=""
if [ -n "${REVIEW_BASE:-}" ]; then
  BASE=$(git merge-base HEAD "$REVIEW_BASE" 2>/dev/null || echo "")
  [ -n "$BASE" ] && log "база: REVIEW_BASE=$REVIEW_BASE"
elif [ -n "$CUR_BRANCH" ] && git rev-parse --verify "origin/$CUR_BRANCH" >/dev/null 2>&1; then
  BASE=$(git merge-base HEAD "origin/$CUR_BRANCH" 2>/dev/null || echo "")
  [ -n "$BASE" ] && log "база: origin/$CUR_BRANCH"
else
  for b in origin/main origin/develop origin/master; do
    if git rev-parse --verify "$b" >/dev/null 2>&1; then
      BASE=$(git merge-base HEAD "$b" 2>/dev/null || echo "") && break
    fi
  done
fi

# ---------------------------------------------------------------------------
# Шаг 1 — механика. Автоопределение команд по маркерным файлам.
# ---------------------------------------------------------------------------
if [ -f package.json ]; then
  log "JS/TS-проект — lint / typecheck / affected tests"
  [ -f package-lock.json ] && PM="npm" || true
  [ -f pnpm-lock.yaml ]    && PM="pnpm" || true
  [ -f yarn.lock ]         && PM="yarn" || true
  [ -f bun.lockb ]         && PM="bun" || true
  PM="${PM:-npm}"
  $PM run lint >/dev/null 2>&1 || warn "lint: скрипта нет или ошибки (см. вывод без -q)"
  if [ -f tsconfig.json ]; then
    $PM exec -- tsc --noEmit 2>&1 | tail -15 || warn "typecheck: ошибки выше"
  fi
elif [ -f go.mod ]; then
  log "Go-проект — go vet"
  go vet ./... 2>&1 | tail -15 || warn "go vet: ошибки выше"
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  log "Python-проект — пропуск механики (добавь ruff/mypy по вкусу)"
else
  warn "Стек не распознан — пропускаю механику"
fi

# ---------------------------------------------------------------------------
# Шаг 2 — AI-ревью диффа через opencode.
# ---------------------------------------------------------------------------
if [ -z "$BASE" ]; then
  warn "нет базы для сравнения (первый пуш?) — пропускаю AI-ревью"
  exit 0
fi

if ! command -v opencode >/dev/null 2>&1; then
  warn "opencode не найден в PATH — пропускаю AI-ревью"
  exit 0
fi

DIFF_STAT=$(git diff --shortstat "$BASE"..HEAD)
log "opencode review ($REVIEW_MODEL) — $DIFF_STAT"

# Предел размера диффа для авто-ревью. Гигантские диффы (напр. первый коммит всей
# кодовой базы, или неверно выбранная база) съедают много токенов и дают шум.
# Переопределяется: REVIEW_MAX_FILES / REVIEW_MAX_INSERTIONS. Если превышено —
# предупреждаем и пропускаем без блокировки (нужно проверить выбранную базу).
MAX_FILES="${REVIEW_MAX_FILES:-80}"
MAX_INS="${REVIEW_MAX_INSERTIONS:-1500}"
NF=$(git diff --shortstat "$BASE"..HEAD | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo 0)
NI=$(git diff --shortstat "$BASE"..HEAD | grep -oE '[0-9]+ insertions' | grep -oE '[0-9]+' || echo 0)
if [ "$NF" -gt "$MAX_FILES" ] || [ "$NI" -gt "$MAX_INS" ]; then
  warn "дифф слишком большой ($NF файлов / $NI вставок) — пропускаю AI-ревью."
  warn "Это может быть неверная REVIEW_BASE или первый коммит всей базы."
  exit 0
fi

FILES=$(git diff --name-only "$BASE"..HEAD | tr '\n' ' ')
if [ -z "$FILES" ]; then
  warn "нет изменённых файлов — пропускаю"
  exit 0
fi

# Only pass files that actually exist on disk — renamed/deleted files in the
# diff would make opencode fail with "File not found" (seen on Windows: path in
# the diff but not on disk for the model to read).
EXISTING_FILES=""
for f in $FILES; do
  [ -f "$f" ] && EXISTING_FILES="$EXISTING_FILES $f"
done

VERDICT_FILE=$(mktemp)
PROMPT_FILE="$SCRIPT_DIR/layer1-review.prompt.md"
if [ -f "$PROMPT_FILE" ]; then
  PROMPT=$(sed "s/{{BASE}}/$BASE/g" "$PROMPT_FILE")
else
  warn "НЕ найдено: $PROMPT_FILE — использую встроенный fallback-промт"
  warn "Промт-файл лежит в scripts/ рядом со скриптом; проверь что он есть после clone/pull."
  PROMPT="Review the uncommitted work vs base $BASE. Find only hard bugs that block CI (hardcoded secrets, broken imports, removed permission checks, missing await). Reply exactly [PASS] or [BLOCK] <reason>, then up to 5 issues."
fi
if [ -n "$EXISTING_FILES" ]; then
  opencode run --model "$REVIEW_MODEL" "$PROMPT" \
    -f $EXISTING_FILES > "$VERDICT_FILE" 2>&1 || true
else
  opencode run --model "$REVIEW_MODEL" "$PROMPT" > "$VERDICT_FILE" 2>&1 || true
fi
tail -40 "$VERDICT_FILE"
echo

# Если opencode НЕ дал вердикт — это сбой (серверная ошибка, модель недоступна,
# rate-limit, пустой ответ). Не блокируем пуш, но явно предупреждаем вместо
# тихого PASS. Сбой ловим по явным маркерам/пустоте, а не по позиции вердикта —
# свободные модели не всегда ставят [PASS]/[BLOCK] первой строкой.
if [ ! -s "$VERDICT_FILE" ]; then
  warn "AI-ревью НЕ выполнено: opencode вернул пустой ответ (модель ${REVIEW_MODEL})."
  warn "Пуш НЕ заблокирован, но проверка пропущена — проверь модель и повтори."
  exit 0
fi
if grep -qiE 'unexpected server error|{"name":"unknownerror"|model not found|rate.?limit' "$VERDICT_FILE"; then
  warn "AI-ревью НЕ выполнено: opencode/модель вернули ошибку (${REVIEW_MODEL})."
  warn "Пуш НЕ заблокирован, но проверка пропущена — проверь модель и повтори."
  tail -15 "$VERDICT_FILE"
  exit 0
fi

# BLOCK-вердикт: ищем строку, начинающуюся с [BLOCK] (модель может поставить её
# не первой, после краткого анализа). [PASS] без [BLOCK] = чистый проход.
if grep -E '^\[BLOCK\]' "$VERDICT_FILE"; then
  fail "opencode нашёл блокирующие проблемы. Push остановлен."
  fail "Если уверен что это ложное срабатывание: REVIEW_BLOCK=off отключает блокировку на этот запуск"
  [ "$REVIEW_BLOCK" = "off" ] && exit 0 || exit 1
fi

log "AI-ревью пройдено [PASS]. Push разрешён."
exit 0
