# Git information shown in the prompt, split into fast and slow halves.
#
# Fast half (synchronous, runs in precmd):
#   * Are we in a git working tree? — a filesystem walk for `.git`, no fork.
#   * What's the branch name? — one `git symbolic-ref` call, reads HEAD only.
#
# Slow half (asynchronous):
#   * How many staged, untracked, and modified files? — `git status --porcelain`
#     walks the index AND the working tree, which can take 100ms+ in large repos.
#   * Is the branch in sync with origin? — `git ls-remote` makes a network round
#     trip, which is unbounded (and just hangs when offline).
#
# Both slow jobs run in backgrounded subshells whose stdout is captured into a
# file descriptor; `zle -F` notifies us when a result is ready and we call
# `zle reset-prompt` to redraw, all without ever blocking input. The two jobs
# are independent so the (local, fast-ish) file counts are never held up behind
# the (remote, slow) sync check.
#
# Results are cached by absolute directory path, so revisiting a known repo
# shows its state instantly while the new computation runs in the background.

typeset -gA _tinyzsh_git_status_cache_by_directory
typeset -gA _tinyzsh_git_remote_cache_by_directory
typeset -g  _tinyzsh_branch_name_for_current_directory=""

# Generic async-job plumbing, shared by the "status" and "remote" jobs above.
# Each job name maps to: a compute function (takes a directory, prints one
# result line) and a store function (takes that directory and the line, and
# files it into the right cache).
typeset -gA _tinyzsh_async_compute_fn_by_job
typeset -gA _tinyzsh_async_store_fn_by_job
typeset -gA _tinyzsh_async_pending_fd_by_job
typeset -gA _tinyzsh_async_pending_directory_by_job
typeset -gA _tinyzsh_async_job_by_fd

_tinyzsh_async_compute_fn_by_job[status]=_tinyzsh_compute_git_status_counts_for_directory
_tinyzsh_async_store_fn_by_job[status]=_tinyzsh_store_git_status_result
_tinyzsh_async_compute_fn_by_job[remote]=_tinyzsh_compute_git_remote_state_for_directory
_tinyzsh_async_store_fn_by_job[remote]=_tinyzsh_store_git_remote_result


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

  # Out-of-sync-with-origin sign, sitting right after the branch name. Empty
  # when up to date, offline, or the remote couldn't be reached — i.e. nothing.
  case ${_tinyzsh_git_remote_cache_by_directory[$PWD]:-} in
    ahead)  content+=" $TINYZSH_GIT_AHEAD_SIGN" ;;
    behind) content+=" $TINYZSH_GIT_BEHIND_SIGN" ;;
  esac

  local cached=${_tinyzsh_git_status_cache_by_directory[$PWD]:-}
  if [[ -n $cached ]]; then
    local parts=(${(s: :)cached})
    local staged_count=${parts[1]:-0}
    local untracked_count=${parts[2]:-0}
    local modified_count=${parts[3]:-0}
    (( untracked_count > 0 )) && content+=" ?${untracked_count}"
    (( staged_count    > 0 )) && content+=" +${staged_count}"
    (( modified_count  > 0 )) && content+=" !${modified_count}"
  fi

  print -rn -- "$content"
}


# Count staged, untracked, and modified files for $1. Designed to run in a
# subshell.
# Output (always one line):  "<staged_count> <untracked_count> <modified_count>"
#
# In `git status --porcelain` each tracked entry is "XY path", where X is the
# index (staged) status and Y is the working-tree status. A file can show up in
# more than one bucket at once (e.g. "MM" is both staged and modified), so the
# columns are counted independently rather than as mutually exclusive cases.
_tinyzsh_compute_git_status_counts_for_directory() {
  local directory=$1
  builtin cd -q -- "$directory" 2>/dev/null || { print -r -- "0 0 0"; return }

  local porcelain
  porcelain=$(git status --porcelain=v1 2>/dev/null) || {
    print -r -- "0 0 0"; return
  }

  local staged_count=0
  local untracked_count=0
  local modified_count=0
  local line index_status worktree_status

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ ${line:0:2} == '??' ]]; then
      (( untracked_count++ ))
    else
      index_status=${line:0:1}
      worktree_status=${line:1:1}
      [[ $index_status    != ' ' ]] && (( staged_count++ ))
      [[ $worktree_status != ' ' ]] && (( modified_count++ ))
    fi
  done <<< "$porcelain"

  print -r -- "$staged_count $untracked_count $modified_count"
}


