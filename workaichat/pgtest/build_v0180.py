#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Волна v0.18.0 — сборка скрипта 29_client_card_v9.sql.

create_order v9 извлекается из скрипта 26 (v8) и патчится хирургическими
заменами (решения Д2а/Д3) — неизменяемые части копируются байт-в-байт.
Каждая заменаassert'ится (ровно одно вхождение). Новые функции
(admin_update_client, draft_client_card_bundle) — из шаблона ниже.

Запуск: python3 workaichat/pgtest/build_v0180.py   (из корня клона Sisku)
Выход: supabase/29_client_card_v9.sql
"""
import io
import sys

SRC = 'supabase/26_field_limits_and_promo_timezone.sql'
OUT = 'supabase/29_client_card_v9.sql'

src = io.open(SRC, encoding='utf-8').read()

# ---- извлечение create_order v8 (от CREATE до первого "$$;" + комментарий) --
start = src.index('CREATE OR REPLACE FUNCTION public.create_order(p jsonb)')
end = src.index('\n$$;\n', start) + len('\n$$;\n')
func = src[start:end]
cm_start = src.index("comment on function public.create_order(jsonb)", end)
cm_end = src.index('\n', cm_start) + 1
comment_v8 = src[cm_start:cm_end]


def rep(text, old, new, tag):
    n = text.count(old)
    assert n == 1, 'замена %s: вхождений %d (ожидалось 1)' % (tag, n)
    return text.replace(old, new)


# ---- R1: declare — новые переменные -----------------------------------------
func = rep(func,
           '    v_client_id  integer;\n',
           '    v_client_id  integer;\n'
           '    v_client_new boolean := false;   /* v9: клиент создан этим заказом */\n'
           '    v_cur_phone  text;                /* v9: текущие контакты — для истории */\n'
           '    v_cur_email  text;\n',
           'R1-declare')

# ---- R2: phone-ветка — пары контактов не перезаписываются (Д3) --------------
func = rep(func,
           """            on conflict (phone_key) do update
               set full_name  = case when public.clients.name_confirmed
                            then public.clients.full_name
                            else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
                   phone      = coalesce(excluded.phone, public.clients.phone),
                   email      = coalesce(excluded.email, public.clients.email),
                   address    = coalesce(excluded.address, public.clients.address),
                   email_key  = coalesce(public.clients.email_key, excluded.email_key),
                   updated_at = now()
            returning id into v_client_id;
""",
           """            on conflict (phone_key) do update
               set full_name  = case when public.clients.name_confirmed
                            then public.clients.full_name
                            else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
                   address    = coalesce(excluded.address, public.clients.address),
                   updated_at = now()
                   /* v9 (Д3): пары (phone, phone_key) и (email, email_key) НЕ
                      перезаписываются — отличный от текущего контакт заказа
                      уходит в client_contact_history ('offered') ниже по телу */
            returning id, (xmax = 0) into v_client_id, v_client_new;
""",
           'R2-phone-upsert')

# ---- R3: exception-ветка (слияние по e-mail) — телефон только если свободен --
func = rep(func,
           """            update public.clients
               set full_name  = case when name_confirmed then full_name
                            else v_name end,   -- (v7, правка 2.20)
                   phone      = coalesce(phone, v_phone),
                   address    = coalesce(address, v_address),
                   phone_key  = coalesce(phone_key, v_pkey),
                   updated_at = now()
             where id = v_client_id;
""",
           """            update public.clients
               set full_name  = case when name_confirmed then full_name
                            else v_name end,   -- (v7, правка 2.20)
                   address    = coalesce(address, v_address),
                   /* v9 (Д2а/Д3): телефон принимается, только если у клиента
                      его ещё нет и ключ свободен — иначе контакт уходит
                      в историю ('offered'); сырая 23505 исключена */
                   phone      = case when phone is null
                                      and not exists (select 1 from public.clients c2
                                                      where c2.phone_key = v_pkey)
                                     then v_phone else phone end,
                   phone_key  = case when phone_key is null
                                      and not exists (select 1 from public.clients c2
                                                      where c2.phone_key = v_pkey)
                                     then v_pkey else phone_key end,
                   updated_at = now()
             where id = v_client_id;
""",
           'R3-merge-update')

# ---- R4: email-ветка — мёртвый exception-блок v8 убран, пары не трогаются ----
func = rep(func,
           """    elsif v_ekey is not null then
        begin
            insert into public.clients (full_name, phone, email, address, phone_key, email_key)
            values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
            on conflict (email_key) do update
               set full_name  = case when public.clients.name_confirmed
                            then public.clients.full_name
                            else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
                   phone      = coalesce(excluded.phone, public.clients.phone),
                   address    = coalesce(excluded.address, public.clients.address),
                   phone_key  = coalesce(public.clients.phone_key, excluded.phone_key),
                   updated_at = now()
            returning id into v_client_id;
        exception when unique_violation then
            select id into v_client_id from public.clients where email_key = v_ekey limit 1;
            if v_client_id is null then
                raise exception 'Контактные данные конфликтуют с существующим клиентом — измените телефон или e-mail';
            end if;
            update public.clients
               set full_name  = case when name_confirmed then full_name
                            else v_name end,   -- (v7, правка 2.20)
                   phone      = coalesce(phone, v_phone),
                   address    = coalesce(address, v_address),
                   updated_at = now()
             where id = v_client_id;
        end;
    else
