# Dotfiles для ручной загрузки на GitHub (волна v0.17.1)

Файлы с точкой в начале имени не отображаются в рабочей области ИИ-чата,
поэтому их нельзя скачать и загрузить пакетом. Создайте их вручную на GitHub:

1. Откройте репозиторий `paprekolyx/Sisku` → **Add file → Create new file**.
2. В поле имени введите имя файла **с ведущей точкой** (например, `.gitignore`) —
   GitHub позволяет такие имена; слэш вводить не нужно (файлы создаются в корне).
3. Скопируйте содержимое из соответствующего блока ниже **дословно**
   (включая комментарии) → **Commit changes**.
4. Повторите для всех трёх файлов.
5. Проверка: все три файла видны в корневом списке файлов репозитория.

Тот же текст продублирован в инструкции волны:
`docs/update/update-v0171.md`, приложение А (загружается в составе пакета).

---

## Файл 1: `.gitignore`

```
# v0.17.0 (внешний ревью 06.10.2026, находка E4): OS/редакторский мусор.
# ВНИМАНИЕ: data/*.csv — бэкапы содержимого БД, они ДОЛЖНЫ коммититься.
.DS_Store
Thumbs.db
desktop.ini
*.swp
*~
.idea/
.vscode/
```

## Файл 2: `.editorconfig`

```
# v0.17.0 (внешний ревью 06.10.2026, находка E4): единый стиль файлов.
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.py]
indent_size = 4

[*.sql]
indent_size = 4

[data/*.csv]
# автовыгрузки Supabase Table Editor: CRLF, UTF-8 без BOM — не нормализуем
end_of_line = crlf
insert_final_newline = false
trim_trailing_whitespace = false
```

## Файл 3: `.gitattributes`

```
# v0.17.0 (внешний ревью 06.10.2026, находка E4): шум диффов автовыгрузок
# data/*.csv устранён — дифф не отображается (содержимое читаемо в файле).
data/*.csv -diff
*.woff2 binary
*.jpg binary
*.webp binary
*.png binary
```
