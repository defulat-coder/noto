"""Release CLI workload; only seeds a new temporary database, never user data."""
import argparse
import json
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--keep-fixture', action='store_true', help='Keep the temporary database for desktop profiling')
args = parser.parse_args()
cli = Path(__file__).resolve().parents[1] / 'build/bin/noto'
directory = Path(tempfile.mkdtemp(prefix='noto-performance-'))
database = directory / 'notes.sqlite'


def run(*command):
    result = subprocess.run([str(cli), *command, '--database', str(database)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def timed(name, command, check):
    samples = []
    for _ in range(3):
        start = time.perf_counter()
        result = run(*command)
        samples.append((time.perf_counter() - start) * 1000)
        check(result)
    print(f'{name}: median {statistics.median(samples):.1f} ms (process + database + JSON)')


def count(expected):
    def check(result):
        assert len(result) == expected, (len(result), expected)
    return check


try:
    run('export')  # Use the app's real migrations.
    with sqlite3.connect(database) as db:
        rows = []
        messages = []
        for i in range(20_000):
            todo = i >= 10_000
            completed = todo and i % 3 == 0
            conversation = not todo and i % 10 == 0
            entry_id = f'perf-{i:05}'
            date = f'2026-08-{i % 28 + 1:02} 12:00:00.000'
            rows.append((entry_id, 'todo' if todo else 'note', f'记录 {i} ' + '性能排查正文。' * 20,
                         f'2026-09-{i % 28 + 1:02}' if todo and i % 5 else None,
                         completed, date, date, conversation,
                         ('completed' if completed else 'pending') if todo else None,
                         ('important' if i % 7 == 0 else 'normal') if todo else None,
                         date if completed else None))
            if conversation:
                messages.extend([(entry_id, 'user', '问题', date), (entry_id, 'assistant', 'conversation-needle ' + '回答。' * 100, date)])
        db.executemany('INSERT INTO entries (id,kind,text,due,completed,createdAt,updatedAt,hasConversation,status,priority,completedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?)', rows)
        db.executemany('INSERT INTO messages (entryID,role,text,createdAt) VALUES (?,?,?,?)', messages)
    print('Fixture: 20,000 entries; 10,000 tasks; 1,000 conversations / 2,000 messages')
    timed('list notes', ['note', 'list'], count(10_000))
    timed('list tasks', ['todo', 'list'], count(10_000))
    timed('search conversation', ['search', 'conversation-needle'], count(1_000))
    def check_update(result):
        assert result['id'] == 'perf-00001' and result['text'] == '更新单条'
    timed('update one note', ['note', 'update', '--id', 'perf-00001', '--text', '更新单条'], check_update)
    def check_backup(result):
        assert len(result['entries']) == 20_000 and len(result['conversations']) == 1_000
        assert all(len(messages) == 2 for messages in result['conversations'].values())
    timed('export with conversations', ['export', '--include-conversations'], check_backup)
    print(f'PASS; database: {database}')
finally:
    if not args.keep_fixture:
        shutil.rmtree(directory)
