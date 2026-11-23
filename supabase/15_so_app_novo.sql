-- ============================================================
--  Checklist: o banco só aceita gravação do app ATUALIZADO (v40)
--  Rodar UMA vez, no SQL Editor, DEPOIS que a v40 estiver no ar.
--  (Rodar antes deixaria todo mundo sem conseguir salvar até a
--  v40 chegar.)
--
--  O pedido (23/11/2026): "de jeito nenhum pode ser gravado coisa
--  que não foi a própria pessoa que gravou, e de jeito nenhum
--  pode remover ou alterar algo sem que a pessoa altere ou remova".
--
--  O que aconteceu: em 23/11, às 9h13, o computador da conta
--  Oriente abriu o app (v39), um pedido da leitura de abertura
--  falhou, e o app reenviou a cópia inteira do aparelho por cima
--  do servidor (~200 atendimentos). Esse comportamento existe em
--  TODAS as versões até a v39. A v40 não tem mais esse caminho:
--  ela só envia o que a pessoa fez no aparelho, campo por campo.
--
--  Mas um celular que ainda não abriu a v40 continua rodando a
--  versão velha, e pode repetir o estrago na próxima abertura com
--  internet ruim. Este arquivo fecha essa porta NO BANCO: toda
--  gravação que vem do app precisa dizer que é a v40 ou mais nova
--  (cabeçalho x-checklist-app). Versão velha passa a só LER; ao
--  fechar e abrir o app, ela vira v40 e volta a gravar.
--
--  Não muda nada para:
--  - o SQL Editor (você continua mexendo à vontade por aqui);
--  - a função de avisos (ela só grava push_sent e push_subscriptions);
--  - o cadastro de conta e a faxina agendada (não passam pela API).
--
--  Para desfazer, se um dia precisar:
--    drop trigger ... (os 8 nomes "so_app_novo_*" lá embaixo)
--    e drop function public.so_app_atualizado();
-- ============================================================


-- ------------------------------------------------------------
-- 1. A trava
-- ------------------------------------------------------------
create or replace function public.so_app_atualizado()
returns trigger
language plpgsql
as $fn$
declare
  cab    json;
  versao text;
begin
  -- Fora de um pedido da API não existe cabeçalho: SQL Editor,
  -- cadastro de conta, tarefas agendadas. Esses passam.
  begin
    cab := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    cab := null;
  end;
  if cab is null then
    return coalesce(new, old);
  end if;

  versao := cab->>'x-checklist-app';
  if versao is null or versao !~ '^v[0-9]+$' or substring(versao from 2)::int < 40 then
    raise exception 'Versao antiga do app. Feche e abra o app de novo para atualizar.'
      using errcode = 'PT426';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists so_app_novo_profiles     on public.profiles;
drop trigger if exists so_app_novo_categories   on public.categories;
drop trigger if exists so_app_novo_tasks        on public.tasks;
drop trigger if exists so_app_novo_task_checks  on public.task_checks;
drop trigger if exists so_app_novo_lists        on public.lists;
drop trigger if exists so_app_novo_list_items   on public.list_items;
drop trigger if exists so_app_novo_agendas      on public.agendas;
drop trigger if exists so_app_novo_appointments on public.appointments;

create trigger so_app_novo_profiles     before insert or update or delete on public.profiles
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_categories   before insert or update or delete on public.categories
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_tasks        before insert or update or delete on public.tasks
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_task_checks  before insert or update or delete on public.task_checks
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_lists        before insert or update or delete on public.lists
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_list_items   before insert or update or delete on public.list_items
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_agendas      before insert or update or delete on public.agendas
  for each row execute function public.so_app_atualizado();
create trigger so_app_novo_appointments before insert or update or delete on public.appointments
  for each row execute function public.so_app_atualizado();


