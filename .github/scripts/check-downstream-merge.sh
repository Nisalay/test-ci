#!/usr/bin/env bash
# Проверяет, что после мержа PR в BASE_BRANCH изменения смогут каскадно
# залиться в нижестоящие ветки (release -> devel -> integra) без конфликтов.
#
# Мерж симулируется через `git merge-tree --write-tree` — в памяти, без
# изменения рабочей копии и без пушей.
#
# Env:
#   BRANCH_CHAIN  — ветки сверху вниз, через пробел (по умолчанию "release devel integra")
#   BASE_BRANCH   — целевая ветка PR
#   PR_SHA        — коммит "PR влит в BASE_BRANCH" (refs/pull/N/merge) или голова PR
#   REMOTE        — имя remote (по умолчанию origin)
#   REPORT_FILE   — куда писать markdown-отчёт
#   GITHUB_OUTPUT — (необязательно) сюда пишется has_conflicts=true|false
set -euo pipefail

BRANCH_CHAIN=${BRANCH_CHAIN:-"release devel integra"}
REMOTE=${REMOTE:-origin}
REPORT_FILE=${REPORT_FILE:-downstream-merge-report.md}
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${PR_SHA:?PR_SHA is required}"

# commit-tree требует автора; коммиты временные и никуда не пушатся
export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@localhost
export GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@localhost

read -r -a chain <<< "$BRANCH_CHAIN"
downstream=()
found=false
for b in "${chain[@]}"; do
  if $found; then downstream+=("$b"); fi
  [[ $b == "$BASE_BRANCH" ]] && found=true
done

set_output() {
  [[ -n ${GITHUB_OUTPUT:-} ]] && echo "$1" >> "$GITHUB_OUTPUT"
  return 0
}

if ! $found || [[ ${#downstream[@]} -eq 0 ]]; then
  echo "Ветка '$BASE_BRANCH' не имеет нижестоящих веток в цепочке ($BRANCH_CHAIN), проверять нечего."
  : > "$REPORT_FILE"
  set_output has_conflicts=false
  exit 0
fi

# Пробный мерж. Печатает tree OID первой строкой, затем конфликтные файлы.
# Код возврата: 0 — чисто, 1 — конфликт, >1 — ошибка.
try_merge() {
  git merge-tree --write-tree --name-only --no-messages "$1" "$2"
}

# Коммит-результат успешного мержа $3 в $2 с деревом $1 (fast-forward, если возможно)
merge_commit() {
  if git merge-base --is-ancestor "$2" "$3"; then
    git rev-parse "$3"
  else
    git commit-tree "$1" -p "$2" -p "$3" -m "simulated merge"
  fi
}

# Состояние верхней ветки "после мержа PR" и "как сейчас" (baseline).
# Baseline нужен, чтобы отличить конфликты, внесённые PR, от уже существующих.
with_pr=$PR_SHA
without_pr="$REMOTE/$BASE_BRANCH"
upstream=$BASE_BRANCH
has_conflicts=false
rows=()
details=""

for target in "${downstream[@]}"; do
  target_ref="$REMOTE/$target"

  set +e
  out=$(try_merge "$target_ref" "$with_pr"); rc=$?
  base_out=$(try_merge "$target_ref" "$without_pr"); base_rc=$?
  set -e
  if (( rc > 1 || base_rc > 1 )); then
    echo "::error::git merge-tree завершился с ошибкой при проверке $upstream -> $target" >&2
    echo "$out" >&2
    exit 2
  fi

  files=$(tail -n +2 <<< "$out")
  base_files=$(tail -n +2 <<< "$base_out")

  if (( rc == 0 )); then
    rows+=("| \`$upstream\` → \`$target\` | ✅ без конфликтов |")
    with_pr=$(merge_commit "$(head -1 <<< "$out")" "$target_ref" "$with_pr")
  else
    has_conflicts=true
    # Конфликты, которых нет без этого PR, — именно их вносит PR
    new_files=$(comm -23 <(sort -u <<< "$files") <(sort -u <<< "$base_files"))
    old_files=$(comm -12 <(sort -u <<< "$files") <(sort -u <<< "$base_files"))
    if [[ -n $new_files ]]; then
      status="⚠️ конфликт, вносит этот PR"
    else
      status="⚠️ конфликт, уже существует без этого PR"
    fi
    rows+=("| \`$upstream\` → \`$target\` | $status |")
    details+=$'\n'"#### \`$upstream\` → \`$target\`"$'\n'
    if [[ -n $new_files ]]; then
      details+=$'\n'"Новые конфликты (из-за этого PR):"$'\n'
      details+=$(sed 's/.*/- `&`/' <<< "$new_files")$'\n'
      while IFS= read -r f; do
        echo "::warning file=$f,title=Конфликт при мерже в $target::После мержа PR в $BASE_BRANCH файл не смержится в $target без конфликта"
      done <<< "$new_files"
    fi
    if [[ -n $old_files ]]; then
      details+=$'\n'"Уже конфликтуют и без этого PR:"$'\n'
      details+=$(sed 's/.*/- `&`/' <<< "$old_files")$'\n'
    fi
    # Чистого результата нет — дальше по цепочке проверяем мерж изменений PR
    # напрямую, это приближение: реальный каскад требует ручного разрешения.
  fi

  if (( base_rc == 0 )); then
    without_pr=$(merge_commit "$(head -1 <<< "$base_out")" "$target_ref" "$without_pr")
  fi
  upstream=$target
done

{
  echo "<!-- downstream-merge-check -->"
  echo "### Проверка каскадного мержа"
  echo
  echo "PR в \`$BASE_BRANCH\`: проверено, что после мержа изменения зальются дальше по цепочке \`${BRANCH_CHAIN// / → }\`."
  echo
  echo "| Мерж | Результат |"
  echo "|---|---|"
  printf '%s\n' "${rows[@]}"
  if $has_conflicts; then
    echo "$details"
    echo "> Это предупреждение, мерж PR не заблокирован. Но после него каскадный мерж потребует ручного разрешения конфликтов."
  fi
} > "$REPORT_FILE"

cat "$REPORT_FILE"
set_output "has_conflicts=$has_conflicts"
