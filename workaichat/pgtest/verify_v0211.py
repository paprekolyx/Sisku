#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.21.1 — верификация консолидации SQL (методика v0.17.0).

База A (sisku_v211_a): НОВЫЙ baseline 01,02,03,04,05,09 — ДВАЖДЫ (идемпотентность).
База B (sisku_v211_b): старая цепочка 01→05,09,26→33 (/tmp/chain_v0210).
Диффы каталогов и посевов A↔B должны быть пустыми; самопроверки A — дословно;
смоук v0.20.0 + v0.21.0 — на A; RLS под anon — на A.

Запуск из /home/user/Sisku: python3 workaichat/pgtest/verify_v0211.py
"""
import os
import re
import subprocess
import sys

BASE = '/tmp/baseline_v0211'
CHAIN = '/tmp/chain_v0210'
DB_A = 'sisku_v211_a'
DB_B = 'sisku_v211_b'

BASELINE = ['01_schema.sql', '02_rls_and_access.sql', '03_functions.sql',
            '04_seed_references_and_content.sql', '05_seed_catalog.sql',
            '09_admin_bundles.sql']
OLDCHAIN = ['01_schema.sql', '02_rls_and_access.sql', '03_functions.sql',
            '04_seed_references_and_content.sql', '05_seed_catalog.sql',
            '09_admin_bundles.sql',
            '26_field_limits_and_promo_timezone.sql', '27_webp_image_paths.sql',
            '28_client_history.sql', '29_client_card_v9.sql',
            '30_client_segments.sql', '31_inventory_schema.sql',
            '32_inventory_rpc.sql', '33_badges.sql']

# ожидаемые строки самопроверок нового baseline
EXPECT_A = {
    '01_schema.sql': None,   # заполняется из комментария файла
    '02_rls_and_access.sql': None,
    '03_functions.sql': None,
    '04_seed_references_and_content.sql': None,
    '05_seed_catalog.sql': None,
    '09_admin_bundles.sql': None,
}

fails = []


def pg(sql, db='postgres'):
    r = subprocess.run(['su', 'postgres', '-c',
                        "psql -d %s -v ON_ERROR_STOP=1 -q -At -c %s"
                        % (db, "'" + sql.replace("'", "'\\''") + "'")],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def pg_file(path, db):
    r = subprocess.run(['su', 'postgres', '-c',
                        'psql -d %s -v ON_ERROR_STOP=1 -q -At -f %s' % (db, path)],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def one(sql, db):
    rc, out, err = pg(sql, db)
    assert rc == 0, (sql[:120], err[:300])
    return out


def check(cond, label):
    print(('PASS ' if cond else 'FAIL ') + label)
    if not cond:
        fails.append(label)


def fresh(db):
    pg('drop database if exists %s' % db)
    rc, out, err = pg('create database %s' % db)
    assert rc == 0, err
    for role in ['anon', 'authenticated', 'service_role']:
        pg("do $$ begin execute 'create role %s nologin'; exception when duplicate_object then null; end $$;" % role)
    pg('grant usage on schema public to anon, authenticated, service_role', db=db)


# ---------------------------------------------------------------- A: новый baseline ×2
fresh(DB_A)
subprocess.run(['chmod', '-R', 'a+rX', BASE, CHAIN], check=True)
runs = {}
for f in BASELINE:
    for rnd in (1, 2):
        rc, out, err = pg_file(os.path.join(BASE, f), DB_A)
        if rc != 0:
            fails.append('%s (прогон %d): rc=%d %s' % (f, rnd, rc, err[:400]))
            print('FAIL %s прогон %d: %s' % (f, rnd, err[:300]))
        runs[(f, rnd)] = [l for l in out.split('\n') if l.strip()]

# ожидаемые строки — из комментариев файлов («Ожидаемая строка самопроверки (psql -At): …»)
import re
for f in BASELINE:
    text = open(os.path.join(BASE, f), encoding='utf-8').read()
    m = re.findall(r'Ожидаемая строка самопроверки \(psql -At\): ([0-9t|]+)', text)
    if not m:
        fails.append('%s: нет комментария ожидаемой строки' % f)
        continue
    exp = m[-1]
    got1 = runs[(f, 1)]
    if exp in got1 and got1 == runs[(f, 2)]:
        print('PASS самопроверка %-42s %s (×2 идентично — идемпотентность)' % (f, exp))
    else:
        fails.append('%s: ожидали %s, прогон1=%s прогон2=%s' % (f, exp, got1[-3:], runs[(f, 2)][-3:]))
        print('FAIL самопроверка %s: ожидали %s, получили %s / %s' % (f, exp, got1[-3:], runs[(f, 2)][-3:]))

# ---------------------------------------------------------------- B: старая цепочка
fresh(DB_B)
for f in OLDCHAIN:
    rc, out, err = pg_file(os.path.join(CHAIN, f), DB_B)
    if rc != 0:
        fails.append('B/%s: rc=%d %s' % (f, rc, err[:400]))
        print('FAIL B/%s: %s' % (f, err[:300]))

# ---------------------------------------------------------------- диффы каталогов A↔B
def cat_dump(db):
    d = {}
    d['tables'] = one("""select c.relname || ' ' || c.relrowsecurity from pg_class c
        join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='r' order by 1""", db)
    d['columns'] = one("""select table_name||'.'||column_name||' '||data_type||' '||is_nullable||' '||coalesce(column_default,'')
        from information_schema.columns where table_schema='public'
        order by table_name, column_name""", db)
    d['constraints'] = one("""select conrelid::regclass||' '||conname||' '||pg_get_constraintdef(oid)
        from pg_constraint where connamespace='public'::regnamespace order by 1""", db)
    d['indexes'] = '\n'.join(sorted(one("""select pg_get_indexdef(indexrelid) from pg_index i
        join pg_class c on c.oid=i.indexrelid join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public'""", db).split('\n')))
    d['policies'] = '\n'.join(sorted(re.sub(r'\s+', ' ', l).strip() for l in
        one("""select tablename||' '||policyname||' '||permissive||' '||cmd||' '||
        array_to_string(roles,',')||' '||coalesce(qual,'')||' '||coalesce(with_check,'')
        from pg_policies where schemaname='public'""", db).split('\n')))
    d['functions'] = one("""select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' order by 1""", db)
    d['funcdefs'] = one("""select md5(string_agg(def, '|' order by name)) from (
          select p.proname||pg_get_function_identity_arguments(p.oid) as name,
                 replace(pg_get_functiondef(p.oid), '$function$', '$$') as def
          from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public') s""", db)
    d['comments_tables'] = one("""select c.relname||'='||coalesce(obj_description(c.oid),'')
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='r' order by 1""", db)
    d['comments_cols'] = one("""select c.relname||'.'||a.attname||'='||coalesce(col_description(c.oid,a.attnum),'')
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        join pg_attribute a on a.attrelid=c.oid
        where n.nspname='public' and c.relkind='r' and a.attnum>0 order by 1""", db)
    d['comments_funcs'] = one("""select p.proname||'='||coalesce(obj_description(p.oid,'pg_proc'),'')
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' order by 1""", db)
    d['sequences'] = one("""select sequencename from pg_sequences where schemaname='public' order by 1""", db)
    return d

