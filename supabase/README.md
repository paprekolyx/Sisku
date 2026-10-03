# supabase/ — скрипты изменения базы данных (черновик Sisku)

SQL-скрипты проекта Supabase `sisku-draft`. Выполняются в Supabase → SQL Editor
по порядку номеров, все идемпотентны (повторный запуск безопасен).

## Порядок и состав

| Файл | Что делает |
|---|---|
| `01_schema.sql` | таблицы каталога, заказов, справочников + включение RLS |
| `02_rls_and_access.sql` | политики чтения (каталог публичен; заказы читаются — черновик без пароля) |
| `03_functions.sql` | `create_order()`, `admin_set_status()`, `admin_set_paid()` |
| `04_seed_references_and_content.sql` | статусы, модель переходов, оплата/доставка, тексты site_content |
| `05_seed_catalog.sql` | запасной посев каталога без CSV |
| `06_remove_paid_status.sql` | миграция v0.2.0: статус «Оплачен» вынесен в признак |
| `07_draft_v040.sql` | миграция v0.4.0: текст оплаты, защита отменённых, `admin_users` |
| `08_text_fixes.sql` | текстовая правка вычитки v0.4.0 |
| `09_admin_bundles.sql` | запросы-сборки против медленной загрузки |
| `10_promo_and_tracking.sql` | промокоды (`check_promo`, create_order v2) и `track_order` |
| `11_product_management.sql` | anon-запись каталога для CRUD из админки + префлайт проекта |
| `12_manage_policies.sql` | anon-запись брендов, способов оплаты/доставки, site_content |
| `13_reserve_and_looks.sql` | резервирование (возврат остатков), `draft_reserved_map`, комплекты, create_order v3 |
| `14_brandbook.sql` | `brand_colors`, `brand_templates`, create_order v4 (частичный комплект) |

## Правила написания скриптов (регламент проекта)

1. **Идемпотентность:** `create table if not exists`, `add column if not exists`,
   `drop policy if exists` перед `create policy`, `on conflict … do nothing` в посевах.
2. **Никаких разрушающих действий** (`drop table`, `truncate`, `delete` без where)
   без пометки DANGER и резервной копии.
3. **Один скрипт — одна задача;** номер файла не переиспользуется.
4. **Доллар-квоты только парные:** `as $$ … $$;`. Одиночный `$` — синтаксическая
   ошибка 42601; проверяется автотестом `tests/check-repo.py`.
5. **Системный каталог политик RLS:** колонка называется **`pg_policies.policyname`**
   (без внутреннего подчёркивания!). Писать `policy_name` — ошибка 42703.
   Автотест `tests/check-repo.py` падает, если в `supabase/*.sql` встречается
   `policy_name`.
6. **Префлайт проекта:** скрипты, которые могут быть выполнены не в том проекте
   Supabase, начинаются с `do $$ … to_regclass(...) … $$`-проверки наличия таблиц
   черновика и падают с понятным текстом (см. скрипты 11, 12).
7. **Комментарий в шапке:** что делает, зачем, безопасно ли; в конце — самопроверка
   select-ом ожидаемых значений.
