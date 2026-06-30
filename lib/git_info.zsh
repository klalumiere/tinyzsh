# Git information shown in the prompt, split into fast and slow halves.
#
# Fast half (synchronous, runs in precmd):
#   * Are we in a git working tree? — a filesystem walk for `.git`, no fork.
#   * What's the branch name? — one `git symbolic-ref` call, reads HEAD only.
#
# Slow half (asynchronous):
#   * How many staged, untracked, and modified files, and is the branch ahead
#     of / behind origin? — a single `git status --porcelain -b` call. It walks
#     the index AND the working tree (which can take 100ms+ in large repos), and
#     its branch header reports ahead/behind against the remote-tracking ref.
#     We spawn it in a backgrounded subshell and let `zle -F` notify us when
#     the result is ready, then call `zle reset-prompt` to redraw.
#
# The ahead/behind counts come from the locally cached remote-tracking ref
# (e.g. origin/main), which is whatever the last `git fetch` recorded — so the
# sync sign costs no network round trip and stays fast even when offline.
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


# Build the text shown inside the git segment, e.g. "main ⇡ ?1 +2".
# Returns nonzero (and prints nothing) when we are not in a repo.
_tinyzsh_render_git_segment_text() {
  [[ -z $_tinyzsh_branch_name_for_current_directory ]] && return 1

  local content=$_tinyzsh_branch_name_for_current_directory
  local cached=${_tinyzsh_git_status_cache_by_directory[$PWD]:-}

  if [[ -n $cached ]]; then
    local parts=(${(s: :)cached})
    local staged_count=${parts[1]:-0}
    local untracked_count=${parts[2]:-0}
    local modified_count=${parts[3]:-0}
    local remote_state=${parts[4]:-synced}

    # Out-of-sync-with-origin sign, right after the branch name. Nothing is
    # shown when in sync with (or having no) upstream.
    case $remote_state in
      ahead)    content+=" $TINYZSH_GIT_AHEAD_SIGN" ;;
      behind)   content+=" $TINYZSH_GIT_BEHIND_SIGN" ;;
      diverged) content+=" $TINYZSH_GIT_DIVERGED_SIGN" ;;
    esac

    (( untracked_count > 0 )) && content+=" ?${untracked_count}"
    (( staged_count    > 0 )) && content+=" +${staged_count}"
    (( modified_count  > 0 )) && content+=" !${modified_count}"
  fi

  print -rn -- "$content"
}


# Summarise the working tree and the branch's position relative to origin for
# $1. Designed to run in a subshell.
# Output (always one line):
#   "<staged_count> <untracked_count> <modified_count> <remote_state>"
# where remote_state is one of: synced | ahead | behind | diverged.
#
# `git status --porcelain -b` emits a leading "## " branch header carrying the
# ahead/behind counts (read from the cached remote-tracking ref, no network),
# followed by one "XY path" line per changed file. In each file line X is the
# index (staged) status and Y is the working-tree status; a file can land in
# more than one bucket at once (e.g. "MM" is both staged and modified), so the
# columns are counted independently rather than as mutually exclusive cases.
_tinyzsh_compute_git_status_counts_for_directory() {
  local directory=$1
  builtin cd -q -- "$directory" 2>/dev/null || { print -r -- "0 0 0 synced"; return }

  local porcelain
  porcelain=$(git status --porcelain=v1 -b 2>/dev/null) || {
    print -r -- "0 0 0 synced"; return
  }

  local staged_count=0
  local untracked_count=0
  local modified_count=0
  local remote_state=synced
  local line index_status worktree_status

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ ${line:0:2} == '##' ]]; then
      # Branch header, e.g. "## main...origin/main [ahead 1, behind 2]".
      if   [[ $line == *'[ahead '*'behind '* ]]; then remote_state=diverged
      elif [[ $line == *'[ahead '* ]];           then remote_state=ahead
      elif [[ $line == *'[behind '* ]];          then remote_state=behind
      fi
    elif [[ ${line:0:2} == '??' ]]; then
      (( untracked_count++ ))
    else
      index_status=${line:0:1}
      worktree_status=${line:1:1}
      [[ $index_status    != ' ' ]] && (( staged_count++ ))
      [[ $worktree_status != ' ' ]] && (( modified_count++ ))
    fi
  done <<< "$porcelain"

  print -r -- "$staged_count $untracked_count $modified_count $remote_state"
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
