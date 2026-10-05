-- ============================================================================
--  SISKU (черновик) — СКРИПТ 18: признак оплаты у отменённых заказов
--  (волна v0.15.0, правка 2.2 обработки записок приёмки v0.14.x)
-- ============================================================================
--  ПРОБЛЕМА (записка 22, баг): у отменённого заказа нельзя снять отметку
--  оплаты — двойная блокировка: UI дизейблил кнопку (admin.js), а серверная
--  admin_set_paid рейзила «Заказ отменён: изменять признак оплаты нельзя»
--  (скрипт 03, затем 07). Деньги при этом могли поступить после отмены или
--  быть возвращены — признак оплаты должен учитываться (см. также п.23:
--  денежная аналитика считает оплаты по is_paid).
--
--  РЕШЕНИЕ (по приёмке): блокировки РАЗДЕЛЕНЫ —
--  • статусные переходы у отменённого заказа остаются заблокированными
--    (admin_set_status v3, скрипт 16 — без изменений);
--  • признак оплаты разрешено менять у заказа в любом статусе;
--  • событие смены оплаты пишется в историю заказа (order_status_history)
--    с автором (p_changed_by) — строка с текущим статусом и комментарием
--    «Оплата: …» (видна и в карточке заказа, и в отслеживании покупателем);
--  • история пишется только при ФАКТИЧЕСКОМ изменении признака.
--
--  Старая двухаргументная сигнатура подменяется трёхаргументной (p_changed_by
--  имеет значение по умолчанию) — прежняя сигнатура удаляется, чтобы вызовы
--  PostgREST не «спорили» между перегрузками.
--
--  Идемпотентен: drop if exists + create or replace.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном
--    (правило 6 supabase/README.md — скрипт создаёт draft-объект).
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.orders') is null
       or to_regclass('public.order_status_history') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (orders / order_status_history). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. admin_set_paid v2: без cancelled-guard, с автором и событием в истории
-- ----------------------------------------------------------------------------
drop function if exists public.admin_set_paid(integer, boolean);

create or replace function public.admin_set_paid(
    p_order_id   integer,
    p_is_paid    boolean,
    p_changed_by text default 'admin'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_status_id integer;
    v_was_paid  boolean;
begin
    select status_id, is_paid into v_status_id, v_was_paid
    from public.orders
    where id = p_order_id
    for update;

    if v_status_id is null then
        raise exception 'Заказ не найден';
    end if;

    update public.orders
       set is_paid = p_is_paid,
           paid_at = case when p_is_paid then coalesce(paid_at, now()) else null end
     where id = p_order_id;

    -- событие оплаты — в историю заказа (только при фактическом изменении);
    -- статус в строке истории остаётся текущим: это не статусный переход
    if v_was_paid is distinct from p_is_paid then
        insert into public.order_status_history (order_id, status_id, changed_by, comment)
        values (
            p_order_id,
            v_status_id,
            coalesce(nullif(btrim(p_changed_by), ''), 'admin'),
            case when p_is_paid
                 then 'Оплата: заказ отмечен оплаченным'
                 else 'Оплата: отметка об оплате снята'
            end
        );
    end if;

    return jsonb_build_object('ok', true, 'is_paid', p_is_paid);
end;
$$;

comment on function public.admin_set_paid(integer, boolean, text) is
    'v2 (скрипт 18, волна v0.15.0, правка 2.2): признак оплаты можно менять у заказа в любом статусе, включая отменённый (деньги могли поступить или быть возвращены); статусные переходы по-прежнему только через admin_set_status; событие смены оплаты пишется в историю заказа с автором';

-- ----------------------------------------------------------------------------
-- 2. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_set_paid')       as fn_count,     -- ждём 1 (старая сигнатура удалена)
    (select pg_get_function_identity_arguments(p.oid)
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_set_paid')       as fn_args,      -- ждём p_order_id integer, p_is_paid boolean, p_changed_by text
    (select pg_get_functiondef(p.oid) like '%Заказ отменён%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_set_paid')       as guard_gone;   -- ждём f (cancelled-guard убран)
