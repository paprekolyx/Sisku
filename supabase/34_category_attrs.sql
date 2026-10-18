-- ============================================================================
--  SISKU (черновик) — СКРИПТ 34: атрибуты по категориям (волна v0.22.0, fp №14)
-- ============================================================================
--  Цель: EAV-атрибуты категорий — конструктор атрибутов в админке
--  («Магазин → Категории»), динамическая секция «Характеристики» в карточке
--  товара, чипы и блок характеристик на витрине, фильтрация каталога по
--  разрешённым атрибутам (ответ 7.8 — флаг is_filterable; Д9 — блок фильтров
--  только при выбранной одной категории).
--  Волна: v0.22.0 (MINOR) · версия сайта: 0.21.1-draft → 0.22.0-draft.
--  Порядок: baseline 01–05, 09 (ревизия 2) → 34 → 35. Живая база (F21):
--  только инкременты, baseline не перезапускать; посев — один раз
--  (on conflict do nothing), повторный прогон — no-op.
--  Идемпотентен: create table if not exists / drop-create policy /
--  on conflict do nothing / create or replace function.
--  RLS (Д5-паттерн бейджей, скрипт 33): чтение публичное (anon,
--  authenticated — одна политика на таблицу, как в скрипте 33); записи —
--  только через RPC (SECURITY DEFINER), write-политик нет. +2 политики → 74.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Префлайт: проект и baseline на месте
-- ----------------------------------------------------------------------------
do $$
begin
    if to_regclass('public.categories') is null or to_regclass('public.products') is null then
        raise exception 'Скрипт 34: таблицы categories/products не найдены — выбран не тот проект Supabase или не выполнен baseline 01';
    end if;
    if to_regprocedure('public.draft_storefront_bundle()') is null then
        raise exception 'Скрипт 34: функция draft_storefront_bundle не найдена — сначала выполните baseline 01–05, 09 (ревизия 2)';
    end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 1. Таблицы: справочник атрибутов категорий и значения товаров
-- ----------------------------------------------------------------------------
create table if not exists public.category_attrs (
    id            serial primary key,
    category_id   integer not null references public.categories(id) on delete cascade,
    code          text not null,                      -- snake_case латиницей
    name          text not null,
    type          text not null check (type in ('text', 'number', 'enum')),
    enum_values   jsonb not null default '[]',        -- массив строк для type = enum
    sort_order    integer not null default 1,
    show_in_list  boolean not null default false,     -- чипы у карточек списка витрины
    is_filterable boolean not null default false,     -- фильтр каталога (ответ 7.8)
    is_active     boolean not null default true,
    created_at    timestamptz not null default now(),
    unique (category_id, code)
);

create table if not exists public.product_attrs (
    id         serial primary key,
    product_id integer not null references public.products(id) on delete cascade,
    attr_id    integer not null references public.category_attrs(id) on delete cascade,
    value      text not null default '',
    created_at timestamptz not null default now(),
    unique (product_id, attr_id)
);

create index if not exists category_attrs_category_idx on public.category_attrs (category_id);
create index if not exists product_attrs_product_idx   on public.product_attrs (product_id);
create index if not exists product_attrs_attr_idx      on public.product_attrs (attr_id);

-- ----------------------------------------------------------------------------
-- 2. RLS: публичное чтение; запись — только через RPC (write-политик нет)
-- ----------------------------------------------------------------------------
alter table public.category_attrs enable row level security;
alter table public.product_attrs  enable row level security;

drop policy if exists anon_read_category_attrs on public.category_attrs;
create policy anon_read_category_attrs on public.category_attrs
    as permissive
    for select
    to anon, authenticated
    using (true);

drop policy if exists anon_read_product_attrs on public.product_attrs;
create policy anon_read_product_attrs on public.product_attrs
    as permissive
    for select
    to anon, authenticated
    using (true);

