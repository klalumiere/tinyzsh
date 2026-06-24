# Time how long the previous foreground command took, and only surface it on
# the prompt once it crosses a "this took noticeably long" threshold.

# Gives us $EPOCHSECONDS — reading a shell variable is far cheaper than
# forking `date +%s` on every preexec/precmd.
zmodload zsh/datetime

# Don't show the duration segment unless the command took at least this long.
typeset -g TINYZSH_DURATION_VISIBILITY_THRESHOLD_SECONDS=3

# Set by preexec, consumed (and cleared) by precmd.
typeset -g _tinyzsh_command_start_epoch_seconds=""

# Set by precmd; empty means "don't draw a duration segment this round".
typeset -g _tinyzsh_last_command_duration_seconds=""


# preexec hook — runs the instant before the command actually starts.
_tinyzsh_remember_command_start_time() {
  _tinyzsh_command_start_epoch_seconds=$EPOCHSECONDS
}


# precmd hook — runs once the command has finished, before drawing the prompt.
_tinyzsh_calculate_last_command_duration() {
  if [[ -z $_tinyzsh_command_start_epoch_seconds ]]; then
    _tinyzsh_last_command_duration_seconds=""
    return
  fi

  local elapsed=$(( EPOCHSECONDS - _tinyzsh_command_start_epoch_seconds ))
  _tinyzsh_command_start_epoch_seconds=""

  if (( elapsed >= TINYZSH_DURATION_VISIBILITY_THRESHOLD_SECONDS )); then
    _tinyzsh_last_command_duration_seconds=$elapsed
  else
    _tinyzsh_last_command_duration_seconds=""
  fi
}


# Pretty-print an integer seconds count compactly:
#   42     → "42s"
#   125    → "2m5s"
#   3725   → "1h2m5s"
_tinyzsh_format_duration_for_display() {
  local total_seconds=$1

  if (( total_seconds < 60 )); then
    print -rn -- "${total_seconds}s"
    return
  fi

  local minutes=$(( total_seconds / 60 ))
  local seconds=$(( total_seconds % 60 ))

  if (( minutes < 60 )); then
    print -rn -- "${minutes}m${seconds}s"
    return
  fi

  local hours=$(( minutes / 60 ))
  minutes=$(( minutes % 60 ))
  print -rn -- "${hours}h${minutes}m${seconds}s"
}
