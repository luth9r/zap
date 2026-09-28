const std = @import("std");

pub const SCRIPT =
    \\# Zap prompt integration for Zsh
    \\
    \\zmodload zsh/datetime 2>/dev/null
    \\
    \\typeset -g _zap_start_time
    \\
    \\_zap_preexec() {
    \\    _zap_start_time=$EPOCHREALTIME
    \\}
    \\
    \\_zap_precmd() {
    \\    local exit_code=$?
    \\    local -i duration=0
    \\
    \\    if [[ -n "$_zap_start_time" ]]; then
    \\        local end_time=$EPOCHREALTIME
    \\        duration=$(( (end_time - _zap_start_time) * 1000 ))
    \\        unset _zap_start_time
    \\    fi
    \\
    \\    PROMPT="$("{{EXE}}" prompt --status "$exit_code" --duration "$duration" --shell zsh)"
    \\}
    \\
    \\autoload -Uz add-zsh-hook
    \\add-zsh-hook preexec _zap_preexec
    \\add-zsh-hook precmd _zap_precmd
    \\
;