-- ----------------------------------------------------------------------------
-- 3. Посев: 53 атрибута всех 6 категорий (приложение Б черновика v0.22.0;
--    источник — набор аналитика 05.10.2026 в fp №14, согласован владельцем
--    06.10.2026 — «не сокращённый состав»: общие страна производства/уход/
--    комплектация добавлены в каждую категорию без дублей).
--    Флаги (Д2): is_filterable — все enum (22); show_in_list — по пометкам
--    «В списке: …» набора fp №14 (11: состав/посадка — верхняя одежда,
--    состав/длина — платья, состав/крой — трикотаж, состав/посадка — рубашки,
--    стойкость/концентрация — парфюмерия, материал — аксессуары).
--    F21: вставляются только отсутствующие строки; повторный прогон — no-op.
-- ----------------------------------------------------------------------------
insert into public.category_attrs
    (category_id, code, name, type, enum_values, sort_order, show_in_list, is_filterable)
select c.id, v.code, v.name, v.type, v.enum_values, v.sort_order, v.show_in_list, v.is_filterable
  from (values
    -- 1. Верхняя одежда (9)
    ('Верхняя одежда', 'composition',   'Состав',                'text',   '[]'::jsonb,                                                1, true,  false),
    ('Верхняя одежда', 'lining',        'Подкладка',             'text',   '[]'::jsonb,                                                2, false, false),
    ('Верхняя одежда', 'fit',           'Посадка',               'enum',   '["маломерит","в размер","большемерит"]'::jsonb,            3, true,  true),
    ('Верхняя одежда', 'cut',           'Крой',                  'enum',   '["прямой","свободный","приталенный"]'::jsonb,               4, false, true),
    ('Верхняя одежда', 'length',        'Длина',                 'enum',   '["укороченное","миди","длинное"]'::jsonb,                   5, false, true),
    ('Верхняя одежда', 'season',        'Сезон',                 'enum',   '["демисезон","зима","всесезон"]'::jsonb,                    6, false, true),
    ('Верхняя одежда', 'care',          'Уход',                  'text',   '[]'::jsonb,                                                7, false, false),
    ('Верхняя одежда', 'country',       'Страна производства',   'text',   '[]'::jsonb,                                                8, false, false),
    ('Верхняя одежда', 'kit',           'Комплектация',          'text',   '[]'::jsonb,                                                9, false, false),
    -- 2. Платья (9)
    ('Платья',         'composition',   'Состав',                'text',   '[]'::jsonb,                                                1, true,  false),
    ('Платья',         'cut',           'Крой',                  'enum',   '["прямой","свободный","приталенный"]'::jsonb,               2, false, true),
    ('Платья',         'length',        'Длина',                 'enum',   '["мини","миди","макси"]'::jsonb,                           3, true,  true),
    ('Платья',         'sleeve',        'Рукав',                 'enum',   '["без","короткий","длинный"]'::jsonb,                       4, false, true),
    ('Платья',         'fit',           'Посадка',               'enum',   '["маломерит","в размер","большемерит"]'::jsonb,            5, false, true),
    ('Платья',         'occasion',      'Повод',                 'enum',   '["повседневное","офис","вечер"]'::jsonb,                   6, false, true),
    ('Платья',         'care',          'Уход',                  'text',   '[]'::jsonb,                                                7, false, false),
    ('Платья',         'country',       'Страна производства',   'text',   '[]'::jsonb,                                                8, false, false),
    ('Платья',         'kit',           'Комплектация',          'text',   '[]'::jsonb,                                                9, false, false),
    -- 3. Трикотаж (8)
    ('Трикотаж',       'composition',   'Состав',                'text',   '[]'::jsonb,                                                1, true,  false),
    ('Трикотаж',       'yarn',          'Пряжа/толщина',         'text',   '[]'::jsonb,                                                2, false, false),
    ('Трикотаж',       'cut',           'Крой',                  'enum',   '["прямой","свободный","приталенный"]'::jsonb,               3, true,  true),
    ('Трикотаж',       'neckline',      'Воротник',              'enum',   '["круглый","V-образный","водолазка"]'::jsonb,              4, false, true),
    ('Трикотаж',       'season',        'Сезон',                 'enum',   '["демисезон","зима","всесезон"]'::jsonb,                    5, false, true),
    ('Трикотаж',       'care',          'Уход',                  'text',   '[]'::jsonb,                                                6, false, false),
    ('Трикотаж',       'country',       'Страна производства',   'text',   '[]'::jsonb,                                                7, false, false),
    ('Трикотаж',       'kit',           'Комплектация',          'text',   '[]'::jsonb,                                                8, false, false),
    -- 4. Рубашки и блузы (9)
    ('Рубашки и блузы','composition',   'Состав',                'text',   '[]'::jsonb,                                                1, true,  false),
    ('Рубашки и блузы','fabric',        'Ткань/переплетение',    'enum',   '["поплин","оксфорд","сатин"]'::jsonb,                      2, false, true),
    ('Рубашки и блузы','cut',           'Крой',                  'enum',   '["прямой","свободный","приталенный"]'::jsonb,               3, false, true),
    ('Рубашки и блузы','neckline',      'Воротник',              'enum',   '["классический","на пуговице","стойка"]'::jsonb,           4, false, true),
    ('Рубашки и блузы','cuff',          'Манжет',                'enum',   '["прямой","на пуговице","французский"]'::jsonb,            5, false, true),
    ('Рубашки и блузы','fit',           'Посадка',               'enum',   '["маломерит","в размер","большемерит"]'::jsonb,            6, true,  true),
    ('Рубашки и блузы','care',          'Уход',                  'text',   '[]'::jsonb,                                                7, false, false),
    ('Рубашки и блузы','country',       'Страна производства',   'text',   '[]'::jsonb,                                                8, false, false),
    ('Рубашки и блузы','kit',           'Комплектация',          'text',   '[]'::jsonb,                                                9, false, false),
    -- 5. Парфюмерия (12)
    ('Парфюмерия',     'concentration', 'Концентрация',          'enum',   '["eau de parfum","extrait","eau de toilette"]'::jsonb,     1, true,  true),
    ('Парфюмерия',     'volume',        'Объём',                 'text',   '[]'::jsonb,                                                2, false, false),
    ('Парфюмерия',     'top_notes',     'Верхние ноты',          'text',   '[]'::jsonb,                                                3, false, false),
    ('Парфюмерия',     'heart_notes',   'Ноты сердца',           'text',   '[]'::jsonb,                                                4, false, false),
    ('Парфюмерия',     'base_notes',    'Базовые ноты',          'text',   '[]'::jsonb,                                                5, false, false),
    ('Парфюмерия',     'longevity',     'Стойкость',             'enum',   '["до 4 ч","4–6 ч","6–8 ч","8+ ч"]'::jsonb,                 6, true,  true),
    ('Парфюмерия',     'sillage',       'Шлейф',                 'enum',   '["близкий","умеренный","сильный"]'::jsonb,                 7, false, true),
    ('Парфюмерия',     'season_time',   'Сезон/время суток',     'enum',   '["универсальное","дневное","вечернее"]'::jsonb,            8, false, true),
    ('Парфюмерия',     'house',         'Дом/страна',            'text',   '[]'::jsonb,                                                9, false, false),
    ('Парфюмерия',     'care',          'Уход',                  'text',   '[]'::jsonb,                                               10, false, false),
    ('Парфюмерия',     'country',       'Страна производства',   'text',   '[]'::jsonb,                                               11, false, false),
    ('Парфюмерия',     'kit',           'Комплектация',          'text',   '[]'::jsonb,                                               12, false, false),
    -- 6. Аксессуары (6)
    ('Аксессуары',     'material',      'Материал',              'enum',   '["шёлк","кожа","шерсть","смесовый"]'::jsonb,                1, true,  true),
    ('Аксессуары',     'sizes',         'Размеры',               'text',   '[]'::jsonb,                                                2, false, false),
    ('Аксессуары',     'hardware',      'Фурнитура/цвет',        'text',   '[]'::jsonb,                                                3, false, false),
    ('Аксессуары',     'kit',           'Комплектация',          'text',   '[]'::jsonb,                                                4, false, false),
    ('Аксессуары',     'care',          'Уход',                  'text',   '[]'::jsonb,                                                5, false, false),
    ('Аксессуары',     'country',       'Страна производства',   'text',   '[]'::jsonb,                                                6, false, false)
  ) as v (cat_name, code, name, type, enum_values, sort_order, show_in_list, is_filterable)
  join public.categories c on c.name = v.cat_name
