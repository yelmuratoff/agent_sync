#!/usr/bin/env bash
# agentsync shell-init — prints a shell snippet that keeps the nearest project's
# generated outputs fresh by running `sync --if-stale` on every directory change.
# The snippet is meant to be appended to a shell rc file or eval'd; it must emit
# nothing but the snippet on stdout so redirection into ~/.zshrc stays clean.

_shell_init_usage() {
    echo "Usage: agentsync shell-init [zsh|bash]"
    echo ""
    echo "  Prints a shell snippet that runs 'agentsync sync --if-stale' for the"
    echo "  nearest .ai/ project whenever you change directory, so generated"
    echo "  outputs never go stale between edits. Append it to your rc file:"
    echo ""
    echo "    agentsync shell-init zsh  >> ~/.zshrc"
    echo "    agentsync shell-init bash >> ~/.bashrc"
    echo ""
    echo "  The shell is auto-detected from \$SHELL when omitted."
    echo "  Set AGENTSYNC_NO_AUTO_SYNC=1 to disable without removing the snippet."
}

# The auto-sync function, identical across shells: walk up from \$PWD to the
# nearest .ai/src and run a staleness-gated sync there (silent when fresh). The
# quoted heredoc keeps every expansion for the user's shell, not this one.
_shell_init_common() {
    cat <<'SNIPPET'
_agentsync_autosync() {
  [ -n "${AGENTSYNC_NO_AUTO_SYNC:-}" ] && return 0
  command -v agentsync >/dev/null 2>&1 || return 0
  _agentsync_dir=$PWD
  while [ -n "$_agentsync_dir" ] && [ "$_agentsync_dir" != "/" ]; do
    if [ -d "$_agentsync_dir/.ai/src" ]; then
      ( cd "$_agentsync_dir" && agentsync sync --if-stale ) || true
      break
    fi
    _agentsync_dir=${_agentsync_dir%/*}
  done
  unset _agentsync_dir
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