-- ------------------------------------------------------------
-- 2. App de empresa (espelho): alterar SÓ o campo mudado
--    também em abas e tarefas.
--
--    No 14_empresas.sql, abas e tarefas só tinham "gravar" (a
--    linha inteira por cima). A v40 manda só o que a pessoa mudou
--    ("alterar"); o resto da função é igual ao 14, linha por linha.
--    Campo que não veio fica como está. Para poder APAGAR um campo
--    de propósito (tarefa que perde a data), vale a presença da
--    chave, não o valor: por isso aqui é j ? 'campo'.
-- ------------------------------------------------------------
create or replace function public.espelho_gravar(cliente uuid, tabela text, modo text, linhas jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  n int := 0;
begin
  if not public.acompanho(cliente) then
    raise exception 'sem acesso a este app' using errcode = '42501';
  end if;
  if linhas is null or jsonb_typeof(linhas) <> 'array' then
    raise exception 'linhas precisa ser uma lista' using errcode = '22023';
  end if;

  -- ---------- abas ----------
  if tabela = 'categories' and modo = 'gravar' then
    insert into public.categories as d (user_id, id, label, palette, sort_order)
    select cliente, r.id, coalesce(r.label, 'Sem nome'), coalesce(r.palette, 'azul'), coalesce(r.sort_order, 0)
      from jsonb_to_recordset(linhas) as r(id text, label text, palette text, sort_order int)
    on conflict (user_id, id) do update
       set label = excluded.label, palette = excluded.palette, sort_order = excluded.sort_order;
    get diagnostics n = row_count;

  elsif tabela = 'categories' and modo = 'alterar' then
    update public.categories d set
           label      = case when j ? 'label'      then coalesce(j->>'label', d.label)                  else d.label end,
           palette    = case when j ? 'palette'    then coalesce(j->>'palette', d.palette)              else d.palette end,
           sort_order = case when j ? 'sort_order' then coalesce((j->>'sort_order')::int, d.sort_order) else d.sort_order end
      from jsonb_array_elements(linhas) as j
     where d.user_id = cliente and d.id = j->>'id';
    get diagnostics n = row_count;

  -- ---------- tarefas ----------
  -- A chave estrangeira (user_id, category_id) já garante que a aba é da
  -- empresa: tarefa apontando para aba de outra conta é recusada pelo banco.
  elsif tabela = 'tasks' and modo = 'gravar' then
    insert into public.tasks as d
           (user_id, id, category_id, kind, title, note, days, due_date, time_of_day, done, created_at)
    select cliente, r.id, r.category_id, r.kind, coalesce(r.title, ''), coalesce(r.note, ''),
           coalesce(r.days, '{}'), r.due_date, coalesce(r.time_of_day, ''), coalesce(r.done, false),
           coalesce(r.created_at, now())
      from jsonb_to_recordset(linhas) as r(
             id text, category_id text, kind text, title text, note text, days smallint[],
             due_date date, time_of_day text, done boolean, created_at timestamptz)
    on conflict (user_id, id) do update
       set category_id = excluded.category_id, kind = excluded.kind, title = excluded.title,
           note = excluded.note, days = excluded.days, due_date = excluded.due_date,
           time_of_day = excluded.time_of_day, done = excluded.done, created_at = excluded.created_at;
    get diagnostics n = row_count;

  elsif tabela = 'tasks' and modo = 'alterar' then
    update public.tasks d set
           category_id = case when j ? 'category_id' then j->>'category_id' else d.category_id end,
           kind        = case when j ? 'kind'        then j->>'kind'        else d.kind end,
           title       = case when j ? 'title'       then coalesce(j->>'title', '') else d.title end,
           note        = case when j ? 'note'        then coalesce(j->>'note', '')  else d.note end,
           days        = case when j ? 'days'
                              then coalesce(array(select jsonb_array_elements_text(j->'days'))::smallint[], '{}')
                              else d.days end,
           due_date    = case when j ? 'due_date'    then (j->>'due_date')::date else d.due_date end,
           time_of_day = case when j ? 'time_of_day' then coalesce(j->>'time_of_day', '') else d.time_of_day end,
           done        = case when j ? 'done'        then coalesce((j->>'done')::boolean, false) else d.done end
      from jsonb_array_elements(linhas) as j
     where d.user_id = cliente and d.id = j->>'id';
    get diagnostics n = row_count;

  -- ---------- marcações da semana ----------
  elsif tabela = 'task_checks' and modo = 'gravar' then
    insert into public.task_checks (user_id, task_id, week_monday, weekday)
    select cliente, r.task_id, r.week_monday, r.weekday
      from jsonb_to_recordset(linhas) as r(task_id text, week_monday date, weekday smallint)
    on conflict do nothing;
    get diagnostics n = row_count;

  -- ---------- listas ----------
  elsif tabela = 'lists' and modo = 'criar' then
    insert into public.lists (id, owner_id, title, palette, sort_order, created_at)
    select r.id, cliente, coalesce(r.title, 'Nova lista'), coalesce(r.palette, 'turquesa'),
           coalesce(r.sort_order, 0), coalesce(r.created_at, now())
      from jsonb_to_recordset(linhas) as r(id text, title text, palette text, sort_order int, created_at timestamptz);
    get diagnostics n = row_count;

  elsif tabela = 'lists' and modo = 'alterar' then
    update public.lists d
       set title = coalesce(r.title, d.title), palette = coalesce(r.palette, d.palette),
           sort_order = coalesce(r.sort_order, d.sort_order)
      from jsonb_to_recordset(linhas) as r(id text, title text, palette text, sort_order int)
     where d.id = r.id and d.owner_id = cliente;
    get diagnostics n = row_count;

  -- ---------- itens das listas ----------
  elsif tabela = 'list_items' and modo in ('criar', 'alterar') then
    if exists (
      select 1 from jsonb_to_recordset(linhas) as r(list_id text)
       where not exists (select 1 from public.lists l where l.id = r.list_id and l.owner_id = cliente)
    ) then
      raise exception 'item de uma lista que não é deste app' using errcode = '42501';
    end if;

    if modo = 'criar' then
      insert into public.list_items (id, list_id, qty, name, done, sort_order, created_at)
      select r.id, r.list_id, coalesce(r.qty, ''), coalesce(r.name, ''), coalesce(r.done, false),
             coalesce(r.sort_order, 0), coalesce(r.created_at, now())
        from jsonb_to_recordset(linhas) as r(
               id text, list_id text, qty text, name text, done boolean, sort_order int, created_at timestamptz);
    else
      update public.list_items d
         set list_id = r.list_id, qty = coalesce(r.qty, d.qty), name = coalesce(r.name, d.name),
             done = coalesce(r.done, d.done), sort_order = coalesce(r.sort_order, d.sort_order)
        from jsonb_to_recordset(linhas) as r(id text, list_id text, qty text, name text, done boolean, sort_order int)
       where d.id = r.id
         and d.list_id in (select l.id from public.lists l where l.owner_id = cliente);
    end if;
    get diagnostics n = row_count;

  -- ---------- agendas ----------
  elsif tabela = 'agendas' and modo = 'criar' then
    insert into public.agendas (id, owner_id, title, palette, sort_order, created_at)
    select r.id, cliente, coalesce(r.title, 'Nova agenda'), coalesce(r.palette, 'violeta'),
           coalesce(r.sort_order, 0), coalesce(r.created_at, now())
      from jsonb_to_recordset(linhas) as r(id text, title text, palette text, sort_order int, created_at timestamptz);
    get diagnostics n = row_count;

  elsif tabela = 'agendas' and modo = 'alterar' then
    update public.agendas d
       set title = coalesce(r.title, d.title), palette = coalesce(r.palette, d.palette),
           sort_order = coalesce(r.sort_order, d.sort_order)
      from jsonb_to_recordset(linhas) as r(id text, title text, palette text, sort_order int)
     where d.id = r.id and d.owner_id = cliente;
    get diagnostics n = row_count;

  -- ---------- atendimentos ----------
  elsif tabela = 'appointments' and modo in ('criar', 'alterar') then
    if exists (
      select 1 from jsonb_to_recordset(linhas) as r(agenda_id text)
       where not exists (select 1 from public.agendas g where g.id = r.agenda_id and g.owner_id = cliente)
    ) then
      raise exception 'atendimento de uma agenda que não é deste app' using errcode = '42501';
    end if;

    if modo = 'criar' then
      insert into public.appointments
             (id, owner_id, agenda_id, day_date, time_of_day, name, kind, note, done, confirmed, created_at)
      select r.id, cliente, r.agenda_id, r.day_date, coalesce(r.time_of_day, ''), coalesce(r.name, ''),
             coalesce(r.kind, ''), coalesce(r.note, ''), coalesce(r.done, false),
             coalesce(r.confirmed, false), coalesce(r.created_at, now())
        from jsonb_to_recordset(linhas) as r(
               id text, agenda_id text, day_date date, time_of_day text, name text, kind text,
               note text, done boolean, confirmed boolean, created_at timestamptz);
    else
      update public.appointments d
         set agenda_id = r.agenda_id, day_date = coalesce(r.day_date, d.day_date),
             time_of_day = coalesce(r.time_of_day, d.time_of_day), name = coalesce(r.name, d.name),
             kind = coalesce(r.kind, d.kind), note = coalesce(r.note, d.note),
             done = coalesce(r.done, d.done), confirmed = coalesce(r.confirmed, d.confirmed)
        from jsonb_to_recordset(linhas) as r(
               id text, agenda_id text, day_date date, time_of_day text, name text, kind text,
               note text, done boolean, confirmed boolean)
       where d.id = r.id and d.owner_id = cliente;
    end if;
    get diagnostics n = row_count;

  else
    raise exception 'tabela ou modo não aceito: % / %', tabela, modo using errcode = '22023';
  end if;

  return json_build_object('ok', true, 'n', n);
end;
$fn$;
