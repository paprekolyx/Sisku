#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.20.0 — сборка свежей базы PostgreSQL 15 и верификация скриптов 31–32.

Паттерн run_v0190.py: свежая база sisku_v20, цепочка baseline 01–05, 09 +
инкременты 26–30 + новые 31–32; самопроверки сверяются с ожидаемыми строками;
затем смоук S1–S12 (smoke_v0200.sql), RLS под anon (справочник причин —
публичное чтение + draft-insert, delete — отказ; сессии/лист/журнал — 0 строк;
бандлы исполняются) и повторный прогон 31 (on conflict do nothing — причин
не прибавляется; drop constraint if exists — no-op).

Запуск: python3 workaichat/pgtest/run_v0200.py   (из корня клона Sisku;
нужен локальный PostgreSQL 15 и права на su postgres).
"""
import os
import shutil
import subprocess
import sys

SRC = 'supabase'
WORK = '/tmp/sisku_v20'
DB = 'sisku_v20'

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
    ('30_client_segments.sql',               't|t|t|t|t|t'),
    ('31_inventory_schema.sql',              't|t|t|t|65|t'),
    ('32_inventory_rpc.sql',                 't|t|t|t|t|t|t|t|t|28'),
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
shutil.copy('workaichat/pgtest/smoke_v0200.sql', WORK)
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

# ---------------------------------------------------------------- смоук S1–S12
rc, out, err = pg_file(os.path.join(WORK, 'smoke_v0200.sql'))
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

# ---------------------------------------------------------------- RLS под anon
# эмуляция живого Supabase: anon имеет табличные гранты (default privileges),
# доступ ограничивают политики RLS; serial-вставка — usage на последовательности
pg('grant select, insert, update, delete on all tables in schema public to anon', db=DB)
pg('grant usage, select on all sequences in schema public to anon', db=DB)
pg('grant execute on all functions in schema public to anon', db=DB)
rc, out, err = pg('set role anon; select count(*) from public.writeoff_reasons', db=DB)
if rc == 0 and out == '5':
    print('OK  RLS: anon читает справочник причин (5 строк, публичное чтение)')
else:
    fails.append('RLS writeoff_reasons под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))
rc, out, err = pg("set role anon; insert into public.writeoff_reasons (code, name) values ('anon_probe', 'Проба') returning id is not null", db=DB)
if rc == 0 and out == 't':
    print('OK  RLS: draft-insert справочника под anon работает (граница черновика — SECURITY.md)')
else:
    fails.append('RLS insert writeoff_reasons: rc=%d out=%s err=%s' % (rc, out, err[:200]))
rc, out, err = pg("set role anon; delete from public.writeoff_reasons where code = 'anon_probe'", db=DB)
if rc == 0:
    # delete без USING-политики: строки не удаляются (0 затронутых) — ошибки нет
    rc2, out2, err2 = pg("select count(*) from public.writeoff_reasons where code = 'anon_probe'", db=DB)
    if out2 == '1':
        print('OK  RLS: delete под anon бессилен (DELETE-политики нет — удаление только деактивацией)')
    else:
        fails.append('RLS delete writeoff_reasons: строка удалена (out=%s)' % out2)
else:
    fails.append('RLS delete writeoff_reasons: rc=%d err=%s' % (rc, err[:200]))
for t in ['inventory_sessions', 'inventory_items', 'writeoffs']:
    rc, out, err = pg('set role anon; select count(*) from public.%s' % t, db=DB)
    if rc == 0 and out == '0':
        print('OK  RLS: %s под anon — 0 строк (доступ только через RPC/бандлы)' % t)
    else:
        fails.append('RLS %s под anon: rc=%d out=%s err=%s' % (t, rc, out, err[:200]))
rc, out, err = pg('set role anon; select draft_inventory_bundle() is not null and draft_writeoffs_bundle() is not null', db=DB)
if rc == 0 and out == 't':
    print('OK  RPC: оба бандла под anon исполняются (SECURITY DEFINER)')
else:
    fails.append('RPC бандлы под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))
rc, out, err = pg('set role anon; select draft_clients_bundle() is not null', db=DB)
if rc == 0 and out == 't':
    print('OK  Регресс: draft_clients_bundle v3 под anon исполняется (v0.19.0)')
else:
    fails.append('Регресс draft_clients_bundle: rc=%d out=%s err=%s' % (rc, out, err[:200]))

# ------------------------------------------------- повторный прогон 31 — no-op
rc, before, err = pg('select count(*) from writeoff_reasons', db=DB)
rc2, out2, err2 = pg_file(os.path.join(WORK, '31_inventory_schema.sql'))
rc3, after, err3 = pg('select count(*) from writeoff_reasons', db=DB)
if rc2 == 0 and rc == 0 and rc3 == 0 and before == after:
    print('OK  Повторный прогон 31: no-op (причин %s → %s, drop constraint if exists)' % (before, after))
else:
    fails.append('Повторный прогон 31: rc=%d/%d до=%s после=%s err=%s' % (rc2, rc3, before, after, err2[:300]))

# ---------------------------------------------------------------- итог
print()
if fails:
    print('ИТОГ: ПРОВАЛ (%d)' % len(fails))
    for f in fails:
        print(' - ' + f)
    sys.exit(1)
print('ИТОГ: все проверки волны v0.20.0 пройдены')