on conflict (category_id, code) do nothing;

-- ----------------------------------------------------------------------------
-- 4. Комментарии таблиц и колонок
-- ----------------------------------------------------------------------------
comment on table public.category_attrs is
    'Справочник атрибутов категорий (волна v0.22.0, fp №14 — EAV): конструктор в «Магазин → Категории» (RPC admin_save_category_attr / admin_delete_category_attr); посев — 53 атрибута всех 6 категорий (набор аналитика 05.10.2026, согласован владельцем 06.10.2026 — «не сокращённый состав»); unique (category_id, code) — общие атрибуты разных категорий — разные строки; удаление атрибута — каскад значений product_attrs (подтверждение в UI); чтение публичное, запись — только RPC';
comment on column public.category_attrs.type is
    'Тип атрибута: text (строка), number (число), enum (выпадающий список из enum_values); CHECK-констрейнт';
comment on column public.category_attrs.show_in_list is
    'Показывать значение чипом у карточек товара в списке витрины (пометки «В списке: …» набора fp №14 — 11 атрибутов посева)';
comment on column public.category_attrs.is_filterable is
    'Может использоваться для фильтрации каталога витрины (ответ 7.8 — 10.10.2026; все enum-атрибуты посева — 22); неразрешённые — только чипы; блок фильтров — при выбранной одной категории (Д9; общие атрибуты всех категорий — fp №14b)';
