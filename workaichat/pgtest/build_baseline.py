#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.17.0 — сборка консолидированного baseline SQL (01,02,03,04,05,09)
и инкрементов (26,27) из эталонной базы sisku_a (прогон старой цепочки 01→25).

Принцип: схема (таблицы/ALTER/индексы/RLS) извлекается из исходных скриптов
(сохраняются проектный стиль и проверенные идемпотентные паттерны); функции,
политики, комментарии и посевы — генерируются из КАТАЛОГА эталонной базы
(гарантия совпадения конечного состояния по построению).

Запуск из /home/user: python3 pgtest/build_baseline.py
Выход: /tmp/baseline/*.sql
"""
import os
import re
import subprocess

import pglast

SUP = '/tmp/oldchain'  # исторические скрипты 01–25 (копия до консолидации)
OUT = '/tmp/baseline'
DB = 'sisku_a'

CORE12 = ['draft_phone_key', 'draft_email_key', 'check_promo', 'create_order',
          'admin_set_status', 'admin_set_paid', 'track_order', 'draft_save_look',
          'create_return_request', 'admin_set_return_status',
          'admin_set_return_refund', 'admin_resolve_quarantine']
BUNDLES6 = ['draft_reserved_map', 'draft_admin_bundle', 'draft_assembly_bundle',
            'draft_clients_bundle', 'draft_storefront_bundle', 'draft_returns_bundle']
SEED04 = ['order_statuses', 'status_transitions', 'payment_methods',
          'delivery_methods', 'return_reasons', 'site_content', 'brand_colors']
SEED05 = ['brands', 'categories', 'products', 'product_variants']


def psql(query, db=DB):
    r = subprocess.run(['psql', '-d', db, '-At', '-c', query],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[:500]
    return r.stdout


def psql_file(path, db=DB):
    r = subprocess.run(['psql', '-d', db, '-v', 'ON_ERROR_STOP=1', '-q',
                        '-f', path], capture_output=True, text=True)
    return r


# ---------------------------------------------------------------------------
# 1. Разбор исходных скриптов: таблицы, ALTER, DO-констрейнты, индексы, RLS
# ---------------------------------------------------------------------------
files = sorted(f for f in os.listdir(SUP) if re.match(r'^\d{2}_.*\.sql$', f))
assert len(files) == 25, files

tables = {}          # name -> текст create table (первое вхождение)
table_order = []
alters = []          # (порядок, текст) — не RLS
constraint_dos = []
indexes = {}
constraint_comments = []
rls = set()
warn = []

for fi, fn in enumerate(files):
    sql = open(os.path.join(SUP, fn), encoding='utf-8').read()
    for st in pglast.parse_sql(sql):
        loc, ln = st.stmt_location, st.stmt_len
        text = (sql[loc:loc + ln] if ln else sql[loc:]).strip()
        low = re.sub(r'\s+', ' ', text.lower())
        if low.startswith('create table'):
            m = re.match(r'create table (if not exists )?public\.(\w+)', low)
            assert m, text[:80]
            name = m.group(2)
            if not m.group(1):
                text = text.replace('create table public.', 'create table if not exists public.', 1) \
                    if text.startswith('create table public.') else \
                    re.sub(r'(?i)^create table public\.', 'create table if not exists public.', text)
            if name not in tables:
                tables[name] = text
                table_order.append(name)
        elif low.startswith('comment on constraint'):
            constraint_comments.append(text)
        elif low.startswith('comment on'):
            pass  # комментарии таблиц/колонок/функций берём из каталога БД
        elif low.startswith('alter table') and 'enable row level security' in low:
            m = re.match(r'alter table public\.(\w+)', low)
            rls.add(m.group(1))
        elif low.startswith('alter table'):
            if text not in [t for _, t in alters]:
                alters.append((fi, text))
        elif low.startswith('do'):
            if 'pg_constraint' in low:
                constraint_dos.append((fi, text))
            elif 'to_regclass' in low:
                pass  # префлайты — заменяются единым в 02
            elif 'insert into' in low or 'update ' in low:
                pass  # DO-блоки исторических data-миграций (15) — на свежей базе не нужны
            else:
                warn.append((fn, text[:100]))
        elif low.startswith('create index') or low.startswith('create unique index'):
            m = re.search(r'index (if not exists )?(\w+)', low)
            indexes[m.group(2)] = text
        elif (low.startswith(('create policy', 'drop policy', 'drop function',
                              'drop index', 'create function',
                              'create or replace function', 'insert into',
                              'update ', 'delete from', 'select', 'truncate',
                              'grant', 'revoke'))):
            pass  # генерируется из эталонной БД / самопроверки / историческая миграция
        else:
            warn.append((fn, text[:100]))

print('таблиц:', len(tables), '| alters:', len(alters), '| DO-констрейнтов:',
      len(constraint_dos), '| индексов:', len(indexes), '| RLS:', len(rls))
assert len(tables) == 22 and len(rls) == 22, (len(tables), len(rls))
for w in warn:
    print('WARN неклассифицировано:', w)

# ---------------------------------------------------------------------------
# 2. Функции из каталога эталонной БД
# ---------------------------------------------------------------------------
raw = psql("select proname || E'\\x03' || pg_get_functiondef(p.oid) || E'\\x02' "
           "from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
           "where n.nspname = 'public' order by proname")
funcs = {}
for chunk in raw.split('\x02'):
    chunk = chunk.strip('\n')
    if not chunk:
        continue
    name, body = chunk.split('\x03', 1)
    if body.startswith('CREATE FUNCTION'):
        body = 'CREATE OR REPLACE FUNCTION' + body[len('CREATE FUNCTION'):]
    # регlament проекта: доллар-квоты только парные $$ (check-repo, правило 4);
    # pg_get_functiondef выдаёт $function$ — нормализуем, если тело не содержит $
    if '$function$' in body:
        inner = body.split('$function$', 1)[1].rsplit('$function$', 1)[0]
        assert '$' not in inner, 'в теле %s есть $ — нормализация небезопасна' % name
        body = body.replace('$function$', '$$')
    funcs[name] = body.rstrip()
assert set(funcs) == set(CORE12) | set(BUNDLES6), set(funcs) ^ (set(CORE12) | set(BUNDLES6))

# комментарии функций из каталога
fcomments = {}
raw = psql("select proname || E'\\x03' || coalesce(obj_description(p.oid), '') || E'\\x02' "
           "from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
           "where n.nspname = 'public'")
for chunk in raw.split('\x02'):
    chunk = chunk.strip('\n')
    if not chunk:
        continue
    name, c = chunk.split('\x03', 1)
    if c:
        fcomments[name] = c

# ---------------------------------------------------------------------------
# 3. Политики из каталога (финальное состояние, 62 шт.)
# ---------------------------------------------------------------------------
order_arr = "array[" + ','.join("'%s'" % t for t in table_order) + "]"
pol_sql = ("select format('drop policy if exists %I on public.%I;\n"
           "create policy %I on public.%I\n"
           "    as %s\n"
           "    for %s\n"
           "    to %s%s%s;' || E'\\x02',\n"
           "  policyname, tablename, policyname, tablename, lower(permissive), lower(cmd),\n"
           "  array_to_string(roles, ', '),\n"
           "  coalesce(E'\\n    using (' || qual || ')', ''),\n"
           "  coalesce(E'\\n    with check (' || with_check || ')', ''))\n"
           "from pg_policies where schemaname = 'public'\n"
           "order by array_position(@ORDER@, tablename), policyname").replace('@ORDER@', order_arr)
raw = psql(pol_sql)
policies = [p for p in raw.split('\x02') if p.strip()]
assert len(policies) == 62, len(policies)

# ---------------------------------------------------------------------------
# 4. Комментарии таблиц/колонок из каталога
# ---------------------------------------------------------------------------
def q(s):
    return "'" + s.replace("'", "''") + "'"


tab_comments = []
raw = psql("select relname || E'\\x03' || obj_description(c.oid) || E'\\x02' "
           "from pg_class c join pg_namespace n on n.oid = c.relnamespace "
           "where n.nspname = 'public' and c.relkind = 'r' "
           "and obj_description(c.oid) is not null order by relname")
for chunk in raw.split('\x02'):
    chunk = chunk.strip('\n')
    if chunk:
        name, c = chunk.split('\x03', 1)
        tab_comments.append('comment on table public.%s is %s;' % (name, q(c)))

col_comments = []
raw = psql("""
select c.relname || '.' || a.attname || E'\\x03' ||
       col_description(c.oid, a.attnum) || E'\\x02'
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid
where n.nspname = 'public' and c.relkind = 'r'
  and a.attnum > 0 and not a.attisdropped
  and col_description(c.oid, a.attnum) is not null
order by c.relname, a.attnum""")
for chunk in raw.split('\x02'):
    chunk = chunk.strip('\n')
    if chunk:
        tgt, c = chunk.split('\x03', 1)
        t, col = tgt.split('.', 1)
        col_comments.append('comment on column public.%s.%s is %s;' % (t, col, q(c)))

n_comments = len(tab_comments) + len(col_comments) + len(fcomments) + len(constraint_comments)
print('комментариев: таблиц %d, колонок %d, функций %d, констрейнтов %d (всего %d)' % (
    len(tab_comments), len(col_comments), len(fcomments), len(constraint_comments), n_comments))
assert n_comments == 49, n_comments

# ---------------------------------------------------------------------------
# 5. Посевы из data-дампа эталонной БД (guard: on conflict do nothing)
# ---------------------------------------------------------------------------
data_sql = open('/tmp/data_a.sql', encoding='utf-8').read()
data_sql = '\n'.join(l for l in data_sql.split('\n') if not l.startswith('\\'))
seeds = {t: [] for t in SEED04 + SEED05}
setvals = {t: [] for t in SEED04 + SEED05}
for st in pglast.parse_sql(data_sql):
    loc, ln = st.stmt_location, st.stmt_len
    text = (data_sql[loc:loc + ln] if ln else data_sql[loc:]).strip()
    low = text.lower()
    m = re.match(r'insert into public\.(\w+)', low)
    if m:
        seeds[m.group(1)].append(text.rstrip(';') + ' on conflict do nothing;')
        continue
    m = re.search(r"setval\('public\.(\w+)_id_seq'", text)
    if m:
        setvals[m.group(1)].append(text.rstrip(';') + ';')
        continue
    if low.startswith('set ') or low.startswith('select pg_catalog.'):
        continue
    raise AssertionError('неожиданное в data-дампе: ' + text[:80])
for t in SEED04 + SEED05:
    assert seeds[t], t
    assert len(setvals[t]) <= 1, (t, setvals[t])

# ---------------------------------------------------------------------------
# 6. Ожидаемые значения самопроверок — из эталонной БД
# ---------------------------------------------------------------------------
exp = {}
exp['tables'] = int(psql("select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'").strip())
exp['rls'] = int(psql("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relrowsecurity").strip())
exp['policies'] = int(psql("select count(*) from pg_policies where schemaname='public'").strip())
for cmd in ('SELECT', 'INSERT', 'UPDATE', 'DELETE'):
    exp['pol_' + cmd.lower()] = int(psql("select count(*) from pg_policies where schemaname='public' and cmd='%s'" % cmd).strip())
exp['indexes'] = int(psql("select count(*) from pg_indexes where schemaname='public' and indexname like 'idx_%' or schemaname='public' and indexname like 'return_%'").strip())
exp['fn'] = int(psql("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'").strip())
exp['rr_write_policies'] = int(psql("select count(*) from pg_policies where schemaname='public' and tablename='return_requests' and cmd in ('INSERT','UPDATE','DELETE')").strip())
exp['constraints_named'] = psql("select string_agg(conname, ',' order by conname) from pg_constraint where conname in ('orders_total_nonneg','product_variants_quarantine_nonneg')").strip()
for t, key in [('order_statuses', 'statuses'), ('status_transitions', 'transitions'),
               ('payment_methods', 'payments'), ('delivery_methods', 'deliveries'),
               ('return_reasons', 'reasons'), ('site_content', 'keys'),
               ('brand_colors', 'colors'), ('brands', 'brands'),
               ('categories', 'categories'), ('products', 'products'),
               ('product_variants', 'variants')]:
    exp[key] = int(psql('select count(*) from public.%s' % t).strip())
exp['returns_keys'] = int(psql("select count(*) from site_content where key like 'returns.%'").strip())
exp['boxberry'] = int(psql("select count(*) from delivery_methods where code='boxberry'").strip())
exp['pochtaruss'] = int(psql("select count(*) from delivery_methods where code='pochtaruss'").strip())
exp['content_boxberry'] = int(psql("select count(*) from site_content where value ilike '%boxberry%'").strip())
exp['jpg_paths'] = int(psql("select count(*) from products where image_url like 'assets/img/products/%.jpg'").strip())
print('ожидаемые значения:', exp)
assert (exp['tables'], exp['rls'], exp['policies'], exp['fn'], exp['keys']) == (22, 22, 62, 18, 70)
assert exp['constraints_named'] == 'orders_total_nonneg,product_variants_quarantine_nonneg'

os.makedirs(OUT, exist_ok=True)
HDR = """-- ============================================================================
--  SISKU (черновик) — СКРИПТ %s: %s
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты %s.
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: %s
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================
"""


def w(name, text):
    path = os.path.join(OUT, name)
    open(path, 'w', encoding='utf-8').write(text)
    print('записан', path, len(text), 'симв.')


# ---- 01_schema.sql ---------------------------------------------------------
parts = [HDR % ('1', 'схема — все таблицы конечного состояния (22)',
                '01, 07, 10, 13, 14, 15, 16 (схема/констрейнты), 19, 21, 22 (таблицы), 23 (колонка)',
                'create table if not exists, add column if not exists, DO-guard констрейнты, create index if not exists.')]
parts.append('\n-- 1. Таблицы (порядок исходных скриптов — FK-цели создаются раньше)\n')
for t in table_order:
    parts.append(tables[t] + ';\n')
parts.append('\n-- 2. Колонки и констрейнты, добавленные историческими волнами\n')
for _, a in alters:
    parts.append(a + ';\n')
for _, d in constraint_dos:
    parts.append(d + ';\n')
for c in constraint_comments:
    parts.append(c + ';\n')
parts.append('\n-- 3. Индексы\n')
for i in indexes.values():
    parts.append(i + ';\n')
parts.append('\n-- 4. Включение RLS (все 22 таблицы)\n')
for t in table_order:
    assert t in rls, t
    parts.append('alter table public.%s enable row level security;' % t)
parts.append('\n-- 5. Комментарии\n')
parts.extend(c + '\n' for c in tab_comments)
parts.extend(c + '\n' for c in col_comments)
parts.append("""
-- ----------------------------------------------------------------------------
-- 6. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from information_schema.tables
      where table_schema = 'public' and table_type = 'BASE TABLE')      as tables_ok,      -- ждём 22
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relrowsecurity)                  as rls_ok,         -- ждём 22
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'product_variants'
        and column_name = 'quarantine_qty')                             as quarantine_col, -- ждём 1
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'clients'
        and column_name = 'name_confirmed')                             as name_conf_col,  -- ждём 1
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'admin_users'
        and column_name = 'phone')                                      as phone_col,      -- ждём 1
    (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'orders'
        and column_name in ('client_id','promo_discount','look_discount',
                            'promo_code_id','look_id'))                 as orders_cols,    -- ждём 5
    (select count(*) from pg_constraint
      where conname in ('orders_total_nonneg',
                        'product_variants_quarantine_nonneg'))          as wave_constraints; -- ждём 2
""")
w('01_schema.sql', '\n'.join(parts))

# ---- 02_rls_and_access.sql -------------------------------------------------
preflight_tables = ',\n        '.join("'%s'" % t for t in table_order)
parts = [HDR % ('2', 'политики RLS — все 62 политики конечного состояния',
                '02, 07 (политики), 09–16 (политики), 22, 23',
                'drop policy if exists + create policy; префлайт to_regclass по всем таблицам.')]
parts.append("""
-- ----------------------------------------------------------------------------
-- 0. Префлайт: все таблицы должны существовать (скрипт 01 выполнен)
-- ----------------------------------------------------------------------------
do $$
declare
    t text;
begin
    foreach t in array array[
        %s
    ] loop
        if to_regclass('public.' || t) is null then
            raise exception 'Sisku draft: не найдена таблица %% (скрипт 02). Сначала выполните скрипт 01 и проверьте переключатель проектов Supabase: нужен sisku-draft.', t;
        end if;
    end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Политики (группировка по таблицам; чтение каталога и справочников
--    публичное — using (true) (фикс F09/V4); draft-anon-CRUD — осознанная
--    граница черновика (SECURITY.md §3); запись заявок на возврат — только
--    через RPC (прямых политик нет); удаление причин возврата — только
--    деактивацией (DELETE-политики нет)
-- ----------------------------------------------------------------------------""" % preflight_tables)
for p in policies:
    parts.append(p.strip() + '\n')
parts.append("""
-- ----------------------------------------------------------------------------
-- 2. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_policies where schemaname = 'public')      as policies_ok,     -- ждём 62
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'SELECT')                   as select_policies, -- ждём %d
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'INSERT')                   as insert_policies, -- ждём %d
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'UPDATE')                   as update_policies, -- ждём %d
    (select count(*) from pg_policies
      where schemaname = 'public' and cmd = 'DELETE')                   as delete_policies, -- ждём %d
    (select count(*) from pg_policies
      where schemaname = 'public' and tablename = 'return_requests'
        and cmd in ('INSERT','UPDATE','DELETE'))                        as request_write_policies; -- ждём 0 (запись только через RPC)
""" % (exp['pol_select'], exp['pol_insert'], exp['pol_update'], exp['pol_delete']))
w('02_rls_and_access.sql', '\n'.join(parts))

# ---- 03_functions.sql / 09_admin_bundles.sql -------------------------------
def fn_block(names, title, num, replaces, fn_total):
    parts = [HDR % (num, title, replaces, 'create or replace function — тела конечных версий (v0.16.0).')]
    for n in names:
        parts.append('\n-- ---------- %s ----------\n' % n)
        parts.append(funcs[n] + ';\n')
        if n in fcomments:
            parts.append("\ncomment on function public.%s is %s;\n" % (n, q(fcomments[n])))
    return parts

parts = fn_block(CORE12, 'функции ядра (12) — конечные версии на v0.16.0', '3',
                 '03, 10 (check_promo, track_order v1), 16 (create_order v6), 17, 18, 19 (create_order v7), 22 (track_order v2, RPC возвратов), 23 (admin_set_status v4, admin_resolve_quarantine)', 12)
parts.append("""
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                       as functions_total, -- ждём 12
    (select prosrc like '%name_confirmed%' from pg_proc
      where proname = 'create_order')                                   as create_order_v7, -- ждём t
    (select prosrc like '%quarantine_qty = quarantine_qty + v_item.quantity%'
      from pg_proc where proname = 'admin_set_status')                  as set_status_v4,   -- ждём t
    (select prosrc like '%return_available%' from pg_proc
      where proname = 'track_order')                                    as track_v2,        -- ждём t
    (select count(*) from pg_proc where proname in
      ('create_return_request','admin_set_return_status',
       'admin_set_return_refund','admin_resolve_quarantine',
       'draft_save_look'))                                              as wave_fns;        -- ждём 5
""")
w('03_functions.sql', '\n'.join(parts))

parts = fn_block(BUNDLES6, 'бандлы чтения (6) — конечные версии на v0.16.0', '09',
                 '09, 13 (draft_reserved_map v1), 15 (admin/clients v2), 16 (storefront v1, reserved_map v2), 22 (storefront v2, returns), 23 (assembly v2)', 6)
parts.append("""
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                       as functions_total,   -- ждём 18
    (select count(*) from pg_proc where proname in
      ('draft_admin_bundle','draft_assembly_bundle','draft_clients_bundle',
       'draft_storefront_bundle','draft_reserved_map',
       'draft_returns_bundle'))                                         as bundles_ok,        -- ждём 6
    (select prosrc like '%return_reasons%' from pg_proc
      where proname = 'draft_storefront_bundle')                        as storefront_v2,     -- ждём t
    (select prosrc like '%quarantine_qty%' from pg_proc
      where proname = 'draft_assembly_bundle')                          as assembly_v2,       -- ждём t
    (select prosrc like '%promos%' from pg_proc
      where proname = 'draft_admin_bundle')                             as admin_bundle_v2;   -- ждём t
""")
w('09_admin_bundles.sql', '\n'.join(parts))

# ---- 04_seed_references_and_content.sql / 05_seed_catalog.sql --------------
def seed_block(tbl_list, title, num, replaces, idem):
    parts = [HDR % (num, title, replaces, idem)]
    for t in tbl_list:
        parts.append('\n-- ---------- %s (%d стр.) ----------\n' % (t, len(seeds[t])))
        parts.extend(s + '\n' for s in seeds[t])
        if setvals[t]:
            parts.append(setvals[t][0] + '\n')
    return parts

parts = seed_block(SEED04, 'посевы справочников и контента — конечное состояние (70 ключей site_content)',
                   '04', '04, 06 (статус «Оплачен» не сеется), 07 (order.payment.text), 14 (brand_colors), 20, 22 (return_reasons), 24, 25 (pochtaruss)',
                   'insert … on conflict do nothing — вставка только отсутствующих строк (культура F21): на живой базе с правками владельца безопасен, но по регламенту не запускается.')
parts.append('''
-- ---------- admin_users: демо-администратор мок-входа (посев исторического
-- скрипта 07; живая база не выгружается в data/ — чувствительные данные) ----

insert into public.admin_users (fio, email, messenger_url, role, password_hash)
select 'Иванов Иван Иванович', 'owner@sisku.example', 'https://t.me/sisku_owner', 'admin',
       '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'
where not exists (select 1 from public.admin_users where email = 'owner@sisku.example');
''')
parts.append("""
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.order_statuses)                        as statuses_ok,      -- ждём 7 (без «Оплачен»)
    (select count(*) from public.status_transitions)                    as transitions_ok,   -- ждём 8 (вкл. shipped→returned)
    (select count(*) from public.payment_methods)                       as payments_ok,      -- ждём 3
    (select count(*) from public.delivery_methods)                      as deliveries_ok,    -- ждём 4
    (select count(*) from public.delivery_methods
      where code = 'pochtaruss')                                        as pochtaruss_ok,    -- ждём 1
    (select count(*) from public.delivery_methods
      where code = 'boxberry')                                          as boxberry_left,    -- ждём 0
    (select count(*) from public.return_reasons)                        as reasons_ok,       -- ждём 4
    (select count(*) from public.site_content)                          as keys_total,       -- ждём 70
    (select count(*) from public.site_content
      where key like 'returns.%')                                       as returns_keys,     -- ждём 18
    (select count(*) from public.site_content
      where value ilike '%boxberry%')                                   as content_boxberry, -- ждём 0
    (select count(*) from public.brand_colors)                          as colors_ok,        -- ждём 20
    (select count(*) from public.admin_users
      where email = 'owner@sisku.example')                              as demo_admin_ok;    -- ждём 1 (свежий стенд; на живой базе — фактический состав админов)
""")
w('04_seed_references_and_content.sql', '\n'.join(parts))

parts = seed_block(SEED05, 'запасной посев каталога без CSV — конечное состояние на v0.16.0',
                   '05', '05, 08 (описание товара 30001 исправлено в посеве)',
                   'insert … on conflict do nothing; id задаются явно, в конце sequence выставляются на максимум.')
parts.append("""
-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.brands)                                as brands_ok,     -- ждём 6
    (select count(*) from public.categories)                            as categories_ok, -- ждём 6
    (select count(*) from public.products)                              as products_ok,   -- ждём 8 (демо-каталог; «Тестовый товар» владельца — данные живой базы, в посев не входят)
    (select count(*) from public.product_variants)                      as variants_ok,   -- ждём 20
    (select count(*) from public.products
      where image_url like 'assets/img/products/%.jpg')                  as jpg_paths;     -- ждём 8 (на v0.16.0; в .webp переводит скрипт 27)
""")
w('05_seed_catalog.sql', '\n'.join(parts))

print('baseline собран в', OUT)