da, db_ = cat_dump(DB_A), cat_dump(DB_B)
for k in da:
    if k == 'funcdefs':
        check(da[k] == db_[k], 'дифф A↔B: определения 29 функций (md5)')
    else:
        same = da[k] == db_[k]
        check(same, 'дифф A↔B: %s (%s строк)' % (k, len(da[k].split('\n'))))
        if not same:
            sa, sb = set(da[k].split('\n')), set(db_[k].split('\n'))
            for x in list(sa - sb)[:4]:
                print('   только A:', x[:160])
            for x in list(sb - sa)[:4]:
                print('   только B:', x[:160])

# ---------------------------------------------------------------- диффы посевов A↔B
SEEDS = ['order_statuses', 'status_transitions', 'payment_methods', 'delivery_methods',
         'return_reasons', 'writeoff_reasons', 'badges', 'site_content', 'brand_colors',
         'admin_users', 'brands', 'categories', 'products', 'product_variants', 'product_badges']
for t in SEEDS:
    cols = one("""select string_agg(column_name, ',' order by ordinal_position)
        from information_schema.columns
        where table_schema='public' and table_name='%s'
          and column_name not in ('created_at','updated_at')""" % t, DB_A)
    ra = one('select %s from public.%s order by 1' % (cols, t), DB_A)
    rb = one('select %s from public.%s order by 1' % (cols, t), DB_B)
    check(ra == rb, 'посев A↔B: %s (%s)' % (t, cols[:60]))
    if ra != rb:
        la, lb = ra.split('\n'), rb.split('\n')
        for i, (x, y) in enumerate(zip(la, lb)):
            if x != y:
                print('   строка %d:\n     A: %s\n     B: %s' % (i, x[:150], y[:150]))
                break
