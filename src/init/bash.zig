const std = @import("std");

pub const SCRIPT =
    \\# Zap prompt integration for Bash
    \\
    \\_zap_start_time=""
    \\_zap_preexec_ready="true"
    \\
    \\_zap_preexec() {
    \\    if [ "$_zap_preexec_ready" = "true" ]; then
    \\        _zap_preexec_ready="false"
    \\        _zap_start_time="${EPOCHREALTIME:-$(date +%s%3N 2>/dev/null || date +%s000)}"
    \\    fi
    \\}
    \\
    \\_zap_prompt_command() {
    \\    local exit_code=$?
    \\    local duration=0
    \\
    \\    if [ -n "$_zap_start_time" ]; then
    \\        local end_time="${EPOCHREALTIME:-$(date +%s%3N 2>/dev/null || date +%s000)}"
    \\        if [[ "$_zap_start_time" == *"."* && "$end_time" == *"."* ]]; then
    \\            local start_s="${_zap_start_time%.*}"
    \\            local start_us="${_zap_start_time#*.}"
    \\            local end_s="${end_time%.*}"
    \\            local end_us="${end_time#*.}"
    \\            start_us=$(printf "%-6s" "$start_us" | tr ' ' '0')
    \\            end_us=$(printf "%-6s" "$end_us" | tr ' ' '0')
    \\            local diff_s=$(( 10#$end_s - 10#$start_s ))
    \\            local diff_us=$(( 10#$end_us - 10#$start_us ))
    \\            duration=$(( diff_s * 1000 + diff_us / 1000 ))
    \\        else
    \\            duration=$(( end_time - _zap_start_time ))
    \\        fi
    \\        _zap_start_time=""
    \\    fi
    \\    _zap_preexec_ready="true"
    \\
    \\    PS1="$("{{EXE}}" prompt --status "$exit_code" --duration "${duration:-0}" --shell bash)"
    \\}
    \\
    \\if [[ ! "$PROMPT_COMMAND" =~ _zap_prompt_command ]]; then
    \\    PROMPT_COMMAND="_zap_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    \\fi
    \\
    \\if ! type preexec >/dev/null 2>&1; then
    \\    trap '_zap_preexec' DEBUG
    \\fi
    \\
;
