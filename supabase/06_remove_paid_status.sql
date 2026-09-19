-- ============================================================================
--  SISKU (черновик) — СКРИПТ 6: миграция живой базы к v0.2.0-draft
-- ============================================================================
--  1. Статус «Оплачен» УБИРАЕТСЯ из статусной модели: оплата — это булев
--     признак orders.is_paid + дата paid_at (отдельная кнопка в админке),
--     а не этап воронки. Модель переходов становится:
--        new → confirmed → packing → shipped → delivered → returned
--        (+ отмены из new / confirmed).
--     Накопительная история оплат не теряется: признак is_paid/paid_at
--     остаётся на заказе и виден в карточке и в списке.
--  2. Контакты: WhatsApp заменяется на Telegram; добавлен ключ
--     contacts.repo_url (ссылка на репозиторий под блоком контактов).
--
--  Безопасность миграции: заказы, стоявшие в статусе «Оплачен», переводятся
--  в «Подтверждён» (оплата при этом видна по признаку is_paid); записи
--  журнала о входе в «Оплачен» удаляются (в черновике журнала мало,
--  информация об оплате сохранена в is_paid/paid_at).
--  Скрипт идемпотентен: повторный запуск не ломает ничего (все действия
--  с проверками «если существует»).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Уводим заказы из статуса paid в confirmed
-- ----------------------------------------------------------------------------
update public.orders
   set status_id = (select id from public.order_statuses where code = 'confirmed')
 where status_id = (select id from public.order_statuses where code = 'paid')
   and exists (select 1 from public.order_statuses where code = 'paid');

-- ----------------------------------------------------------------------------
-- 2. Чистим журнал и переходы, связанные с paid
-- ----------------------------------------------------------------------------
delete from public.order_status_history
 where status_id = (select id from public.order_statuses where code = 'paid');

delete from public.status_transitions
 where from_status_id = (select id from public.order_statuses where code = 'paid')
    or to_status_id   = (select id from public.order_statuses where code = 'paid');

-- ----------------------------------------------------------------------------
-- 3. Новый переход confirmed → packing (ранее шёл через paid)
-- ----------------------------------------------------------------------------
insert into public.status_transitions (from_status_id, to_status_id)
select a.id, b.id
from public.order_statuses a, public.order_statuses b
where a.code = 'confirmed' and b.code = 'packing'
  and not exists (
    select 1 from public.status_transitions t
    where t.from_status_id = a.id and t.to_status_id = b.id
  );

-- ----------------------------------------------------------------------------
-- 4. Удаляем сам статус и правим порядок сортировки
-- ----------------------------------------------------------------------------
delete from public.order_statuses where code = 'paid';

update public.order_statuses s set sort_order = v.sort_order
from (values
    ('new', 1), ('confirmed', 2), ('packing', 3), ('shipped', 4),
    ('delivered', 5), ('cancelled', 6), ('returned', 7)
) as v(code, sort_order)
where s.code = v.code;

-- ----------------------------------------------------------------------------
-- 5. site_content: Telegram вместо WhatsApp + ссылка на репозиторий
-- ----------------------------------------------------------------------------
update public.site_content set value = 'Написать в Telegram', updated_at = now()
 where key = 'contacts.messenger';
update public.site_content set value = 'https://t.me/sisku_shop', updated_at = now()
 where key = 'contacts.messenger_url';

insert into public.site_content (key, value, description)
values ('contacts.repo_url', 'https://github.com/paprekolyx/Sisku',
        'Контакты: ссылка на репозиторий макета под блоком контактов')
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 6. Самопроверка: статусов paid быть не должно, переход confirmed→packing есть
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.order_statuses where code = 'paid')              as paid_statuses_left,   -- ждём 0
    (select count(*) from public.status_transitions t
       join public.order_statuses a on a.id = t.from_status_id
       join public.order_statuses b on b.id = t.to_status_id
      where a.code = 'confirmed' and b.code = 'packing')                          as confirmed_to_packing, -- ждём 1
    (select value from public.site_content where key = 'contacts.messenger')      as messenger;            -- ждём «Написать в Telegram»
