#!/usr/bin/env bash
# CLI color helpers for agentsync.
# Evaluated once at source-time; safe for piped output.

_USE_COLORS=false
[[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && _USE_COLORS=true

_bold()    { [[ "$_USE_COLORS" == true ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }
_green()   { [[ "$_USE_COLORS" == true ]] && printf '\033[32m%s\033[0m' "$1" || printf '%s' "$1"; }
_cyan()    { [[ "$_USE_COLORS" == true ]] && printf '\033[36m%s\033[0m' "$1" || printf '%s' "$1"; }
_yellow()  { [[ "$_USE_COLORS" == true ]] && printf '\033[33m%s\033[0m' "$1" || printf '%s' "$1"; }
_red()     { [[ "$_USE_COLORS" == true ]] && printf '\033[31m%s\033[0m' "$1" || printf '%s' "$1"; }
_dim()     { [[ "$_USE_COLORS" == true ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"; }