""",
           """    elsif v_ekey is not null then
        /* v9: в этой ветке v_pkey заведомо null — phone_key уникальность
           нарушить не может; мёртвый exception-блок v8 убран; пары контактов
           не перезаписываются (Д3) — отличный телефон заказа уходит в историю */
        insert into public.clients (full_name, phone, email, address, phone_key, email_key)
        values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
        on conflict (email_key) do update
           set full_name  = case when public.clients.name_confirmed
                        then public.clients.full_name
                        else excluded.full_name end,   -- (v7, правка 2.20) подтверждённое имя не затирается
               address    = coalesce(excluded.address, public.clients.address),
               updated_at = now()
        returning id, (xmax = 0) into v_client_id, v_client_new;
    else
""",
           'R4-email-branch')

# ---- R5: else-ветка + блок истории после end if ------------------------------
func = rep(func,
           """    else
        insert into public.clients (full_name, phone, email, address)
        values (v_name, v_phone, v_email, v_address)
        returning id into v_client_id;
    end if;
""",
           """    else
        insert into public.clients (full_name, phone, email, address)
        values (v_name, v_phone, v_email, v_address)
        returning id, true into v_client_id, v_client_new;
    end if;

    /* ----------------------------------------------------------------------
       v9 (волна v0.18.0, правила владельца 05.10.2026, решения Д1–Д3):
       история вариантов имён и контактов. Вариант имени пишется КАЖДЫМ
       заказом (включая подтверждённое имя — перезаписи full_name при этом
       нет, логика v7 сохранена); контакты — только события: новый клиент
       ('set'), отличный от текущего контакт существующего клиента
       ('offered' — не принят, пары ключей не перезаписываются).
       ---------------------------------------------------------------------- */
    insert into public.client_name_history (client_id, full_name, source, created_by)
    values (v_client_id, v_name, 'order', 'site');

    select c.phone, c.email into v_cur_phone, v_cur_email
    from public.clients c where c.id = v_client_id;

    if v_client_new then
        if v_phone is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'phone', v_phone, 'set', 'site');
        end if;
        if v_email is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'email', v_email, 'set', 'site');
        end if;
    else
        if v_phone is not null
           and public.draft_phone_key(v_cur_phone) is distinct from v_pkey then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'phone', v_phone, 'offered', 'site');
        end if;
        if v_email is not null
           and public.draft_email_key(v_cur_email) is distinct from v_ekey then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_client_id, 'email', v_email, 'offered', 'site');
        end if;
    end if;
