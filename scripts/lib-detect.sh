#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   descendant_processes <pid> [ps_snapshot] — prints every descendant
#   pane_has_assistant <pane_pid> [ps_snapshot] — returns 0 + prints PID if found

# --- detect_tool ---
# Match the executable token, with an optional interpreter token, rather than
# any later mention of an assistant path. This distinction matters for recorder
# wrappers such as:
#
#   script -q /tmp/capture /opt/homebrew/bin/codex
#
# The wrapper is not Codex; the real Codex child is discovered separately by
# the process-tree walk.
#
# Handles: /path/to/claude, claude --resume ..., node /path/to/claude, etc.
# Excludes: opencode run ... (LSP subprocesses)
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
		case "$args" in
		*"opencode run "*) ;;
		*) echo "opencode" ;;
		esac
		;;
	codex | codex-*)
		# app-server is an internal helper spawned by Codex tools, not a
		# resumable TUI. It may appear before its parent TUI in macOS ps output,
		# so accepting it here can make the saver assign the wrong rollout.
		case "$tool_args" in
		app-server | app-server\ *) ;;
		*) echo "codex" ;;
		esac
		;;
	esac
}

# --- descendant_processes ---
# Print every descendant of a process without relying on ps output order.
#
# macOS can return a child before its parent in `ps -eo` output. Build the full
# parent map first, then repeatedly expand the reachable set. Output preserves
# snapshot order, but callers do not depend on that order.
descendant_processes() {
	local root_pid="$1"
	local snapshot="${2:-$(ps -eo pid=,ppid=,args= 2>/dev/null)}"

	printf '%s\n' "$snapshot" | awk -v root="$root_pid" '
		{
			pid[NR] = $1
			ppid[NR] = $2
			args[NR] = substr($0, index($0, $3))
		}
		END {
			reachable[root] = 1
			do {
				changed = 0
				for (i = 1; i <= NR; i++) {
					if ((ppid[i] in reachable) && !(pid[i] in reachable)) {
						reachable[pid[i]] = 1
						changed = 1
					}
				}
			} while (changed)

			for (i = 1; i <= NR; i++) {
				if ((pid[i] in reachable) && pid[i] != root) {
					print pid[i], ppid[i], args[i]
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
