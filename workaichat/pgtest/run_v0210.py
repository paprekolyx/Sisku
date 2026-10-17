#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.21.0 — сборка свежей базы PostgreSQL 15 и верификация скрипта 33.

Паттерн run_v0200.py: свежая база sisku_v21, цепочка baseline 01–05, 09 +
инкременты 26–32 + новый 33; самопроверки сверяются с ожидаемыми строками
(33 — методика Д11: проектные функции по явному списку = 29, политики 72);
затем смоук S1–S8 (smoke_v0210.sql), RLS под anon (badges — публичное чтение
+ draft-insert, delete бессилен; product_badges — draft-CRUD полностью;
RPC draft_save_product_badges и бандл v3 под anon исполняются) и повторный
прогон 33 (on conflict do nothing — no-op).

Запуск: python3 workaichat/pgtest/run_v0210.py   (из корня клона Sisku;
нужен локальный PostgreSQL 15 и права на su postgres).
"""
import json
import os
import shutil
import subprocess
import sys

SRC = 'supabase'
WORK = '/tmp/sisku_v21'
DB = 'sisku_v21'

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
    ('33_badges.sql',                        't|t|t|t|t|t|72|29|t'),
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
shutil.copy('workaichat/pgtest/smoke_v0210.sql', WORK)
subprocess.run(['chmod', '-R', 'a+rX', WORK], check=True)

rc, out, err = pg('drop database if exists %s' % DB)
assert rc == 0, err
rc, out, err = pg('create database %s' % DB)
assert rc == 0, err

# роли Supabase (политики 02/33 ссылаются на anon/authenticated)
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

# ---------------------------------------------------------------- смоук S1–S8
rc, out, err = pg_file(os.path.join(WORK, 'smoke_v0210.sql'))
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
    print('    смоук: PASS %d, FAIL %d'
          % (passes, len([f for f in fails if f.startswith('smoke')])))

# ---------------------------------------------------------------- RLS под anon
# эмуляция живого Supabase: anon имеет табличные гранты (default privileges),
# доступ ограничивают политики RLS; serial-вставка — usage на последовательности
pg('grant select, insert, update, delete on all tables in schema public to anon', db=DB)
pg('grant usage, select on all sequences in schema public to anon', db=DB)
pg('grant execute on all functions in schema public to anon', db=DB)

rc, out, err = pg('set role anon; select count(*) from public.badges', db=DB)
if rc == 0 and out == '5':
    print('OK  RLS: anon читает справочник бейджей (5 строк, публичное чтение)')
else:
    fails.append('RLS badges под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg("set role anon; insert into public.badges (code, name) "
                  "values ('anon_probe', 'Проба') returning id is not null", db=DB)
if rc == 0 and out == 't':
    print('OK  RLS: draft-insert справочника бейджей под anon работает '
          '(граница черновика — SECURITY.md)')
else:
    fails.append('RLS insert badges: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg("set role anon; delete from public.badges "
                  "where code = 'anon_probe'", db=DB)
if rc == 0:
    rc2, out2, err2 = pg("select count(*) from public.badges where code = 'anon_probe'", db=DB)
    if out2 == '1':
        print('OK  RLS: delete бейджа под anon бессилен (DELETE-политики нет — '
              'удаление только деактивацией)')
    else:
        fails.append('RLS delete badges: строка удалена (out=%s)' % out2)
else:
    fails.append('RLS delete badges: rc=%d err=%s' % (rc, err[:200]))
pg("delete from public.badges where code = 'anon_probe'", db=DB)  # чистка суперпользователем

rc, out, err = pg('set role anon; select count(*) from public.product_badges', db=DB)
if rc == 0 and out.isdigit() and int(out) >= 8:
    print('OK  RLS: anon читает назначения product_badges (%s строк — draft-чтение)' % out)
else:
    fails.append('RLS product_badges select: rc=%d out=%s err=%s' % (rc, out, err[:200]))

# draft-CRUD product_badges под anon: insert → update → delete пробы
rc, out, err = pg('set role anon; insert into public.product_badges '
                  '(product_id, badge_id, sort_order) '
                  '(select p.id, b.id, 99 from products p, badges b '
                  " where b.code = 'soon' order by p.id limit 1) "
                  'returning id is not null', db=DB)
if rc == 0 and out == 't':
    rc2, out2, err2 = pg('set role anon; update public.product_badges '
                         'set sort_order = 98 where sort_order = 99 '
                         'returning id is not null', db=DB)
    rc3, out3, err3 = pg('set role anon; delete from public.product_badges '
                         'where sort_order = 98 returning id is not null', db=DB)
    if rc2 == 0 and out2 == 't' and rc3 == 0 and out3 == 't':
        print('OK  RLS: draft-CRUD product_badges под anon (insert/update/delete '
              '— граница черновика, как каталог)')
    else:
        fails.append('RLS product_badges CRUD: upd rc=%d out=%s; del rc=%d out=%s'
                     % (rc2, out2, rc3, out3))
else:
    fails.append('RLS product_badges insert: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg("set role anon; select draft_save_product_badges(jsonb_build_object("
                  "'product_id', (select id from products order by id limit 1), "
                  "'badge_ids', jsonb_build_array((select id from badges where code = 'new'))"
                  "))->>'ok'", db=DB)
if rc == 0 and out == 'true':
    print('OK  RPC: draft_save_product_badges под anon исполняется (SECURITY DEFINER)')
else:
    fails.append('RPC draft_save_product_badges под anon: rc=%d out=%s err=%s'
                 % (rc, out, err[:200]))

rc, out, err = pg("set role anon; select (draft_storefront_bundle() ? 'badges') "
                  "and (draft_storefront_bundle() ? 'product_badges')", db=DB)
if rc == 0 and out == 't':
    print('OK  RPC: draft_storefront_bundle v3 под anon — ключи badges/product_badges')
else:
    fails.append('Бандл v3 под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

rc, out, err = pg('set role anon; select draft_clients_bundle() is not null '
                  'and draft_writeoffs_bundle() is not null', db=DB)
if rc == 0 and out == 't':
    print('OK  Регресс: draft_clients_bundle v3 / draft_writeoffs_bundle под anon '
          '(v0.19.0/v0.20.0)')
else:
    fails.append('Регресс бандлов под anon: rc=%d out=%s err=%s' % (rc, out, err[:200]))

# ------------------------------------------------- повторный прогон 33 — no-op
rc, before_b, err = pg('select count(*) from badges', db=DB)
rc0, before_pb, err0 = pg('select count(*) from product_badges', db=DB)
rc2, out2, err2 = pg_file(os.path.join(WORK, '33_badges.sql'))
rc3, after_b, err3 = pg('select count(*) from badges', db=DB)
rc4, after_pb, err4 = pg('select count(*) from product_badges', db=DB)
if (rc2 == 0 and rc == 0 and rc3 == 0 and rc0 == 0 and rc4 == 0
        and before_b == after_b and before_pb == after_pb):
    print('OK  Повторный прогон 33: no-op (бейджей %s → %s, назначений %s → %s; '
          'on conflict do nothing + create or replace)'
          % (before_b, after_b, before_pb, after_pb))
else:
    fails.append('Повторный прогон 33: rc=%d/%d до=%s/%s после=%s/%s err=%s'
                 % (rc2, rc3, before_b, before_pb, after_b, after_pb, err2[:300]))

# ------------------------------------------------- S9: статика фронтенда
site_js = open('assets/js/site.js', encoding='utf-8').read()
prod_js = open('assets/js/products.js', encoding='utf-8').read()
hc_site = '30 * 864e5' in site_js
hc_prod = '30 * 864e5' in prod_js
if (not hc_site and not hc_prod
        and 'product_badges' in site_js and 'renderBadges' in site_js
        and 'draft_save_product_badges' in prod_js and 'pf-badges' in prod_js):
    print('OK  S9 статика: хардкод «New по created_at» убран (site.js, '
          'products.js), рендер product_badges/renderBadges и RPC '
          'draft_save_product_badges на месте')
else:
    fails.append('S9 статика: hc_site=%s hc_prod=%s product_badges=%s '
                 'renderBadges=%s rpc=%s pf-badges=%s'
                 % (hc_site, hc_prod, 'product_badges' in site_js,
                    'renderBadges' in site_js,
                    'draft_save_product_badges' in prod_js,
                    'pf-badges' in prod_js))

# ---------------------------------------------------------------- итог
print()
if fails:
    print('ИТОГ: ПРОВАЛ (%d)' % len(fails))
    for f in fails:
        print(' - ' + f)
    sys.exit(1)
print('ИТОГ: все проверки волны v0.21.0 пройдены')