""",
           'R5-else-and-history')

# ---- R6: шапка функции — отметка v9 ------------------------------------------
func = func.replace(
    'CREATE OR REPLACE FUNCTION public.create_order(p jsonb)',
    'CREATE OR REPLACE FUNCTION public.create_order(p jsonb)', 1)

comment_v9 = (
    "comment on function public.create_order(jsonb) is 'v9 (волна v0.18.0, "
    "правила владельца 05.10.2026, решения Д2а/Д3): варианты имени — в "
    "client_name_history; пары контактов при слиянии не перезаписываются "
    "(отличный контакт заказа — в client_contact_history «offered»); слияние "
    "— только по e-mail; заказ на старые контакты — новый клиент; база — v8 "
    "(волна v0.17.0, скрипт 26): лимит текстовых полей ≤1000 символов';\n")

HEADER = u"""-- ============================================================================
--  SISKU (черновик) — СКРИПТ 29: карточка клиента — create_order v9 + RPC
-- ============================================================================
--  Волна v0.18.0 (09.10.2026) — «Карточка клиента» (fp №1, план развития
--  §3.2). Решения аналитика 09.10.2026 (Д2а, Д3, Д4, Д5):
--    (1) create_order v9 (база — v8, скрипт 26; вся логика v8 сохранена,
--        кроме оговорённой): каждый вариант имени — в client_name_history;
--        пары (phone, phone_key) и (email, email_key) при слияниях НЕ
--        перезаписываются — устранено рассогласование v8 (email обновлялся,
--        email_key — нет); отличный контакт заказа фиксируется в
--        client_contact_history ('offered'); слияние — только по e-mail;
--        заказ на контакты, изменённые админом, — новый клиент (правило
--        владельца 05.10.2026 — работает колоночной моделью, решение Д1);
--    (2) admin_update_client — сохранение карточки клиента ОДНОЙ
--        транзакцией (clients + история контактов/имени + name_confirmed),
--        замена прямого update из clients.js (прецедент draft_save_look,
--        v0.15.0); серверная валидация форматов (зеркало масок util.js);
--    (3) draft_client_card_bundle — карточка клиента ОДНИМ запросом
--        (клиент + имена + контакты + заказы с позициями и статусами);
--        грабля №6 — никаких N+1 на странице.
--  RLS: функции SECURITY DEFINER (владелец обходит RLS таблиц истории —
--  анонимных политик у них нет, скрипт 28); EXECUTE для anon — в пределах
--  задокументированной границы черновика (SECURITY.md, A2 — до M2).
--  Идемпотентен: create or replace function. Порядок: после baseline 01–05,
--  09 и инкрементов 26–28. Применим к живой базе (инкремент — модель F21).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: скрипт должен выполняться в проекте Sisku после скрипта 28
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.client_name_history') is null
       or to_regclass('public.client_contact_history') is null then
        raise exception 'Скрипт 29: таблицы истории клиента не найдены — сначала выполните скрипт 28_client_history.sql';
    end if;
    if to_regprocedure('public.draft_phone_key(text)') is null then
        raise exception 'Скрипт 29: функция draft_phone_key не найдена — выбран не тот проект Supabase или не выполнен baseline 03';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. create_order v9 (база — v8, скрипт 26; изменения — см. шапку и комментарии
--    в теле; неотличимые части скопированы из скрипта 26 байт-в-байт)
-- ----------------------------------------------------------------------------
"""

AUC = u"""
-- ----------------------------------------------------------------------------
-- 2. admin_update_client — сохранение карточки клиента одной транзакцией (Д4)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_update_client(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_id     integer;
    v_name   text;
    v_phone  text;
    v_email  text;
    v_note   text;
    v_pkey   text;
    v_ekey   text;
    v_old    record;
begin
    v_id    := nullif(btrim(coalesce(p->>'client_id', '')), '')::integer;
    v_name  := nullif(btrim(coalesce(p->>'full_name', '')), '');
    v_phone := nullif(btrim(coalesce(p->>'phone', '')), '');
    v_email := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
    v_note  := nullif(btrim(coalesce(p->>'note', '')), '');

    if v_id is null then
        raise exception 'Клиент не указан';
    end if;
    if v_name is null then
        raise exception 'ФИО не может быть пустым';
    end if;
    if length(v_name) > 1000 then
        raise exception 'Слишком длинное имя (не более 1000 символов)';
    end if;
    if length(coalesce(v_note, '')) > 2000 then
        raise exception 'Слишком длинный комментарий (не более 2000 символов)';
    end if;
    if v_phone is null and v_email is null then
        raise exception 'Оставьте хотя бы один контакт: телефон или e-mail';
    end if;

    /* серверное зеркало масок util.js (phoneOk/emailOk): телефон — 11 цифр
       с ведущей 7 после нормализации (8→7), почта — простая маска a@b.cc */
    v_pkey := public.draft_phone_key(v_phone);
    /* draft_phone_key возвращает только цифры (8→7) — регэксы не нужны:
       валидность = 11 цифр с ведущей 7 (без dollar-якоря — регламент
       «одиночных долларов нет», правило 4 supabase/README) */
    if v_phone is not null
       and (v_pkey is null or length(v_pkey) <> 11 or left(v_pkey, 1) <> '7') then
        raise exception 'Формат телефона: +7 (999) 123-45-67 или 8 999 123-45-67';
    end if;
    v_ekey := public.draft_email_key(v_email);
    if v_email is not null
       and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]{2,}\\Z' then
        raise exception 'Формат почты: name@example.ru';
    end if;

    select c.id, c.full_name, c.phone, c.email
      into v_old
      from public.clients c
     where c.id = v_id
     for update;
    if v_old.id is null then
        raise exception 'Клиент не найден';
    end if;

    begin
        update public.clients
           set full_name      = v_name,
               phone          = v_phone,
               email          = v_email,
               note           = v_note,
               phone_key      = v_pkey,
               email_key      = v_ekey,
               name_confirmed = true,   /* правка 2.20 (v0.15.0): сохранение
                                          карточки = имя подтверждено */
               updated_at     = now()
         where id = v_id;
    exception when unique_violation then
        raise exception 'Такой телефон или e-mail уже принадлежит другому клиенту — объедините дубли вручную (Table Editor → clients).';
    end;

    /* история контактов (правило владельца 05.10.2026: вести так же, как
       историю имён): старое значение — 'invalidated', новое — 'changed' */
    if coalesce(v_old.phone, '') <> coalesce(v_phone, '') then
        if v_old.phone is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'phone', v_old.phone, 'invalidated', 'admin');
        end if;
        if v_phone is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'phone', v_phone, 'changed', 'admin');
        end if;
    end if;
    if coalesce(v_old.email, '') <> coalesce(v_email, '') then
        if v_old.email is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'email', v_old.email, 'invalidated', 'admin');
        end if;
        if v_email is not null then
            insert into public.client_contact_history (client_id, type, value, action, changed_by)
            values (v_id, 'email', v_email, 'changed', 'admin');
        end if;
    end if;
    if v_old.full_name <> v_name then
        insert into public.client_name_history (client_id, full_name, source, created_by)
        values (v_id, v_name, 'admin', 'admin');
    end if;

    return jsonb_build_object('ok', true, 'client_id', v_id);
