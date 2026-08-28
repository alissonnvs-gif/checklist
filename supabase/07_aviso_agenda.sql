-- ============================================================
--  Checklist — o aviso do dia da AGENDA
--  Rodar UMA vez, no SQL Editor, depois do 06_agenda.sql.
--
--  Decisão dele (28/08/2026): o aviso da agenda sai no MESMO
--  horário do resumo das tarefas, mas como NOTIFICAÇÃO SEPARADA
--  — dois alertas, um de cada coisa, e não um só com as duas
--  dentro. Por isso não existe hora nova aqui: existe só um
--  interruptor novo, e a hora continua sendo notif_resumo_hora.
--
--  ⚠️ RODE ISTO ANTES de publicar a versão nova do app. O app
--  passa a gravar esta coluna no perfil; sem ela, a gravação do
--  perfil seria recusada e o sincronismo travaria.
-- ============================================================

alter table public.profiles
  add column if not exists notif_agenda boolean not null default true;


-- Conferência rápida (deve listar a coluna nova):
--   select column_name, data_type, column_default
--   from information_schema.columns
--   where table_schema = 'public' and table_name = 'profiles'
--     and column_name = 'notif_agenda';
