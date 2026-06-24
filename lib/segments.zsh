# Powerline segment rendering helpers and the colour palette.
#
# Every visible piece of the top line is built by appending "segments" into a
# caller-scoped $REPLY. A segment is "[colored body][angled separator]".
# Two flavours:
#   * left-facing  → body, then an arrow pointing right (used on the left side)
#   * right-facing → an arrow pointing left, then body (used on the right side)

# Unicode glyphs from the Powerline range — require a patched terminal font.
typeset -g TINYZSH_RIGHT_FACING_SEPARATOR=$''  #
typeset -g TINYZSH_LEFT_FACING_SEPARATOR=$''   #

# Sentinel value meaning "no segment on this side, fade into the terminal bg".
typeset -g TINYZSH_TRANSPARENT_BACKGROUND='transparent'

# Character that fills the empty space between the two sides of the prompt.
typeset -g TINYZSH_FILL_CHARACTER='.'

# 256-colour palette. Tweak these to taste.
typeset -g TINYZSH_PATH_BACKGROUND=23
typeset -g TINYZSH_PATH_FOREGROUND=87
typeset -g TINYZSH_GIT_BACKGROUND=58
typeset -g TINYZSH_GIT_FOREGROUND=185
typeset -g TINYZSH_DURATION_BACKGROUND=58
typeset -g TINYZSH_DURATION_FOREGROUND=185
typeset -g TINYZSH_TIME_BACKGROUND=23
typeset -g TINYZSH_TIME_FOREGROUND=87
typeset -g TINYZSH_DOT_FILL_FOREGROUND=240
typeset -g TINYZSH_INPUT_ARROW_FOREGROUND=82


# Append one left-side segment to the caller's $REPLY (dynamic scope).
#   $1  visible content (spaces are added around it automatically)
#   $2  segment background colour code
#   $3  segment foreground colour code
#   $4  background of whatever follows, or $TINYZSH_TRANSPARENT_BACKGROUND
_tinyzsh_append_left_facing_segment() {
  local content=$1
  local background=$2
  local foreground=$3
  local next_background=$4

  REPLY+="%K{$background}%F{$foreground} $content %k%f"

  if [[ $next_background == $TINYZSH_TRANSPARENT_BACKGROUND ]]; then
    REPLY+="%F{$background}$TINYZSH_RIGHT_FACING_SEPARATOR%f"
  else
    REPLY+="%K{$next_background}%F{$background}$TINYZSH_RIGHT_FACING_SEPARATOR%k%f"
  fi
}


# Append one right-side segment to the caller's $REPLY (dynamic scope).
#   $1  visible content
#   $2  segment background colour code
#   $3  segment foreground colour code
#   $4  background of whatever preceded this one, or
#       $TINYZSH_TRANSPARENT_BACKGROUND if it's the first right-side segment
_tinyzsh_append_right_facing_segment() {
  local content=$1
  local background=$2
  local foreground=$3
  local previous_background=$4

  if [[ $previous_background == $TINYZSH_TRANSPARENT_BACKGROUND ]]; then
    REPLY+="%F{$background}$TINYZSH_LEFT_FACING_SEPARATOR%f"
  else
    REPLY+="%K{$previous_background}%F{$background}$TINYZSH_LEFT_FACING_SEPARATOR%k%f"
  fi

  REPLY+="%K{$background}%F{$foreground} $content %k%f"
}


# Count the visible columns a prompt-formatted string will take up.
# Result lands in $REPLY. We expand the %-codes (turning %F{...} into ANSI
# escapes, %B into bold-on, %D{...} into the formatted time, ...) and then
# strip the ANSI escapes — what's left is exactly what shows on screen.
_tinyzsh_measure_visible_column_width() {
  # The strip pattern below uses `##` ("one or more") which is part of zsh's
  # EXTENDED_GLOB syntax. Enable it locally so the function works regardless
  # of how the user has their shell configured. `local_options` reverts the
  # change when the function returns.
  setopt local_options extended_glob

  local text=$1
  local expanded=${(%)text}
  local stripped=${expanded//$'\x1b['[0-9;]##m/}
  REPLY=${#stripped}
}