comment on table public.product_attrs is
    'Значения атрибутов товаров (волна v0.22.0, fp №14): unique (product_id, attr_id); сохранение набора — RPC draft_save_product_attrs одной транзакцией (пустое значение — удаление строки); значения атрибутов другой категории (после смены категории товара) остаются в БД до правки, но не отображаются (бандлы фильтруют по категории товара)';

-- ----------------------------------------------------------------------------
-- 5. RPC: конструктор атрибутов (админка) и значения товара
--    Валидации «только цифры/латиница» — паттерном [^…] без якоря-доллара
--    (урок v0.19.0: одиночные доллары в скриптах под запретом)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_save_category_attr(p_attr jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_id_text  text;
    v_id       integer;
    v_cat_text text;
    v_cat_id   integer;
    v_code     text;
    v_name     text;
    v_type     text;
    v_enum     jsonb;
    v_sort_txt text;
    v_sort     integer;
    v_show     boolean;
    v_filter   boolean;
    v_active   boolean;
    v_new_id   integer;
begin
    if p_attr is null or jsonb_typeof(p_attr) <> 'object' then
        raise exception 'Параметр p_attr — не объект';
    end if;

    v_id_text := trim(coalesce(p_attr->>'id', ''));
    if v_id_text <> '' then
        if v_id_text ~ '[^0-9]' then
            raise exception 'id атрибута — не число';
        end if;
        v_id := v_id_text::integer;
        if not exists (select 1 from public.category_attrs where id = v_id) then
            raise exception 'Атрибут не найден: id %', v_id;
        end if;
    end if;

    v_cat_text := trim(coalesce(p_attr->>'category_id', ''));
    if v_cat_text = '' or v_cat_text ~ '[^0-9]' then
        raise exception 'category_id не указан или не число';
    end if;
    v_cat_id := v_cat_text::integer;
    if not exists (select 1 from public.categories where id = v_cat_id) then
        raise exception 'Категория не найдена: id %', v_cat_id;
    end if;

    v_code := lower(trim(coalesce(p_attr->>'code', '')));
    if v_code = '' then
        raise exception 'Код атрибута пуст';
    end if;
    if length(v_code) > 50 then
        raise exception 'Код атрибута длиннее 50 символов';
    end if;
    if v_code ~ '[^a-z0-9_]' then
        raise exception 'Код атрибута — только строчная латиница, цифры и «_»';
    end if;

    v_name := trim(coalesce(p_attr->>'name', ''));
    if v_name = '' then
        raise exception 'Название атрибута пусто';
    end if;
    if length(v_name) > 100 then
        raise exception 'Название атрибута длиннее 100 символов';
    end if;

    v_type := lower(trim(coalesce(p_attr->>'type', 'text')));
    if v_type not in ('text', 'number', 'enum') then
        raise exception 'Тип атрибута — text, number или enum';
    end if;

    v_enum := coalesce(p_attr->'enum_values', '[]'::jsonb);
    if jsonb_typeof(v_enum) <> 'array' then
        raise exception 'enum_values — не массив';
    end if;
    if v_type = 'enum' then
        if jsonb_array_length(v_enum) = 0 then
            raise exception 'Атрибут enum: нужно хотя бы одно значение';
        end if;
        if jsonb_array_length(v_enum) > 50 then
            raise exception 'Атрибут enum: значений больше 50';
        end if;
        if exists (select 1 from jsonb_array_elements_text(v_enum) as t(v)
                    where nullif(trim(t.v), '') is null or length(trim(t.v)) > 100) then
            raise exception 'Значение enum: пустое или длиннее 100 символов';
        end if;
        select jsonb_agg(trim(t.v) order by t.ord)
          into v_enum
          from jsonb_array_elements_text(v_enum) with ordinality as t(v, ord);
    else
        v_enum := '[]'::jsonb;
    end if;

    v_sort_txt := trim(coalesce(p_attr->>'sort_order', ''));
    if v_sort_txt = '' then
        v_sort := 1;
    elsif v_sort_txt ~ '[^0-9]' then
        raise exception 'sort_order — не число';
    else
        v_sort := greatest(1, v_sort_txt::integer);
    end if;

    v_show   := coalesce(nullif(trim(coalesce(p_attr->>'show_in_list', '')), ''), 'false')::boolean;
    v_filter := coalesce(nullif(trim(coalesce(p_attr->>'is_filterable', '')), ''), 'false')::boolean;
    v_active := coalesce(nullif(trim(coalesce(p_attr->>'is_active', '')), ''), 'true')::boolean;

    if v_id is not null then
        begin
            update public.category_attrs
               set category_id   = v_cat_id,
                   code          = v_code,
                   name          = v_name,
                   type          = v_type,
                   enum_values   = v_enum,
                   sort_order    = v_sort,
                   show_in_list  = v_show,
                   is_filterable = v_filter,
                   is_active     = v_active
             where id = v_id
            returning id into v_new_id;
        exception when unique_violation then
            raise exception 'В этой категории уже есть атрибут с кодом «%»', v_code;
        end;
    else
        begin
            insert into public.category_attrs
                (category_id, code, name, type, enum_values,
                 sort_order, show_in_list, is_filterable, is_active)
            values
                (v_cat_id, v_code, v_name, v_type, v_enum,
                 v_sort, v_show, v_filter, v_active)
            returning id into v_new_id;
        exception when unique_violation then
            raise exception 'В этой категории уже есть атрибут с кодом «%»', v_code;
        end;
    end if;

    return jsonb_build_object('ok', true, 'id', v_new_id);
end;
$$;

comment on function public.admin_save_category_attr is 'v1 (волна v0.22.0, fp №14): upsert атрибута категории из конструктора («Магазин → Категории»): p_attr = { id?, category_id, code, name, type text/number/enum, enum_values[], sort_order, show_in_list, is_filterable, is_active } → { ok, id }; валидации: категория существует, code — строчная латиница/цифры/«_» (≤ 50), name ≤ 100, enum — непустой массив строк ≤ 50 (значения ≤ 100, trim), для text/number enum_values очищается; дубль кода в категории — понятная ошибка; прототип боевого PUT /api/categories/:id/attrs';

CREATE OR REPLACE FUNCTION public.admin_delete_category_attr(p_attr_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_values integer;
begin
    if p_attr_id is null then
        raise exception 'p_attr_id не указан';
    end if;
    if not exists (select 1 from public.category_attrs where id = p_attr_id) then
        raise exception 'Атрибут не найден: id %', p_attr_id;
    end if;
    select count(*) into v_values from public.product_attrs where attr_id = p_attr_id;
    delete from public.category_attrs where id = p_attr_id;
    return jsonb_build_object('ok', true, 'deleted_values', coalesce(v_values, 0));
end;
$$;

comment on function public.admin_delete_category_attr is 'v1 (волна v0.22.0, fp №14): удаление атрибута категории; значения product_attrs удаляются каскадом (FK on delete cascade) — подтверждение в UI конструктора; → { ok, deleted_values }';

CREATE OR REPLACE FUNCTION public.draft_save_product_attrs(p_product_id integer, p_attrs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
    v_cat   integer;
    v_key   text;
    v_val   text;
    v_aid   integer;
    v_type  text;
    v_saved integer := 0;
    v_del   integer := 0;
    v_n     integer;
begin
    if p_product_id is null then
        raise exception 'p_product_id не указан';
    end if;
    select pr.category_id into v_cat
      from public.products pr
     where pr.id = p_product_id;
    if not found then
        raise exception 'Товар не найден: id %', p_product_id;
    end if;
    if p_attrs is null then
        p_attrs := '{}'::jsonb;
    end if;
    if jsonb_typeof(p_attrs) <> 'object' then
        raise exception 'p_attrs — не объект';
    end if;

    for v_key, v_val in select * from jsonb_each_text(p_attrs)
    loop
        if v_key ~ '[^0-9]' then
            raise exception 'id атрибута (ключ p_attrs) — не число: %', v_key;
        end if;
        v_aid := v_key::integer;
        select a.type into v_type
          from public.category_attrs a
         where a.id = v_aid and a.is_active and a.category_id = v_cat;
        if v_type is null then
            raise exception 'Атрибут % не найден, неактивен или не относится к категории товара', v_aid;
        end if;
        v_val := trim(coalesce(v_val, ''));
        if length(v_val) > 1000 then
            raise exception 'Значение длиннее 1000 символов: атрибут %', v_aid;
        end if;
        if v_val = '' then
            delete from public.product_attrs
             where product_id = p_product_id and attr_id = v_aid;
            get diagnostics v_n = row_count;
            v_del := v_del + v_n;
            continue;
        end if;
        if v_type = 'number' and translate(v_val, '0123456789.,-', '') <> '' then
            raise exception 'Значение числового атрибута — только цифры (атрибут %)', v_aid;
        end if;
        insert into public.product_attrs (product_id, attr_id, value)
        values (p_product_id, v_aid, v_val)
        on conflict (product_id, attr_id) do update set value = excluded.value;
        v_saved := v_saved + 1;
    end loop;

    return jsonb_build_object('ok', true, 'saved', v_saved, 'deleted', v_del);
end;
$$;

comment on function public.draft_save_product_attrs is 'v1 (волна v0.22.0, fp №14): сохранение значений атрибутов товара одной транзакцией (паттерн draft_save_product_badges): p_attrs = { attr_id: value } — upsert; пустое значение — удаление строки; валидации: товар существует, атрибут активен и относится к категории товара, значение ≤ 1000, для number — только цифры/точка/запятая/минус; → { ok, saved, deleted }; прототип боевого PATCH /api/products/:id/attrs';

CREATE OR REPLACE FUNCTION public.draft_attrs_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'attrs',  (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', a.id, 'category_id', a.category_id, 'code', a.code,
                   'name', a.name, 'type', a.type, 'enum_values', a.enum_values,
                   'sort_order', a.sort_order, 'show_in_list', a.show_in_list,
                   'is_filterable', a.is_filterable, 'is_active', a.is_active)
                   order by a.category_id, a.sort_order, a.id), '[]'::jsonb)
                 from public.category_attrs a
                where a.is_active),
    'values', (select coalesce(jsonb_agg(jsonb_build_object(
                   'product_id', v.product_id, 'attr_id', v.attr_id,
                   'value', v.value)
                   order by v.product_id, v.attr_id), '[]'::jsonb)
                 from public.product_attrs v)
);
$$;

