"""Real PostgreSQL logical restore, in a disposable loopback-only database."""
import os
import shutil
import subprocess
import uuid
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo

from app import create_app
from test_collector import AUTH,prepare,send,approve

def test_restore_recovers_images_revisions_and_frozen_export(env):
    client,data,metadata,headers=prepare(env)
    revision=send(client,data,headers).json['revision']
    assert approve(client,metadata['id'],revision).status_code==200
    version=client.post('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['id']
    link=client.post('/v1/versions/'+version+'/link',headers=AUTH).json['url'].removeprefix('https://collector.example.com')+'/archive'
    original_export=client.get(link).data
    pg_bin=Path(os.getenv('POSTGRES_BIN','/opt/homebrew/opt/postgresql@15/bin'))
    binary=shutil.which('pg_dump') or str(pg_bin/'pg_dump')
    restore_binary=shutil.which('pg_restore') or str(pg_bin/'pg_restore')
    assert binary and restore_binary, 'PostgreSQL tools are required for the restore check'
    dump=subprocess.run([binary,'--dbname',env[1],'--schema',env[4],'--format=custom','--no-owner','--no-acl'],check=True,capture_output=True).stdout
    database='collector_test_restore_'+uuid.uuid4().hex
    admin=os.environ['TEST_DATABASE_URL']
    restore_url=make_conninfo(admin,dbname=database)
    restored=None
    with psycopg.connect(admin,autocommit=True) as conn:
        conn.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(database)))
    try:
        subprocess.run([restore_binary,'--dbname',restore_url,'--no-owner','--no-acl'],input=dump,capture_output=True,check=True)
        scoped=make_conninfo(restore_url,options='-c search_path='+env[4])
        restored=create_app({'TESTING':True,'DATABASE_URL':scoped,'ALLOW_LOCAL_DATABASE':True,'PUBLIC_BASE_URL':'https://collector.example.com'})
        with restored.test_client() as recovered:
            assert recovered.get('/v1/samples/'+metadata['id']+'/image',headers=AUTH).data==data
            assert recovered.get('/v1/samples/'+metadata['id'],headers=AUTH).json['status']=='approved'
            assert recovered.get('/v1/projects/'+env[2]+'/versions',headers=AUTH).json['versions'][0]['id']==version
            assert recovered.get(link).data==original_export
    finally:
        if restored:restored.extensions['pool'].close()
        with psycopg.connect(admin,autocommit=True) as conn:
            conn.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(database)))
