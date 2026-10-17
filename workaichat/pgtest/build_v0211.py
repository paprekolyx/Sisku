#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.21.1 — консолидация SQL: сборка нового baseline (01,02,03,04,05,09)
из эталонной базы sisku_ref (прогон полной цепочки 01→33 состояния v0.21.0).

Методика v0.17.0 (build_baseline.py): схема (таблицы/индексы) извлекается из
исходных скриптов (проектный стиль), политики/функции/комментарии/посевы —
генерируются из КАТАЛОГА эталонной базы (гарантия совпадения конечного
состояния по построению); грабля №16 — нормализация $function$ → $$.

Запуск из /home/user/Sisku:  python3 workaichat/pgtest/build_v0211.py
Выход: /tmp/baseline_v0211/*.sql  (6 файлов) + печать самопроверочных строк.
"""
import os
import re
import shutil
import subprocess
import sys

SRC = 'supabase'                     # текущие скрипты (baseline v0.16.0 + 26–33)
CHAIN_DIR = '/tmp/chain_v0210'       # замороженная копия цепочки для эталона
OUT = '/tmp/baseline_v0211'
DB = 'sisku_ref'

CHAIN = ['01_schema.sql', '02_rls_and_access.sql', '03_functions.sql',
         '04_seed_references_and_content.sql', '05_seed_catalog.sql',
         '09_admin_bundles.sql',
         '26_field_limits_and_promo_timezone.sql', '27_webp_image_paths.sql',
         '28_client_history.sql', '29_client_card_v9.sql',
         '30_client_segments.sql', '31_inventory_schema.sql',
         '32_inventory_rpc.sql', '33_badges.sql']

# итоговые наборы функций (порядок — для секций генерируемых файлов)
CORE = ['draft_phone_key', 'draft_email_key', 'check_promo', 'create_order',
        'admin_set_status', 'admin_set_paid', 'track_order', 'draft_save_look',
        'create_return_request', 'admin_set_return_status',
        'admin_set_return_refund', 'admin_resolve_quarantine',
        'admin_update_client',
        'admin_create_inventory_session', 'admin_start_inventory_session',
        'admin_cancel_inventory_session', 'admin_save_inventory_items',
        'admin_finish_inventory_session', 'admin_create_writeoff',
        'draft_save_product_badges']
BUNDLES = ['draft_reserved_map', 'draft_admin_bundle', 'draft_assembly_bundle',
           'draft_clients_bundle', 'draft_storefront_bundle',
           'draft_returns_bundle', 'draft_client_card_bundle',
           'draft_inventory_bundle', 'draft_writeoffs_bundle']
SEED04 = ['order_statuses', 'status_transitions', 'payment_methods',
          'delivery_methods', 'return_reasons', 'writeoff_reasons', 'badges',
          'site_content', 'brand_colors', 'admin_users']
SEED05 = ['brands', 'categories', 'products', 'product_variants']


def pg(sql, db='postgres'):
    r = subprocess.run(['su', 'postgres', '-c',
                        "psql -d %s -v ON_ERROR_STOP=1 -q -At -c %s"
                        % (db, "'" + sql.replace("'", "'\\''") + "'")],
                       capture_output=True, text=True)
    assert r.returncode == 0, 'SQL FAIL: %s\n%s' % (sql[:200], r.stderr[:800])
    return r.stdout


def pg_file(path, db=DB):
    r = subprocess.run(['su', 'postgres', '-c',
                        'psql -d %s -v ON_ERROR_STOP=1 -q -At -f %s' % (db, path)],
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def q(sql):
    """многострочный запрос в эталонной базе — список строк"""
    return pg(sql, db=DB).rstrip('\n').split('\n') if pg(sql, db=DB) else []


# ---------------------------------------------------------------- 0. копия цепочки
if os.path.isdir(CHAIN_DIR):
    shutil.rmtree(CHAIN_DIR)
os.makedirs(CHAIN_DIR)
for f in os.listdir(SRC):
    if f.endswith('.sql'):
        shutil.copy(os.path.join(SRC, f), CHAIN_DIR)
subprocess.run(['chmod', '-R', 'a+rX', CHAIN_DIR], check=True)

# ---------------------------------------------------------------- 1. эталонная база
pg('drop database if exists %s' % DB)
pg('create database %s' % DB)
for role in ['anon', 'authenticated', 'service_role']:
    try:
        pg("do $$ begin execute 'create role %s nologin'; exception when duplicate_object then null; end $$;" % role)
    except AssertionError:
        pass
pg('grant usage on schema public to anon, authenticated, service_role', db=DB)
for f in CHAIN:
    rc, out, err = pg_file(os.path.join(CHAIN_DIR, f))
    assert rc == 0, '%s: %s' % (f, err[:600])
print('Эталонная база %s собрана цепочкой из %d скриптов' % (DB, len(CHAIN)))

# контрольные счётчики эталона
n_tables = int(pg("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'", db=DB))
n_policies = int(pg("select count(*) from pg_policies where schemaname='public'", db=DB))
n_funcs = int(pg("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'", db=DB))
n_keys = int(pg("select count(*) from public.site_content", db=DB))
n_rls = int(pg("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and c.relrowsecurity", db=DB))
print('Эталон: таблиц %d (RLS %d), политик %d, функций %d, ключей site_content %d'
      % (n_tables, n_rls, n_policies, n_funcs, n_keys))
assert n_tables == 30 and n_policies == 72 and n_funcs == 29 and n_keys == 73, 'счётчики эталона вне ожидания'

if os.path.isdir(OUT):
    shutil.rmtree(OUT)
os.makedirs(OUT)

# ---------------------------------------------------------------- 2. извлечение CREATE TABLE из исходников
def extract_tables(files):
    """имя → текст create table (последнее вхождение wins)"""
    out = {}
    for f in files:
        text = open(os.path.join(CHAIN_DIR, f), encoding='utf-8').read()
        for m in re.finditer(r'create table if not exists public\.(\w+)\s*\((.*?)\n\);',
                             text, re.S):
            out[m.group(1)] = 'create table if not exists public.%s (%s\n);' % (m.group(1), m.group(2))
    return out

tables = extract_tables(['01_schema.sql', '28_client_history.sql',
                         '31_inventory_schema.sql', '33_badges.sql'])
assert len(tables) == 30, 'таблиц извлечено %d (ждём 30)' % len(tables)

# АН-21 вариант (б): CHECK stock >= 0 в новом baseline НЕ создаётся (снятие зашито)
pv = tables['product_variants']
pv_new = pv.replace(' not null default 0 check (stock >= 0)', ' not null default 0')
assert pv_new != pv, 'CHECK stock не найден в product_variants'
tables['product_variants'] = pv_new.replace(
    'stock     integer not null default 0',
    'stock     integer not null default 0')  # стиль сохранён; минус допустим с v0.20.0

# топосортировка по FK
deps = {}
for name, ddl in tables.items():
    deps[name] = set(re.findall(r'references public\.(\w+)', ddl)) - {name}
order = []
while deps:
    ready = sorted(n for n, d in deps.items() if not (d - set(order)))
    assert ready, 'цикл FK: %s' % deps
    order.extend(ready)
    for n in ready:
        del deps[n]

# индексы — из каталога эталона (только явные, не constraint-бэкинг;
# регэксп-извлечение из исходников пропускало многострочные операторы)
idx = {}
for line in pg("""select c.relname || E'\\x01' || replace(pg_get_indexdef(i.indexrelid), chr(10), ' ')
       from pg_index i
       join pg_class c on c.oid = i.indexrelid
       join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'\n         and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid)
       order by c.relname""", db=DB).rstrip('\n').split('\n'):
    name, ddl = line.split('\x01', 1)
    ddl = ddl.replace('CREATE INDEX ', 'create index if not exists ', 1)
    ddl = ddl.replace('CREATE UNIQUE INDEX ', 'create unique index if not exists ', 1)
    idx[name] = ddl + ';'

# регион «колонки и констрейнты исторических волн» — дословно из старого 01
_old01 = open(os.path.join(CHAIN_DIR, '01_schema.sql'), encoding='utf-8').read()
_m = re.search(r'(-- 2\. Колонки и констрейнты.*?)\n-- 3\. Индексы', _old01, re.S)
assert _m, 'регион ALTER/DO в старом 01 не найден'
ALTERS_REGION = _m.group(1).strip()

# ---------------------------------------------------------------- 3. комментарии из каталога
def gen_comments():
    lines = []
    # табличные комментарии
    for raw in pg("""select c.relname || E'\\x01' || replace(replace(obj_description(c.oid), E'\\x01',''), chr(10), ' ')
                     from pg_class c join pg_namespace n on n.oid=c.relnamespace
                     where n.nspname='public' and c.relkind='r' and obj_description(c.oid) is not null
                     order by relname""", db=DB).rstrip('\n').split('\n'):
        t, txt = raw.split('\x01', 1)
        lines.append("comment on table public.%s is '%s';" % (t, txt.replace("'", "''")))
    for raw in pg("""select c.relname || '.' || a.attname || E'\\x01' ||
                            replace(replace(col_description(c.oid, a.attnum), E'\\x01',''), chr(10), ' ')
                     from pg_class c
                     join pg_namespace n on n.oid=c.relnamespace
                     join pg_attribute a on a.attrelid=c.oid
                     where n.nspname='public' and c.relkind='r' and a.attnum>0
                       and col_description(c.oid, a.attnum) is not null
                     order by c.relname, a.attnum""", db=DB).rstrip('\n').split('\n'):
        tc, txt = raw.split('\x01', 1)
        t, col = tc.split('.', 1)
        lines.append("comment on column public.%s.%s is '%s';" % (t, col, txt.replace("'", "''")))
    return lines

comments = gen_comments()

# ---------------------------------------------------------------- 4. политики из каталога
def gen_policies():
    lines = []
    rows = pg("""select tablename || E'\\x01' || policyname || E'\\x01' || cmd || E'\\x01' ||
                        array_to_string(roles, ',') || E'\\x01' || coalesce(qual,'') || E'\\x01' || coalesce(with_check,'')
                 from pg_policies where schemaname='public'
                 order by tablename, policyname""", db=DB).rstrip('\n').split('\n')
    for raw in rows:
        t, name, cmd, roles, qual, wc = raw.split('\x01')
        s = 'drop policy if exists %s on public.%s;\n' % (name, t)
        s += 'create policy %s on public.%s\n    as permissive\n    for %s\n    to %s' % (name, t, cmd.lower(), roles)
        if qual:
            s += '\n    using (%s)' % qual
        if wc:
            s += '\n    with check (%s)' % wc
        lines.append(s + ';')
    return lines, len(rows)

policies, n_pol = gen_policies()
assert n_pol == 72, n_pol

# ---------------------------------------------------------------- 5. функции из каталога (грабля №16)
def gen_function(name):
    d = pg("""select pg_get_functiondef(p.oid) from pg_proc p
              join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='%s'""" % name, db=DB).rstrip('\n')
    assert d, 'функция %s не найдена' % name
    if '$function$' in d:
        body = d.split('$function$')[1] if d.count('$function$') == 2 else ''
        assert '$' not in body.replace('$function$', ''), 'в теле %s есть $ — нормализация небезопасна' % name
        d = d.replace('$function$', '$$')
    assert d.count('$$') % 2 == 0, 'непарные $$ в %s' % name
    cmt = pg("""select coalesce(obj_description(p.oid,'pg_proc'),'') from pg_proc p
                join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname='%s'""" % name, db=DB).strip()
    if not d.endswith(';'):
        d += ';'
    out = d
    if cmt:
        out += "\n\ncomment on function public.%s is '%s';" % (name, cmt.replace('\n', ' ').replace("'", "''"))
    return out

# ---------------------------------------------------------------- 6. посевы из каталога
def gen_seed(table, conflict='do nothing'):
    """insert-строки из эталона; created_at/updated_at — только «застывшие» (не сегодняшние)"""
    cols = pg("""select column_name from information_schema.columns
                 where table_schema='public' and table_name='%s'
                 order by ordinal_position""" % table, db=DB).rstrip('\n').split('\n')
    # определяем, какие timestamp-колонки несут застывшие значения (посевыпрежних скриптов)
    keep = list(cols)
    for tc in ('created_at', 'updated_at'):
        if tc in cols:
            mx = pg("select coalesce(max(%s)::date < current_date, false) from public.%s" % (tc, table), db=DB).strip()
            if mx != 't':
                keep.remove(tc)
    collist = ', '.join(keep)
    sel = ', '.join(("quote_nullable(%s)" % c) if c not in ('id',) else "%s::text" % c for c in keep)
    has_id = 'id' in cols
    order_by = 'order by id' if has_id else 'order by ' + ', '.join(keep)
    rows = pg("select '(' || concat_ws(', ', %s) || ')' from public.%s %s" % (sel, table, order_by), db=DB)
    lines = []
    for r in rows.rstrip('\n').split('\n') if rows.strip() else []:
        lines.append('insert into public.%s (%s) values %s on conflict %s;' % (table, collist, r, conflict))
    if has_id:
        lines.append("select setval(pg_get_serial_sequence('public.%s', 'id'), (select coalesce(max(id), 1) from public.%s));" % (table, table))
    return lines

N_IDX = int(pg("select count(*) from pg_indexes where schemaname='public'", db=DB))

# ---------------------------------------------------------------- 7. сборка файлов
def w(name, text):
    open(os.path.join(OUT, name), 'w', encoding='utf-8').write(text)
    print('создан', name, '—', len(text), 'байт')

HDR = ('-- ============================================================================\n'
       '--  SISKU (черновик) — СКРИПТ %s: %s\n'
       '-- ============================================================================\n'
       '--  КОНСОЛИДИРОВАННЫЙ BASELINE, ревизия 2 (волна v0.21.1, 17.10.2026):\n'
       '--  состояние базы на v0.21.0 шестью скриптами (первая ревизия — v0.17.0,\n'
       '--  состояние на v0.16.0; инкременты 26–33 поглощены — замороженный архив\n'
       '--  supabase/archive/sql-26-33-v0210.md). Baseline ЗАМОРОЖЕН (правило 9):\n'
       '--  правки — только новыми инкрементами с номера 34.\n'
       '--  Живая база НЕ перезапускается (модель F21): baseline — только для\n'
       '--  новых стендов; живая база получает инкременты ≥ 34.\n'
       '--  Идемпотентен: create if not exists / drop-create policy / on conflict\n'
       '--  do nothing / create or replace. Порядок: 01 → 02 → 03 → 04 → 05 → 09.\n'
       '-- ============================================================================\n')

# ---- 01 схема
s = HDR % ('01', 'схема — все 30 таблиц конечного состояния (консолидация v0.21.1)')
s += '\n-- 0. Префлайт не требуется — скрипт 01 открывает цепочку\n'
s += '\n-- 1. Таблицы (30; порядок — по FK-зависимостям)\n'
for t in order:
    s += '\n' + tables[t] + '\n'
s += '\n-- 2. Колонки и констрейнты исторических волн (дословно из baseline ревизии 1;\n--    все операторы идемпотентны)\n'
s += ALTERS_REGION + '\n'
s += '\n-- 3. Индексы\n'
for k in sorted(idx):
    s += idx[k] + '\n'
s += '\n-- 3. RLS включён на всех таблицах (политики — скрипт 02)\n'
for t in order:
    s += 'alter table public.%s enable row level security;\n' % t
s += '\n-- 4. Комментарии (конечное состояние каталога)\n'
s += '\n'.join(comments) + '\n'
s += """
-- ----------------------------------------------------------------------------
-- 5. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r')                        as tables_30,   -- ждём 30
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity)   as rls_30,      -- ждём 30
    (select count(*) = 0 from pg_constraint where conname = 'product_variants_stock_check')
                                                                             as no_stock_check, -- ждём t (АН-21 (б))
    (select count(*) from pg_indexes where schemaname = 'public')            as indexes;      -- ждём %d
-- Ожидаемая строка самопроверки (psql -At): 30|30|t|%d
""" % (N_IDX, N_IDX)
w('01_schema.sql', s)

CMD_COUNTS = tuple(int(pg("select count(*) from pg_policies where schemaname='public' and cmd='%s'" % c, db=DB)) for c in ['SELECT', 'INSERT', 'UPDATE', 'DELETE'])

# ---- 02 RLS
s = HDR % ('02', 'RLS и доступ — все 72 политики конечного состояния (консолидация v0.21.1)')
s += '\n-- 0. Префлайт: все таблицы должны существовать (скрипт 01)\ndo $$\nbegin\n'
for t in order:
    s += "    if to_regclass('public.%s') is null then\n        raise exception 'Скрипт 02: таблица %s не найдена — сначала выполните 01_schema.sql';\n    end if;\n" % (t, t)
s += 'end\n$$;\n\n-- 1. Политики (72; сгенерированы из конечного состояния каталога)\n'
s += '\n\n'.join(policies) + '\n'
s += """
-- ----------------------------------------------------------------------------
-- 2. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_policies where schemaname = 'public')           as policies_72,  -- ждём 72
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'SELECT')  as sel,   -- ждём %d
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'INSERT')  as ins,   -- ждём %d
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'UPDATE')  as upd,   -- ждём %d
    (select count(*) from pg_policies where schemaname = 'public' and cmd = 'DELETE')  as del,   -- ждём %d
    (select count(*) from pg_policies where schemaname = 'public'
      and tablename in ('return_requests') and cmd in ('INSERT','UPDATE','DELETE'))    as rr_direct_write; -- ждём 0
-- Ожидаемая строка самопроверки (psql -At): 72|%d|%d|%d|%d|0
""" % (CMD_COUNTS + CMD_COUNTS)
w('02_rls_and_access.sql', s)

# ---- 03 функции ядра
s = HDR % ('03', 'функции ядра записи — 20 конечных версий (консолидация v0.21.1)')
s += '\n-- Функции сгенерированы из конечного состояния каталога эталонной базы\n-- (create or replace; порядок — ядро заказа → возвраты → клиенты →\n--  инвентаризация/списания → бейджи)\n'
for name in CORE:
    s += '\n-- ---------- %s ----------\n' % name
    s += gen_function(name) + '\n'
s += """
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array[%s]))            as core_20,     -- ждём 20
    (select obj_description(oid,'pg_proc') like 'v9%%' from pg_proc where proname = 'create_order')  as order_v9,   -- ждём t
    (select obj_description(oid,'pg_proc') like 'v2%%' from pg_proc where proname = 'check_promo')  as promo_v2,   -- ждём t
    (select to_regprocedure('public.draft_save_product_badges(jsonb)') is not null)                 as badges_rpc; -- ждём t
-- Ожидаемая строка самопроверки (psql -At): 20|t|t|t
""" % ', '.join("'%s'" % n for n in CORE)
w('03_functions.sql', s)

# ---- 09 бандлы
s = HDR % ('09', 'бандлы чтения — 9 конечных версий (консолидация v0.21.1)')
s += '\n-- Бандлы — один запрос на страницу (грабля №4/№6); сгенерированы из\n-- конечного состояния каталога эталонной базы\n'
for name in BUNDLES:
    s += '\n-- ---------- %s ----------\n' % name
    s += gen_function(name) + '\n'
s += """
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array[%s]))            as bundles_9,   -- ждём 9
    (select obj_description(oid,'pg_proc') like 'v3%%' from pg_proc where proname = 'draft_clients_bundle')    as clients_v3,   -- ждём t
    (select obj_description(oid,'pg_proc') like 'v3%%' from pg_proc where proname = 'draft_storefront_bundle') as storefront_v3,-- ждём t
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                            as funcs_total_29; -- ждём 29
-- Ожидаемая строка самопроверки (psql -At): 9|t|t|29
""" % ', '.join("'%s'" % n for n in BUNDLES)
w('09_admin_bundles.sql', s)

# ---- 04 посевы справочников и контента
s = HDR % ('04', 'посевы справочников и контента конечного состояния (консолидация v0.21.1)')
s += '\n-- Посевы сгенерированы из эталонной базы; вставка — только отсутствующих\n-- строк (on conflict do nothing — культура F21); setval — последовательности\n'
for t in SEED04:
    s += '\n-- ---------- %s ----------\n' % t
    s += '\n'.join(gen_seed(t)) + '\n'
s += """
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.order_statuses)                             as statuses_7,   -- ждём 7
    (select count(*) from public.status_transitions)                         as transitions_8,-- ждём 8
    (select count(*) from public.payment_methods)                            as payments_3,   -- ждём 3
    (select count(*) from public.delivery_methods)                           as deliveries_4, -- ждём 4
    (select count(*) from public.delivery_methods where code = 'pochtaruss') as pochtaruss_1, -- ждём 1
    (select count(*) from public.delivery_methods where name ilike '%%boxberry%%') as boxberry_0, -- ждём 0
    (select count(*) from public.return_reasons)                             as rr_4,         -- ждём 4
    (select count(*) from public.writeoff_reasons)                           as wr_5,         -- ждём 5
    (select count(*) from public.badges)                                     as badges_5,     -- ждём 5
    (select count(*) from public.site_content)                               as keys_73,      -- ждём 73
    (select count(*) from public.site_content where key like 'returns.%%')    as returns_18,   -- ждём 18
    (select count(*) from public.site_content where key like 'segments.%%')   as segments_3,   -- ждём 3
    (select count(*) from public.brand_colors)                               as colors_20,    -- ждём 20
    (select count(*) from public.admin_users)                                as admins_1;     -- ждём 1
-- Ожидаемая строка самопроверки (psql -At): 7|8|3|4|1|0|4|5|5|73|18|3|20|1
"""
w('04_seed_references_and_content.sql', s)

# ---- 05 посев каталога
s = HDR % ('05', 'посев каталога конечного состояния (консолидация v0.21.1; альтернатива импорту CSV)')
s += '\n-- Демонстрационный каталог (8 товаров, 20 вариантов); «Тестовый товар»\n-- владельца (00001) — данные живой базы, в посев не входят\n'
for t in SEED05:
    s += '\n-- ---------- %s ----------\n' % t
    s += '\n'.join(gen_seed(t)) + '\n'
s += """
-- ---------- бейдж «New» — всем товарам (волна v0.21.0, ответ 1.9/Д7) ----------
insert into public.product_badges (product_id, badge_id, sort_order)
select p.id, b.id, 1
  from public.products p
 cross join public.badges b
 where b.code = 'new'
on conflict (product_id, badge_id) do nothing;

-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.brands)                                     as brands_6,    -- ждём 6
    (select count(*) from public.categories)                                 as cats_6,      -- ждём 6
    (select count(*) from public.products)                                   as products_8,  -- ждём 8
    (select count(*) from public.product_variants)                           as variants_20, -- ждём 20
    (select count(*) from public.products where image_url like '%%.jpg')      as jpg_0,       -- ждём 0
    (select (select count(*) from public.product_badges pb
              join public.badges b on b.id = pb.badge_id
             where b.code = 'new')
          = (select count(*) from public.products))                          as new_all;     -- ждём t
-- Ожидаемая строка самопроверки (psql -At): 6|6|8|20|0|t
"""
w('05_seed_catalog.sql', s)

print()
print('Готово: /tmp/baseline_v0211 — 6 файлов. Следующий шаг — verify_v0211.py'
      ' (две свежие базы, нулевой дифф, смоук).')
