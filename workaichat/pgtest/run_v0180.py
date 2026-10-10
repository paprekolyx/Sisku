#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.18.0 — сборка свежей базы PostgreSQL 15 и верификация скриптов 28–29.

Повторяет паттерн verify.py волны v0.17.0: свежая база sisku_v18, цепочка
baseline 01–05, 09 + инкременты 26–27 + новые 28–29; самопроверки каждого
скрипта сверяются с ожидаемыми строками; затем смоук S1–S6, S7 (RLS под
anon) и S8 (повторный прогон 28 — no-op).

Запуск: python3 workaichat/pgtest/run_v0180.py   (из корня клона Sisku;
нужен локальный PostgreSQL 15 и права на su postgres).
"""
import os
import shutil
import subprocess
import sys

SRC = 'supabase'
WORK = '/tmp/sisku_v18'
DB = 'sisku_v18'

CHAIN = [
    ('01_schema.sql',                        '22|22|1|1|1|5|2'),
    ('02_rls_and_access.sql',                '62|22|14|15|11|0'),
    ('03_functions.sql',                     '12|t|t|t|5'),
    ('04_seed_references_and_content.sql',   '7|8|3|4|1|0|4|70|18|0|20|1'),
    ('05_seed_catalog.sql',                  '6|6|8|20|8'),
    ('09_admin_bundles.sql',                 '18|6|t|t|t'),
    ('26_field_limits_and_promo_timezone.sql', '3|t|2|t|t'),
    ('27_webp_image_paths.sql',              '8|0|0'),
    ('28_client_history.sql',                't|t|t|t|t|t'),
    ('29_client_card_v9.sql',                't|t|t|t|t|t|20'),
]

fails = []


def pg(sql, db='postgres', at=True):
    flags = ['-At'] if at else []
    r = subprocess.run(['su', 'postgres', '-c',
                        'psql -d %s -v ON_ERROR_STOP=1 -q %s -c %s'
                        % (db, ' '.join(flags), shell_quote(sql))],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def pg_file(path, db=DB):
    r = subprocess.run(['su', 'postgres', '-c',
                        'psql -d %s -v ON_ERROR_STOP=1 -q -At -f %s'
                        % (db, path)], capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


# ---------------------------------------------------------------- подготовка
if os.path.isdir(WORK):
    shutil.rmtree(WORK)
os.makedirs(WORK)
for f in os.listdir(SRC):
    if f.endswith('.sql'):
        shutil.copy(os.path.join(SRC, f), WORK)
shutil.copy('workaichat/pgtest/smoke_v0180.sql', WORK)
subprocess.run(['chmod', '-R', 'a+rX', WORK], check=True)

rc, out, err = pg('drop database if exists %s' % DB)
assert rc == 0, err
rc, out, err = pg('create database %s' % DB)
assert rc == 0, err

# роли Supabase (политики 02 ссылаются на anon/authenticated)
for role in ['anon', 'authenticated', 'service_role']:
    sql = ("do $$ begin execute 'create role " + role + " nologin'; "
           "exception when duplicate_object then null; end $$;")
    pg(sql)
pg('grant usage on schema public to anon, authenticated, service_role', db=DB)

# ---------------------------------------------------------------- цепочка
for fname, expect in CHAIN:
    rc, out, err = pg_file(os.path.join(WORK, fname))
    lines = [l for l in out.split('\n') if l.strip()]
    if rc != 0:
        fails.append('%s: psql rc=%d\n%s' % (fname, rc, err[:800]))
        continue
    if expect in lines:
        print('OK  %-42s самопроверка: %s' % (fname, expect))
    else:
        fails.append('%s: самопроверка — ожидали «%s», получили «%s»'
                     % (fname, expect, ' / '.join(lines[-3:])))

# ---------------------------------------------------------------- смоук S1–S6
rc, out, err = pg_file(os.path.join(WORK, 'smoke_v0180.sql'))
if rc != 0:
    fails.append('smoke: psql rc=%d\n%s' % (rc, err[:800]))
else:
    passes = 0
    for line in out.split('\n'):
        if not line.strip():
            continue
        print('    ' + line)
        if line.startswith('FAIL'):
            fails.append('smoke: ' + line)
        elif line.startswith('PASS'):
            passes += 1
    print('    смоук: PASS %d, FAIL %d' % (passes, len([f for f in fails if f.startswith('smoke')])))

# ---------------------------------------------------------------- S7: RLS под anon
pg('grant select on all tables in schema public to anon', db=DB)
pg('grant execute on all functions in schema public to anon', db=DB)
rc, out, err = pg('set role anon; select count(*) from public.client_name_history', db=DB)
if rc == 0 and out == '0':
    print('OK  S7 RLS: anon видит 0 строк client_name_history (политик нет)')
else:
    fails.append('S7 RLS client_name_history: rc=%d out=%s err=%s' % (rc, out, err[:200]))
rc, out, err = pg('set role anon; select count(*) from public.client_contact_history', db=DB)
if rc == 0 and out == '0':
    print('OK  S7 RLS: anon видит 0 строк client_contact_history')
else:
    fails.append('S7 RLS client_contact_history: rc=%d out=%s err=%s' % (rc, out, err[:200]))
rc, out, err = pg('set role anon; select draft_client_card_bundle(1) is not null', db=DB)
if rc == 0 and out == 't':
    print('OK  S7 RPC: draft_client_card_bundle под anon исполняется (SECURITY DEFINER)')
else:
    fails.append('S7 RPC под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

# ---------------------------------------------------------------- S8: повторный прогон 28 — no-op
rc, before, err = pg('select (select count(*) from client_name_history) || \'|\' || (select count(*) from client_contact_history)', db=DB)
rc2, out2, err2 = pg_file(os.path.join(WORK, '28_client_history.sql'))
rc3, after, err3 = pg('select (select count(*) from client_name_history) || \'|\' || (select count(*) from client_contact_history)', db=DB)
if rc2 == 0 and rc == 0 and rc3 == 0 and before == after:
    print('OK  S8 повторный прогон 28: no-op (строк %s → %s)' % (before, after))
else:
    fails.append('S8: rc=%d/%d до=%s после=%s err=%s' % (rc2, rc3, before, after, err2[:300]))

# ---------------------------------------------------------------- итог
print()
if fails:
    print('ИТОГ: ПРОВАЛ (%d)' % len(fails))
    for f in fails:
        print(' - ' + f)
    sys.exit(1)
print('ИТОГ: все проверки волны v0.18.0 пройдены')
