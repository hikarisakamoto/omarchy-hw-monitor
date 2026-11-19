#!/bin/bash
# Checks to run before pushing: the manifest the way `omarchy plugin add`
# validates it, manifest defaults against the schema, and a syntax pass over
# every helper and QML file. shellcheck and pyflakes run when installed.
#
# Nothing here writes inside the repo: an installed copy of the plugin is
# watched for file changes, and a write there reloads the running widget.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

status=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; status=1; }
skip() { printf 'skip  %s (%s not installed)\n' "$1" "$2"; }

# The validator also parses the JSON; jq alone is the fallback without it.
if command -v omarchy-plugin-validate >/dev/null; then
  if omarchy-plugin-validate .; then ok "manifest: omarchy-plugin-validate"; else bad "manifest: omarchy-plugin-validate"; fi
elif jq -e . manifest.json >/dev/null; then
  ok "manifest: valid JSON (omarchy-plugin-validate not installed)"
else
  bad "manifest: valid JSON"
fi

# Every `defaults` key must carry its schema entry's defaultValue, and the
# reverse. A key whose default depends on the mode (showGauges) has neither.
if ! drift=$(jq -r '.barWidget
    | (.defaults // {}) as $d
    | ([(.schema // [])[] | select(has("defaultValue")) | {(.key): .defaultValue}] | add // {}) as $s
    | (($d | keys) + ($s | keys) | unique)[] | select($d[.] != $s[.])' manifest.json); then
  bad "manifest: could not compare defaults with the schema"
elif [[ -n $drift ]]; then
  bad "manifest: defaults and schema disagree on: ${drift//$'\n'/, }"
else
  ok "manifest: defaults match schema defaultValues"
fi

for file in hw-probe scripts/*.sh; do
  if bash -n "$file"; then ok "bash -n: $file"; else bad "bash -n: $file"; fi
done

# ast.parse rather than py_compile, so no __pycache__ lands in the tree.
if python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], "rb").read(), sys.argv[1])' proc_top.py; then
  ok "python3: proc_top.py parses"
else
  bad "python3: proc_top.py parses"
fi

# A syntax gate only. Without the shell's qs.* modules on the import path
# qmllint prints hundreds of unresolved-import warnings but still exits 0;
# a parse error exits non-zero.
qmllint=$(command -v qmllint || echo /usr/lib/qt6/bin/qmllint)
if [[ -x $qmllint ]]; then
  for file in *.qml Model.js; do
    if "$qmllint" "$file" >/dev/null 2>&1; then ok "qmllint: $file parses"; else bad "qmllint: $file parses"; fi
  done
else
  skip "qmllint" "qmllint"
fi

if command -v shellcheck >/dev/null; then
  if shellcheck -S warning hw-probe scripts/*.sh; then ok "shellcheck"; else bad "shellcheck"; fi
else
  skip "shellcheck" "shellcheck"
fi

if command -v pyflakes >/dev/null; then
  if pyflakes proc_top.py; then ok "pyflakes"; else bad "pyflakes"; fi
else
  skip "pyflakes" "pyflakes"
fi

exit "$status"
