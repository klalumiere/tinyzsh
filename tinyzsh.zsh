# tinyzsh — a tiny zsh prompt focused on speed and clarity.
#
# Add `source /path/to/tinyzsh.zsh` to your ~/.zshrc to use it.
#
# The whole thing is roughly 200 lines of zsh split across this file and the
# four files in lib/. Read them top to bottom and you should be able to audit
# everything that runs on every prompt.

autoload -Uz add-zsh-hook

# Locate ourselves so we can source siblings even when sourced from anywhere.
_tinyzsh_installation_directory=${${(%):-%x}:A:h}

source $_tinyzsh_installation_directory/lib/segments.zsh
source $_tinyzsh_installation_directory/lib/git_info.zsh
source $_tinyzsh_installation_directory/lib/command_duration.zsh
source $_tinyzsh_installation_directory/lib/prompt_layout.zsh

setopt prompt_subst

add-zsh-hook precmd  _tinyzsh_refresh_state_before_each_prompt
add-zsh-hook preexec _tinyzsh_remember_command_start_time

# The top line is rebuilt via command substitution on every prompt render
# (including after zle reset-prompt), so the clock and the dot-fill always
# match the current terminal width.
# %(?.A.B) is a zsh prompt conditional: A when the last command's exit status
# was 0, B otherwise — so the arrow is green on success and red on error.
PROMPT='$(_tinyzsh_render_top_prompt_line)
%(?.%F{$TINYZSH_INPUT_ARROW_FOREGROUND}.%F{$TINYZSH_INPUT_ARROW_ERROR_FOREGROUND})›%f '
PROMPT2='%F{$TINYZSH_INPUT_ARROW_FOREGROUND}›%f '
RPROMPT=''


# Called by zsh right before each prompt is shown. Cheap work only — anything
# that might block goes through the async path in lib/git_info.zsh.
_tinyzsh_refresh_state_before_each_prompt() {
  _tinyzsh_calculate_last_command_duration
  _tinyzsh_refresh_cached_git_branch_for_current_directory
  _tinyzsh_kick_off_async_git_status_update_if_in_repo
}
