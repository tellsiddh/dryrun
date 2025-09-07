#!/usr/bin/env bash

set -o nounset -o pipefail

if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

die()   { printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }
warn()  { printf "%s[WARNING]%s %s\n" "$YELLOW" "$RESET" "$*" >&2; }
info()  { printf "%s[DRY-RUN]%s %s\n" "$BLUE" "$RESET" "$*"; }
ok()    { printf "%s[OK]%s %s\n" "$GREEN" "$RESET" "$*"; }

usage() {
  cat <<'USAGE'
Usage: dryrun <command> [args...]

Executes real dry-run modes where supported; otherwise simulates.

Filesystem:   rm, cp, mv, mkdir, touch, echo, cat, ls, chmod, chown, rmdir

Text tools:   grep, find

Exec dry-run: rsync, apt/apt-get(-s), yum/dnf(--assumeno), make(-n),
              git(clean -n, push --dry-run), terraform(plan),
              ansible-playbook(--check), kubectl(--dry-run=client),
              aws(--dry-run)

System tools: docker (simulate), systemctl/service (simulate),
              ping (simulate), wget/curl (simulate)

Extra dryrun modes:
  dryrun syntax <script>       - Syntax check only
  dryrun trace <script>        - Print commands without execution
  dryrun script <script>       - Simulate file operations inside script
  dryrun check-vars <script>   - Warn about dangerous \$VAR usage
  dryrun lint <script>         - Run shellcheck linter on script

Examples:
  dryrun cp file.txt /tmp/
  dryrun apt-get install nginx
  dryrun -- rm -rf -- /etc
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "$#" -lt 1 ]]; then
  usage; exit 0
fi

cmd="$1"; shift

flags=()
args=()
seen_ddash=0
for a in "$@"; do
  if [[ $seen_ddash -eq 1 ]]; then
    args+=("$a")
  elif [[ "$a" == "--" ]]; then
    seen_ddash=1
  elif [[ "$a" == -* ]]; then
    flags+=("$a")
  else
    args+=("$a")
  fi
done

join_q() { local out=() x; for x in "$@"; do out+=("$(printf "%q" "$x")"); done; printf "%s" "${out[*]}"; }

printf "Dry run mode: showing what would happen if you ran: %s %s\n" \
  "$(printf "%q" "$cmd")" "$(join_q "${flags[@]}" "${args[@]}")"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    if [[ "$1" == "shellcheck" ]]; then
      die "'shellcheck' is not installed. Install it via: sudo apt install shellcheck"
    else
      die "Required command not found in PATH: $1"
    fi
  fi
}


if [[ "$cmd" == "syntax" ]]; then
  script="${args[0]:-}"
  [[ -f "$script" ]] || die "Script not found: $script"
  info "Checking syntax for: $(printf "%q" "$script")"
  if bash -n "$script"; then
    ok "No syntax errors detected."
  else
    die "Syntax errors found in the script."
  fi
  exit 0
fi

if [[ "$cmd" == "trace" ]]; then
  script="${args[0]:-}"
  [[ -f "$script" ]] || die "Script not found: $script"
  info "Showing command trace (simulated):"
  grep -v '^\s*#' "$script" | sed -n '/^\s*[^#]/p' | while read -r line; do
    echo "+ $line"
  done
  exit 0
fi

if [[ "$cmd" == "script" ]]; then
  script="${args[0]:-}"
  [[ -f "$script" ]] || die "Script not found: $script"
  info "Parsing and simulating script: $(printf "%q" "$script")"

  while IFS= read -r line || [ -n "$line" ]; do
    # Strip comments
    clean=$(echo "$line" | sed 's/#.*//')
    clean=$(echo "$clean" | xargs)
    [[ -z "$clean" ]] && continue

    # Basic pattern matching
    first=$(echo "$clean" | awk '{print $1}')
    rest=$(echo "$clean" | cut -d' ' -f2-)

    if [[ "$first" =~ ^(rm|cp|mv|mkdir|touch|echo|cat|ls|chmod|chown|grep|find|rmdir)$ ]]; then
      info "Simulating: $first $rest"
      $0 "$first" $rest
    else
      warn "Skipping unsupported or complex line: $clean"
    fi
  done < "$script"

  exit 0
fi

if [[ "$cmd" == "check-vars" ]]; then
  script="${args[0]:-}"
  [[ -f "$script" ]] || die "Script not found: $script"
  info "Scanning for potentially dangerous \$VAR usage..."

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ \$[A-Za-z_][A-Za-z0-9_]* ]] && warn "Found variable usage: $line"

    if [[ "$line" =~ rm\ -[rf]+.*\$[A-Za-z_] ]]; then
      warn "⚠️  Possible dangerous 'rm' with unquoted variable: $line"
    fi
  done < "$script"

  ok "Finished scanning for variable-related issues."
  exit 0
