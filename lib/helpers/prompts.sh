#!/usr/bin/env bash
# Interactive prompt utilities.
#
# All prompts read from /dev/tty so they keep working when stdout is captured
# (e.g. `foo=$(cmd_init ...)`). In non-TTY environments the helpers degrade
# gracefully — callers are expected to detect this via `is_tty` up front and
# pass defaults instead of prompting.

# Is stdin attached to a terminal? Used by callers to decide whether to prompt.
is_tty() {
    [[ -t 0 ]] && [[ -t 1 ]]
}

# prompt_confirm <question> <default: y|n>
# TTY → asks "question [Y/n]" (or [y/N]), returns 0 on yes / 1 on no.
# Non-TTY → returns based on default silently.
prompt_confirm() {
    local question="$1"
    local default="${2:-n}"
    default="${default,,}"

    if ! is_tty; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    local hint
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    local reply
    printf '%s %s ' "$question" "$hint" >&2
    read -r reply </dev/tty || reply=""
    reply="${reply,,}"
    reply="${reply:-$default}"
    [[ "$reply" == "y" || "$reply" == "yes" ]]
}

# prompt_multiselect <title> <options_space_sep> <preselected_space_sep>
# TTY → interactive checkbox list (arrow keys, space toggle, enter confirm).
# Non-TTY → prints preselected unchanged.
# Prints selected items space-separated on stdout. Status msgs go to stderr.
prompt_multiselect() {
    local title="$1"
    local options="$2"
    local preselected="$3"

    # Non-TTY fast path.
    if ! is_tty; then
        echo "$preselected"
        return 0
    fi

    # Build parallel arrays.
    local -a opts=()
    local -a selected=()
    local tok
    for tok in $options; do
        opts+=("$tok")
        if [[ " $preselected " == *" $tok "* ]]; then
            selected+=(1)
        else
            selected+=(0)
        fi
    done

    local n=${#opts[@]}
    [[ $n -eq 0 ]] && { echo ""; return 0; }

    local cursor=0
    local key
    local initial_draw=1

    # Save cursor, hide cursor.
    printf '\033[?25l' >&2
    trap 'printf "\033[?25h" >&2' RETURN

    _redraw() {
        local i marker check name
        # Move cursor up to top of the list (except first draw).
        if [[ $initial_draw -eq 0 ]]; then
            printf '\033[%dA' "$((n + 2))" >&2
        fi
        initial_draw=0

        printf '\r\033[K%s\n' "$title" >&2
        printf '\r\033[K%s\n' "$(_dim "  (space: toggle · a: all · n: none · enter: confirm)")" >&2
        for ((i=0; i<n; i++)); do
            if [[ ${selected[$i]} -eq 1 ]]; then
                check="[$(_green "x")]"
            else
                check="[ ]"
            fi
            if [[ $i -eq $cursor ]]; then
                marker="$(_cyan "›")"
                name="$(_bold "${opts[$i]}")"
            else
                marker=" "
                name="${opts[$i]}"
            fi
            printf '\r\033[K %s %s %s\n' "$marker" "$check" "$name" >&2
        done
    }

    _redraw
    while true; do
        IFS= read -rsn1 key </dev/tty || break
        # Handle escape sequences for arrow keys.
        if [[ "$key" == $'\033' ]]; then
            local k2 k3
            IFS= read -rsn1 -t 0.01 k2 </dev/tty || k2=""
            IFS= read -rsn1 -t 0.01 k3 </dev/tty || k3=""
            case "$k2$k3" in
                "[A") key="UP" ;;
                "[B") key="DOWN" ;;
                *)    key="ESC" ;;
            esac
        fi

        case "$key" in
            UP|k)
                cursor=$(( (cursor - 1 + n) % n ))
                ;;
            DOWN|j)
                cursor=$(( (cursor + 1) % n ))
                ;;
            " ")
                if [[ ${selected[$cursor]} -eq 1 ]]; then
                    selected[$cursor]=0
                else
                    selected[$cursor]=1
                fi
                ;;
            a|A)
                local i
                for ((i=0; i<n; i++)); do selected[$i]=1; done
                ;;
            n|N)
                local i
                for ((i=0; i<n; i++)); do selected[$i]=0; done
                ;;
            "")
                # Enter.
                break
                ;;
            q|ESC)
                # Cancel — keep preselected as-is.
                printf '\033[?25h' >&2
                trap - RETURN
                echo "$preselected"
                return 130
                ;;
        esac
        _redraw
    done

    printf '\033[?25h' >&2
    trap - RETURN

    # Emit selection as space-separated tokens.
    local out="" i
    for ((i=0; i<n; i++)); do
        [[ ${selected[$i]} -eq 1 ]] && out="${out:+$out }${opts[$i]}"
    done
    echo "$out"
}
