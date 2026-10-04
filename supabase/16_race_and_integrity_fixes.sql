-- ============================================================================
--  SISKU (черновик) — СКРИПТ 16: гонки и целостность (по независимому ревью
--  v0.13.1, находки F01–F03, F07–F09, F12, F17, F18, F23, F27)
-- ============================================================================
--  Живые конкурентные тесты ревью (две сессии, PostgreSQL 15) воспроизвели
--  три гонки и несколько дефектов целостности. Всё чинится здесь, до переноса
--  логики в PHP (план боя переносит функции почти построчно — дефекты уехали
--  бы в боевую версию вместе с ними).
--
--  1. admin_set_status v3 (F01): строка заказа блокируется SELECT … FOR UPDATE
--     в начале функции — два параллельных перевода в «Отменён» больше не
--     возвращают остатки на склад дважды и не пишут дубль в историю.
--  2. create_order v6:
--     (а) F02 — клиент создаётся UPSERT-ом (ON CONFLICT (phone_key) /
--         (email_key) DO UPDATE): параллельные заказы одного нового клиента
--         не роняют один из заказов сырой ошибкой 23505;
--     (б) F08 — корзина нормализуется: строки одного варианта группируются
--         (qty суммируется) до валидации остатка; списание условное
--         (WHERE stock >= qty) с читаемым сообщением вместо сырого 23514;
--     (в) F07 — итог заказа не может стать отрицательным: greatest(…, 0)
--         + констрейнт orders_total_nonneg CHECK (total >= 0);
--     (г) F12 — в join позиций возвращено условие vr.product_id = pr.id
--         (в v5 оно потерялось относительно v3/v4);
--     (д) F23 — детерминированный порядок блокировок: сначала строки товаров
--         по возрастанию id, затем строки вариантов по возрастанию id —
--         параллельные заказы с пересекающимися товарами не дают deadlock 40P01;
--     (е) F17 — анти-спам 3/10 мин сравнивает телефон по draft_phone_key()
--         («+7 999…» и «8999…» больше не разные «люди»);
--     (ж) F03 — строка промокода блокируется FOR UPDATE, лимит перепроверяется
--         под блокировкой, инкремент used_count условный — лимит использования
--         нельзя пробить двумя параллельными заказами.
--  3. draft_reserved_map v2 (F18): из списка открытых статусов убран 'paid'
--     (статус «Оплачен» удалён ещё в v0.2.0, скрипт 06 — мёртвый код).
--  4. Констрейнт CHECK (total >= 0) на orders (F07). DANGER-блок: найденные
--     отрицательные итоги (след воспроизведённого в ревью бага) обнуляются —
--     данные черновика тестовые, количество показывается в самопроверке.
--  5. Честное удаление способов оплаты/доставки (F09): кнопка «Удалить» в
--     «Управление → Оплата и доставка» больше не показывает фейковый успех
--     (раньше anon-delete политики не было, PostgREST молча возвращал
--     DELETE 0). Добавлены DELETE-политики; FK от orders/deliveries защищает
--     способы, уже использованные в заказах (ошибка 23503 — фронт покажет её
--     читаемо, manage.js). Чтение справочников для anon открыто полностью
--     (вместо «только активные»): иначе отключённый способ невидим — его
--     нельзя включить обратно или удалить. Границу держит сервер:
--     create_order принимает только активные способы.
--  6. draft_storefront_bundle() (F27): все данные витрины одним RPC вместо
--     9 параллельных запросов — по образцу draft_admin_bundle (лечение
--     очереди соединений бесплатного тарифа; в бою — прототип агрегирующего
--     GET /api/storefront).
--
--  Идемпотентен: функции пересоздаются, политики drop-if-exists, констрейнт
--  добавляется только если его ещё нет, DANGER-обнуление повторяемо.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: убеждаемся, что мы в проекте черновика Sisku, а не в учебном.
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.orders') is null
       or to_regclass('public.product_variants') is null
       or to_regclass('public.clients') is null
       or to_regclass('public.promo_codes') is null then
        raise exception 'Sisku draft: не найдены таблицы черновика (orders / product_variants / clients / promo_codes). Проверьте переключатель проектов Supabase слева вверху: нужен проект sisku-draft, а не учебный.';
    end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. admin_set_status v3 (F01): блокировка строки заказа до проверки перехода
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_status(
    p_order_id   integer,
    p_status_code text,
    p_comment    text default null,
    p_changed_by text default 'admin'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_from integer;
    v_to   integer;
    v_from_name text;
    v_to_name   text;
    v_item      record;
begin
    -- v3 (fix F01): FOR UPDATE — параллельные вызовы для одного заказа
    -- выстраиваются в очередь; второй вызов увидит уже новый статус
    -- и не вернёт остатки на склад повторно.
    select status_id into v_from
    from public.orders
    where id = p_order_id
    for update;
    if v_from is null then
        raise exception 'Заказ не найден';
    end if;
    select id, name into v_to, v_to_name from public.order_statuses where code = p_status_code;
    if v_to is null then
        raise exception 'Неизвестный статус: %', p_status_code;
    end if;
    if v_to = v_from then
        return jsonb_build_object('ok', true, 'status', p_status_code, 'note', 'без изменения');
    end if;

    if not exists (
        select 1 from public.status_transitions
        where from_status_id = v_from and to_status_id = v_to
    ) then
        select name into v_from_name from public.order_statuses where id = v_from;
        raise exception 'Переход запрещён моделью: % → %', v_from_name, v_to_name;
    end if;

    update public.orders set status_id = v_to where id = p_order_id;

    -- резервирование: отмена и возврат возвращают остатки на склад
    if p_status_code in ('cancelled', 'returned') then
        for v_item in
            select variant_id, quantity from public.order_items
            where order_id = p_order_id and variant_id is not null
        loop
            update public.product_variants
               set stock = stock + v_item.quantity
             where id = v_item.variant_id;
        end loop;
    end if;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (p_order_id, v_to, p_changed_by, p_comment);

    return jsonb_build_object('ok', true, 'status', p_status_code, 'status_name', v_to_name);
end;
$$;

comment on function public.admin_set_status(integer, text, text, text) is
    'v3: смена статуса с проверкой status_transitions; FOR UPDATE на строке заказа (fix F01 — двойная отмена не возвращает остатки дважды); возврат остатков при cancelled/returned';

-- ----------------------------------------------------------------------------
-- 2. draft_reserved_map v2 (F18): открытые статусы без удалённого 'paid'
-- ----------------------------------------------------------------------------
create or replace function public.draft_reserved_map()
returns jsonb
language sql security definer set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object('variant_id', t.variant_id, 'reserved', t.qty)), '[]'::jsonb)
from (
    select i.variant_id, sum(i.quantity) as qty
    from public.order_items i
    join public.orders o on o.id = i.order_id
    join public.order_statuses s on s.id = o.status_id
    -- открытые статусы (модель v0.2.0+, без «Оплачен» — это признак is_paid):
    -- новый, подтверждённый, собирается. 'paid' удалён из списка (fix F18).
    where s.code in ('new', 'confirmed', 'packing')
      and i.variant_id is not null
    group by i.variant_id
) t;
$$;

