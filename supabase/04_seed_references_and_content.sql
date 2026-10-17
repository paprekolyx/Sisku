-- ============================================================================
--  SISKU (черновик) — СКРИПТ 04: посевы справочников и контента конечного состояния (консолидация v0.21.1)
-- ============================================================================
--  КОНСОЛИДИРОВАННЫЙ BASELINE, ревизия 2 (волна v0.21.1, 17.10.2026):
--  состояние базы на v0.21.0 шестью скриптами (первая ревизия — v0.17.0,
--  состояние на v0.16.0; инкременты 26–33 поглощены — замороженный архив
--  supabase/archive/sql-26-33-v0210.md). Baseline ЗАМОРОЖЕН (правило 9):
--  правки — только новыми инкрементами с номера 34.
--  Живая база НЕ перезапускается (модель F21): baseline — только для
--  новых стендов; живая база получает инкременты ≥ 34.
--  Идемпотентен: create if not exists / drop-create policy / on conflict
--  do nothing / create or replace. Порядок: 01 → 02 → 03 → 04 → 05 → 09.
-- ============================================================================

-- Посевы сгенерированы из эталонной базы; вставка — только отсутствующих
-- строк (on conflict do nothing — культура F21); setval — последовательности

-- ---------- order_statuses ----------
insert into public.order_statuses (id, code, name, is_final, sort_order) values (1, 'new', 'Новый', 'false', '1') on conflict do nothing;
insert into public.order_statuses (id, code, name, is_final, sort_order) values (2, 'confirmed', 'Подтверждён', 'false', '2') on conflict do nothing;
insert into public.order_statuses (id, code, name, is_final, sort_order) values (3, 'packing', 'Сборка', 'false', '3') on conflict do nothing;
insert into public.order_statuses (id, code, name, is_final, sort_order) values (4, 'shipped', 'Отправлен', 'false', '4') on conflict do nothing;
insert into public.order_statuses (id, code, name, is_final, sort_order) values (5, 'delivered', 'Доставлен', 'true', '5') on conflict do nothing;
insert into public.order_statuses (id, code, name, is_final, sort_order) values (6, 'cancelled', 'Отменён', 'true', '6') on conflict do nothing;
insert into public.order_statuses (id, code, name, is_final, sort_order) values (7, 'returned', 'Возврат', 'true', '7') on conflict do nothing;
select setval(pg_get_serial_sequence('public.order_statuses', 'id'), (select coalesce(max(id), 1) from public.order_statuses));

-- ---------- status_transitions ----------
insert into public.status_transitions (from_status_id, to_status_id) values ('1', '2') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('1', '6') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('2', '3') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('2', '6') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('3', '4') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('4', '5') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('4', '7') on conflict do nothing;
insert into public.status_transitions (from_status_id, to_status_id) values ('5', '7') on conflict do nothing;

-- ---------- payment_methods ----------
insert into public.payment_methods (id, code, name, is_active) values (1, 'sbp', 'СБП (перевод по номеру телефона)', 'true') on conflict do nothing;
insert into public.payment_methods (id, code, name, is_active) values (2, 'card', 'Перевод на карту', 'true') on conflict do nothing;
insert into public.payment_methods (id, code, name, is_active) values (3, 'onsite', 'Наличными при самовывозе', 'true') on conflict do nothing;
select setval(pg_get_serial_sequence('public.payment_methods', 'id'), (select coalesce(max(id), 1) from public.payment_methods));

-- ---------- delivery_methods ----------
insert into public.delivery_methods (id, code, name, base_price, price_max, is_active) values (1, 'pickup', 'Самовывоз из шоурума (Москва)', '0.00', '0.00', 'true') on conflict do nothing;
insert into public.delivery_methods (id, code, name, base_price, price_max, is_active) values (2, 'courier', 'Курьер по Москве, 1–2 дня', '600.00', '600.00', 'true') on conflict do nothing;
insert into public.delivery_methods (id, code, name, base_price, price_max, is_active) values (3, 'cdek', 'СДЭК по России, 2–7 дней', '350.00', '900.00', 'true') on conflict do nothing;
insert into public.delivery_methods (id, code, name, base_price, price_max, is_active) values (4, 'pochtaruss', 'Почта России, 3–8 дней', '300.00', '800.00', 'true') on conflict do nothing;
select setval(pg_get_serial_sequence('public.delivery_methods', 'id'), (select coalesce(max(id), 1) from public.delivery_methods));

