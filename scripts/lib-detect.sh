#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   descendant_processes <pid> [ps_snapshot] — prints every descendant
#   pane_has_assistant <pane_pid> [ps_snapshot] — returns 0 + prints PID if found
#   resurrect_data_dir           — prints tmux-resurrect's save directory

# --- detect_tool ---
# Match the executable token, with an optional interpreter token, rather than
# any later mention of an assistant path. Recorder wrappers can include the
# future executable in their arguments; the actual assistant is discovered as
# a separate child by the process-tree walk.
#
# Handles: /path/to/claude, claude, claude --resume ..., opencode -s ...,
#          codex resume ..., pi --session ..., omp --resume ..., grok --resume ..., etc.
# Excludes: Codex app-server, opencode run (LSP), and OMP worker subprocesses.
detect_tool() {
	local args="$1"
	local executable="${args%% *}"
	local executable_name="${executable##*/}"
	local remainder=""
	local tool_args=""

	case "$executable_name" in
	node | nodejs | bun | bash | sh | zsh)
		remainder="${args#"$executable"}"
		remainder="${remainder# }"
		executable="${remainder%% *}"
		executable_name="${executable##*/}"
		tool_args="${remainder#"$executable"}"
		;;
	*)
		tool_args="${args#"$executable"}"
		;;
	esac
	tool_args="${tool_args# }"

	case "$executable_name" in
	claude) echo "claude" ;;
	opencode)
		# Exclude LSP/language server subprocesses
		case "$tool_args" in
		run | run\ *) ;;
		*) echo "opencode" ;;
		esac
		;;
	codex | codex-*-*-*)
		# app-server is an internal helper, not a resumable TUI.
		case "$tool_args" in
		app-server | app-server\ *) ;;
		*) echo "codex" ;;
		esac
		;;
	pi) echo "pi" ;;
	omp)
		# Exclude hidden OMP worker subprocesses; their process title can also be "omp".
		case "$tool_args" in
		__omp_worker_* | *" __omp_worker_"*) ;;
		*) echo "omp" ;;
		esac
		;;
	grok) echo "grok" ;;
	esac
}

# --- descendant_processes ---
# Print descendants in breadth-first order without relying on ps output order.
# Building the full parent map first matters on macOS, where a child can appear
# before its parent in `ps -eo` output.
descendant_processes() {
	local root_pid="$1"
	local snapshot="${2:-$(ps -eo pid=,ppid=,args= 2>/dev/null)}"

	printf '%s\n' "$snapshot" | awk -v root="$root_pid" '
		{
			pid = $1 + 0
			ppid = $2 + 0
			line = $0
			sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
			parent[pid] = ppid
			args[pid] = line
			children[ppid] = (ppid in children) ? children[ppid] SUBSEP pid : "" pid
		}
		END {
			qs = 1
			qe = 0
			if (root in children) {
				n = split(children[root], child, SUBSEP)
				for (i = 1; i <= n; i++) {
					candidate = child[i] + 0
					if (candidate > 0) queue[++qe] = candidate
				}
			}
			while (qs <= qe) {
				current = queue[qs++] + 0
				print current, parent[current], args[current]
				if (current in children) {
					n = split(children[current], child, SUBSEP)
					for (i = 1; i <= n; i++) {
						candidate = child[i] + 0
						if (candidate > 0) queue[++qe] = candidate
					}
				}
			}
		}
	'
}

# --- pane_has_assistant ---
# Check if a pane has a running assistant anywhere in its process tree.
# Checks the pane PID itself (exec-replaced shells) AND walks the full
# descendant tree (handles wrappers like npx, env, direnv, bash -lc).
#
# Usage: pane_has_assistant <pane_shell_pid> [ps_snapshot]
# If ps_snapshot is not provided, takes a fresh snapshot.
# Returns 0 and prints the assistant PID if found, returns 1 otherwise.
pane_has_assistant() {
	local shell_pid="$1"
	local snapshot="${2:-$(ps -eo pid=,ppid=,args= 2>/dev/null)}"

	# Check the pane PID itself (handles exec-replaced shells, e.g. exec claude)
	local pane_args
	pane_args=$(echo "$snapshot" | awk -v pid="$shell_pid" '$1 == pid {print substr($0, index($0,$3)); exit}')
	if [ -n "$(detect_tool "$pane_args")" ]; then
		echo "$shell_pid"
		return 0
	fi

	local found_pid
	found_pid=$(descendant_processes "$shell_pid" "$snapshot" |
		while read -r cpid _ppid cargs; do
			if [ -n "$(detect_tool "$cargs")" ]; then
				echo "$cpid"
				break
			fi
		done)

	if [ -n "$found_pid" ]; then
		echo "$found_pid"
		return 0
	fi

	return 1
}

# --- posix_quote ---
# POSIX-safe single-quote escaping.  Wraps value in single quotes and
# replaces embedded single quotes with the sequence '"'"' which closes
# the single-quoted string, adds an escaped single quote in double quotes,
# and re-opens the single-quoted string.
#
# Safe for bash, zsh, sh, dash, and fish (fish accepts single-quoted strings).
posix_quote() {
	local val="$1"
	# Replace each ' with '"'"'
	val="${val//\'/\'\"\'\"\'}"
	printf "'%s'" "$val"
}

# --- resurrect_data_dir ---
# Print the directory tmux-resurrect saves into, resolved the SAME way resurrect
# resolves it itself (scripts/helpers.sh:resurrect_dir). Our sidecar files
# (assistant-sessions.json, *.log) and the pane_contents.tar.gz we rewrite must
# live next to resurrect's own saves, so this has to track resurrect's logic
# rather than assume a fixed location.
#
# Resolution order:
#   1. $TMUX_RESURRECT_DIR        — explicit override (tests / unusual setups)
#   2. @resurrect-dir tmux option — when the user set one
#   3. ~/.tmux/resurrect          — when that directory already exists (legacy default)
#   4. ${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect — modern (XDG) default
#
# Why this matters — do NOT hardcode ~/.tmux/resurrect: on an XDG install that
# directory does not exist, so resurrect saves under ~/.local/share. Writing our
# files to ~/.tmux/resurrect anyway would not only split them away from
# resurrect's real saves, it would `mkdir` that directory — and resurrect's own
# dir-exists check (step 3) would then flip the user's save location to it on the
# next run, silently migrating their data and orphaning prior saves.
#
# Mirrors resurrect's expansion of ~, $HOME and $HOSTNAME inside @resurrect-dir.
resurrect_data_dir() {
	if [ -n "${TMUX_RESURRECT_DIR:-}" ]; then
		echo "$TMUX_RESURRECT_DIR"
		return
	fi

	local dir
	dir=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
	if [ -z "$dir" ]; then
		if [ -d "$HOME/.tmux/resurrect" ]; then
			dir="$HOME/.tmux/resurrect"
		else
			dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
		fi
	fi

	local host
	host=$(hostname 2>/dev/null || true)
	echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}
