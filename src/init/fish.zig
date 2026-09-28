const std = @import("std");

pub const SCRIPT =
    \\# Zap prompt integration for Fish
    \\
    \\function fish_prompt
    \\    set -l last_status $status
    \\    set -l duration "$CMD_DURATION"
    \\    if test -z "$duration"
    \\        set duration 0
    \\    end
    \\    "{{EXE}}" prompt --status "$last_status" --duration "$duration" --shell fish
    \\end
    \\
;
