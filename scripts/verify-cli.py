"""Run the public CLI contract end-to-end against a disposable database."""
import json
from pathlib import Path
import subprocess
import tempfile

cli = Path(__file__).resolve().parents[1] / 'build/bin/noto'
with tempfile.TemporaryDirectory(prefix='noto-cli-qa-') as directory:
    database = str(Path(directory) / 'test.sqlite')
    def run(*args, fails=False):
        result = subprocess.run([str(cli), *args, '--database', database], capture_output=True, text=True)
        if fails:
            assert result.returncode != 0, result.stdout
            return
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    note = run('note', 'add', '--text', '端到端记录', '--request-id', 'qa-note')
    assert run('note', 'add', '--text', '端到端记录', '--request-id', 'qa-note')['id'] == note['id']
    run('note', 'add', '--text', '冲突内容', '--request-id', 'qa-note', fails=True)
    todo = run('todo', 'add', '--title', '整理设计规范', '--due', '2026-09-09')
    assert run('todo', 'complete', '--id', todo['id'])['completed']
    assert len(run('todo', 'list', '--status', 'completed')) == 1
    assert not run('todo', 'reopen', '--id', todo['id'])['completed']
    updated = run('todo', 'update', '--id', todo['id'], '--title', '核对设计规范', '--clear-due')
    assert updated.get('due') is None
    run('todo', 'update', '--id', todo['id'], '--due', '2026-02-30', fails=True)
    run('note', 'update', '--id', note['id'], '--text', '修改后的小记')
    assert run('search', '修改后')[0]['id'] == note['id']
    assert run('search', '不存在的关键词') == []
    backup = run('export', '--include-conversations')
    assert len(backup['entries']) == 2 and backup['conversations'] == {}
    print('PASS: create, idempotency, conflict, complete, filter, reopen, edit, clear date, invalid date, search, export')
