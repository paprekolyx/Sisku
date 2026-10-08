-- ============================================================================
--  SISKU (черновик) — СКРИПТ 04: посевы справочников и контента — конечное состояние (70 ключей site_content)
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE (волна v0.17.0, 07.10.2026): состояние базы на
--  v0.16.0-draft одним скриптом. Заменяет исторические скрипты 04, 06 (статус «Оплачен» не сеется), 07 (order.payment.text), 14 (brand_colors), 20, 22 (return_reasons), 24, 25 (pochtaruss).
--  Исторические версии (включая промежуточные версии функций) — замороженный
--  архив supabase/archive/sql-01-25-v0160.md и git-история; номера удалённых
--  скриптов не переиспользуются (SQL-регламент).
--  Идемпотентен: insert … on conflict do nothing — вставка только отсутствующих строк (культура F21): на живой базе с правками владельца безопасен, но по регламенту не запускается.
--  Порядок для НОВОГО стенда: 01 → 02 → 03 → 04 → 05 → 09 → 26 → 27.
--  ⚠ НА ЖИВОЙ БАЗЕ (контент отредактирован владельцем) baseline НЕ
--  перезапускать — модель F21: живая база получает только инкременты ≥ 26.
-- ============================================================================


-- ---------- order_statuses (7 стр.) ----------

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (1, 'new', 'Новый', false, 1) on conflict do nothing;

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (2, 'confirmed', 'Подтверждён', false, 2) on conflict do nothing;

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (3, 'packing', 'Сборка', false, 3) on conflict do nothing;

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (4, 'shipped', 'Отправлен', false, 4) on conflict do nothing;

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (5, 'delivered', 'Доставлен', true, 5) on conflict do nothing;

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (6, 'cancelled', 'Отменён', true, 6) on conflict do nothing;

INSERT INTO public.order_statuses (id, code, name, is_final, sort_order) VALUES (7, 'returned', 'Возврат', true, 7) on conflict do nothing;

SELECT pg_catalog.setval('public.order_statuses_id_seq', 7, true);


-- ---------- status_transitions (8 стр.) ----------

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (1, 2) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (2, 3) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (3, 4) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (4, 5) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (2, 6) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (1, 6) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (5, 7) on conflict do nothing;

INSERT INTO public.status_transitions (from_status_id, to_status_id) VALUES (4, 7) on conflict do nothing;


-- ---------- payment_methods (3 стр.) ----------

INSERT INTO public.payment_methods (id, code, name, is_active) VALUES (1, 'sbp', 'СБП (перевод по номеру телефона)', true) on conflict do nothing;

INSERT INTO public.payment_methods (id, code, name, is_active) VALUES (2, 'card', 'Перевод на карту', true) on conflict do nothing;

INSERT INTO public.payment_methods (id, code, name, is_active) VALUES (3, 'onsite', 'Наличными при самовывозе', true) on conflict do nothing;

SELECT pg_catalog.setval('public.payment_methods_id_seq', 3, true);


-- ---------- delivery_methods (4 стр.) ----------

INSERT INTO public.delivery_methods (id, code, name, base_price, price_max, is_active) VALUES (1, 'pickup', 'Самовывоз из шоурума (Москва)', 0.00, 0.00, true) on conflict do nothing;

INSERT INTO public.delivery_methods (id, code, name, base_price, price_max, is_active) VALUES (2, 'courier', 'Курьер по Москве, 1–2 дня', 600.00, 600.00, true) on conflict do nothing;

INSERT INTO public.delivery_methods (id, code, name, base_price, price_max, is_active) VALUES (3, 'cdek', 'СДЭК по России, 2–7 дней', 350.00, 900.00, true) on conflict do nothing;

INSERT INTO public.delivery_methods (id, code, name, base_price, price_max, is_active) VALUES (4, 'pochtaruss', 'Почта России, 3–8 дней', 300.00, 800.00, true) on conflict do nothing;

SELECT pg_catalog.setval('public.delivery_methods_id_seq', 4, true);


-- ---------- return_reasons (4 стр.) ----------

INSERT INTO public.return_reasons (id, name, is_active, sort_order) VALUES (1, 'Не подошёл размер', true, 1) on conflict do nothing;

INSERT INTO public.return_reasons (id, name, is_active, sort_order) VALUES (2, 'Брак / дефект', true, 2) on conflict do nothing;

INSERT INTO public.return_reasons (id, name, is_active, sort_order) VALUES (3, 'Не подошло', true, 3) on conflict do nothing;

INSERT INTO public.return_reasons (id, name, is_active, sort_order) VALUES (4, 'Передумал(а)', true, 4) on conflict do nothing;