-- ---------- return_reasons ----------
insert into public.return_reasons (id, name, is_active, sort_order) values (1, 'Не подошёл размер', 'true', '1') on conflict do nothing;
insert into public.return_reasons (id, name, is_active, sort_order) values (2, 'Брак / дефект', 'true', '2') on conflict do nothing;
insert into public.return_reasons (id, name, is_active, sort_order) values (3, 'Не подошло', 'true', '3') on conflict do nothing;
insert into public.return_reasons (id, name, is_active, sort_order) values (4, 'Передумал(а)', 'true', '4') on conflict do nothing;
select setval(pg_get_serial_sequence('public.return_reasons', 'id'), (select coalesce(max(id), 1) from public.return_reasons));

-- ---------- writeoff_reasons ----------
insert into public.writeoff_reasons (id, code, name, is_system, is_active, sort_order) values (1, 'defect', 'Брак', 'false', 'true', '1') on conflict do nothing;
insert into public.writeoff_reasons (id, code, name, is_system, is_active, sort_order) values (2, 'sample', 'Витринный образец', 'false', 'true', '2') on conflict do nothing;
insert into public.writeoff_reasons (id, code, name, is_system, is_active, sort_order) values (3, 'shortage', 'Недостача', 'true', 'true', '3') on conflict do nothing;
insert into public.writeoff_reasons (id, code, name, is_system, is_active, sort_order) values (4, 'surplus', 'Излишек', 'true', 'true', '4') on conflict do nothing;
insert into public.writeoff_reasons (id, code, name, is_system, is_active, sort_order) values (5, 'other', 'Прочее', 'false', 'true', '5') on conflict do nothing;
select setval(pg_get_serial_sequence('public.writeoff_reasons', 'id'), (select coalesce(max(id), 1) from public.writeoff_reasons));

-- ---------- badges ----------
insert into public.badges (id, code, name, is_system, is_active, sort_order) values (1, 'new', 'New', 'true', 'true', '1') on conflict do nothing;
insert into public.badges (id, code, name, is_system, is_active, sort_order) values (2, 'hit', 'Хит', 'false', 'true', '2') on conflict do nothing;
insert into public.badges (id, code, name, is_system, is_active, sort_order) values (3, 'ending', 'Заканчивается', 'false', 'true', '3') on conflict do nothing;
insert into public.badges (id, code, name, is_system, is_active, sort_order) values (4, 'soon', 'Скоро', 'false', 'true', '4') on conflict do nothing;
insert into public.badges (id, code, name, is_system, is_active, sort_order) values (5, 'percent', '%', 'false', 'true', '5') on conflict do nothing;
select setval(pg_get_serial_sequence('public.badges', 'id'), (select coalesce(max(id), 1) from public.badges));

