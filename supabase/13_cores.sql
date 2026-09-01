-- =====================================================================
-- 13_cores.sql — a cor escolhida na criação da agenda e da lista
--
-- Antes disso a cor era fixa no código: agenda sempre violeta, lista
-- sempre turquesa. Agora quem cria escolhe, e a escolha precisa viajar
-- entre os aparelhos como o resto.
--
-- Rodar inteiro de uma vez no SQL Editor do Supabase.
--
-- É seguro rodar mais de uma vez: o IF NOT EXISTS impede erro se a
-- coluna já estiver lá.
--
-- E é seguro NÃO rodar: o app detecta que a coluna não existe, reenvia
-- a linha sem a cor e continua salvando normalmente. Só a cor é que não
-- fica guardada até isto aqui rodar.
-- =====================================================================

alter table public.lists
  add column if not exists palette text not null default 'turquesa';

alter table public.agendas
  add column if not exists palette text not null default 'violeta';

-- Conferência: as duas linhas abaixo têm que devolver 'palette'.
-- select column_name from information_schema.columns
--   where table_schema = 'public' and table_name = 'lists' and column_name = 'palette';
-- select column_name from information_schema.columns
--   where table_schema = 'public' and table_name = 'agendas' and column_name = 'palette';
