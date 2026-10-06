-- ============================================================================
--  SISKU (черновик) — СКРИПТ 22: заявки на возврат (волна v0.16.0, fp №3 —
--  приоритет №1 владельца; статусная модель — черновик до юриста, ЮР-06/M4)
-- ============================================================================
--  ЧТО ПОЯВЛЯЕТСЯ
--    1. Справочник `return_reasons` (название, активность, порядок) + сид
--       из 4 причин. Управление — «Управление → Справочники» (внизу страницы);
--       удаление причины — только деактивацией (DELETE-политики нет: причина
--       может быть использована в заявках, как справочники v0.14.0).
--    2. Таблица `return_requests` — заявки на возврат со своей статусной
--       моделью: created («Заявка оформлена») → returned_to_stock («Товар
--       вернулся на склад») → verified («Товар проверен, возврат оформлен»);
--       из created и returned_to_stock возможен rejected («Отклонено»).
--       verified/rejected — финальные (resolved_at).
--       Блок «Деньги возвращены»: refund_paid + refund_paid_at +
--       refund_receipt (реквизиты чека возврата в макете НЕОБЯЗАТЕЛЬНЫЕ —
--       юридический контур M4, 54-ФЗ).
--       photo_urls jsonb — ЗАГЛУШКА до подключения файлового хранилища (M5,
--       триггер АН-04.8): форма витрины поле не отправляет.
--       created_by/handled_by — TEXT (паттерн order_status_history.changed_by):
--       в макете нет авторизации, заявку создаёт покупатель с витрины
--       ('site'), обрабатывает админка ('draft-admin'); FK на admin_users —
--       в боевой версии (M2, вместе с настоящей ролевой моделью).
--    3. RPC `create_return_request(p jsonb)` — создание заявки покупателем:
--       валидация заказа (существует; статус «Отправлен» или «Доставлен» —
--       решение аналитика 06.10.2026: менеджер мог ещё не сменить статус,
--       а клиент уже хочет вернуть; повторные заявки из «Возврата» не делаем),
--       код подтверждения — механизм track_order (последние 4 цифры телефона
--       или 4 символа e-mail до @), причина — только активная из справочника,
--       антиспам: одна незакрытая заявка на заказ + не более 3 заявок
--       за 10 минут на заказ.
--    4. RPC `admin_set_return_status(...)` — переходы статуса заявки с
--       проверкой модели; при «Товар вернулся на склад» заказ АВТОМАТИЧЕСКИ
--       переводится в статус «Возврат» (admin_set_status — с волны v0.16.0,
--       скрипт 23, остатки уходят в КАРАНТИН quarantine_qty, а не в продажу;
--       вызов идемпотентен: если заказ уже «Возврат» — «без изменения»).
--    5. RPC `admin_set_return_refund(...)` — флаг «Деньги возвращены» + дата
--       + реквизиты чека (необязательные).
--    6. RPC `draft_returns_bundle()` — очередь возвратов ОДНИМ запросом
--       (заявки + причины + тексты returns.* — грабля №4: очередь соединений
--       бесплатного тарифа; заказы/статусы админка уже имеет из
--       draft_admin_bundle).
--    7. `track_order` v2 — в ответе появляются status_code, status_name и
--       return_available (форма возврата доступна из «Отправлен»/«Доставлен»);
--       состав v1 не меняется (обратная совместимость витрины).
--    8. `draft_storefront_bundle` v2 — добавлен блок return_reasons (активные,
--       по порядку): причина в форме возврата — из того же одного RPC витрины.
--    9. Модель переходов ЗАКАЗОВ дополнена парой shipped → returned: возврат
--       возможен и до простановки «Доставлен» (заявка из «Отправлен»).
--
--  RLS: чтение причин — публичное (форма витрины); чтение заявок — anon
--  (черновое упрощение, как заказы: админка без пароля); запись причин —
--  draft-политики для «Управление → Справочники»; запись заявок — ТОЛЬКО
--  через RPC (security definer), прямых политик записи нет.
--
--  Скрипт идемпотентен: create table if not exists, drop policy if exists,
--  create or replace function, сиды — where not exists.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном
--    (правило 6 supabase/README.md).
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.orders') is null
       or to_regclass('public.order_statuses') is null
       or to_regclass('public.site_content') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (orders / order_statuses / site_content). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Справочник причин возврата