comment on function public.draft_attrs_bundle is 'Админ-бандл атрибутов (волна v0.22.0, fp №14 — грабля №6, один запрос): attrs — активные атрибуты всех категорий (порядок category_id, sort_order) + values — значения всех товаров; конструктор категорий читает полный справочник (включая неактивные — для повторной активации) прямой выборкой (anon_read_category_attrs); карточка товара — секция «Характеристики» по категории';

-- ----------------------------------------------------------------------------
-- 6. draft_storefront_bundle → v4: форма v3 + attr_dict + attrs у товаров
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.draft_storefront_bundle()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
select jsonb_build_object(
    'brands',     (select coalesce(jsonb_agg(b order by b.name), '[]'::jsonb)
                     from public.brands b where b.is_active),
    'categories', (select coalesce(jsonb_agg(c order by c.id), '[]'::jsonb)
                     from public.categories c),
    'products',   (select coalesce(jsonb_agg(to_jsonb(pr) || jsonb_build_object(
                       'attrs', coalesce((select jsonb_object_agg(v.attr_id::text, v.value)
                                            from public.product_attrs v
                                            join public.category_attrs a on a.id = v.attr_id
                                           where v.product_id = pr.id
                                             and a.is_active
                                             and a.category_id = pr.category_id
                                             and v.value <> ''), '{}'::jsonb))
                       order by pr.created_at desc, pr.id desc), '[]'::jsonb)
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
                     from public.return_reasons rr where rr.is_active),
    'badges',     (select coalesce(jsonb_agg(b order by b.sort_order, b.id), '[]'::jsonb)
                     from public.badges b where b.is_active),
    'product_badges', (select coalesce(jsonb_agg(pb order by pb.sort_order, pb.id), '[]'::jsonb)
                     from public.product_badges pb
                     join public.badges b on b.id = pb.badge_id and b.is_active),
    'attr_dict',  (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', a.id, 'category_id', a.category_id, 'code', a.code,
                       'name', a.name, 'type', a.type, 'enum_values', a.enum_values,
                       'is_filterable', a.is_filterable, 'show_in_list', a.show_in_list,
                       'sort_order', a.sort_order)
                       order by a.category_id, a.sort_order, a.id), '[]'::jsonb)
                     from public.category_attrs a where a.is_active)
);
$$;