-- ---------- site_content ----------
insert into public.site_content (id, key, value, description) values (1, 'brand.name', 'SISKU', 'Логотип в шапке и футере') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (2, 'brand.tagline', 'мультибрендовый бутик одежды и парфюмерии', 'Подпись под логотипом в футере') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (3, 'hero.eyebrow', 'Осень — зима 2026', 'Надзаголовок первого экрана') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (4, 'hero.title', 'Одежда и ароматы, которые остаются с вами', 'Заголовок первого экрана') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (5, 'hero.subtitle', 'Избранные коллекции небольших домов и нишевая парфюмерия. Оригиналы с гарантией подлинности и бережной доставкой по всей России.', 'Подзаголовок первого экрана') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (6, 'about.title', 'О магазине', 'Заголовок раздела «О магазине»') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (7, 'about.lead', 'Sisku — витрина избранного: мы собираем коллекции небольших домов и нишевых марок, которые невозможно найти в масс-маркете.', 'Первый абзац раздела «О магазине»') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (8, 'about.text', 'Каждая вещь проходит ручной отбор — по тканям, посадке и характеру коллекции. Мы работаем напрямую с брендами и официальными дистрибьюторами, поэтому гарантируем подлинность каждого товара. Заказы уезжают в плотной упаковке с фирменной лентой и открыткой, написанной от руки.', 'Второй абзац раздела «О магазине»') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (9, 'adv.1.title', 'Ручной отбор', 'Преимущество 1, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (10, 'adv.1.text', 'Каждая позиция проходит отбор по тканям, посадке и характеру коллекции.', 'Преимущество 1, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (11, 'adv.2.title', 'Гарантия подлинности', 'Преимущество 2, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (12, 'adv.2.text', 'Работаем с брендами и официальными дистрибьюторами. Батч-коды и документы — по запросу.', 'Преимущество 2, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (13, 'adv.3.title', 'Бережная доставка', 'Преимущество 3, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (14, 'adv.3.text', 'Плотная упаковка, фирменная лента и открытка. СДЭК, Почта России и курьер по Москве.', 'Преимущество 3, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (15, 'adv.4.title', 'Поддержка без скриптов', 'Преимущество 4, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (16, 'adv.4.text', 'Отвечаем лично: поможем с размером и подбором аромата до и после заказа.', 'Преимущество 4, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (17, 'catalog.eyebrow', 'Каталог', 'Надзаголовок раздела товаров') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (18, 'catalog.title', 'Коллекция', 'Заголовок раздела товаров') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (19, 'order.payment.title', 'Оплата', 'Карточка условий: оплата, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (20, 'order.payment.text', 'Три способа оплаты: перевод через СБП, перевод по номеру карты или наличными при самовывозе из шоурума. Способ фиксируется при подтверждении заказа менеджером.', 'Карточка условий: оплата, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (21, 'order.delivery.title', 'Доставка', 'Карточка условий: доставка, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (22, 'order.delivery.text', 'Курьер по Москве — 1–2 дня. СДЭК и Почта России по России — 2–8 дней. Самовывоз из шоурума — бесплатно, в день заказа.', 'Карточка условий: доставка, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (23, 'order.returns.title', 'Возврат', 'Карточка условий: возврат, заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (24, 'order.returns.text', 'Если вещь не подошла — напишите нам в течение 7 дней с момента получения. Поможем с обменом размера или возвратом, без лишних вопросов.', 'Карточка условий: возврат, текст') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (25, 'contacts.phone_display', '+7 (999) 123-45-67', 'Контакты: телефон (заглушка)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (26, 'contacts.phone_href', 'tel:+79991234567', 'Контакты: ссылка на набор номера (должна совпадать с отображаемым!)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (27, 'contacts.email', 'hello@sisku.example', 'Контакты: e-mail (заглушка)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (28, 'contacts.city', 'Москва, шоурум по предварительной записи', 'Контакты: город и шоурум') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (29, 'contacts.hours', 'Ежедневно 11:00–21:00 (МСК)', 'Контакты: часы работы') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (30, 'contacts.messenger', 'Написать в Telegram', 'Контакты: подпись кнопки мессенджера') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (31, 'contacts.messenger_url', 'https://t.me/sisku_shop', 'Контакты: ссылка на мессенджер (заглушка)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (32, 'contacts.repo_url', 'https://github.com/paprekolyx/Sisku', 'Контакты: ссылка на репозиторий макета под блоком контактов') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (33, 'footer.description', 'Sisku — мультибрендовый бутик одежды и парфюмерии. Черновой макет для обсуждения.', 'Футер: описание') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (34, 'footer.copyright', '© 2026 Sisku', 'Футер: копирайт') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (36, 'looks.title', 'Комплекты', 'Витрина: заголовок секции «Комплекты» (до волны v0.15.0 — «Готовые образы»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (37, 'looks.subtitle', 'Подборки', 'Витрина: надзаголовок (подпись) над заголовком секции «Комплекты»') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (38, 'order.confirm.text', 'Статус заказа можно отслеживать по номеру и коду подтверждения — сохраните их.', 'Оформление заказа: текст на экране «Заказ принят» под номером заказа (нейтральная формулировка без обещания звонка — правка 2.5)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (39, 'checkout.hint.phone', '+7 (999) 123-45-67 или 8 999 123-45-67', 'Форма заказа: подсказка под полем «Телефон» (формат номера)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (40, 'checkout.hint.address', 'Город, улица, дом, квартира — или номер пункта выдачи (СДЭК, Почта России)', 'Форма заказа: подсказка под полем «Город и адрес / пункт выдачи»') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (41, 'checkout.consent.text', 'Согласен(на) на обработку персональных данных и ознакомлен(а) с условиями публичной оферты', 'Форма заказа: текст чекбокса согласия (ссылки «Политика ПДн» и «Публичная оферта» — рядом с текстом; запись факта согласия в БД — боевая версия M4)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (42, 'checkout.promo.placeholder', 'Например, SISKU10', 'Форма заказа: подсказка в поле «Промокод»') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (43, 'checkout.promo.apply', 'Применить', 'Форма заказа: кнопка проверки промокода') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (44, 'theme.light.name', 'Ivoire', 'Брендбук: название светлой темы (справка на витрине и «Управление → Брендбук»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (45, 'theme.light.role', 'основная тема витрины', 'Брендбук: подпись светлой темы (после названия, через тире)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (46, 'theme.dark.name', 'Noir & Champagne', 'Брендбук: название тёмной темы (справка на витрине и «Управление → Брендбук»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (47, 'theme.dark.role', 'вторая тема', 'Брендбук: подпись тёмной темы (после названия, через тире)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (48, 'about.img.dark', '', 'Витрина: путь к фото раздела «О магазине» для тёмной темы (пусто — то же фото, что в светлой теме)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (49, 'order.track.cta', 'Статус заказа по номеру', 'Витрина, контакты: кнопка открытия окна отслеживания заказа') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (50, 'order.track.title', 'Отследить заказ', 'Окно отслеживания: заголовок') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (51, 'order.track.hint', 'Введите номер заказа и код подтверждения: последние 4 цифры телефона ИЛИ первые 4 символа e-mail до «@».', 'Окно отслеживания: подсказка под заголовком') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (52, 'order.track.button', 'Показать статус', 'Окно отслеживания: кнопка проверки') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (53, 'order.track.history', 'История статусов', 'Окно отслеживания: заголовок блока истории') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (54, 'returns.cta.track', 'Оформить возврат', 'Окно отслеживания заказа: кнопка заявки на возврат (видна для заказов в статусе «Отправлен» или «Доставлен»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (55, 'returns.form.title', 'Заявка на возврат', 'Форма возврата: заголовок окна') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (56, 'returns.form.hint', 'Заявку на возврат можно оформить в течение 7 дней после получения заказа. Заполните форму — заявка поступит менеджеру.', 'Форма возврата: подсказка под заголовком (нейтральная формулировка до юридического блока M4)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (57, 'returns.form.order', 'Номер заказа', 'Форма возврата: подпись номера заказа (значение подставляется из окна отслеживания)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (58, 'returns.form.code', 'Код подтверждения', 'Форма возврата: подпись кода подтверждения (значение подставляется из окна отслеживания)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (59, 'returns.form.reason', 'Причина возврата', 'Форма возврата: подпись списка причин (справочник — «Управление → Справочники»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (60, 'returns.form.reason.placeholder', 'Выберите причину…', 'Форма возврата: подсказка в списке причин, пока причина не выбрана') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (61, 'returns.form.comment', 'Комментарий', 'Форма возврата: подпись поля комментария') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (62, 'returns.form.comment.placeholder', 'Опишите ситуацию подробнее — это ускорит рассмотрение заявки', 'Форма возврата: подсказка в поле комментария') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (63, 'returns.form.photo', 'Фото товара', 'Форма возврата: подпись блока фото (заглушка до подключения файлового хранилища — M5)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (64, 'returns.form.photo.note', 'Загрузка фото появится позже — пока опишите причину в комментарии', 'Форма возврата: пояснение к заглушке блока фото') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (65, 'returns.form.submit', 'Отправить заявку', 'Форма возврата: кнопка отправки') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (66, 'returns.form.success', 'Заявка принята и передана менеджеру. Номер заявки:', 'Форма возврата: текст после успешной отправки (далее — номер заявки)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (67, 'returns.status.created', 'Заявка оформлена', 'Админка «Заказы → Возвраты»: подпись статуса заявки (ожидает обработки)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (68, 'returns.status.returned_to_stock', 'Товар вернулся на склад', 'Админка «Заказы → Возвраты»: подпись статуса (товар получен, остаток в карантине до осмотра)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (69, 'returns.status.verified', 'Товар проверен, возврат оформлен', 'Админка «Заказы → Возвраты»: подпись финального статуса успешного возврата') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (70, 'returns.status.rejected', 'Отклонено', 'Админка «Заказы → Возвраты»: подпись финального статуса отклонённой заявки') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (71, 'returns.stats.title', 'Возвраты', 'Админка «Статистика»: название подвкладки возвратов') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (72, 'segments.vip_orders_min', '5', 'Порог VIP-сегмента: заказов не менее («Статистика → Клиенты»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (73, 'segments.vip_sum_min', '100000', 'Порог VIP-сегмента: сумма заказов не менее, руб. («Статистика → Клиенты»)') on conflict do nothing;
insert into public.site_content (id, key, value, description) values (74, 'segments.dormant_days', '90', 'Критерий «уснул»: дней без заказов («Статистика → Клиенты»)') on conflict do nothing;
select setval(pg_get_serial_sequence('public.site_content', 'id'), (select coalesce(max(id), 1) from public.site_content));

-- ---------- brand_colors ----------
insert into public.brand_colors (id, theme, key, value) values (1, 'light', 'bg', '#FAF7F2') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (2, 'light', 'surface', '#FFFFFF') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (3, 'light', 'card', '#FFFFFF') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (4, 'light', 'text', '#1A1A1E') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (5, 'light', 'muted', '#6F6A60') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (6, 'light', 'accent', '#7A5C2E') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (7, 'light', 'line', '#E5E0D6') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (8, 'light', 'btn_bg', '#1A1A1E') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (9, 'light', 'btn_text', '#FAF7F2') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (10, 'dark', 'bg', '#0D0D10') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (11, 'dark', 'surface', '#16161B') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (12, 'dark', 'card', '#1D1D24') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (13, 'dark', 'text', '#F2EEE4') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (14, 'dark', 'muted', '#A79FB0') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (15, 'dark', 'accent', '#C9A96A') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (16, 'dark', 'line', '#2A2A33') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (17, 'dark', 'btn_bg', '#C9A96A') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (18, 'dark', 'btn_text', '#0D0D10') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (19, 'global', 'typo_base', '16') on conflict do nothing;
insert into public.brand_colors (id, theme, key, value) values (20, 'global', 'typo_scale', '100') on conflict do nothing;
select setval(pg_get_serial_sequence('public.brand_colors', 'id'), (select coalesce(max(id), 1) from public.brand_colors));

-- ---------- admin_users ----------
insert into public.admin_users (id, fio, email, messenger_url, role, password_hash, is_active, phone) values (1, 'Иванов Иван Иванович', 'owner@sisku.example', 'https://t.me/sisku_owner', 'admin', '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92', 'true', NULL) on conflict do nothing;
select setval(pg_get_serial_sequence('public.admin_users', 'id'), (select coalesce(max(id), 1) from public.admin_users));

-- ----------------------------------------------------------------------------
-- Самопроверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from public.order_statuses)                             as statuses_7,   -- ждём 7
    (select count(*) from public.status_transitions)                         as transitions_8,-- ждём 8
    (select count(*) from public.payment_methods)                            as payments_3,   -- ждём 3
    (select count(*) from public.delivery_methods)                           as deliveries_4, -- ждём 4
    (select count(*) from public.delivery_methods where code = 'pochtaruss') as pochtaruss_1, -- ждём 1
    (select count(*) from public.delivery_methods where name ilike '%%boxberry%%') as boxberry_0, -- ждём 0
    (select count(*) from public.return_reasons)                             as rr_4,         -- ждём 4
    (select count(*) from public.writeoff_reasons)                           as wr_5,         -- ждём 5
    (select count(*) from public.badges)                                     as badges_5,     -- ждём 5
    (select count(*) from public.site_content)                               as keys_73,      -- ждём 73
    (select count(*) from public.site_content where key like 'returns.%%')    as returns_18,   -- ждём 18
    (select count(*) from public.site_content where key like 'segments.%%')   as segments_3,   -- ждём 3
    (select count(*) from public.brand_colors)                               as colors_20,    -- ждём 20
    (select count(*) from public.admin_users)                                as admins_1;     -- ждём 1
-- Ожидаемая строка самопроверки (psql -At): 7|8|3|4|1|0|4|5|5|73|18|3|20|1
