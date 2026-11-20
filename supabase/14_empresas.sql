-- ============================================================
--  Checklist: APPS DE EMPRESA acompanhados por um consultor
--  Rodar UMA vez, no SQL Editor, depois do 13.
--  Logo depois, rodar o arquivo pequeno que diz qual conta é a
--  do consultor (fica FORA do repositório, porque tem o e-mail).
--
--  O pedido (20/11/2026): o app da loja Havaianas Beltrão nasce
--  configurado, e TUDO o que existe nele aparece, e pode ser
--  mexido, no app do Alisson, numa seção "Apps compartilhados".
--  A ideia é repetir isso com as outras empresas que ele atende.
--
--  Como isto é feito SEM mexer em ninguém:
--  nenhuma regra de segurança (RLS) das tabelas que já existem
--  muda uma linha. O consultor lê e grava o app da empresa só
--  pelas funções deste arquivo, que conferem a ligação em TODA
--  chamada. Quem não tem ligação (todo mundo que já usa o app)
--  nunca passa por elas, e as buscas normais do próprio
--  consultor continuam trazendo só o que é dele.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Quem é consultor
--    Sem política nenhuma, de propósito: ninguém lê nem grava
--    esta tabela pelo app. Só o SQL Editor coloca alguém aqui.
-- ------------------------------------------------------------
create table public.consultores (
  user_id    uuid        primary key references auth.users(id) on delete cascade,
  nome       text        not null default '',   -- como a empresa vê: "Alisson, da Blue Crab Design Lab"
  created_at timestamptz not null default now()
);

alter table public.consultores enable row level security;


-- ------------------------------------------------------------
-- 2. A ligação empresa → consultor
--    Uma conta de empresa tem UM consultor (a chave é a conta
--    da empresa). Os dois lados enxergam a ligação; criar e
--    desfazer só pelas funções lá embaixo.
-- ------------------------------------------------------------
create table public.empresas (
  cliente_id   uuid        primary key references auth.users(id) on delete cascade,
  consultor_id uuid        not null references public.consultores(user_id) on delete cascade,
  nome         text        not null default '',
  created_at   timestamptz not null default now()
);

create index empresas_consultor_idx on public.empresas (consultor_id);

alter table public.empresas enable row level security;

create policy "ver a minha ligacao" on public.empresas
  for select using (
    cliente_id = (select auth.uid()) or consultor_id = (select auth.uid())
  );


-- ------------------------------------------------------------
-- 3. O link de empresa
--    É um LINK, não os 6 dígitos das listas: a empresa pode
--    abrir dias depois, então ele vale 7 dias, e por isso
--    precisa ser impossível de chutar (32 letras e números
--    sorteados). Usou, morre.
--    config guarda o que o app da empresa já traz pronto:
--    {"abas": ["Feed", ...], "agendas": ["Reunião MKT"]}
-- ------------------------------------------------------------
create table public.convites_empresa (
  token        text        primary key,
  consultor_id uuid        not null references public.consultores(user_id) on delete cascade,
  nome         text        not null,
  config       jsonb       not null default '{}'::jsonb,
  expires_at   timestamptz not null,
  used_at      timestamptz,
  used_by      uuid        references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);

create index convites_empresa_consultor_idx on public.convites_empresa (consultor_id);

alter table public.convites_empresa enable row level security;

create policy "ver meus links de empresa" on public.convites_empresa
  for select using ( consultor_id = (select auth.uid()) );

create policy "cancelar meus links de empresa" on public.convites_empresa
  for delete using ( consultor_id = (select auth.uid()) );


-- ------------------------------------------------------------
-- 4. A conferência que TODA função de espelho faz primeiro
-- ------------------------------------------------------------
create or replace function public.acompanho(cliente uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.empresas e
     where e.cliente_id = cliente
       and e.consultor_id = (select auth.uid())
  );
$fn$;


-- ------------------------------------------------------------
-- 5. Perguntas simples que o app faz
-- ------------------------------------------------------------
create or replace function public.sou_consultor()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (select 1 from public.consultores c where c.user_id = (select auth.uid()));
$fn$;

