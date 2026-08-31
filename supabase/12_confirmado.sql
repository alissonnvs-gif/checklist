-- ============================================================
--  Checklist — "confirmado" no atendimento
--  Rodar UMA vez, no SQL Editor, depois do 11.
--
--  São dois estados diferentes, e de propósito:
--    confirmed = o paciente avisou que vem
--    done      = a consulta aconteceu
--  Um é da véspera, o outro é do fim do atendimento. Juntar os
--  dois num campo só faria perder a diferença que importa na
--  hora de olhar o dia.
--
--  ⚠️ O app aguenta esta coluna não existir: ele detecta a
--  recusa, tira o campo do envio e continua. Rodar antes ou
--  depois de publicar não quebra nada.
-- ============================================================

alter table public.appointments
  add column if not exists confirmed boolean not null default false;


-- Conferência rápida (deve listar a coluna nova):
--   select column_name, data_type, column_default
--   from information_schema.columns
--   where table_schema = 'public' and table_name = 'appointments'
--     and column_name = 'confirmed';
