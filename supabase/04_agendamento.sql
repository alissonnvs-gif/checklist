-- ============================================================
--  Checklist — passo 6: o agendamento
--  Rodar UMA vez, DEPOIS de a função "avisos" estar publicada.
--
--  ATENÇÃO — este arquivo tem um lugar para colar a chave de
--  administrador do projeto. NÃO salve o arquivo preenchido dentro
--  do repositório e NÃO mande a chave para ninguém, nem para mim.
--  Preencha na hora de colar no SQL Editor.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Ligar as duas peças que o banco usa para isso
--    pg_cron: o despertador. pg_net: a capacidade de o banco fazer
--    uma chamada para fora.
-- ------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;


-- ------------------------------------------------------------
-- 2. Guardar a chave de administrador no cofre do banco
--
--    O despertador precisa se identificar ao chamar a função. Em vez
--    de deixar a chave escrita no agendamento (onde ficaria visível
--    para quem abrisse a lista de tarefas agendadas), ela vai para o
--    cofre e o agendamento só faz referência a ela.
--
--    TROQUE o texto COLE_A_SERVICE_ROLE_KEY_AQUI pela chave real,
--    que está em Project Settings -> API Keys -> service_role.
-- ------------------------------------------------------------
select vault.create_secret(
  'COLE_A_SERVICE_ROLE_KEY_AQUI',
  'service_role_key',
  'Usada pelo agendamento para chamar a funcao de avisos'
);


-- ------------------------------------------------------------
-- 3. O agendamento em si — de 5 em 5 minutos, o dia inteiro
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
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'service_role_key'
      )
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
