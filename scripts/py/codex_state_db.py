# Codex thread-state SQLite lookup (get_codex_session, Method 3).
# Invoked as: USED_CODEX_SESSION_IDS=... python3 codex_state_db.py <codex_home> <cwd> <process_start_epoch>
import glob, os, sqlite3, sys

codex_home = sys.argv[1]
cwd = sys.argv[2]
start_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

# Find the newest state_*.sqlite by mtime.
dbs = sorted(glob.glob(os.path.join(codex_home, "state_*.sqlite")),
             key=os.path.getmtime, reverse=True)
if not dbs:
    sys.exit(0)

# Absolute epoch of the assistant process start (empty on platforms where it
# can't be determined, in which case matching falls back to most-recent).
try:
    process_start = float(start_raw) if start_raw else None
except ValueError:
    process_start = None

# Open read-only so we never conflict with a running codex writer.
try:
    con = sqlite3.connect(f"file:{dbs[0]}?mode=ro", uri=True)
except sqlite3.Error:
    sys.exit(0)

try:
    cur = con.cursor()
    cur.execute(
        "SELECT id, updated_at FROM threads "
        "WHERE cwd = ? AND archived = 0 "
        "ORDER BY updated_at DESC",
        (cwd,),
    )
    rows = cur.fetchall()
finally:
    con.close()

# Prefer threads whose last update happened after the process started
# (rules out stale threads in the same cwd). Fall back to most-recent
# overall if nothing qualifies — covers the edge case where a session
# was spawned but hasn't had any user turns yet.
def pick(rows, require_after_start):
    for sid, updated_at in rows:
        if sid in used:
            continue
        if require_after_start and process_start is not None and updated_at < process_start:
            continue
        return sid
    return None

sid = pick(rows, require_after_start=True) or pick(rows, require_after_start=False)
if sid:
    print(sid)
