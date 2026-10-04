# Инструкция 1. Новый репозиторий и GitHub Pages

Цель: опубликовать черновой макет Sisku по адресу
`https://paprekolyx.github.io/Sisku/` (имя репозитория можно поменять —
тогда изменится только адрес).

## Шаг 1. Создать репозиторий

1. GitHub → кнопка **New** (или плюс в шапке → New repository).
2. Repository name: **Sisku** (или другое — запомни его для адреса).
3. Вид: **Public** (для Pages на бесплатном тарифе публичный обязателен)
   или **Private** — но тогда Pages доступен только на платном тарифе.
   Для макета, который отправляем на просмотр, подойдёт Public.
4. Галочку «Add a README» **не ставить** (README уже есть в папке проекта).
5. Create repository.

## Шаг 2. Загрузить файлы

**Вариант А (рекомендую, надёжнее всего): через git на компьютере.**

```bash
# один раз, если git ещё не настроен
git config --global user.name  "Ваше имя"
git config --global user.email "ваш@email.ru"

# распаковать архив макета (sisku-draft.zip) в папку Sisku, затем:
cd Sisku
git init
git add .
git commit -m "Sisku v0.1.0-draft: макет витрины и админ-панели"
git branch -M main
git remote add origin https://github.com/paprekolyx/Sisku.git
git push -u origin main
```

**Вариант Б: через веб-интерфейс GitHub** (как в учебном проекте).
Заходить в каждую папку и перетаскивать файлы пачками:

| Куда на GitHub | Что перетащить из папки макета |
|---|---|
| корень репозитория | `index.html`, `admin.html`, `README.md` |
| `assets/css/` (создать: Add file → Create new file, ввести имя с `/`) | `fonts.css`, `styles.css`, `admin.css` |
| `assets/js/` | `config.js`, `site.js`, `admin.js` |
| `assets/vendor/` | `supabase.min.js`, `chart.umd.min.js` |
| `assets/fonts/` | 4 файла `.woff2` |
| `assets/img/` | `hero.jpg` |
| `assets/img/products/` | `p001.jpg … p008.jpg` |
| `data/` | 4 файла `.csv` |
| `supabase/` | 4 файла `.sql` |
| `docs/` | эти инструкции |

Совет: сначала создай структуру папок одним коммитом (Create new file с именем
`assets/css/.keep` и т.п. — GitHub создаст папку), потом загружай файлы
в нужные папки через Upload files.

## Шаг 3. Включить GitHub Pages (самый простой способ — без Actions)

1. В репозитории: **Settings → Pages**.
2. Build and deployment → Source: **Deploy from a branch**.
3. Branch: **main**, папка **/ (root)** → Save.
4. Через 1–2 минуты сайт появится по адресу
   `https://<твой-логин>.github.io/<имя-репозитория>/`
   (ссылка будет видна там же, в Settings → Pages, и в зелёной плашке).
5. Открой сайт и обнови с очисткой кеша: **Ctrl + F5**.

Админ-панель черновика: `…/admin.html` (добавь `admin.html` к адресу сайта).

## Шаг 4. Как обновлять макет позже

- Правим файл локально → `git add . && git commit -m "…" && git push` →
  Pages обновится сам за 1–2 минуты.
- Или через веб: открыть файл на GitHub → карандаш (Edit) → правки →
  Commit changes.
- После обновления открываем сайт с **Ctrl + F5**.

## Частые проблемы

| Симптом | Причина и лечение |
|---|---|
| Страница 404 | Pages ещё не задеплоился (подождать 2 минуты) или в Settings → Pages выбрана не та ветка/папка |
| Сайт без стилей | Файлы css легли не в `assets/css/` — проверить пути в Network (F12) |
| Каталог пустой, плашка «База не подключена» | Не заполнены ключи в `assets/js/config.js` → Инструкция 2 |
| Фото не открываются | Проверить, что `assets/img/products/p001…p008.jpg` лежат именно в этой папке |
