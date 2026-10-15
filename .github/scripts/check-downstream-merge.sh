#!/usr/bin/env bash
# Проверяет, что source-ветка PR смержится без конфликтов в каждую ветку,
# лежащую ниже BASE_BRANCH в цепочке (release -> devel -> integra).
# Например, PR в release проверяется на мерж в devel и в integra.
#
# Мерж симулируется через `git merge-tree --write-tree` — в памяти, без
# изменения рабочей копии и без пушей.
#
# Env:
#   BRANCH_CHAIN  — ветки сверху вниз, через пробел (по умолчанию "release devel integra")
#   BASE_BRANCH   — целевая ветка PR
#   HEAD_SHA      — голова source-ветки PR
#   HEAD_BRANCH   — имя source-ветки (только для отчёта)
#   REMOTE        — имя remote (по умолчанию origin)
#   REPORT_FILE   — куда писать markdown-отчёт
#   GITHUB_OUTPUT — (необязательно) сюда пишется has_conflicts=true|false
set -euo pipefail

BRANCH_CHAIN=${BRANCH_CHAIN:-"release devel integra"}
REMOTE=${REMOTE:-origin}
REPORT_FILE=${REPORT_FILE:-downstream-merge-report.md}
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
HEAD_BRANCH=${HEAD_BRANCH:-$HEAD_SHA}

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

has_conflicts=false
rows=()
details=""

for target in "${downstream[@]}"; do
  # Код возврата: 0 — чисто, 1 — конфликт, >1 — ошибка.
  # Вывод: tree OID первой строкой, затем конфликтные файлы.
  set +e
  out=$(git merge-tree --write-tree --name-only --no-messages "$REMOTE/$target" "$HEAD_SHA"); rc=$?
  set -e
  if (( rc > 1 )); then
    echo "::error::git merge-tree завершился с ошибкой при проверке $HEAD_BRANCH -> $target" >&2
    echo "$out" >&2
    exit 2
  fi

  if (( rc == 0 )); then
    rows+=("| \`$HEAD_BRANCH\` → \`$target\` | ✅ без конфликтов |")
    continue
  fi

  has_conflicts=true
  files=$(tail -n +2 <<< "$out" | sort -u)
  rows+=("| \`$HEAD_BRANCH\` → \`$target\` | ⚠️ конфликт |")
  details+=$'\n'"#### \`$HEAD_BRANCH\` → \`$target\`"$'\n\n'
  details+=$(sed 's/.*/- `&`/' <<< "$files")$'\n'
  while IFS= read -r f; do
    echo "::warning file=$f,title=Конфликт при мерже в $target::$HEAD_BRANCH не смержится в $target без конфликта"
  done <<< "$files"
done

{
  echo "<!-- downstream-merge-check -->"
  echo "### Проверка мержа в нижестоящие ветки"
  echo
  echo "PR \`$HEAD_BRANCH\` → \`$BASE_BRANCH\`: проверено, что \`$HEAD_BRANCH\` смержится в ветки ниже \`$BASE_BRANCH\` (\`${BRANCH_CHAIN// / → }\`)."
  echo
  echo "| Мерж | Результат |"
  echo "|---|---|"
  printf '%s\n' "${rows[@]}"
  if $has_conflicts; then
    echo "$details"
    echo "> Это предупреждение, мерж PR не заблокирован. Но мерж в нижестоящие ветки потребует ручного разрешения конфликтов."
  fi
} > "$REPORT_FILE"

cat "$REPORT_FILE"
set_output "has_conflicts=$has_conflicts"
