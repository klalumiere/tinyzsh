# Composes the segments from the other lib/ files into the single top line
# that sits above the input arrow.
#
# Layout:
#     [ path ][ git? ] ........................ [ duration? ][ time ]
#     ›
#
# The dot-fill in the middle is sized to fill the terminal column width given
# what's visible on each side. If the terminal is too narrow for everything,
# the fill shrinks to zero and the two sides just touch.


# Text shown inside the path segment. The directory's basename is bolded —
# that's what gives the design its emphasized last component, e.g. tinyzsh.
_tinyzsh_render_path_segment_text() {
  local full_path=${(%):-%~}
  local parent base
  if [[ $full_path == */* ]]; then
    parent=${full_path%/*}
    base=${full_path##*/}
    # Escape any literal % in the path so prompt expansion can't reinterpret
    # them when we feed this string back through %-substitution.
    parent=${parent//\%/%%}
    base=${base//\%/%%}
    print -rn -- "${parent}/%B${base}%b"
  else
    full_path=${full_path//\%/%%}
    print -rn -- "%B${full_path}%b"
  fi
}


# Append the left-side segments (path, then git if applicable) to $REPLY.
_tinyzsh_append_left_side_segments_to_reply() {
  local path_text=$(_tinyzsh_render_path_segment_text)
  local git_text=$(_tinyzsh_render_git_segment_text)

  if [[ -n $git_text ]]; then
    _tinyzsh_append_left_facing_segment \
      "$path_text" "$TINYZSH_PATH_BACKGROUND" "$TINYZSH_PATH_FOREGROUND" \
      "$TINYZSH_GIT_BACKGROUND"
    _tinyzsh_append_left_facing_segment \
      "$git_text" "$TINYZSH_GIT_BACKGROUND" "$TINYZSH_GIT_FOREGROUND" \
      "$TINYZSH_TRANSPARENT_BACKGROUND"
  else
    _tinyzsh_append_left_facing_segment \
      "$path_text" "$TINYZSH_PATH_BACKGROUND" "$TINYZSH_PATH_FOREGROUND" \
      "$TINYZSH_TRANSPARENT_BACKGROUND"
  fi
}


# Append the right-side segments (optional duration, then the clock) to $REPLY.
# The clock is left as the %D{...} prompt code so it stays accurate even when
# the prompt is redrawn between commands (e.g. via zle reset-prompt).
_tinyzsh_append_right_side_segments_to_reply() {
  local previous_background=$TINYZSH_TRANSPARENT_BACKGROUND

  if [[ -n $_tinyzsh_last_command_duration_seconds ]]; then
    local duration_text
    duration_text=$(_tinyzsh_format_duration_for_display \
      "$_tinyzsh_last_command_duration_seconds")
    _tinyzsh_append_right_facing_segment \
      "$duration_text" "$TINYZSH_DURATION_BACKGROUND" \
      "$TINYZSH_DURATION_FOREGROUND" "$previous_background"
    previous_background=$TINYZSH_DURATION_BACKGROUND
  fi

  _tinyzsh_append_right_facing_segment \
    '%D{%H:%M:%S}' "$TINYZSH_TIME_BACKGROUND" \
    "$TINYZSH_TIME_FOREGROUND" "$previous_background"
}


# Build the whole top line: left side, dot-fill, right side.
# Called via $(...) inside PROMPT, so it runs on every prompt render.
_tinyzsh_render_top_prompt_line() {
  local REPLY=""

  _tinyzsh_append_left_side_segments_to_reply
  local left_side=$REPLY

  REPLY=""
  _tinyzsh_append_right_side_segments_to_reply
  local right_side=$REPLY

  _tinyzsh_measure_visible_column_width "$left_side"
  local left_width=$REPLY

  _tinyzsh_measure_visible_column_width "$right_side"
  local right_width=$REPLY

  local dot_count=$(( COLUMNS - left_width - right_width ))
  local filler=""
  if (( dot_count > 0 )); then
    # Build a string of `dot_count` fill characters.
    # Tempting alternative: ${(l:dot_count::$TINYZSH_FILL_CHARACTER:)} — but
    # zsh does NOT expand $-references inside that flag's string argument
    # reliably, so the literal var name leaks into the prompt. A plain
    # `repeat` loop is unambiguous and fast enough for typical widths.
    local pad=""
    repeat $dot_count; do pad+=$TINYZSH_FILL_CHARACTER; done
    filler="%F{$TINYZSH_DOT_FILL_FOREGROUND}${pad}%f"
  fi

  print -rn -- "${left_side}${filler}${right_side}"
}