create or replace function public.minhas_empresas()
returns table (cliente_id uuid, nome text, desde timestamptz)
language sql
stable
security definer
set search_path = public
as $fn$
  select e.cliente_id, e.nome, e.created_at
    from public.empresas e
   where e.consultor_id = (select auth.uid())
   order by e.created_at;
$fn$;

-- Do lado da empresa: quem acompanha este app. É o que o app usa para
-- avisar a equipe, nas Configurações, que o app é acompanhado.
create or replace function public.meu_consultor()
returns table (empresa text, consultor text)
language sql
stable
security definer
set search_path = public
as $fn$
  select e.nome,
         coalesce(nullif(c.nome, ''), nullif(p.display_name, ''), 'seu consultor')
    from public.empresas e
    join public.consultores c on c.user_id = e.consultor_id
    left join public.profiles p on p.id = e.consultor_id
   where e.cliente_id = (select auth.uid());
$fn$;


-- ------------------------------------------------------------
-- 6. Gerar o link de uma empresa nova (só consultor)
-- ------------------------------------------------------------
create or replace function public.criar_convite_empresa(nome_empresa text, config_empresa jsonb)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu    uuid := (select auth.uid());
  limpo text := left(btrim(coalesce(nome_empresa, '')), 80);
  tk    text;
  vence timestamptz := now() + interval '7 days';
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;
  if not exists (select 1 from public.consultores c where c.user_id = eu) then
    return json_build_object('ok', false, 'erro', 'nao e consultor');
  end if;
  if limpo = '' then
    return json_build_object('ok', false, 'erro', 'sem nome');
  end if;

  -- 122 bits sorteados: chutar um link destes não é uma possibilidade real.
  tk := replace(gen_random_uuid()::text, '-', '');

  insert into public.convites_empresa (token, consultor_id, nome, config, expires_at)
  values (tk, eu, limpo, coalesce(config_empresa, '{}'::jsonb), vence);

  return json_build_object('ok', true, 'token', tk, 'expira_em', vence);
end;
$fn$;


