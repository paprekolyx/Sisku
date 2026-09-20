/* ==========================================================================
   SISKU · config.js — ЕДИНСТВЕННОЕ МЕСТО, КУДА ВСТАВЛЯЮТСЯ КЛЮЧИ ОТ БАЗЫ
   Черновик v0.1.0-draft

   КАК ПОДКЛЮЧИТЬ СВОЮ БАЗУ (инструкция: docs/setup-supabase.md):
   1. Supabase Dashboard → ваш новый проект → Settings → API
      (в новом интерфейсе: Connect → API keys).
   2. Скопируйте "Project URL" и "anon public" ключ.
   3. Вставьте их в две константы ниже вместо заглушек.
   4. Закоммитьте файл. Публичный ключ в черновике — это нормально:
      доступ ограничивает RLS (см. supabase/02_rls_and_access.sql).
   ========================================================================== */

const SUPABASE_URL = 'https://pvycejsqrkkmueyzijsp.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_LOV49t7eyUZbGP-dZMoGJw_rdGjLF14';

const SITE_VERSION = '0.5.0-draft';

/* Клиент БД. Если ключи не заполнены или библиотека не загрузилась —
   страницы покажут понятную плашку вместо бесконечного скелетона. */
let db = null;
let dbError = null;
try {
  if (/ВСТАВЬТЕ/.test(SUPABASE_URL) || /ВСТАВЬТЕ/.test(SUPABASE_ANON_KEY)) {
    dbError = 'Ключи базы не заполнены в assets/js/config.js';
  } else if (typeof window.supabase === 'undefined') {
    dbError = 'Библиотека Supabase не загрузилась (assets/vendor/supabase.min.js)';
  } else {
    db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
} catch (e) {
  dbError = 'Не удалось создать клиент БД: ' + e.message;
}