comment on function public.draft_reserved_map() is
    'v2: сколько единиц варианта зарезервировано открытыми заказами (new/confirmed/packing); fix F18 — мёртвый статус paid убран';

-- ----------------------------------------------------------------------------
-- 3. create_order v6 (F02, F03, F07, F08, F12, F17, F23)
-- ----------------------------------------------------------------------------
create or replace function public.create_order(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_name      text;
    v_phone     text;
    v_email     text;
    v_address   text;
    v_comment   text;
    v_payment   integer;
    v_delivery  integer;
    v_items     jsonb;
    v_item      jsonb;
    v_qty       integer;
    v_line      record;
    v_lock      record;
    v_prod      record;
    v_total     numeric(10,2) := 0;
    v_net       numeric(10,2) := 0;
    v_deliv_cost numeric(10,2) := 0;
    v_order_id  integer;
    v_status_new integer;
    v_recent    integer;
    v_promo_code text;
    v_promo_id   integer;
    v_promo      record;
    v_discount   numeric(10,2) := 0;
    v_chk        jsonb;
    v_look_id    integer;
    v_look       public.looks%rowtype;
    v_look_item  record;
    v_look_sum   numeric(10,2) := 0;
    v_look_disc  numeric(10,2) := 0;
    v_in_cart    boolean;
    v_pkey       text;
    v_ekey       text;
    v_client_id  integer;
begin
    v_name    := nullif(btrim(coalesce(p->>'customer_name', '')), '');
    v_phone   := nullif(btrim(coalesce(p->>'customer_phone', '')), '');
    v_email   := nullif(lower(btrim(coalesce(p->>'customer_email', ''))), '');
    v_address := nullif(btrim(coalesce(p->>'customer_address', '')), '');
    v_comment := nullif(btrim(coalesce(p->>'comment', '')), '');
    v_payment := (p->>'payment_method_id')::integer;
    v_delivery:= (p->>'delivery_method_id')::integer;
    v_items   := coalesce(p->'items', '[]'::jsonb);
    v_promo_code := upper(btrim(coalesce(p->>'promo_code', '')));
    v_look_id := nullif(p->>'look_id', '')::integer;
    v_pkey    := public.draft_phone_key(v_phone);
    v_ekey    := public.draft_email_key(v_email);

    if v_name is null then
        raise exception 'Укажите имя';
    end if;
    if v_phone is null and v_email is null then
        raise exception 'Укажите телефон или e-mail для связи';
    end if;
    if jsonb_array_length(v_items) = 0 then
        raise exception 'Корзина пуста';
    end if;
    if jsonb_array_length(v_items) > 50 then
        raise exception 'Слишком много позиций в заказе (максимум 50)';
    end if;

    -- построчная валидация количества (до нормализации корзины)
    for v_item in select * from jsonb_array_elements(v_items)
    loop
        v_qty := coalesce((v_item->>'quantity')::integer, 0);
        if v_qty < 1 or v_qty > 99 then
            raise exception 'Некорректное количество товара';
        end if;
    end loop;

    -- анти-спам (fix F17): телефон сравнивается нормализованным ключом —
    -- «+7 999 123-45-67» и «89991234567» один и тот же человек
    select count(*) into v_recent
    from public.orders
    where created_at > now() - interval '10 minutes'
      and ((v_pkey is not null and public.draft_phone_key(customer_phone) = v_pkey)
        or (v_email is not null and lower(coalesce(customer_email, '')) = v_email));
    if v_recent >= 3 then
        raise exception 'Слишком много заказов подряд. Пожалуйста, попробуйте через несколько минут';
    end if;

    if not exists (select 1 from public.payment_methods where id = v_payment and is_active) then
        raise exception 'Некорректный способ оплаты';
    end if;
    select base_price into v_deliv_cost
    from public.delivery_methods
    where id = v_delivery and is_active;
    if v_deliv_cost is null then
        raise exception 'Некорректный способ доставки';
    end if;

    -- (fix F23) детерминированный порядок блокировок: товары по возрастанию id,
    -- затем варианты по возрастанию id. Параллельные заказы блокируют строки
    -- в одном порядке — deadlock 40P01 исключён.
    for v_lock in
        select distinct (x->>'product_id')::integer as pid
        from jsonb_array_elements(v_items) x
        where (x->>'product_id') is not null
        order by 1
    loop
        perform 1 from public.products where id = v_lock.pid for update;
    end loop;
    for v_lock in
        select distinct (x->>'variant_id')::integer as vid
        from jsonb_array_elements(v_items) x
        where (x->>'variant_id') is not null
        order by 1
    loop
        perform 1 from public.product_variants where id = v_lock.vid for update;
    end loop;

    -- (fix F08) нормализация корзины: строки одного варианта схлопываются
    -- в одну (qty суммируется) — дубль варианта больше не проходит поштучную
    -- валидацию против одного остатка
    for v_line in
        select (x->>'product_id')::integer as product_id,
               (x->>'variant_id')::integer as variant_id,
               sum(coalesce((x->>'quantity')::integer, 0)) as qty
        from jsonb_array_elements(v_items) x
        group by 1, 2
        order by 2
    loop
        select pr.id, pr.name, pr.price, pr.is_active, vr.label, vr.stock
        into v_prod
        from public.products pr
        join public.product_variants vr on vr.product_id = pr.id
        where pr.id = v_line.product_id
          and vr.id = v_line.variant_id;

        if v_prod.id is null or not v_prod.is_active then
            raise exception 'Товар недоступен для заказа';
        end if;
        if v_line.qty > 99 then
            raise exception 'Слишком много единиц одного товара в корзине (максимум 99)';
        end if;
        if v_prod.stock < v_line.qty then
            raise exception 'Недостаточно остатка: % (%), осталось % шт.', v_prod.name, v_prod.label, v_prod.stock;
        end if;

        v_total := v_total + v_prod.price * v_line.qty;
    end loop;

    -- комплект: скидка на сумму позиций лука, ФАКТИЧЕСКИ лежащих в корзине
    if v_look_id is not null then
        select * into v_look from public.looks where id = v_look_id and is_active;
        if v_look.id is null then
            raise exception 'Комплект не найден или отключён';
        end if;
        for v_look_item in
            select li.product_id, li.variant_id, pr.price
            from public.look_items li
            join public.products pr on pr.id = li.product_id
            where li.look_id = v_look_id
        loop
            select exists (
                select 1 from jsonb_array_elements(v_items) x
                where (x->>'product_id')::integer = v_look_item.product_id
                  and (
                       (v_look_item.variant_id is null and true)
                    or (x->>'variant_id')::integer = v_look_item.variant_id
                  )
            ) into v_in_cart;
            if v_in_cart then
                v_look_sum := v_look_sum + v_look_item.price;
            end if;
        end loop;
        v_look_disc := round(v_look_sum * v_look.discount_percent / 100, 2);
    end if;

    -- промокод: проверка и расчёт скидки только на сервере;
    -- (fix F03) строка кода блокируется, лимит перепроверяется под блокировкой
    if v_promo_code <> '' then
        v_chk := public.check_promo(v_promo_code, v_total);
        if coalesce((v_chk->>'ok')::boolean, false) then
            v_discount := (v_chk->>'discount_amount')::numeric(10,2);
            select pc.id, pc.usage_limit, pc.used_count
            into v_promo
            from public.promo_codes pc
            where pc.code = v_promo_code
            for update;
            if v_promo.id is null then
                raise exception 'Промокод не найден или отключён';
            end if;
            if v_promo.usage_limit is not null and v_promo.used_count >= v_promo.usage_limit then
                raise exception 'Лимит использований промокода исчерпан';
            end if;
            v_promo_id := v_promo.id;
        else
            raise exception '%', coalesce(v_chk->>'error', 'Промокод не применён');
        end if;
    end if;

    -- клиентская база (fix F02): UPSERT вместо select-then-insert —
    -- два параллельных заказа одного нового клиента не дают сырую ошибку 23505
    if v_pkey is not null then
        begin
            insert into public.clients (full_name, phone, email, address, phone_key, email_key)
            values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
            on conflict (phone_key) do update
               set full_name  = excluded.full_name,
                   phone      = coalesce(excluded.phone, public.clients.phone),
                   email      = coalesce(excluded.email, public.clients.email),
                   address    = coalesce(excluded.address, public.clients.address),
                   email_key  = coalesce(public.clients.email_key, excluded.email_key),
                   updated_at = now()
            returning id into v_client_id;
        exception when unique_violation then
            -- e-mail уже занят другим клиентом при новом телефоне —
            -- объединяем с существующим клиентом по e-mail
            select id into v_client_id from public.clients where email_key = v_ekey limit 1;
            if v_client_id is null then
                raise exception 'Контактные данные конфликтуют с существующим клиентом — измените телефон или e-mail';
            end if;
            update public.clients
               set full_name  = v_name,
                   phone      = coalesce(phone, v_phone),
                   address    = coalesce(address, v_address),
                   phone_key  = coalesce(phone_key, v_pkey),
                   updated_at = now()
             where id = v_client_id;
        end;
    elsif v_ekey is not null then
        begin
            insert into public.clients (full_name, phone, email, address, phone_key, email_key)
            values (v_name, v_phone, v_email, v_address, v_pkey, v_ekey)
            on conflict (email_key) do update
               set full_name  = excluded.full_name,
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
               set full_name  = v_name,
                   phone      = coalesce(phone, v_phone),
                   address    = coalesce(address, v_address),
                   updated_at = now()
             where id = v_client_id;
        end;
    else
        insert into public.clients (full_name, phone, email, address)
        values (v_name, v_phone, v_email, v_address)
        returning id into v_client_id;
    end if;

    select id into v_status_new from public.order_statuses where code = 'new';

    -- (fix F07) итог не может быть отрицательным: скидки, стекающиеся
    -- сверх суммы товаров (fixed-промо + комплект), обрезаются нулём
    v_net := greatest(v_total - v_discount - v_look_disc, 0);

    insert into public.orders (
        customer_name, customer_phone, customer_email, customer_address,
        status_id, payment_method_id, delivery_method_id,
        total, delivery_cost, comment, promo_code_id, look_id,
        client_id, promo_discount, look_discount
    ) values (
        v_name, v_phone, v_email, v_address,
        v_status_new, v_payment, v_delivery,
        v_net, v_deliv_cost, v_comment, v_promo_id, v_look_id,
        v_client_id, v_discount, v_look_disc
    ) returning id into v_order_id;

    -- позиции: одна строка на вариант (итог нормализации корзины);
    -- (fix F12) join снова содержит vr.product_id = pr.id
    for v_line in
        select (x->>'product_id')::integer as product_id,
               (x->>'variant_id')::integer as variant_id,
               sum(coalesce((x->>'quantity')::integer, 0)) as qty
        from jsonb_array_elements(v_items) x
        group by 1, 2
        order by 2
    loop
        insert into public.order_items (
            order_id, product_id, variant_id, quantity, price, title_snapshot, variant_snapshot
        )
        select v_order_id, pr.id, vr.id, v_line.qty, pr.price, pr.name, vr.label
        from public.products pr
        join public.product_variants vr on vr.product_id = pr.id
        where pr.id = v_line.product_id
          and vr.id = v_line.variant_id;

        -- (fix F08) условное списание: защита от перепродажи даже если
        -- валидация выше когда-нибудь разойдётся с фактом
        update public.product_variants
           set stock = stock - v_line.qty
         where id = v_line.variant_id
           and stock >= v_line.qty;
        if not found then
            raise exception 'Недостаточно остатка на складе — обновите корзину и попробуйте снова';
        end if;
    end loop;

    -- (fix F03) условный инкремент: второй страховкой лимит не пробивается
    if v_promo_id is not null then
        update public.promo_codes
           set used_count = used_count + 1
         where id = v_promo_id
           and (usage_limit is null or used_count < usage_limit);
        if not found then
            raise exception 'Лимит использований промокода исчерпан';
        end if;
    end if;

    insert into public.deliveries (order_id, delivery_method_id, address, cost)
    select v_order_id, v_delivery, v_address, v_deliv_cost;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (v_order_id, v_status_new, 'system', 'Заказ создан на сайте');

    return jsonb_build_object(
        'order_id', v_order_id,
        'client_id', v_client_id,
        'total', v_net,
        'discount', v_discount,
        'look_discount', v_look_disc,
        'delivery_cost', v_deliv_cost,
        'grand_total', v_net + v_deliv_cost);
end;
$$;

comment on function public.create_order(jsonb) is
    'v6: серверные цены/скидки (браузер не считается) + клиентская база; fix F02 (UPSERT клиента), F03 (блокировка и условный инкремент промокода), F07 (greatest 0), F08 (нормализация дублей варианта, условное списание), F12 (join vr.product_id = pr.id), F17 (анти-спам по draft_phone_key), F23 (детерминированный порядок блокировок)';

-- ----------------------------------------------------------------------------
-- 4. Констрейнт: итог заказа >= 0 (F07)
--    DANGER-блок: отрицательные итоги — след бага, воспроизведённого в ревью
--    (fixed-промо + скидка комплекта). Данные черновика тестовые: такие строки
--    обнуляются, количество выводится в самопроверке. Блок идемпотентен.
-- ----------------------------------------------------------------------------
update public.orders set total = 0 where total < 0;   -- DANGER: правка данных (см. шапку, F07)

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'orders_total_nonneg'
          and conrelid = 'public.orders'::regclass
    ) then
        if exists (select 1 from public.orders where total < 0) then
            raise exception 'DANGER: в orders остались строки с total < 0 — констрейнт не добавить. Выполните блок 4 вручную после разбора данных.';
        end if;
        alter table public.orders add constraint orders_total_nonneg check (total >= 0);
    end if;