# Decide whether the current branch is in sync with its origin. Designed to run
# in a subshell. Makes a network round trip via `git ls-remote` (which does NOT
# touch the repo, unlike `git fetch`).
# Output (always one line):  "" (in sync / offline / unknown) | "ahead" | "behind"
#   ahead  → we have local commits origin doesn't have yet (needs a push)
#   behind → origin has commits we don't have yet (needs a pull; also covers the
#            diverged case, since without fetching we can't see what's over there)
_tinyzsh_compute_git_remote_state_for_directory() {
  local directory=$1
  builtin cd -q -- "$directory" 2>/dev/null || { print -r --; return }

  # Bound the network wait: an offline (or slow) host must not leave `git`
  # hanging. Never block on a credential prompt either.
  export GIT_TERMINAL_PROMPT=0
  export GIT_SSH_COMMAND='ssh -o ConnectTimeout=2 -o BatchMode=yes'
  export GIT_HTTP_LOW_SPEED_LIMIT=1000
  export GIT_HTTP_LOW_SPEED_TIME=2

  # Prefer the branch's configured upstream (e.g. "origin/main"); fall back to
  # origin + the current branch name when no upstream is set.
  local upstream remote remote_branch
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null)
  if [[ -n $upstream && $upstream == */* ]]; then
    remote=${upstream%%/*}
    remote_branch=${upstream#*/}
  else
    remote=origin
    remote_branch=$(git symbolic-ref --short --quiet HEAD 2>/dev/null) || { print -r --; return }
  fi

  # `git ls-remote` output is "<sha>\t<ref>"; parse the first line in pure zsh
  # rather than forking head/cut. Empty output means offline / no such remote.
  local ls_remote_output
  ls_remote_output=$(git ls-remote --heads "$remote" "$remote_branch" 2>/dev/null) || { print -r --; return }
  [[ -z $ls_remote_output ]] && { print -r --; return }
  local first_line=${ls_remote_output%%$'\n'*}
  local remote_sha=${first_line%%[[:space:]]*}
  [[ -z $remote_sha ]] && { print -r --; return }

  local local_sha
  local_sha=$(git rev-parse HEAD 2>/dev/null) || { print -r --; return }

  if [[ $remote_sha == $local_sha ]]; then
    print -r --                                                # in sync → nothing
  elif git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
    print -r -- ahead                                          # origin is behind us
  else
    print -r -- behind                                         # origin has more (or diverged)
  fi
}


_tinyzsh_store_git_status_result() {
  local directory=$1 result=$2
  # Keep the last good counts on a transient failure rather than blanking them.
  [[ -z $result ]] && return
  _tinyzsh_git_status_cache_by_directory[$directory]=$result
}


_tinyzsh_store_git_remote_result() {
  local directory=$1 result=$2
  # Store even when empty: an empty result clears a sign that no longer applies
  # (e.g. we just pushed, or we went offline).
  _tinyzsh_git_remote_cache_by_directory[$directory]=$result
}


# Spawn every slow git computation for the current directory, each in its own
# background subshell wired to `zle -F`. Called from precmd.
_tinyzsh_kick_off_async_git_jobs_if_in_repo() {
  _tinyzsh_cancel_async_job status
  _tinyzsh_cancel_async_job remote
  _tinyzsh_is_inside_git_working_tree || return

  _tinyzsh_kick_off_async_job status
  _tinyzsh_kick_off_async_job remote
}


# Run job $1's compute function for $PWD in a backgrounded subshell and arrange
# for _tinyzsh_receive_async_job_result to be called once it produces output.
_tinyzsh_kick_off_async_job() {
  local job=$1
  _tinyzsh_cancel_async_job "$job"

  local target_directory=$PWD
  local compute_fn=$_tinyzsh_async_compute_fn_by_job[$job]
  local fd
  exec {fd}< <("$compute_fn" "$target_directory")

  _tinyzsh_async_pending_fd_by_job[$job]=$fd
  _tinyzsh_async_pending_directory_by_job[$job]=$target_directory
  _tinyzsh_async_job_by_fd[$fd]=$job

  zle -F "$fd" _tinyzsh_receive_async_job_result
}


_tinyzsh_cancel_async_job() {
  local job=$1
  local fd=$_tinyzsh_async_pending_fd_by_job[$job]
  [[ -z $fd ]] && return
  zle -F "$fd" 2>/dev/null
  exec {fd}<&- 2>/dev/null
  unset "_tinyzsh_async_job_by_fd[$fd]"
  unset "_tinyzsh_async_pending_fd_by_job[$job]"
  unset "_tinyzsh_async_pending_directory_by_job[$job]"
}


# zle -F callback: read the line the subshell produced, hand it to the job's
# store function (keyed by the directory we asked about), and trigger a redraw
# if the user is still sitting in that directory (they may have `cd`d away).
_tinyzsh_receive_async_job_result() {
  local fd=$1
  local job=$_tinyzsh_async_job_by_fd[$fd]
  local result=""
  IFS= read -r result <&$fd
  zle -F "$fd"
  exec {fd}<&-

  local computed_for=$_tinyzsh_async_pending_directory_by_job[$job]
  unset "_tinyzsh_async_job_by_fd[$fd]"
  unset "_tinyzsh_async_pending_fd_by_job[$job]"
  unset "_tinyzsh_async_pending_directory_by_job[$job]"

  local store_fn=$_tinyzsh_async_store_fn_by_job[$job]
  "$store_fn" "$computed_for" "$result"

  if [[ $PWD == $computed_for ]]; then
    zle reset-prompt 2>/dev/null
  fi
}
