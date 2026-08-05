-- ============================================================
--  Checklist — estrutura inicial do banco (Supabase)
--  Rodar UMA vez, no SQL Editor do projeto.
--
--  Regra central: TODA tabela guarda o dono (user_id) e tem
--  RLS ligado. RLS = o banco só devolve as linhas de quem está
--  logado. A separação entre usuários acontece aqui, no banco,
--  não no app — então nem um app com bug nem alguém mexendo
--  direto na API consegue ler as tarefas de outra pessoa.
-- ============================================================


-- ------------------------------------------------------------
-- 1. profiles — preferências da pessoa
--    (nome da saudação e tema dia/noite)
--    A aba ativa e a semana sendo vista NÃO ficam aqui de
--    propósito: são estado de tela, fazem sentido por aparelho.
-- ------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text        not null default '',
  theme        text        check (theme in ('dia', 'noite')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);


-- ------------------------------------------------------------
-- 2. categories — as abas (Blue Crab, LOOM, ... e as criadas)
--    O id continua sendo o texto que o app já usa ("blueCrab").
--    A chave é (user_id, id): dois usuários podem ter uma aba
--    "blueCrab" cada um, sem colidir.
-- ------------------------------------------------------------
create table public.categories (
  user_id    uuid        not null references auth.users(id) on delete cascade,
  id         text        not null,
  label      text        not null default 'Sem nome',
  palette    text        not null,
  sort_order int         not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);


-- ------------------------------------------------------------
-- 3. tasks — cronograma e tarefas únicas na MESMA tabela
--    kind = 'schedule' (recorrente, usa days)
--    kind = 'once'     (única, usa due_date e done)
--    Juntar as duas corta pela metade o código de sincronismo;
--    o app volta a separá-las em duas listas ao carregar.
--    Colunas com nome trocado para não colidir com palavras
--    reservadas do Postgres: date -> due_date, time -> time_of_day.
-- ------------------------------------------------------------
create table public.tasks (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  id          text        not null,
  category_id text        not null,
  kind        text        not null check (kind in ('schedule', 'once')),
  title       text        not null default '',
  note        text        not null default '',
  days        smallint[]  not null default '{}',   -- 0=dom ... 6=sáb
  due_date    date,
  time_of_day text        not null default '',     -- "HH:MM" ou vazio
  done        boolean     not null default false,  -- só usado por 'once'
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (user_id, id),
  foreign key (user_id, category_id)
    references public.categories(user_id, id) on delete cascade
);

create index tasks_user_category_idx on public.tasks (user_id, category_id);


-- ------------------------------------------------------------
-- 4. task_checks — o histórico semanal
--    Uma linha = "esta tarefa foi marcada neste dia desta semana".
--    Desmarcar apaga a linha. Guarda week_monday + weekday
--    exatamente como o app já calcula hoje, para não haver
--    conversão de data no meio (fonte clássica de bug).
-- ------------------------------------------------------------
create table public.task_checks (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  task_id     text        not null,
  week_monday date        not null,
  weekday     smallint    not null check (weekday between 0 and 6),
  created_at  timestamptz not null default now(),
  primary key (user_id, task_id, week_monday, weekday),
  foreign key (user_id, task_id)
    references public.tasks(user_id, id) on delete cascade
);

create index task_checks_user_week_idx on public.task_checks (user_id, week_monday);


-- ============================================================
--  RLS — o isolamento entre usuários
-- ============================================================

alter table public.profiles    enable row level security;
alter table public.categories  enable row level security;
alter table public.tasks       enable row level security;
alter table public.task_checks enable row level security;

-- "using" filtra o que a pessoa PODE LER/alterar.
-- "with check" impede gravar uma linha com o dono de outra pessoa.
create policy "dono do perfil" on public.profiles
  for all
  using       ((select auth.uid()) = id)
  with check  ((select auth.uid()) = id);

create policy "dono das abas" on public.categories
  for all
  using       ((select auth.uid()) = user_id)
  with check  ((select auth.uid()) = user_id);

create policy "dono das tarefas" on public.tasks
  for all
  using       ((select auth.uid()) = user_id)
  with check  ((select auth.uid()) = user_id);

create policy "dono do historico" on public.task_checks
  for all
  using       ((select auth.uid()) = user_id)
  with check  ((select auth.uid()) = user_id);


-- ============================================================
--  Automações
-- ============================================================

-- updated_at se atualiza sozinho em qualquer alteração.
-- Serve para o app saber o que mudou desde a última visita.
create function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch   before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger categories_touch before update on public.categories
  for each row execute function public.touch_updated_at();
create trigger tasks_touch      before update on public.tasks
  for each row execute function public.touch_updated_at();


-- Todo usuário novo ganha um perfil automaticamente no cadastro,
-- para o app nunca encontrar um perfil faltando.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================
--  Tempo real (passo 4 do plano)
--  Ligado desde já porque não custa nada e evita mexer no
--  banco de novo depois. replica identity full faz o aviso de
--  alteração/exclusão carregar o dono da linha, sem o que o
--  RLS não consegue filtrar quem deve receber o aviso.
-- ============================================================

alter table public.categories  replica identity full;
alter table public.tasks       replica identity full;
alter table public.task_checks replica identity full;

alter publication supabase_realtime add table public.categories;
alter publication supabase_realtime add table public.tasks;
alter publication supabase_realtime add table public.task_checks;
