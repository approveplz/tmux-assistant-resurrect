# OpenCode SQLite fallback (get_opencode_session, Method 4).
# Invoked as: python3 opencode_db.py <db_file> <cwd>
# Prints the most recently updated session id whose directory matches cwd.
import sqlite3, sys
try:
    conn = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
    cur = conn.cursor()
    cur.execute(
        'SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1',
        (sys.argv[2],))
    row = cur.fetchone()
    if row:
        print(row[0])
    conn.close()
except Exception:
    pass