end;
$$;

comment on function public.admin_update_client(jsonb) is 'v1 (волна v0.18.0, решение Д4): сохранение карточки клиента одной транзакцией — clients (включая ключи дедупликации и name_confirmed) + client_contact_history (старое — invalidated, новое — changed) + client_name_history (admin); серверная валидация форматов — зеркало масок util.js; 23505 — читаемое сообщение';

-- ----------------------------------------------------------------------------
-- 3. draft_client_card_bundle — карточка клиента одним запросом (Д5)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_client_card_bundle(p_client_id integer)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'client', (select jsonb_build_object(
                   'id',             c.id,
                   'full_name',      c.full_name,
                   'phone',          c.phone,
                   'email',          c.email,
                   'address',        c.address,
                   'note',           c.note,
                   'name_confirmed', c.name_confirmed,
                   'created_at',     c.created_at,
                   'updated_at',     c.updated_at)
                 from public.clients c
                where c.id = p_client_id),
    'names',  (select coalesce(jsonb_agg(jsonb_build_object(
                   'full_name',  h.full_name,
                   'source',     h.source,
                   'created_by', h.created_by,
                   'created_at', h.created_at)
                   order by h.created_at asc, h.id asc), '[]'::jsonb)
                 from public.client_name_history h
                where h.client_id = p_client_id),
    'contacts', (select coalesce(jsonb_agg(jsonb_build_object(
                   'type',       h.type,
                   'value',      h.value,
                   'action',     h.action,
                   'changed_by', h.changed_by,
                   'created_at', h.created_at)
                   order by h.created_at asc, h.id asc), '[]'::jsonb)
                 from public.client_contact_history h
                where h.client_id = p_client_id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id',            o.id,
                   'created_at',    o.created_at,
                   'status_code',   s.code,
                   'status_name',   s.name,
                   'is_paid',       o.is_paid,
                   'total',         o.total,
                   'delivery_cost', o.delivery_cost,
                   'items', (select coalesce(jsonb_agg(jsonb_build_object(
                                'title_snapshot',   oi.title_snapshot,
                                'variant_snapshot', oi.variant_snapshot,
                                'quantity',         oi.quantity,
                                'price',            oi.price)
                                order by oi.id asc), '[]'::jsonb)
                               from public.order_items oi
                              where oi.order_id = o.id))
                   order by o.created_at desc, o.id desc), '[]'::jsonb)
                 from public.orders o
                 join public.order_statuses s on s.id = o.status_id
                where o.client_id = p_client_id)
);
$$;

comment on function public.draft_client_card_bundle(integer) is 'Черновик (волна v0.18.0, решение Д5): карточка клиента одним RPC — клиент, варианты имён, история контактов, все заказы с позициями и статусами (новые сверху); грабля №6 — один запрос на открытие карточки, без N+1';

-- ----------------------------------------------------------------------------
-- 4. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select prosrc like '%client_name_history%' from pg_proc
      where proname = 'create_order')                               as v9_history,      -- ждём t
    (select prosrc like '%xmax = 0%' from pg_proc
      where proname = 'create_order')                               as v9_xmax,         -- ждём t
    (select prosrc not like '%coalesce(excluded.email%' from pg_proc
      where proname = 'create_order')                               as v9_no_overwrite, -- ждём t (Д3)
    (select to_regprocedure('public.admin_update_client(jsonb)') is not null)
                                                                    as auc_exists,      -- ждём t
    (select to_regprocedure('public.draft_client_card_bundle(integer)') is not null)
                                                                    as bundle_exists,   -- ждём t
    (select obj_description(oid, 'pg_proc') like 'v9%' from pg_proc
      where proname = 'create_order')                               as comment_v9,      -- ждём t
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public')                                   as func_count;      -- ждём 20
-- Ожидаемая строка самопроверки (psql -At): t|t|t|t|t|t|20
"""

out = HEADER + func + '\n' + comment_v9 + '\n' + AUC
io.open(OUT, 'w', encoding='utf-8', newline='\n').write(out)
print('собран %s (%d строк)' % (OUT, out.count('\n')))