SELECT pg_catalog.setval('public.return_reasons_id_seq', 4, true);


-- ---------- site_content (70 стр.) ----------

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (1, 'brand.name', 'SISKU', 'Логотип в шапке и футере', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (2, 'brand.tagline', 'мультибрендовый бутик одежды и парфюмерии', 'Подпись под логотипом в футере', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (3, 'hero.eyebrow', 'Осень — зима 2026', 'Надзаголовок первого экрана', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (4, 'hero.title', 'Одежда и ароматы, которые остаются с вами', 'Заголовок первого экрана', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (5, 'hero.subtitle', 'Избранные коллекции небольших домов и нишевая парфюмерия. Оригиналы с гарантией подлинности и бережной доставкой по всей России.', 'Подзаголовок первого экрана', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (6, 'about.title', 'О магазине', 'Заголовок раздела «О магазине»', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (7, 'about.lead', 'Sisku — витрина избранного: мы собираем коллекции небольших домов и нишевых марок, которые невозможно найти в масс-маркете.', 'Первый абзац раздела «О магазине»', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (8, 'about.text', 'Каждая вещь проходит ручной отбор — по тканям, посадке и характеру коллекции. Мы работаем напрямую с брендами и официальными дистрибьюторами, поэтому гарантируем подлинность каждого товара. Заказы уезжают в плотной упаковке с фирменной лентой и открыткой, написанной от руки.', 'Второй абзац раздела «О магазине»', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (9, 'adv.1.title', 'Ручной отбор', 'Преимущество 1, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (10, 'adv.1.text', 'Каждая позиция проходит отбор по тканям, посадке и характеру коллекции.', 'Преимущество 1, текст', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (11, 'adv.2.title', 'Гарантия подлинности', 'Преимущество 2, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (12, 'adv.2.text', 'Работаем с брендами и официальными дистрибьюторами. Батч-коды и документы — по запросу.', 'Преимущество 2, текст', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (13, 'adv.3.title', 'Бережная доставка', 'Преимущество 3, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (15, 'adv.4.title', 'Поддержка без скриптов', 'Преимущество 4, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (16, 'adv.4.text', 'Отвечаем лично: поможем с размером и подбором аромата до и после заказа.', 'Преимущество 4, текст', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (17, 'catalog.eyebrow', 'Каталог', 'Надзаголовок раздела товаров', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (18, 'catalog.title', 'Коллекция', 'Заголовок раздела товаров', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (19, 'order.payment.title', 'Оплата', 'Карточка условий: оплата, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (21, 'order.delivery.title', 'Доставка', 'Карточка условий: доставка, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (23, 'order.returns.title', 'Возврат', 'Карточка условий: возврат, заголовок', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (24, 'order.returns.text', 'Если вещь не подошла — напишите нам в течение 7 дней с момента получения. Поможем с обменом размера или возвратом, без лишних вопросов.', 'Карточка условий: возврат, текст', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (25, 'contacts.phone_display', '+7 (999) 123-45-67', 'Контакты: телефон (заглушка)', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (26, 'contacts.phone_href', 'tel:+79991234567', 'Контакты: ссылка на набор номера (должна совпадать с отображаемым!)', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (27, 'contacts.email', 'hello@sisku.example', 'Контакты: e-mail (заглушка)', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (28, 'contacts.city', 'Москва, шоурум по предварительной записи', 'Контакты: город и шоурум', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (29, 'contacts.hours', 'Ежедневно 11:00–21:00 (МСК)', 'Контакты: часы работы', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (32, 'contacts.repo_url', 'https://github.com/paprekolyx/Sisku', 'Контакты: ссылка на репозиторий макета под блоком контактов', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (33, 'footer.description', 'Sisku — мультибрендовый бутик одежды и парфюмерии. Черновой макет для обсуждения.', 'Футер: описание', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (34, 'footer.copyright', '© 2026 Sisku', 'Футер: копирайт', '2026-10-06 21:43:10.072297+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (30, 'contacts.messenger', 'Написать в Telegram', 'Контакты: подпись кнопки мессенджера', '2026-10-06 21:43:10.191469+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (31, 'contacts.messenger_url', 'https://t.me/sisku_shop', 'Контакты: ссылка на мессенджер (заглушка)', '2026-10-06 21:43:10.191763+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (20, 'order.payment.text', 'Три способа оплаты: перевод через СБП, перевод по номеру карты или наличными при самовывозе из шоурума. Способ фиксируется при подтверждении заказа менеджером.', 'Карточка условий: оплата, текст', '2026-10-06 21:43:10.250599+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (36, 'looks.title', 'Комплекты', 'Витрина: заголовок секции «Комплекты» (до волны v0.15.0 — «Готовые образы»)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (37, 'looks.subtitle', 'Подборки', 'Витрина: надзаголовок (подпись) над заголовком секции «Комплекты»', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (38, 'order.confirm.text', 'Статус заказа можно отслеживать по номеру и коду подтверждения — сохраните их.', 'Оформление заказа: текст на экране «Заказ принят» под номером заказа (нейтральная формулировка без обещания звонка — правка 2.5)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (39, 'checkout.hint.phone', '+7 (999) 123-45-67 или 8 999 123-45-67', 'Форма заказа: подсказка под полем «Телефон» (формат номера)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (41, 'checkout.consent.text', 'Согласен(на) на обработку персональных данных и ознакомлен(а) с условиями публичной оферты', 'Форма заказа: текст чекбокса согласия (ссылки «Политика ПДн» и «Публичная оферта» — рядом с текстом; запись факта согласия в БД — боевая версия M4)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (42, 'checkout.promo.placeholder', 'Например, SISKU10', 'Форма заказа: подсказка в поле «Промокод»', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (43, 'checkout.promo.apply', 'Применить', 'Форма заказа: кнопка проверки промокода', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (44, 'theme.light.name', 'Ivoire', 'Брендбук: название светлой темы (справка на витрине и «Управление → Брендбук»)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (45, 'theme.light.role', 'основная тема витрины', 'Брендбук: подпись светлой темы (после названия, через тире)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (46, 'theme.dark.name', 'Noir & Champagne', 'Брендбук: название тёмной темы (справка на витрине и «Управление → Брендбук»)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (47, 'theme.dark.role', 'вторая тема', 'Брендбук: подпись тёмной темы (после названия, через тире)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (48, 'about.img.dark', '', 'Витрина: путь к фото раздела «О магазине» для тёмной темы (пусто — то же фото, что в светлой теме)', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (49, 'order.track.cta', 'Статус заказа по номеру', 'Витрина, контакты: кнопка открытия окна отслеживания заказа', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (50, 'order.track.title', 'Отследить заказ', 'Окно отслеживания: заголовок', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (51, 'order.track.hint', 'Введите номер заказа и код подтверждения: последние 4 цифры телефона ИЛИ первые 4 символа e-mail до «@».', 'Окно отслеживания: подсказка под заголовком', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (52, 'order.track.button', 'Показать статус', 'Окно отслеживания: кнопка проверки', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (53, 'order.track.history', 'История статусов', 'Окно отслеживания: заголовок блока истории', '2026-10-06 21:43:11.140347+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (54, 'returns.cta.track', 'Оформить возврат', 'Окно отслеживания заказа: кнопка заявки на возврат (видна для заказов в статусе «Отправлен» или «Доставлен»)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (55, 'returns.form.title', 'Заявка на возврат', 'Форма возврата: заголовок окна', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (56, 'returns.form.hint', 'Заявку на возврат можно оформить в течение 7 дней после получения заказа. Заполните форму — заявка поступит менеджеру.', 'Форма возврата: подсказка под заголовком (нейтральная формулировка до юридического блока M4)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (57, 'returns.form.order', 'Номер заказа', 'Форма возврата: подпись номера заказа (значение подставляется из окна отслеживания)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (58, 'returns.form.code', 'Код подтверждения', 'Форма возврата: подпись кода подтверждения (значение подставляется из окна отслеживания)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (59, 'returns.form.reason', 'Причина возврата', 'Форма возврата: подпись списка причин (справочник — «Управление → Справочники»)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (60, 'returns.form.reason.placeholder', 'Выберите причину…', 'Форма возврата: подсказка в списке причин, пока причина не выбрана', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (61, 'returns.form.comment', 'Комментарий', 'Форма возврата: подпись поля комментария', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (62, 'returns.form.comment.placeholder', 'Опишите ситуацию подробнее — это ускорит рассмотрение заявки', 'Форма возврата: подсказка в поле комментария', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (63, 'returns.form.photo', 'Фото товара', 'Форма возврата: подпись блока фото (заглушка до подключения файлового хранилища — M5)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (64, 'returns.form.photo.note', 'Загрузка фото появится позже — пока опишите причину в комментарии', 'Форма возврата: пояснение к заглушке блока фото', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (65, 'returns.form.submit', 'Отправить заявку', 'Форма возврата: кнопка отправки', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (66, 'returns.form.success', 'Заявка принята и передана менеджеру. Номер заявки:', 'Форма возврата: текст после успешной отправки (далее — номер заявки)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (67, 'returns.status.created', 'Заявка оформлена', 'Админка «Заказы → Возвраты»: подпись статуса заявки (ожидает обработки)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (68, 'returns.status.returned_to_stock', 'Товар вернулся на склад', 'Админка «Заказы → Возвраты»: подпись статуса (товар получен, остаток в карантине до осмотра)', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (69, 'returns.status.verified', 'Товар проверен, возврат оформлен', 'Админка «Заказы → Возвраты»: подпись финального статуса успешного возврата', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (70, 'returns.status.rejected', 'Отклонено', 'Админка «Заказы → Возвраты»: подпись финального статуса отклонённой заявки', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (71, 'returns.stats.title', 'Возвраты', 'Админка «Статистика»: название подвкладки возвратов', '2026-10-06 21:43:11.409941+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (14, 'adv.3.text', 'Плотная упаковка, фирменная лента и открытка. СДЭК, Почта России и курьер по Москве.', 'Преимущество 3, текст', '2026-10-06 21:43:11.479458+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (22, 'order.delivery.text', 'Курьер по Москве — 1–2 дня. СДЭК и Почта России по России — 2–8 дней. Самовывоз из шоурума — бесплатно, в день заказа.', 'Карточка условий: доставка, текст', '2026-10-06 21:43:11.479458+00') on conflict do nothing;

INSERT INTO public.site_content (id, key, value, description, updated_at) VALUES (40, 'checkout.hint.address', 'Город, улица, дом, квартира — или номер пункта выдачи (СДЭК, Почта России)', 'Форма заказа: подсказка под полем «Город и адрес / пункт выдачи»', '2026-10-06 21:43:11.479458+00') on conflict do nothing;

SELECT pg_catalog.setval('public.site_content_id_seq', 71, true);


-- ---------- brand_colors (20 стр.) ----------

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (1, 'light', 'bg', '#FAF7F2') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (2, 'light', 'surface', '#FFFFFF') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (3, 'light', 'card', '#FFFFFF') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (4, 'light', 'text', '#1A1A1E') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (5, 'light', 'muted', '#6F6A60') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (6, 'light', 'accent', '#7A5C2E') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (7, 'light', 'line', '#E5E0D6') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (8, 'light', 'btn_bg', '#1A1A1E') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (9, 'light', 'btn_text', '#FAF7F2') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (10, 'dark', 'bg', '#0D0D10') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (11, 'dark', 'surface', '#16161B') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (12, 'dark', 'card', '#1D1D24') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (13, 'dark', 'text', '#F2EEE4') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (14, 'dark', 'muted', '#A79FB0') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (15, 'dark', 'accent', '#C9A96A') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (16, 'dark', 'line', '#2A2A33') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (17, 'dark', 'btn_bg', '#C9A96A') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (18, 'dark', 'btn_text', '#0D0D10') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (19, 'global', 'typo_base', '16') on conflict do nothing;

INSERT INTO public.brand_colors (id, theme, key, value) VALUES (20, 'global', 'typo_scale', '100') on conflict do nothing;

SELECT pg_catalog.setval('public.brand_colors_id_seq', 20, true);


-- ---------- admin_users: демо-администратор мок-входа (посев исторического
-- скрипта 07; живая база не выгружается в data/ — чувствительные данные) ----

insert into public.admin_users (fio, email, messenger_url, role, password_hash)
select 'Иванов Иван Иванович', 'owner@sisku.example', 'https://t.me/sisku_owner', 'admin',
       '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92'
where not exists (select 1 from public.admin_users where email = 'owner@sisku.example');


-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.order_statuses)                        as statuses_ok,      -- ждём 7 (без «Оплачен»)
    (select count(*) from public.status_transitions)                    as transitions_ok,   -- ждём 8 (вкл. shipped→returned)
    (select count(*) from public.payment_methods)                       as payments_ok,      -- ждём 3
    (select count(*) from public.delivery_methods)                      as deliveries_ok,    -- ждём 4
    (select count(*) from public.delivery_methods
      where code = 'pochtaruss')                                        as pochtaruss_ok,    -- ждём 1
    (select count(*) from public.delivery_methods
      where code = 'boxberry')                                          as boxberry_left,    -- ждём 0
    (select count(*) from public.return_reasons)                        as reasons_ok,       -- ждём 4
    (select count(*) from public.site_content)                          as keys_total,       -- ждём 70
    (select count(*) from public.site_content
      where key like 'returns.%')                                       as returns_keys,     -- ждём 18
    (select count(*) from public.site_content
      where value ilike '%boxberry%')                                   as content_boxberry, -- ждём 0
    (select count(*) from public.brand_colors)                          as colors_ok,        -- ждём 20
    (select count(*) from public.admin_users
      where email = 'owner@sisku.example')                              as demo_admin_ok;    -- ждём 1 (свежий стенд; на живой базе — фактический состав админов)