fi

if [[ "$cmd" == "lint" ]]; then
  script="${args[0]:-}"
  [[ -f "$script" ]] || die "Script not found: $script"

  need shellcheck

  info "Running shellcheck on: $(printf "%q" "$script")"
  shellcheck -x "$script"
  status=$?

  if [[ $status -eq 0 ]]; then
    ok "No lint issues found."
  else
    warn "Shellcheck returned warnings or errors (exit code $status)."
  fi
  exit $status
fi

case "$cmd" in
  rm)
    ((${#args[@]} > 0)) || die "'rm' requires at least one target."
    info "Files/directories that would be deleted:"
    for target in "${args[@]}"; do
      if [ -e "$target" ]; then
        cnt=$(find -- "$target" 2>/dev/null | head -n 200 | wc -l | tr -d ' ')
        printf "  - %s (showing up to 200 items; found ~%s)\n" "$(printf "%q" "$target")" "$cnt"
      else
        warn "Target does not exist: $(printf "%q" "$target")"
      fi
    done
    ;;

  cp)
    ((${#args[@]} >= 2)) || die "'cp' requires at least one source and a destination."
    dest="${args[-1]}"; sources=("${args[@]:0:${#args[@]}-1}")
    for src in "${sources[@]}"; do
      [ -e "$src" ] || warn "Source not found: $(printf "%q" "$src")"
      if [ -d "$src" ] && ! printf '%s\n' "${flags[@]}" | grep -qE '(^| )-r($| )|(^| )-R($| )'; then
        warn "Directory source without -r/-R: $(printf "%q" "$src")"
      fi
    done
    if [ "${#sources[@]}" -gt 1 ] && [ ! -d "$dest" ]; then
      warn "Multiple sources into non-directory destination: $(printf "%q" "$dest")"
    fi
    info "Would copy: $(join_q "${sources[@]}") -> $(printf "%q" "$dest")"
    ;;

  mv)
    ((${#args[@]} >= 2)) || die "'mv' requires at least one source and a destination."
    dest="${args[-1]}"; sources=("${args[@]:0:${#args[@]}-1}")
    for src in "${sources[@]}"; do [ -e "$src" ] || warn "Source not found: $(printf "%q" "$src")"; done
    if [ "${#sources[@]}" -gt 1 ] && [ ! -d "$dest" ]; then
      warn "Multiple sources into non-directory destination: $(printf "%q" "$dest")"
    fi
    info "Would move:  $(join_q "${sources[@]}") -> $(printf "%q" "$dest")"
    ;;

  mkdir)
    ((${#args[@]} > 0)) || die "Usage: mkdir <dir> [dir...]"
    for d in "${args[@]}"; do
      [ -d "$d" ] && warn "Directory already exists: $(printf "%q" "$d")"
      info "Would create directory: $(printf "%q" "$d")"
    done
    ;;

  touch)
    ((${#args[@]} > 0)) || die "Usage: touch <file> [file...]"
    for f in "${args[@]}"; do info "Would create file: $(printf "%q" "$f")"; done
    ;;

  echo)
    info "Would output: $(join_q "${args[@]}")"
    ;;

  cat)
    ((${#args[@]} > 0)) || die "Usage: cat <file> [file...]"
    for f in "${args[@]}"; do [ -f "$f" ] && info "Would display: $(printf "%q" "$f")" || die "File not found: $(printf "%q" "$f")"; done
    ;;

  ls)
    targets=("${args[@]}"); ((${#targets[@]})) || targets=(".")
    for t in "${targets[@]}"; do [ -e "$t" ] && info "Would list: $(printf "%q" "$t")" || die "Not found: $(printf "%q" "$t")"; done
    ;;

  chmod)
    mode="${args[0]:-}"; files=("${args[@]:1}")
    [[ -n "${mode}" && ${#files[@]} -gt 0 ]] || die "Usage: chmod <mode> <files>"
    for f in "${files[@]}"; do [ -e "$f" ] && info "Would chmod $mode $(printf "%q" "$f")" || die "Not found: $(printf "%q" "$f")"; done
    ;;

  chown)
    ug="${args[0]:-}"; files=("${args[@]:1}")
    [[ -n "${ug}" && ${#files[@]} -gt 0 ]] || die "Usage: chown <user[:group]> <files>"
    for f in "${files[@]}"; do [ -e "$f" ] && info "Would chown $ug $(printf "%q" "$f")" || die "Not found: $(printf "%q" "$f")"; done
    ;;

  grep)
    pat="${args[0]:-}"; files=("${args[@]:1}")
    [[ -n "${pat}" && ${#files[@]} -gt 0 ]] || die "Usage: grep <pattern> <files>"
    for f in "${files[@]}"; do [ -f "$f" ] && info "Would grep $(printf "%q" "$pat") in $(printf "%q" "$f")" || die "Not found: $(printf "%q" "$f")"; done
    ;;

  find) info "Would run: find $(join_q "${flags[@]}" "${args[@]}")" ;;

  rmdir)
    ((${#args[@]} > 0)) || die "Usage: rmdir <dir> [dir...]"
    for d in "${args[@]}"; do [ -d "$d" ] && info "Would remove empty dir: $(printf "%q" "$d")" || die "Not found: $(printf "%q" "$d")"; done
    ;;

  # SAFE REAL EXECUTION (has true dry-run/plan/check)
  rsync)
    need rsync
    info "Executing: rsync --dry-run $(join_q "${flags[@]}" "${args[@]}")"
    rsync --dry-run "${flags[@]}" "${args[@]}"
    ;;

  apt|apt-get)
    need "$cmd"
    info "Executing: $cmd -s $(join_q "${flags[@]}" "${args[@]}")"
    "$cmd" -s "${flags[@]}" "${args[@]}"
    ;;

  yum|dnf)
    need "$cmd"
    info "Executing: $cmd --assumeno $(join_q "${flags[@]}" "${args[@]}")"
    "$cmd" --assumeno "${flags[@]}" "${args[@]}"
    ;;

  make)
    need make
    info "Executing: make -n $(join_q "${flags[@]}" "${args[@]}")"
    make -n "${flags[@]}" "${args[@]}"
    ;;

  git)
    need git
    sub="${args[0]:-}"; rest=("${args[@]:1}")
    case "$sub" in
      clean)
        info "Executing: git clean -n $(join_q "${rest[@]}")"
        git clean -n "${rest[@]}"
        ;;
      push)
        info "Executing: git push --dry-run $(join_q "${rest[@]}")"
        git push --dry-run "${rest[@]}"
        ;;
      *)
        info "Simulating: git $(join_q "${flags[@]}" "${args[@]}")"
        ;;
    esac
    ;;

  aws)
    need aws
    info "Executing: aws $(join_q "${flags[@]}" "${args[@]}") --dry-run"
    aws "${flags[@]}" "${args[@]}" --dry-run
    ;;

  terraform)
    need terraform
    info "Executing: terraform plan $(join_q "${flags[@]}" "${args[@]}")"
    terraform plan "${flags[@]}" "${args[@]}"
    ;;

  ansible-playbook)
    need ansible-playbook
    info "Executing: ansible-playbook --check $(join_q "${flags[@]}" "${args[@]}")"
    ansible-playbook --check "${flags[@]}" "${args[@]}"
    ;;

  kubectl)
    need kubectl
    info "Executing: kubectl $(join_q "${flags[@]}" "${args[@]}") --dry-run=client -o yaml"
    kubectl "${flags[@]}" "${args[@]}" --dry-run=client -o yaml
    ;;

  # TODO: add some form of dry-run for these commands below
  docker)
    sub="${args[0]:-}"; rest=("${args[@]:1}")
    case "$sub" in
      build) info "Simulating: docker build $(join_q "${rest[@]}")" ;;
      run)   warn "No native dry-run for 'docker run'."; info "Simulating: docker run $(join_q "${rest[@]}")" ;;
      *)     info "Simulating: docker $(join_q "${flags[@]}" "${args[@]}")" ;;
    esac
    ;;

  systemctl)
    info "Simulating: systemctl $(join_q "${flags[@]}" "${args[@]}")"
    ;;

  service)
    info "Simulating: service $(join_q "${flags[@]}" "${args[@]}")"
    ;;

  ping)
    info "Simulating: ping $(join_q "${flags[@]}" "${args[@]}")"
    ;;

  wget|curl)
    info "Simulating: $cmd $(join_q "${flags[@]}" "${args[@]}")"
    ;;

  *) 
    if ! command -v "$cmd" >/dev/null 2>&1; then
      close=$(compgen -c "$cmd" | head -n 1)
      die "Command not found: $cmd${close:+. Did you mean '$close'?}"
    else
      warn "Command '$cmd' is not explicitly supported."
    fi
    ;;

esac

