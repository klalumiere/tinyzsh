# Git information shown in the prompt, split into fast and slow halves.
#
# Fast half (synchronous, runs in precmd):
#   * Are we in a git working tree? — a filesystem walk for `.git`, no fork.
#   * What's the branch name? — one `git symbolic-ref` call, reads HEAD only.
#
# Slow half (asynchronous):
#   * How many staged and untracked files? — `git status --porcelain` walks
#     the index AND the working tree, which can take 100ms+ in large repos.
#     We spawn it in a backgrounded subshell and let `zle -F` notify us when
#     the result is ready, then call `zle reset-prompt` to redraw.
#
# Results are cached by absolute directory path, so revisiting a known repo
# shows its counts instantly while the new computation runs in the background.

typeset -gA _tinyzsh_git_status_cache_by_directory
typeset -g  _tinyzsh_branch_name_for_current_directory=""
typeset -g  _tinyzsh_async_git_pending_directory=""
typeset -g  _tinyzsh_async_git_pending_fd=""


# Cheap filesystem walk for `.git` (handles both regular repos where .git is
# a directory and submodules / worktrees where it's a file).
_tinyzsh_is_inside_git_working_tree() {
  local directory=$PWD
  while [[ -n $directory ]]; do
    [[ -e $directory/.git ]] && return 0
    [[ $directory == / ]] && return 1
    directory=${directory:h}
  done
  return 1
}


# Sets $_tinyzsh_branch_name_for_current_directory once per precmd so that the
# prompt-render path can read a variable instead of forking `git` every time
# zsh redraws (which can happen on every zle reset-prompt).
_tinyzsh_refresh_cached_git_branch_for_current_directory() {
  _tinyzsh_branch_name_for_current_directory=""
  _tinyzsh_is_inside_git_working_tree || return

  local branch
  if branch=$(git symbolic-ref --short --quiet HEAD 2>/dev/null); then
    _tinyzsh_branch_name_for_current_directory=$branch
  elif branch=$(git rev-parse --short HEAD 2>/dev/null); then
    _tinyzsh_branch_name_for_current_directory=$branch
  fi
}


# Build the text shown inside the git segment, e.g. "main ?1 +2".
# Returns nonzero (and prints nothing) when we are not in a repo.
_tinyzsh_render_git_segment_text() {
  [[ -z $_tinyzsh_branch_name_for_current_directory ]] && return 1

  local content=$_tinyzsh_branch_name_for_current_directory
  local cached=${_tinyzsh_git_status_cache_by_directory[$PWD]:-}

  if [[ -n $cached ]]; then
    local staged_count=${cached% *}
    local untracked_count=${cached#* }
    (( untracked_count > 0 )) && content+=" ?${untracked_count}"
    (( staged_count    > 0 )) && content+=" +${staged_count}"
  fi

  print -rn -- "$content"
}


# Count staged and untracked files for $1. Designed to run in a subshell.
# Output (always one line):  "<staged_count> <untracked_count>"
_tinyzsh_compute_git_status_counts_for_directory() {
  local directory=$1
  builtin cd -q -- "$directory" 2>/dev/null || { print -r -- "0 0"; return }

  local porcelain
  porcelain=$(git status --porcelain=v1 2>/dev/null) || {
    print -r -- "0 0"; return
  }

  local staged_count=0
  local untracked_count=0
  local line index_status

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ ${line:0:2} == '??' ]]; then
      (( untracked_count++ ))
    else
      index_status=${line:0:1}
      [[ $index_status != ' ' ]] && (( staged_count++ ))
    fi
  done <<< "$porcelain"

  print -r -- "$staged_count $untracked_count"
}


# Spawn the slow status computation in a background subshell whose stdout is
# captured into a file descriptor. `zle -F` will call the receiver below as
# soon as that descriptor has data, without blocking input.
_tinyzsh_kick_off_async_git_status_update_if_in_repo() {
  _tinyzsh_cancel_any_pending_async_git_job
  _tinyzsh_is_inside_git_working_tree || return

  local target_directory=$PWD
  local fd
  exec {fd}< <(_tinyzsh_compute_git_status_counts_for_directory "$target_directory")

  _tinyzsh_async_git_pending_directory=$target_directory
  _tinyzsh_async_git_pending_fd=$fd

  zle -F "$fd" _tinyzsh_receive_async_git_status_result
}


_tinyzsh_cancel_any_pending_async_git_job() {
  [[ -z $_tinyzsh_async_git_pending_fd ]] && return
  zle -F "$_tinyzsh_async_git_pending_fd" 2>/dev/null
  exec {_tinyzsh_async_git_pending_fd}<&- 2>/dev/null
  _tinyzsh_async_git_pending_fd=""
  _tinyzsh_async_git_pending_directory=""
}


# zle -F callback: read the line the subshell produced, stash it in the cache
# keyed by the directory we asked about, and trigger a redraw if the user is
# still sitting in that directory (they may have `cd`d away meanwhile).
_tinyzsh_receive_async_git_status_result() {
  local fd=$1
  local result=""
  IFS= read -r result <&$fd
  zle -F "$fd"
  exec {fd}<&-

  local computed_for=$_tinyzsh_async_git_pending_directory
  _tinyzsh_async_git_pending_fd=""
  _tinyzsh_async_git_pending_directory=""

  [[ -z $result ]] && return

  _tinyzsh_git_status_cache_by_directory[$computed_for]=$result

  if [[ $PWD == $computed_for ]]; then
    zle reset-prompt 2>/dev/null
  fi
}
