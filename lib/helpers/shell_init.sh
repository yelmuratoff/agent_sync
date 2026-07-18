#!/usr/bin/env bash
# agentsync shell-init — prints a shell snippet that keeps a project's generated
# outputs fresh by running `sync --if-stale` when entering its root directory.
# The snippet is meant to be appended to a shell rc file or eval'd; it must emit
# nothing but the snippet on stdout so redirection into ~/.zshrc stays clean.

_shell_init_usage() {
    echo "Usage: agentsync shell-init [zsh|bash]"
    echo ""
    echo "  Prints a shell snippet that runs 'agentsync sync --if-stale' for the"
    echo "  current .ai/ project when you enter its root directory, so generated"
    echo "  outputs stay fresh without syncing parent projects from descendants."
    echo ""
    echo "  Recommended: add one of these to your rc file. Eval'ing it regenerates"
    echo "  the hook each session, so upgrades and fixes apply without re-editing:"
    echo ""
    echo "    eval \"\$(agentsync shell-init zsh)\"      # in ~/.zshrc"
    echo "    eval \"\$(agentsync shell-init bash)\"     # in ~/.bashrc"
    echo ""
    echo "  Or freeze a copy with 'agentsync shell-init zsh >> ~/.zshrc', but then"
    echo "  re-run it after each upgrade to pick up changes."
    echo ""
    echo "  The shell is auto-detected from \$SHELL when omitted."
    echo "  Set AGENTSYNC_NO_AUTO_SYNC=1 to disable without removing the snippet."
}

# The quoted heredoc keeps every expansion for the user's shell, not this one.
_shell_init_common() {
    cat <<'SNIPPET'
_agentsync_autosync() {
  # Never `cd` here: as a zsh chpwd hook this fires on every directory change,
  # so a `cd` would re-trigger it and recurse (FUNCNEST blow-up). Point the sync
  # at the project via AGENTSYNC_REPO_ROOT instead, and guard against re-entry.
  [ -n "${_AGENTSYNC_BUSY:-}" ] && return 0
  [ -n "${AGENTSYNC_NO_AUTO_SYNC:-}" ] && return 0
  command -v agentsync >/dev/null 2>&1 || return 0
  _AGENTSYNC_BUSY=1
  if [ -d "$PWD/.ai/src" ]; then
    AGENTSYNC_REPO_ROOT="$PWD" agentsync sync --if-stale || true
  fi
  unset _AGENTSYNC_BUSY
}
SNIPPET
}

_shell_init_zsh() {
    echo "# >>> agentsync shell hook (zsh) >>>"
    _shell_init_common
    cat <<'SNIPPET'
autoload -Uz add-zsh-hook 2>/dev/null
if (( ${+functions[add-zsh-hook]} )); then
  add-zsh-hook chpwd _agentsync_autosync
fi
_agentsync_autosync
# <<< agentsync shell hook (zsh) <<<
SNIPPET
}

_shell_init_bash() {
    echo "# >>> agentsync shell hook (bash) >>>"
    _shell_init_common
    cat <<'SNIPPET'
_agentsync_prompt_hook() {
  if [ "$PWD" != "${_AGENTSYNC_LAST_PWD:-}" ]; then
    _AGENTSYNC_LAST_PWD=$PWD
    _agentsync_autosync
  fi
}
case "${PROMPT_COMMAND:-}" in
  *_agentsync_prompt_hook*) : ;;
  *) PROMPT_COMMAND="_agentsync_prompt_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
_AGENTSYNC_LAST_PWD=$PWD
_agentsync_autosync
# <<< agentsync shell hook (bash) <<<
SNIPPET
}

cmd_shell_init() {
    local shell="${1:-}"
    case "$shell" in
        --help|-h) _shell_init_usage; return 0 ;;
    esac

    if [[ -z "$shell" ]]; then
        case "${SHELL:-}" in
            */zsh)  shell="zsh" ;;
            */bash) shell="bash" ;;
        esac
    fi

    case "$shell" in
        zsh)  _shell_init_zsh ;;
        bash) _shell_init_bash ;;
        "")
            log_error "Could not detect your shell from \$SHELL."
            echo "  Pass one explicitly: $(_cyan "agentsync shell-init zsh") or $(_cyan "agentsync shell-init bash")" >&2
            return 2
            ;;
        *)
            log_error "Unsupported shell: $shell (expected 'zsh' or 'bash')"
            return 2
            ;;
    esac
}
