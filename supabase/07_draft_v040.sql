-- ============================================================================
--  SISKU (черновик) — СКРИПТ 7: миграция живой базы к v0.4.0-draft
-- ============================================================================
--  1. Текст оплаты в «Условиях заказа»: три способа — СБП, перевод по номеру
--     карты, наличными при самовывозе.
--  2. admin_set_paid(): у ЗАКРЫТЫХ отменой заказов оплата больше не
--     переключается (ни установить, ни снять) — защита от случайных кликов;
--     проверка дублируется в интерфейсе админки.
--  3. Таблица admin_users для страницы «Пользователи»: ФИО, почта,
--     мессенджер, роль, хеш пароля. Роли черновика: admin, assembler,
--     manager, partner (без ограничения страниц — модель только копится).
--     Пароль хранится хешем SHA-256 ТОЛЬКО потому, что это макет; в боевой
--     версии — bcrypt/argon2id (см. migration-plan.md).
--  Скрипт идемпотентен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Текст оплаты
-- ----------------------------------------------------------------------------
update public.site_content
   set value = 'Три способа оплаты: перевод через СБП, перевод по номеру карты или наличными при самовывозе из шоурума. Способ фиксируется при подтверждении заказа менеджером.',
       updated_at = now()
 where key = 'order.payment.text';

-- ----------------------------------------------------------------------------
-- 2. Защита оплаты у отменённых заказов
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_paid(p_order_id integer, p_is_paid boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_status text;
begin
    select s.code into v_status
    from public.orders o
    join public.order_statuses s on s.id = o.status_id
    where o.id = p_order_id;

    if v_status is null then
        raise exception 'Заказ не найден';
    end if;
    if v_status = 'cancelled' then
        raise exception 'Заказ отменён: изменять признак оплаты нельзя';
    end if;

    update public.orders
       set is_paid = p_is_paid,
           paid_at = case when p_is_paid then coalesce(paid_at, now()) else null end
     where id = p_order_id;

    return jsonb_build_object('ok', true, 'is_paid', p_is_paid);
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. Пользователи админ-панели (черновая ролевая модель)
-- ----------------------------------------------------------------------------
create table if not exists public.admin_users (
    id             serial primary key,
    fio            text not null,
    email          text not null,
    messenger_url  text,
    role           text not null check (role in ('admin', 'assembler', 'manager', 'partner')),
    password_hash  text not null,          -- SHA-256 (только для макета!)
    is_active      boolean not null default true,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);
comment on table  public.admin_users is 'Черновой список администраторов: роли копятся, страницы не ограничивают';
comment on column public.admin_users.password_hash is 'SHA-256 от пароля; в боевой версии заменяется на bcrypt/argon2id';

alter table public.admin_users enable row level security;

drop policy if exists draft_anon_read_admin_users on public.admin_users;
create policy draft_anon_read_admin_users on public.admin_users
    for select to anon, authenticated using (true);

drop policy if exists draft_anon_insert_admin_users on public.admin_users;
create policy draft_anon_insert_admin_users on public.admin_users
    for insert to anon, authenticated with check (true);

drop policy if exists draft_anon_update_admin_users on public.admin_users;
create policy draft_anon_update_admin_users on public.admin_users
    for update to anon, authenticated using (true) with check (true);

-- стартовая запись-пример (пароль 123456, как на экране входа)
insert into public.admin_users (fio, email, messenger_url, role, password_hash)
select 'Иванов Иван Иванович', 'owner@sisku.example', 'https://t.me/sisku_owner', 'admin',
       '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'
where not exists (select 1 from public.admin_users where email = 'owner@sisku.example');

-- ----------------------------------------------------------------------------
-- 4. Самопроверка
-- ----------------------------------------------------------------------------
select
    (select value from public.site_content where key = 'order.payment.text') like '%Три способа оплаты%' as payment_text_ok,
    (select count(*) from public.admin_users) as users_count;