# products.created_at — застывшие даты посева (влияют на сортировку витрины)
ra = one('select article||" "||created_at from public.products order by article'.replace('"', chr(39)), DB_A)
rb = one('select article||" "||created_at from public.products order by article'.replace('"', chr(39)), DB_B)
check(ra == rb, 'посев A↔B: products.created_at (застывшие даты)')
# последовательности — last_value
for t in SEEDS:
    rc, seq, _ = pg("select coalesce(pg_get_serial_sequence('public.%s','id'),'')" % t, db=DB_A)
    seq = seq if rc == 0 else ''
    if seq:
        va = one("select last_value||'/'||is_called from %s" % seq, DB_A)
        vb = one("select last_value||'/'||is_called from %s" % seq, DB_B)
        if t == 'product_badges':
            # допуск: 05 прогоняется дважды (идемпотентность), insert-select с
            # on conflict do nothing расходует nextval — last_value A >= B,
            # семантика не страдает (уникальность гарантирует unique-констрейнт)
            la, lb = int(va.split('/')[0]), int(vb.split('/')[0])
            check(la >= lb and va.endswith('true') and vb.endswith('true'),
                  'последовательность product_badges_id_seq: A=%d >= B=%d (расход nextval при повторном прогоне — допустимо)' % (la, lb))
        else:
            check(va == vb, 'последовательность %s: %s (A) = %s (B)' % (seq.split('.')[-1], va, vb))

# ---------------------------------------------------------------- смоук на A (grant'ы как в Supabase)
pg('grant select, insert, update, delete on all tables in schema public to anon', db=DB_A)
pg('grant usage, select on all sequences in schema public to anon', db=DB_A)
pg('grant execute on all functions in schema public to anon', db=DB_A)
for smoke in ['smoke_v0200.sql', 'smoke_v0210.sql']:
    src = os.path.join('workaichat/pgtest', smoke)
    rc, out, err = pg_file(src, DB_A)
    if rc != 0:
        fails.append('%s на A: rc=%d %s' % (smoke, rc, err[:400]))
        print('FAIL %s на A: %s' % (smoke, err[:300]))
        continue
    npass = nfail = 0
    for line in out.split('\n'):
        if line.startswith('PASS'):
            npass += 1
        elif line.startswith('FAIL'):
            nfail += 1
            fails.append('%s на A: %s' % (smoke, line[:160]))
            print('   ' + line[:160])
    check(nfail == 0 and npass > 0, 'смоук %s на A: PASS %d, FAIL %d' % (smoke, npass, nfail))

# RLS под anon на A
rls_checks = [
    ("select count(*) from public.badges", '5', 'RLS A: badges читаются anon (5)'),
    ("select count(*) from public.writeoff_reasons", '5', 'RLS A: writeoff_reasons читаются anon (5)'),
    ("select count(*) from public.inventory_sessions", '0', 'RLS A: inventory_sessions под anon — 0'),
    ("select count(*) from public.writeoffs", '0', 'RLS A: writeoffs под anon — 0'),
    ("select count(*) from public.client_name_history", '0', 'RLS A: client_name_history под anon — 0'),
    ("select draft_storefront_bundle() ? 'badges'", 't', 'RLS A: бандл витрины v3 под anon'),
    ("select draft_writeoffs_bundle() is not null", 't', 'RLS A: бандл списаний под anon'),
    ("select draft_clients_bundle() is not null", 't', 'RLS A: бандл клиентов v3 под anon'),
]
for sql, exp, label in rls_checks:
    rc, out, err = pg('set role anon; ' + sql, db=DB_A)
    check(rc == 0 and out == exp, label + ' (факт: %s)' % out)

print()
if fails:
    print('ИТОГ: ПРОВАЛ (%d)' % len(fails))
    for f in fails:
        print(' - ' + f)
    sys.exit(1)
print('ИТОГ: консолидация v0.21.1 верифицирована — нулевой дифф A↔B, смоук и RLS на новом baseline пройдены')