end $$;

comment on constraint orders_total_nonneg on public.orders is
    'Итог заказа (за вычетом скидок) не может быть отрицательным — fix F07 (ревью v0.13.1)';

-- ----------------------------------------------------------------------------
-- 5. DELETE-политики способов оплаты/доставки (F09): удаление из админки
--    перестаёт быть «фейковым успехом». Способы, использованные в заказах,
--    защищает FK (orders.payment_method_id / orders.delivery_method_id /
--    deliveries.delivery_method_id) — ошибка 23503, фронт покажет её читаемо.
-- ----------------------------------------------------------------------------
--  Чтение справочников anon открывается ПОЛНОСТЬЮ (было: только активные
--  строки). Причина: админка «Управление → Оплата и доставка» работает под
--  anon — отключённый способ был невидим: его нельзя было включить обратно
--  (UPDATE 0), удалить (DELETE 0) — он просто исчезал из списка. Граница
--  «в заказе только активные способы» обеспечивается сервером: create_order
--  проверяет is_active (скрипт 16, блок 3), витрина и draft_storefront_bundle
--  запрашивают только активные строки. Состав способов не секретен.
drop policy if exists anon_read_delivery_methods on public.delivery_methods;
create policy anon_read_delivery_methods on public.delivery_methods
    for select to anon, authenticated using (true);

