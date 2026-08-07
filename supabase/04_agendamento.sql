-- ============================================================
--  Checklist — passo 6: o agendamento
--  Rodar UMA vez, DEPOIS de a função "avisos" estar publicada com a
--  verificação por senha e com o segredo CRON_SECRET cadastrado.
--
--  Note que a chave de administrador do projeto NÃO aparece aqui.
--  A verificação de token do painel exige chave no formato antigo, que
--  este projeto não usa; em vez de contornar isso com a service_role,
--  a função confere uma senha própria. Uma coisa a menos com poder
--  total sobre o banco circulando por aí.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Ligar as duas peças que o banco usa para isso
--    pg_cron: o despertador. pg_net: a capacidade de o banco fazer
--    uma chamada para fora.
-- ------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;


-- ------------------------------------------------------------
-- 2. O agendamento — de 5 em 5 minutos, o dia inteiro
--
--    Cinco minutos é o que define a precisão do aviso: o "1 hora
--    antes" pode chegar entre 60 e 55 minutos antes. Mais frequente
--    gastaria a franquia à toa; menos frequente ficaria impreciso.
-- ------------------------------------------------------------
select cron.schedule(
  'checklist-avisos',
  '*/5 * * * *',
  $$
  select net.http_post(
    url     := 'https://vccmpzzebhwmbarqnfod.supabase.co/functions/v1/avisos',
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      'x-checklist-cron', 'jpWZ4_mvy1uyZs8fr-2qL58jreRgwYTP'
    ),
    body    := '{}'::jsonb
  );
  $$
);


-- ------------------------------------------------------------
-- Úteis depois
-- ------------------------------------------------------------
-- Ver se está agendado:
--   select jobname, schedule, active from cron.job;
--
-- Ver as últimas execuções (e se deram erro):
--   select status, return_message, start_time
--   from cron.job_run_details order by start_time desc limit 10;
--
-- Desligar sem apagar nada do resto:
--   select cron.unschedule('checklist-avisos');