-- ----------------------------------------------------------------------------
create table if not exists public.return_reasons (
    id         serial primary key,
    name       text not null,
    is_active  boolean not null default true,
    sort_order integer not null default 1
);
comment on table  public.return_reasons is 'Причины возврата (справочник «Управление → Справочники»); удаление — только деактивацией';
comment on column public.return_reasons.sort_order is 'Порядок в списке (имя колонки — по конвенции проекта: order_statuses/product_variants.sort_order)';

alter table public.return_reasons enable row level security;

-- сид: 4 стартовые причины (только если справочник ещё пуст — правки владельца
-- не перезаписываются, культура F21)
insert into public.return_reasons (name, is_active, sort_order)
select v.name, true, v.sort_order
from (values
    ('Не подошёл размер', 1),
    ('Брак / дефект',     2),
    ('Не подошло',        3),
    ('Передумал(а)',      4)
) as v(name, sort_order)
where not exists (select 1 from public.return_reasons);

-- ----------------------------------------------------------------------------
-- 2. Заявки на возврат
-- ----------------------------------------------------------------------------
create table if not exists public.return_requests (
    id             serial primary key,          -- номер заявки, который видит клиент
    order_id       integer not null references public.orders(id),
    reason_id      integer not null references public.return_reasons(id),
    comment        text,
    photo_urls     jsonb not null default '[]'::jsonb,   -- заглушка до хранилища (M5)
    status         text not null default 'created'
                   check (status in ('created', 'returned_to_stock', 'verified', 'rejected')),
    refund_paid    boolean not null default false,
    refund_paid_at timestamptz,
    refund_receipt text,                        -- реквизиты чека возврата; в макете необязательные (M4)
    created_by     text not null default 'site',
    handled_by     text,
    created_at     timestamptz not null default now(),
    resolved_at    timestamptz
);
comment on table  public.return_requests is 'Заявки на возврат: своя статусная модель (created → returned_to_stock → verified / rejected); запись — только через RPC';
comment on column public.return_requests.photo_urls is 'ЗАГЛУШКА: пустой массив до подключения файлового хранилища (M5); загрузка фото покупателем — после хранилища';
comment on column public.return_requests.refund_receipt is 'Реквизиты чека возврата (54-ФЗ) — в макете необязательные; юридический контур M4';
comment on column public.return_requests.created_by is 'Автор (текст, паттерн order_status_history): ''site'' — покупатель с витрины; в боевой версии — FK на пользователей (M2)';

create index if not exists return_requests_order_idx  on public.return_requests (order_id);
create index if not exists return_requests_status_idx on public.return_requests (status, created_at);

alter table public.return_requests enable row level security;

-- ----------------------------------------------------------------------------
-- 3. Политики RLS
-- ----------------------------------------------------------------------------
-- причины читают все (форма витрины + справочники админки — включая отключённые)
drop policy if exists anon_read_return_reasons on public.return_reasons;
create policy anon_read_return_reasons on public.return_reasons
    for select to anon, authenticated using (true);

-- справочник причин правится из «Управление → Справочники» (черновое допущение,
-- как draft_anon_* скриптов 11/12); DELETE-политики НЕТ — деактивация вместо
-- удаления (причина может быть использована в заявках)
drop policy if exists draft_anon_insert_return_reasons on public.return_reasons;
create policy draft_anon_insert_return_reasons on public.return_reasons
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_return_reasons on public.return_reasons;
create policy draft_anon_update_return_reasons on public.return_reasons
    for update to anon, authenticated using (true) with check (true);

-- заявки читает админка (черновое упрощение — как заказы, скрипт 02)
drop policy if exists draft_anon_read_return_requests on public.return_requests;
create policy draft_anon_read_return_requests on public.return_requests
    for select to anon, authenticated using (true);

-- записи заявок напрямую НЕТ: создание — create_return_request(), переходы —
-- admin_set_return_status(), деньги — admin_set_return_refund() (security definer)

-- ----------------------------------------------------------------------------
-- 4. Модель переходов заказов: shipped → returned (возврат до «Доставлен»)
-- ----------------------------------------------------------------------------
insert into public.status_transitions (from_status_id, to_status_id)
select a.id, b.id
from public.order_statuses a, public.order_statuses b
where a.code = 'shipped' and b.code = 'returned'
  and not exists (
    select 1 from public.status_transitions t
    where t.from_status_id = a.id and t.to_status_id = b.id
  );

