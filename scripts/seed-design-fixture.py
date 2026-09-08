"""Create a new, isolated visual QA database. Refuses to modify an existing DB."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

path = Path(sys.argv[1])
if path.exists():
    raise SystemExit('Use a new database path; fixture never overwrites existing records.')
cli = Path(__file__).resolve().parents[1] / 'build/bin/noto'
subprocess.run([str(cli), 'export', '--database', str(path)], check=True, stdout=subprocess.DEVNULL)
notes = ['一个好的默认值，胜过十个设置项。', '让记录足够轻，让回看有所收获。', '观察真正的使用过程，细节会告诉我们答案。', '设计不是多加一点，而是让每一步更自然。']
now = datetime.now().astimezone()
with sqlite3.connect(path) as db:
    for day in range(55):
        stamp = (now - timedelta(days=day)).astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000')
        for row in range(2):
            text = notes[(day+row) % len(notes)]
            if day == 0 and row == 0:
                text = '最近在想，笔记工具应该像桌边的一张纸。打开就能写，写完就能放下；需要整理时，再让 AI 帮忙把零散的片段连起来。所有界面都应该服务于这个简单的过程。'
            db.execute('INSERT INTO entries (id,kind,text,due,completed,createdAt,updatedAt,hasConversation) VALUES (?,?,?,?,?,?,?,0)',
                       (f'fixture-{day:03}-{row}', 'todo' if row else 'note', text if not row else f'回顾第 {day+1} 天的想法', (now-timedelta(days=day)).strftime('%Y-%m-%d') if row else None, row == 1 and day % 3 == 0, stamp, stamp))
print(f'Created {path}: 110 records across 55 days (visual QA only)')
