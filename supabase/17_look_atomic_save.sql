-- ============================================================================
--  SISKU (черновик) — СКРИПТ 17: атомарное сохранение комплекта (волна v0.15.0,
--  правка 2.1-Б обработки записок приёмки v0.14.x)
-- ============================================================================
--  ПРОБЛЕМА (записка 1, баг): looks.js сохранял комплект двумя запросами —
--  сначала insert в `looks`, затем insert в `look_items`. При ошибке второго
--  запроса комплект оставался в таблице БЕЗ СОСТАВА (errBox показывался, но
--  строка уже была создана) — витрина такой комплект не показывает (пустой
--  состав), а админка показывает «пусто».
--
--  РЕШЕНИЕ (вариант Б из приёмки — надёжнее клиентской компенсации):
--  RPC `draft_save_look(p jsonb)` — создание/обновление комплекта и его
--  состава ОДНОЙ функцией = одна транзакция (plpgsql-функция атомарна):
--  при любой ошибке состав/комплект откатываются вместе.
--  Серверная валидация: название ≥ 3 символов, скидка 0–90, минимум одна
--  позиция (≤ 50), товары и варианты существуют, вариант принадлежит товару.
--
--  Контракт p: { id?: int, title: text, description?: text,
--                discount_percent?: number, is_active?: bool,
--                items: [{product_id: int, variant_id?: int|null}, …] }
--  Возврат: { ok: true, look_id: int, items: int }
--
--  Идемпотентен: create or replace function. Существующие данные не меняет.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном
--    (правило 6 supabase/README.md — скрипт создаёт draft-объект).
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.looks') is null
       or to_regclass('public.look_items') is null
       or to_regclass('public.products') is null
       or to_regclass('public.product_variants') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (looks / look_items / products / product_variants). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. RPC сохранения комплекта (создание и правка — один вход)
-- ----------------------------------------------------------------------------
create or replace function public.draft_save_look(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_id      integer;
    v_title   text;
    v_disc    numeric(5,2);
    v_item    jsonb;
    v_pid     integer;
    v_vid     integer;
    v_sort    integer := 0;
    v_items   jsonb;
begin
    v_id    := nullif(btrim(coalesce(p->>'id', '')), '')::integer;
    v_title := nullif(btrim(coalesce(p->>'title', '')), '');
    v_disc  := coalesce((p->>'discount_percent')::numeric(5,2), 0);
    v_items := coalesce(p->'items', '[]'::jsonb);

    -- валидация (зеркалит клиентскую в looks.js — сервер истина)
    if v_title is null or length(v_title) < 3 then
        raise exception 'Укажите название комплекта (минимум 3 символа)';
    end if;
    if v_disc < 0 or v_disc > 90 then
        raise exception 'Скидка комплекта: от 0 до 90 процентов';
    end if;
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
        raise exception 'Добавьте в комплект хотя бы один товар';
    end if;
    if jsonb_array_length(v_items) > 50 then
        raise exception 'Слишком много позиций в комплекте (максимум 50)';
    end if;

    -- состав проверяется ДО записи: товар существует, вариант принадлежит товару
    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_pid := nullif(btrim(coalesce(v_item->>'product_id', '')), '')::integer;
        v_vid := nullif(btrim(coalesce(v_item->>'variant_id', '')), '')::integer;
        if v_pid is null or not exists (select 1 from public.products where id = v_pid) then
            raise exception 'Товар позиции % не найден в каталоге — обновите список товаров', coalesce(v_pid::text, '?');
        end if;
        if v_vid is not null and not exists (
            select 1 from public.product_variants
            where id = v_vid and product_id = v_pid
        ) then
            raise exception 'Вариант позиции % не принадлежит выбранному товару — обновите список вариантов', v_pid::text;
        end if;
    end loop;

    -- комплект: создание или обновление
    if v_id is null then
        insert into public.looks (title, description, discount_percent, is_active)
        values (
            v_title,
            nullif(btrim(coalesce(p->>'description', '')), ''),
            v_disc,
            coalesce((p->>'is_active')::boolean, true)
        )
        returning id into v_id;
    else
        update public.looks
           set title            = v_title,
               description      = nullif(btrim(coalesce(p->>'description', '')), ''),
               discount_percent = v_disc,
               is_active        = coalesce((p->>'is_active')::boolean, true)
         where id = v_id;
        if not found then
            raise exception 'Комплект № % не найден — обновите список', v_id;
        end if;
        -- состав заменяется целиком (как раньше в looks.js, но в той же транзакции)
        delete from public.look_items where look_id = v_id;
    end if;

    -- позиции — в порядке строк редактора
    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_sort := v_sort + 1;
        insert into public.look_items (look_id, product_id, variant_id, sort_order)
        values (
            v_id,
            nullif(btrim(coalesce(v_item->>'product_id', '')), '')::integer,
            nullif(btrim(coalesce(v_item->>'variant_id', '')), '')::integer,
            v_sort
        );
    end loop;

    return jsonb_build_object('ok', true, 'look_id', v_id, 'items', v_sort);
end;
$$;

comment on function public.draft_save_look(jsonb) is
    'v1 (скрипт 17, волна v0.15.0, правка 2.1-Б): сохранение комплекта и состава одной транзакцией — комплект больше не может остаться без позиций; серверная валидация названия, скидки и состава';

-- ----------------------------------------------------------------------------
-- 2. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc pr
       join pg_namespace n on n.oid = pr.pronamespace
      where n.nspname = 'public' and pr.proname = 'draft_save_look')     as fn_count,        -- ждём 1
    (select pg_get_function_identity_arguments(p.oid)
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'draft_save_look')      as fn_args,         -- ждём p jsonb
    (select prosecdef from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'draft_save_look')      as security_definer; -- ждём t