-- ----------------------------------------------------------------------------
-- 5. create_return_request: заявка покупателем (валидация — серверная)
-- ----------------------------------------------------------------------------
create or replace function public.create_return_request(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_order_id  integer;
    v_tail      text;
    v_reason_id integer;
    v_comment   text;
    v_order     record;
    v_phone4    text;
    v_mail4     text;
    v_open      integer;
    v_recent    integer;
    v_id        integer;
begin
    v_order_id  := nullif(btrim(coalesce(p->>'order_id', '')), '')::integer;
    v_tail      := lower(btrim(coalesce(p->>'code', '')));
    v_reason_id := nullif(btrim(coalesce(p->>'reason_id', '')), '')::integer;
    v_comment   := nullif(btrim(coalesce(p->>'comment', '')), '');

    if v_order_id is null or v_tail = '' then
        raise exception 'Укажите номер заказа и код подтверждения';
    end if;
    if v_reason_id is null then
        raise exception 'Укажите причину возврата';
    end if;
    if v_comment is not null and length(v_comment) > 2000 then
        raise exception 'Комментарий слишком длинный (до 2000 символов)';
    end if;

    -- заказ существует + статус, из которого принимается заявка
    select o.id, s.code as status_code, o.customer_phone, o.customer_email
    into v_order
    from public.orders o
    join public.order_statuses s on s.id = o.status_id
    where o.id = v_order_id;
    if v_order.id is null then
        raise exception 'Заказ не найден';
    end if;
    if v_order.status_code not in ('shipped', 'delivered') then
        raise exception 'Заявка на возврат доступна для заказов в статусе «Отправлен» или «Доставлен»';
    end if;

    -- код подтверждения — механизм track_order (скрипт 10)
    v_phone4 := right(regexp_replace(coalesce(v_order.customer_phone, ''), '\D', '', 'g'), 4);
    v_mail4  := left(split_part(lower(coalesce(v_order.customer_email, '')), '@', 1), 4);
    if v_tail <> v_phone4 and v_tail <> v_mail4 then
        raise exception 'Заказ не найден или код подтверждения не совпадает';
    end if;

    -- причина — только активная из справочника
    if not exists (select 1 from public.return_reasons where id = v_reason_id and is_active) then
        raise exception 'Выберите причину возврата из списка';
    end if;

    -- антиспам: одна незакрытая заявка на заказ (повторные не делаем —
    -- решение аналитика 06.10.2026) + лимит 3 заявки за 10 минут на заказ
    select count(*) into v_open
    from public.return_requests
    where order_id = v_order_id
      and status in ('created', 'returned_to_stock', 'verified');
    if v_open > 0 then
        raise exception 'Заявка на возврат этого заказа уже оформлена и находится в обработке';
    end if;
    select count(*) into v_recent
    from public.return_requests
    where order_id = v_order_id
      and created_at > now() - interval '10 minutes';
    if v_recent >= 3 then
        raise exception 'Слишком много заявок подряд. Пожалуйста, попробуйте через несколько минут';
    end if;

    insert into public.return_requests (order_id, reason_id, comment, created_by)
    values (v_order_id, v_reason_id, v_comment, 'site')
    returning id into v_id;

    return jsonb_build_object('ok', true, 'request_id', v_id);
end;
$$;

comment on function public.create_return_request(jsonb) is
    'Заявка на возврат покупателем: номер заказа + код подтверждения (механизм track_order), заказ в статусе shipped/delivered, причина активная, антиспам — одна незакрытая заявка на заказ и 3/10 мин';

-- ----------------------------------------------------------------------------
-- 6. admin_set_return_status: переходы статуса заявки по модели
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_return_status(
    p_request_id  integer,
    p_status_code text,
    p_comment     text default null,
    p_changed_by  text default 'admin'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_req    record;
    v_author text;
begin
    select * into v_req from public.return_requests where id = p_request_id for update;
    if v_req.id is null then
        raise exception 'Заявка не найдена';
    end if;
    if p_status_code not in ('created', 'returned_to_stock', 'verified', 'rejected') then
        raise exception 'Неизвестный статус заявки: %', p_status_code;
    end if;
    if v_req.status = p_status_code then
        return jsonb_build_object('ok', true, 'status', p_status_code, 'note', 'без изменения');
    end if;

    -- модель переходов заявки
    if not (
        (v_req.status = 'created'          and p_status_code in ('returned_to_stock', 'rejected')) or
        (v_req.status = 'returned_to_stock' and p_status_code in ('verified', 'rejected'))
    ) then
        raise exception 'Переход запрещён моделью: % → %', v_req.status, p_status_code;
    end if;

    v_author := coalesce(nullif(btrim(p_changed_by), ''), 'admin');

    -- «Товар вернулся на склад»: заказ переводится в «Возврат» той же
    -- функцией, что и кнопка в карточке заказа (admin_set_status). С волны
    -- v0.16.0 (скрипт 23, admin_set_status v4) остатки при «Возврате» уходят
    -- в КАРАНТИН (quarantine_qty), а не в продажу. Вызов идемпотентен:
    -- если заказ уже «Возврат» — admin_set_status вернёт «без изменения».
    if p_status_code = 'returned_to_stock' then
        perform public.admin_set_status(
            v_req.order_id, 'returned',
            trim(both ' ' from 'Возврат по заявке № ' || v_req.id ||
                 coalesce('. ' || nullif(btrim(p_comment), ''), '.')),
            v_author
        );
    end if;

    update public.return_requests
       set status      = p_status_code,
           handled_by  = v_author,
           resolved_at = case when p_status_code in ('verified', 'rejected')
                              then coalesce(resolved_at, now()) else null end
     where id = p_request_id;

    return jsonb_build_object('ok', true, 'status', p_status_code);
end;
$$;

comment on function public.admin_set_return_status(integer, text, text, text) is
    'Переходы статуса заявки: created → returned_to_stock → verified / rejected (created → rejected). При returned_to_stock заказ переводится в «Возврат» (admin_set_status; с скрипта 23 — остатки в карантин). verified/rejected — финальные, пишется resolved_at';

-- ----------------------------------------------------------------------------
-- 7. admin_set_return_refund: блок «Деньги возвращены»
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_return_refund(
    p_request_id integer,
    p_paid       boolean,
    p_receipt    text default null,
    p_changed_by text default 'admin'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_req record;
begin
    select * into v_req from public.return_requests where id = p_request_id for update;
    if v_req.id is null then
        raise exception 'Заявка не найдена';
    end if;

    update public.return_requests
       set refund_paid    = p_paid,
           refund_paid_at = case when p_paid then coalesce(refund_paid_at, now()) else null end,
           refund_receipt = nullif(btrim(coalesce(p_receipt, '')), ''),
           handled_by     = coalesce(nullif(btrim(p_changed_by), ''), 'admin')
     where id = p_request_id;

    return jsonb_build_object('ok', true, 'refund_paid', p_paid);
end;
$$;

comment on function public.admin_set_return_refund(integer, boolean, text, text) is
    'Флаг «Деньги возвращены» + дата + реквизиты чека возврата (в макете необязательные — 54-ФЗ в боевом контуре M4)';

-- ----------------------------------------------------------------------------
-- 8. draft_returns_bundle: очередь возвратов одним запросом (грабля №4)
-- ----------------------------------------------------------------------------
create or replace function public.draft_returns_bundle()
returns jsonb
language sql security definer set search_path = public
as $$
select jsonb_build_object(
    'requests', (select coalesce(jsonb_agg(r order by r.created_at desc, r.id desc), '[]'::jsonb)
                   from public.return_requests r),
    'reasons',  (select coalesce(jsonb_agg(rr order by rr.sort_order, rr.id), '[]'::jsonb)
                   from public.return_reasons rr),
    'content',  (select coalesce(jsonb_agg(jsonb_build_object('key', sc.key, 'value', sc.value)), '[]'::jsonb)
                   from public.site_content sc
                  where sc.key like 'returns.%')
);
$$;

comment on function public.draft_returns_bundle() is
    'Черновик: заявки на возврат + причины + тексты returns.* одним RPC (подвкладка «Заказы → Возвраты» и «Статистика → Возвраты»; заказы и статусы — из draft_admin_bundle)';

-- ----------------------------------------------------------------------------
-- 9. track_order v2: статус заказа кодом + доступность формы возврата
-- ----------------------------------------------------------------------------
create or replace function public.track_order(p_order_id integer, p_tail text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_order    public.orders%rowtype;
    v_code     text;
    v_name     text;
    v_tail     text;
    v_phone4   text;
    v_mail4    text;
    v_history  jsonb;
begin
    v_tail := lower(btrim(coalesce(p_tail, '')));
    select * into v_order from public.orders where id = p_order_id;
    if v_order.id is null or v_tail = '' then
        return jsonb_build_object('found', false);
    end if;

    v_phone4 := right(regexp_replace(coalesce(v_order.customer_phone, ''), '\D', '', 'g'), 4);
    v_mail4  := left(split_part(lower(coalesce(v_order.customer_email, '')), '@', 1), 4);

    if v_tail <> v_phone4 and v_tail <> v_mail4 then
        return jsonb_build_object('found', false);
    end if;

    select s.code, s.name into v_code, v_name
    from public.order_statuses s where s.id = v_order.status_id;

    select coalesce(jsonb_agg(jsonb_build_object(
        'status', s.name,
        'changed_at', h.changed_at,
        'comment', h.comment) order by h.changed_at), '[]'::jsonb)
    into v_history
    from public.order_status_history h
    join public.order_statuses s on s.id = h.status_id
    where h.order_id = v_order.id;

    -- v2 (волна v0.16.0): добавлены status_code/status_name/return_available;
    -- состав v1 сохранён (обратная совместимость витрины)
    return jsonb_build_object(
        'found', true,
        'created_at', v_order.created_at,
        'total', v_order.total + v_order.delivery_cost,
        'history', v_history,
        'status_code', v_code,
        'status_name', v_name,
        'return_available', v_code in ('shipped', 'delivered'));
end;
$$;

comment on function public.track_order(integer, text) is
    'v2 (волна v0.16.0): отслеживание заказа покупателем + status_code/status_name/return_available — форма «Оформить возврат» доступна из статусов «Отправлен» и «Доставлен»';

-- ----------------------------------------------------------------------------
-- 10. draft_storefront_bundle v2: причины возврата в бандле витрины
-- ----------------------------------------------------------------------------
create or replace function public.draft_storefront_bundle()
returns jsonb
language sql security definer set search_path = public
as $$
select jsonb_build_object(
    'brands',     (select coalesce(jsonb_agg(b order by b.name), '[]'::jsonb)
                     from public.brands b where b.is_active),
    'categories', (select coalesce(jsonb_agg(c order by c.id), '[]'::jsonb)
                     from public.categories c),
    'products',   (select coalesce(jsonb_agg(pr order by pr.created_at desc, pr.id desc), '[]'::jsonb)
                     from public.products pr where pr.is_active),
    'variants',   (select coalesce(jsonb_agg(v order by v.sort_order, v.id), '[]'::jsonb)
                     from public.product_variants v),
    'content',    (select coalesce(jsonb_agg(jsonb_build_object('key', sc.key, 'value', sc.value)), '[]'::jsonb)
                     from public.site_content sc),
    'payments',   (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                     from public.payment_methods m where m.is_active),
    'deliveries', (select coalesce(jsonb_agg(m order by m.id), '[]'::jsonb)
                     from public.delivery_methods m where m.is_active),
    'looks',      (select coalesce(jsonb_agg(l order by l.created_at desc, l.id desc), '[]'::jsonb)
                     from public.looks l where l.is_active),
    'look_items', (select coalesce(jsonb_agg(li order by li.sort_order, li.id), '[]'::jsonb)
                     from public.look_items li),
    'brand',      (select coalesce(jsonb_agg(jsonb_build_object(
                       'theme', bc.theme, 'key', bc.key, 'value', bc.value)), '[]'::jsonb)
                     from public.brand_colors bc),
    'return_reasons', (select coalesce(jsonb_agg(rr order by rr.sort_order, rr.id), '[]'::jsonb)
                     from public.return_reasons rr where rr.is_active)
);
$$;

comment on function public.draft_storefront_bundle() is
    'v2 (волна v0.16.0): все данные витрины одним RPC + return_reasons (активные причины возврата для формы заявки) — fix F27, прототип боевого GET /api/storefront';

-- ----------------------------------------------------------------------------
-- 11. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from information_schema.tables
      where table_schema = 'public'
        and table_name in ('return_reasons', 'return_requests'))      as tables_ok,        -- ждём 2
    (select count(*) from public.return_reasons)                      as reasons_seeded,   -- ждём 4 (на живой базе — сколько завёл владелец, не меньше 4)
    (select count(*) from pg_policies
      where tablename in ('return_reasons', 'return_requests'))       as new_policies,     -- ждём 4
    (select count(*) from pg_policies
      where tablename = 'return_requests' and cmd <> 'SELECT')        as request_write_policies, -- ждём 0 (запись только через RPC)
    (select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('create_return_request', 'admin_set_return_status',
                          'admin_set_return_refund', 'draft_returns_bundle')) as new_functions,  -- ждём 4
    (select count(*) from public.status_transitions t
      join public.order_statuses a on a.id = t.from_status_id
      join public.order_statuses b on b.id = t.to_status_id
      where a.code = 'shipped' and b.code = 'returned')               as shipped_return_transition, -- ждём 1
    (select prosrc like '%return_available%' from pg_proc
      where proname = 'track_order')                                  as track_v2,           -- ждём t
    (select prosrc like '%return_reasons%' from pg_proc
      where proname = 'draft_storefront_bundle')                      as storefront_v2;    -- ждём t