drop policy if exists anon_read_payment_methods on public.payment_methods;
create policy anon_read_payment_methods on public.payment_methods
    for select to anon, authenticated using (true);

drop policy if exists draft_anon_delete_delivery_methods on public.delivery_methods;
create policy draft_anon_delete_delivery_methods on public.delivery_methods
    for delete to anon, authenticated using (true);   -- FK не даст удалить способ с заказами

drop policy if exists draft_anon_delete_payment_methods on public.payment_methods;
create policy draft_anon_delete_payment_methods on public.payment_methods
    for delete to anon, authenticated using (true);   -- FK не даст удалить способ с заказами

-- ----------------------------------------------------------------------------
-- 6. draft_storefront_bundle() (F27): витрина одним запросом
--    (9 параллельных fetch site.js → один RPC; состав повторяет прежние
--    запросы витрины, включая строки брендбука для применения токенов)
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
                     from public.brand_colors bc)
);
$$;

comment on function public.draft_storefront_bundle() is
    'Черновик: все данные витрины (каталог, справочники, тексты, луки, токены брендбука) одним RPC — fix F27, прототип боевого GET /api/storefront';

-- ----------------------------------------------------------------------------
-- 7. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_policies
      where tablename in ('delivery_methods', 'payment_methods')
        and policyname like 'draft_anon_delete_%')                       as method_delete_policies,  -- ожидаем 2
    (select count(*) from pg_policies
      where tablename in ('delivery_methods', 'payment_methods')
        and policyname like 'anon_read_%' and qual = 'true')             as methods_readable_all,    -- ожидаем 2
    (select count(*) from pg_constraint
      where conname = 'orders_total_nonneg'
        and conrelid = 'public.orders'::regclass)                        as total_nonneg_constraint, -- ожидаем 1
    (select count(*) from public.orders where total < 0)                 as negative_totals,         -- ожидаем 0
    (select count(*) from jsonb_array_elements(draft_storefront_bundle() -> 'products'))  as products_in_bundle,   -- ожидаем 8 (демо-каталог)
    (select count(*) from jsonb_array_elements(draft_storefront_bundle() -> 'content'))   as content_keys,         -- ожидаем 34
    (select count(*) from jsonb_array_elements(draft_storefront_bundle() -> 'brand'))     as brand_tokens,         -- ожидаем 20
    (select prosrc like '%(''new'', ''confirmed'', ''packing'')%' from pg_proc
      where proname = 'draft_reserved_map')                               as reserved_map_fixed,      -- ожидаем true (F18: список без paid)
    (select prosrc like '%for update%' from pg_proc
      where proname = 'admin_set_status')                                as set_status_locks,        -- ожидаем true
    (select prosrc like '%on conflict (phone_key)%' from pg_proc
      where proname = 'create_order')                                    as create_order_v6;         -- ожидаем true