-- ------------------------------------------------------------
-- 7. A empresa usa o link
--    Liga a conta ao consultor e devolve o que o app deve
--    deixar pronto (abas e agendas). Quem aplica é o próprio
--    app da empresa, pelo caminho normal de gravação dele.
-- ------------------------------------------------------------
create or replace function public.usar_convite_empresa(token_empresa text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu uuid := (select auth.uid());
  cv public.convites_empresa%rowtype;
  ja public.empresas%rowtype;
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;

  select * into cv
    from public.convites_empresa c
   where c.token = token_empresa
     and c.used_at is null
     and c.expires_at > now();

  -- Mensagem única para errado, usado e vencido, igual aos números de 6
  -- dígitos: separar os três contaria a quem chuta que o link existe.
  if not found then
    return json_build_object('ok', false, 'erro', 'invalido');
  end if;

  -- O consultor abrindo o próprio link (para testar, por exemplo) não pode
  -- virar empresa de si mesmo. Nem de outro consultor.
  if cv.consultor_id = eu or exists (select 1 from public.consultores c where c.user_id = eu) then
    return json_build_object('ok', false, 'erro', 'proprio');
  end if;

  select * into ja from public.empresas e where e.cliente_id = eu;
  if found and ja.consultor_id <> cv.consultor_id then
    return json_build_object('ok', false, 'erro', 'ja acompanhada');
  end if;

  insert into public.empresas (cliente_id, consultor_id, nome)
  values (eu, cv.consultor_id, cv.nome)
  on conflict (cliente_id) do update set nome = excluded.nome;

  update public.convites_empresa c
     set used_at = now(), used_by = eu
   where c.token = cv.token;

  return json_build_object('ok', true, 'nome', cv.nome, 'config', cv.config);
end;
$fn$;


-- ------------------------------------------------------------
-- 8. O consultor desliga uma empresa
--    Só desfaz a ligação. O app da empresa continua inteiro,
--    com tudo dentro; só deixa de aparecer para o consultor.
-- ------------------------------------------------------------
create or replace function public.desligar_empresa(cliente uuid)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
begin
  delete from public.empresas e
   where e.cliente_id = cliente
     and e.consultor_id = (select auth.uid());
  return json_build_object('ok', found);
end;
$fn$;


-- ------------------------------------------------------------
-- 9. LER o app inteiro de uma empresa (só o consultor dela)
--    Devolve as mesmas colunas que o app pede nas buscas
--    normais, para ele montar a tela pelo mesmo caminho.
--    Só o que é DA EMPRESA: listas ou agendas que terceiros
--    compartilharam com ela não entram.
-- ------------------------------------------------------------
create or replace function public.espelho_ler(cliente uuid)
returns json
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if not public.acompanho(cliente) then
    raise exception 'sem acesso a este app' using errcode = '42501';
  end if;

  return json_build_object(
    'nome', (select e.nome from public.empresas e where e.cliente_id = cliente),
    'display_name', (select p.display_name from public.profiles p where p.id = cliente),

    'cats', coalesce((
      select json_agg(json_build_object(
               'id', c.id, 'label', c.label, 'palette', c.palette, 'sort_order', c.sort_order)
             order by c.sort_order, c.created_at)
        from public.categories c where c.user_id = cliente), '[]'::json),

    'tasks', coalesce((
      select json_agg(json_build_object(
               'id', t.id, 'category_id', t.category_id, 'kind', t.kind,
               'title', t.title, 'note', t.note, 'days', t.days,
               'due_date', t.due_date, 'time_of_day', t.time_of_day,
               'done', t.done, 'created_at', t.created_at))
        from public.tasks t where t.user_id = cliente), '[]'::json),

    'checks', coalesce((
      select json_agg(json_build_object(
               'task_id', k.task_id, 'week_monday', k.week_monday, 'weekday', k.weekday))
        from public.task_checks k where k.user_id = cliente), '[]'::json),

    'lists', coalesce((
      select json_agg(json_build_object(
               'id', l.id, 'owner_id', l.owner_id, 'title', l.title,
               'sort_order', l.sort_order, 'created_at', l.created_at, 'palette', l.palette))
        from public.lists l where l.owner_id = cliente), '[]'::json),

    'items', coalesce((
      select json_agg(json_build_object(
               'id', i.id, 'list_id', i.list_id, 'qty', i.qty, 'name', i.name,
               'done', i.done, 'sort_order', i.sort_order, 'created_at', i.created_at))
        from public.list_items i
        join public.lists l on l.id = i.list_id
       where l.owner_id = cliente), '[]'::json),

    'agendas', coalesce((
      select json_agg(json_build_object(
               'id', g.id, 'owner_id', g.owner_id, 'title', g.title,
               'sort_order', g.sort_order, 'created_at', g.created_at, 'palette', g.palette))
        from public.agendas g where g.owner_id = cliente), '[]'::json),

    'appts', coalesce((
      select json_agg(to_jsonb(a))
        from public.appointments a where a.owner_id = cliente), '[]'::json)
  );
end;
$fn$;


-- ------------------------------------------------------------
-- 10. GRAVAR no app de uma empresa (só o consultor dela)
--
--     modo, igual ao que o app já faz nas tabelas dele:
--       'gravar'  = cria ou altera (abas, tarefas, marcações)
--       'criar'   = só cria; se já existe, o banco responde 23505
--                   e o app tenta 'alterar' (listas, itens,
--                   agendas, atendimentos)
--       'alterar' = só altera o que já existe
--     A separação importa por causa do teto de listas e de
--     agendas: um "cria ou altera" passaria pela contagem do
--     teto até para só renomear, e recusaria a 5ª lista.
--
--     O DONO de cada linha é sempre a empresa, venha o que vier
--     do app: user_id e owner_id mandados são ignorados.
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


-- ------------------------------------------------------------
-- 11. APAGAR no app de uma empresa (só o consultor dela)
--     chaves = lista de {"id": ...}; nas marcações,
--     {"task_id", "week_monday", "weekday"}.
--     Só apaga linha cujo dono é a empresa.
-- ------------------------------------------------------------
create or replace function public.espelho_apagar(cliente uuid, tabela text, chaves jsonb)
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
  if chaves is null or jsonb_typeof(chaves) <> 'array' then
    raise exception 'chaves precisa ser uma lista' using errcode = '22023';
  end if;

  if tabela = 'task_checks' then
    delete from public.task_checks d
     using jsonb_to_recordset(chaves) as r(task_id text, week_monday date, weekday smallint)
     where d.user_id = cliente and d.task_id = r.task_id
       and d.week_monday = r.week_monday and d.weekday = r.weekday;
  elsif tabela = 'tasks' then
    delete from public.tasks d
     where d.user_id = cliente
       and d.id in (select r.id from jsonb_to_recordset(chaves) as r(id text));
  elsif tabela = 'categories' then
    delete from public.categories d
     where d.user_id = cliente
       and d.id in (select r.id from jsonb_to_recordset(chaves) as r(id text));
  elsif tabela = 'list_items' then
    delete from public.list_items d
     where d.id in (select r.id from jsonb_to_recordset(chaves) as r(id text))
       and d.list_id in (select l.id from public.lists l where l.owner_id = cliente);
  elsif tabela = 'lists' then
    delete from public.lists d
     where d.owner_id = cliente
       and d.id in (select r.id from jsonb_to_recordset(chaves) as r(id text));
  elsif tabela = 'appointments' then
    delete from public.appointments d
     where d.owner_id = cliente
       and d.id in (select r.id from jsonb_to_recordset(chaves) as r(id text));
  elsif tabela = 'agendas' then
    delete from public.agendas d
     where d.owner_id = cliente
       and d.id in (select r.id from jsonb_to_recordset(chaves) as r(id text));
  else
    raise exception 'tabela não aceita: %', tabela using errcode = '22023';
  end if;
  get diagnostics n = row_count;

  return json_build_object('ok', true, 'n', n);
end;
$fn$;


-- ------------------------------------------------------------
-- 12. Faxina: link vencido e não usado não precisa ficar.
-- ------------------------------------------------------------
select cron.schedule(
  'checklist-links-empresa-vencidos',
  '17 3 * * *',
  $cron$
  delete from public.convites_empresa
   where used_at is null and expires_at < now() - interval '1 day';
  $cron$
);


-- ------------------------------------------------------------
-- 13. Quem pode chamar o quê
--     Função nova nasce liberada para "public" no Postgres. Tira
--     de todo mundo e devolve só para quem está logado.
--     acompanho() é peça interna: não fica liberada para ninguém.
-- ------------------------------------------------------------
revoke execute on function public.acompanho(uuid)                          from public, anon, authenticated;
revoke execute on function public.sou_consultor()                          from public, anon;
revoke execute on function public.minhas_empresas()                        from public, anon;
revoke execute on function public.meu_consultor()                          from public, anon;
revoke execute on function public.criar_convite_empresa(text, jsonb)       from public, anon;
revoke execute on function public.usar_convite_empresa(text)               from public, anon;
revoke execute on function public.desligar_empresa(uuid)                   from public, anon;
revoke execute on function public.espelho_ler(uuid)                        from public, anon;
revoke execute on function public.espelho_gravar(uuid, text, text, jsonb)  from public, anon;
revoke execute on function public.espelho_apagar(uuid, text, jsonb)        from public, anon;

grant execute on function public.sou_consultor()                           to authenticated;
grant execute on function public.minhas_empresas()                         to authenticated;
grant execute on function public.meu_consultor()                           to authenticated;
grant execute on function public.criar_convite_empresa(text, jsonb)        to authenticated;
grant execute on function public.usar_convite_empresa(text)                to authenticated;
grant execute on function public.desligar_empresa(uuid)                    to authenticated;
grant execute on function public.espelho_ler(uuid)                         to authenticated;
grant execute on function public.espelho_gravar(uuid, text, text, jsonb)   to authenticated;
grant execute on function public.espelho_apagar(uuid, text, jsonb)         to authenticated;
