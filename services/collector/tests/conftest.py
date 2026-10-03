import os
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse

import psycopg
import pytest
from psycopg.conninfo import make_conninfo
from psycopg import sql
from werkzeug.security import generate_password_hash

sys.path.insert(0,str(Path(__file__).parents[1]))
from app import create_app, digest

@pytest.fixture
def env():
    url=os.environ.get('TEST_DATABASE_URL')
    if not url:
        pytest.skip('Set TEST_DATABASE_URL for isolated local PostgreSQL integration tests')
    parsed=urlparse(url)
    assert parsed.hostname in ('127.0.0.1','localhost') and 'collector_test' in parsed.path, 'Tests only use a dedicated loopback test database'
    schema='test_'+uuid.uuid4().hex
    with psycopg.connect(url,autocommit=True) as conn:
        conn.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
    scoped=make_conninfo(url,options='-c search_path='+schema)
    with psycopg.connect(scoped) as conn:
        conn.execute(Path(__file__).parents[1].joinpath('migrations/001_collector.sql').read_text())
        conn.execute(Path(__file__).parents[1].joinpath('migrations/002_polygon_annotations.sql').read_text())
        conn.execute(Path(__file__).parents[1].joinpath('migrations/003_archive_to_drive.sql').read_text())
        operator,project,other_operator,other_project=(str(uuid.uuid4()) for _ in range(4))
        conn.execute('INSERT INTO operators VALUES(%s,%s,%s)',(operator,'operator',generate_password_hash('collector-test-password')))
        conn.execute('INSERT INTO operators VALUES(%s,%s,%s)',(other_operator,'other',generate_password_hash('other-test-password')))
        conn.execute('INSERT INTO projects VALUES(%s,%s),(%s,%s)',(project,'Collector',other_project,'Other'))
        conn.execute('INSERT INTO project_members VALUES(%s,%s),(%s,%s)',(project,operator,other_project,other_operator))
        conn.execute("INSERT INTO auth_sessions VALUES(%s,%s,now()+interval '1 day',false),(%s,%s,now()+interval '1 day',false)",(digest('test-token'),operator,digest('other-token'),other_operator))
    app=create_app({'TESTING':True,'DATABASE_URL':scoped,'ALLOW_LOCAL_DATABASE':True,'PUBLIC_BASE_URL':'https://collector.example.com'})
    # make_conninfo returns a keyword DSN, so pass the URI with URL-encoded options instead.
    yield app,scoped,project,other_project,schema
    app.extensions['pool'].close()
    with psycopg.connect(url,autocommit=True) as conn:
        conn.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(schema)))