comment on function public.draft_storefront_bundle is 'v4 (волна v0.22.0, fp №14): + attr_dict (активные атрибуты по категориям: id, category_id, code, name, type, enum_values, is_filterable, show_in_list, sort_order) и attrs у товаров ({attr_id: value} — только заполненные значения активных атрибутов категории товара); витрина: блок «Характеристики» в модалке, чипы show_in_list у карточек, фильтр каталога по is_filterable при выбранной одной категории (Д9); ключи v3 (badges, product_badges — волна v0.21.0) и v2 без изменений; все данные витрины одним RPC — грабля №6';

-- ----------------------------------------------------------------------------
-- Самопроверка (точные ожидаемые значения; функции — явный список 33 проектных
-- имён, методика Д11; rls_auto_enable — платформенная, вне списка, АН-30)
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_tables   where schemaname = 'public')            as tables_32,      -- ждём 32
    (select count(*) from pg_policies where schemaname = 'public')            as policies_74,    -- ждём 74
    (select count(*) from public.category_attrs)                              as attrs_53,       -- ждём 53
    (select count(*) from public.category_attrs where is_filterable)          as filterable_22,  -- ждём 22
    (select count(*) from public.category_attrs where show_in_list)           as in_list_11,     -- ждём 11
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array['draft_phone_key', 'draft_email_key', 'check_promo', 'create_order', 'admin_set_status', 'admin_set_paid', 'track_order', 'draft_save_look', 'create_return_request', 'admin_set_return_status', 'admin_set_return_refund', 'admin_resolve_quarantine', 'admin_update_client', 'admin_create_inventory_session', 'admin_start_inventory_session', 'admin_cancel_inventory_session', 'admin_save_inventory_items', 'admin_finish_inventory_session', 'admin_create_writeoff', 'draft_save_product_badges', 'draft_reserved_map', 'draft_admin_bundle', 'draft_assembly_bundle', 'draft_clients_bundle', 'draft_storefront_bundle', 'draft_returns_bundle', 'draft_client_card_bundle', 'draft_inventory_bundle', 'draft_writeoffs_bundle', 'admin_save_category_attr', 'admin_delete_category_attr', 'draft_save_product_attrs', 'draft_attrs_bundle']))                                                                                             as funcs_33,       -- ждём 33
    (select obj_description(oid,'pg_proc') like 'v4%' from pg_proc
      where proname = 'draft_storefront_bundle')                              as storefront_v4;  -- ждём t
-- Ожидаемая строка самопроверки (psql -At): 32|74|53|22|11|33|t

-- Справочно (не сравнивается; методика Д11): голое число функций в public —
-- на свежей базе 33, на живой 34 (платформенная rls_auto_enable — решение
-- АН-30 «оставить»):
select count(*) as funcs_total_reference
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public';
