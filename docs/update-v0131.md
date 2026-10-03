# Инструкция по обновлению черновика до v0.13.1-draft

**Куда смотреть:** этот файл — порядок применения обновления v0.13.0 → v0.13.1
(patch-волна: хотфикс SQL-скрипта 15 — ошибка 42803 при создании `draft_clients_bundle()`).

## 1. Что сломалось и почему

При выполнении `supabase/15_clients_and_promo_stats.sql` в SQL Editor Supabase
падал с ошибкой:

```
ERROR: 42803: aggregate function calls cannot be nested
LINE 471: 'orders', count(*), ^
```

Причина: в теле `public.draft_clients_bundle()` блок `'stats'` собирался как
`jsonb_agg(jsonb_build_object(..., count(*), sum(...), min(...), max(...)))` с
`group by o.client_id` — то есть агрегатные функции стояли **внутри аргумента
другой агрегатной функции** (`jsonb_agg`). Postgres такое запрещает (42803):
на одном уровне запроса агрегат не может быть аргументом агрегата.

Всё, что шло в скрипте до этой функции (таблица `clients`, политики, колонка
`orders.client_id`, миграция заказов, `create_order v5`, `draft_admin_bundle v2`),
успело выполниться до ошибки — база осталась в консистентном состоянии.

## 2. Как починено

Агрегаты вынесены во внутренний подзапрос (первая ступень), а `jsonb_agg`
оборотачивает уже готовые строки (вторая ступень):

```sql
'stats', (select coalesce(jsonb_agg(jsonb_build_object(
                'client_id',   s.client_id,
                'orders',      s.orders_cnt,
                'sum',         s.sum_total,
                'paid_sum',    s.sum_paid,
                'first_order', s.first_order,
                'last_order',  s.last_order
            )), '[]'::jsonb)
          from (select o.client_id                            as client_id,
                       count(*)                               as orders_cnt,
                       sum(o.total + o.delivery_cost)         as sum_total,
                       sum(case when o.is_paid then o.total + o.delivery_cost
                                else 0 end)                   as sum_paid,
                       min(o.created_at)                      as first_order,
                       max(o.created_at)                      as last_order
                  from public.orders o
                 where o.client_id is not null
                 group by o.client_id) s)
```

Ключи объекта статистики (`client_id`, `orders`, `sum`, `paid_sum`,
`first_order`, `last_order`) не изменились — `assets/js/clients.js` править не
нужно. Функция помечена как v2 в комментарии.

Проверка: все 15 скриптов прогнаны по порядку на живом PostgreSQL 15
(локальный тестовый кластер) — выполнение без ошибок; самопроверка скрипта 15
даёт ожидаемые значения; вызов `draft_clients_bundle()` на тестовых данных
(1 клиент, 2 заказа, один оплачен) возвращает корректную статистику:
`orders = 2`, `sum = 1800`, `paid_sum = 1300`, даты первого/последнего заказа.

## 3. Файлы для загрузки (по папкам, откуда брать)

- **Корень репозитория:** `README.md`, `SECURITY.md`, `LICENSE.md`
- **assets/js/:** `config.js`
- **supabase/:** `15_clients_and_promo_stats.sql`
- **docs/:** `update-v0131.md`, `tehpasport.md`
- **tests/:** `check-repo.py`

## 4. Версия

В `assets/js/config.js` поменять **только строку**
`const SITE_VERSION = '0.13.0-draft';` → `'0.13.1-draft';`.
Ключи базы (`SUPABASE_URL`, `SUPABASE_ANON_KEY`) в GitHub-копии настоящие —
целиком файл не перезаписывать, править только версию.

## 5. База, публикация и проверка

1. В Supabase SQL Editor выполнить исправленный скрипт 15 **целиком**
   (файл `supabase/15_clients_and_promo_stats.sql` из репозитория, заменить им
   содержимое запроса). Скрипт идемпотентен: уже созданные таблицу `clients`,
   колонку `orders.client_id` и функции он пересоздаст/пропустит без потерь.
   В конце должна вывестись самопроверка (9-й раздел):
   `orders_linked = orders_total`, `discounts_missing = 0`, `client_policies = 4`.
2. Push в `main` → Pages → **Ctrl + F5** (визуальных изменений нет).
3. Чек-лист приёмки:
   - скрипт 15 выполняется без ошибки 42803 и выводит самопроверку;
   - админка → «Пользователи → Клиенты»: список открывается, карточка клиента
     показывает строку «Заказов: N · на сумму … (оплачено …) · первый … · последний …»
     без `undefined` и `NaN`;
   - `python3 tests/check-repo.py` завершается с кодом 0.

## 6. Финальная проверка

Локально: `python3 tests/check-repo.py` (выход 0). Зеркало:
`cd "$ARENA_WORKSPACE" && cp sisku-draft/*.html sisku-draft/README.md sisku-draft/LICENSE.md sisku-draft/SECURITY.md sisku-pages/`.
Архив: пересобрать `sisku-draft.zip` (файлы в корне архива).

## 7. Урок для регламента

Правило дополняет `supabase/README.md`: агрегатные функции
(`count/sum/min/max/jsonb_agg/string_agg`) нельзя вкладывать друг в друга на
одном уровне запроса (Postgres 42803). Если нужен «массив агрегатов» —
сначала `group by` в подзапросе/CTE, затем `jsonb_agg` по его строкам.
Синтаксический парсер (pglast) ошибку 42803 не ловит — она семантическая,
поэтому такие места проверяются прогоном на реальном Postgres.
