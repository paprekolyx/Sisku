#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сборка исторического архива SQL-скриптов 01–25 (состояние на v0.16.0-draft)
в один документ sisku/supabase/archive/sql-01-25-v0160.md.
Описания файлов — из реестра supabase/README.md (строки таблицы «Порядок и состав»).
Запуск из /home/user: python3 pgtest/build_sql_archive.py
"""
import os
import re

SUP = os.path.join('sisku', 'supabase')
OUT_DIR = os.path.join(SUP, 'archive')
OUT = os.path.join(OUT_DIR, 'sql-01-25-v0160.md')

# 1. Описания из реестра supabase/README.md
readme = open(os.path.join(SUP, 'README.md'), encoding='utf-8').read()
desc = {}
for m in re.finditer(r'^\|\s*`(\d{2}_\w+\.sql)`\s*\|(.*?)\|\s*$', readme, re.M | re.S):
    d = ' '.join(m.group(2).split())
    desc[m.group(1)] = d

files = sorted(f for f in os.listdir(SUP) if re.match(r'^\d{2}_.*\.sql$', f))
assert len(files) == 25, files

parts = []
parts.append("""# Исторические SQL-скрипты черновика Sisku (01–25) — замороженный архив

**Статус:** [З] замороженный исторический документ · **Основание:** волна v0.17.0
(консолидация SQL-скриптов, 07.10.2026) · **Версия проекта на момент фиксации:**
0.16.0-draft
**Назначение:** полная копия всех 25 скриптов волны v0.1.0–v0.16.0 в том виде,
в каком они применялись к живой базе Supabase `sisku-draft`. Документ —
**НЕ для применения**: живой состав скриптов после консолидации — baseline
`01–05, 09` (состояние на v0.16.0) + инкременты с `26` (реестр —
`supabase/README.md`). Здесь сохранены исторические версии всех файлов,
включая удалённые при консолидации (06–08, 10–25) и дореволюционные версии
консолидированных (01–05, 09), а также промежуточные версии функций
(create_order v1–v7, admin_set_status v1–v4 и т.д.) — для аудита решений
и восстановления контекста находок ревью (F01–F52, V/N).
**Формат:** скрипты приведены подряд в порядке номеров, каждый — с коротким
описанием из реестра `supabase/README.md` редакции 3.0 (волна v0.16.0) и полной
копией содержимого файла. Нумерация историческая; номера 06–08 и 10–25 не
переиспользуются (SQL-регламент). Одноразовые data-миграции помечены ⚠ в
описаниях (решение F21) — к живой базе не применялись повторно с 05.10.2026.

---
""")

total = 0
for f in files:
    body = open(os.path.join(SUP, f), encoding='utf-8').read()
    assert '```' not in body, f
    total += len(body)
    d = desc.get(f, '(описание отсутствует в реестре)')
    parts.append('\n## `%s`\n\n%s\n\n```sql\n%s\n```\n' % (f, d, body.rstrip('\n')))

os.makedirs(OUT_DIR, exist_ok=True)
open(OUT, 'w', encoding='utf-8').write('\n'.join(parts).rstrip() + '\n')
print('OK %s: %d скриптов, SQL %.1f КБ, файл %.1f КБ' % (
    OUT, len(files), total / 1024, os.path.getsize(OUT) / 1024))
missing = [f for f in files if f not in desc]
print('без описания из реестра:', missing if missing else 'нет')
