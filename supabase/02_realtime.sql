-- ============================================================
--  Checklist — permissão de leitura do canal de tempo real
--  Rodar UMA vez, no SQL Editor, depois do 01_schema.sql.
--
--  Por que isto é necessário: este projeto usa o modelo novo de
--  autorização do Realtime. Nele, um canal "público" conecta mas
--  não carrega a identidade de quem conectou — e sem identidade o
--  servidor não consegue aplicar o RLS às linhas alteradas, então
--  filtra tudo e não entrega evento nenhum. O canal precisa ser
--  privado, e canal privado exige uma permissão explícita.
--
--  A regra abaixo é estreita de propósito: cada conta só consegue
--  escutar exatamente o canal com o próprio id no nome, que é o
--  que o app usa ("checklist-<id da conta>"). Ninguém escuta o
--  canal de outra pessoa, nem por engano nem de propósito.
-- ============================================================

create policy "escuta apenas o proprio canal"
  on realtime.messages
  for select
  to authenticated
  using ( realtime.topic() = 'checklist-' || (select auth.uid())::text );
