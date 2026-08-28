-- ============================================================
--  Checklist — Agenda (a segunda faceta)
--  Rodar UMA vez, no SQL Editor, depois do 05_listas.sql.
--
--  Mesma decisão das listas: já nasce com o conceito de
--  convidado, para a regra de segurança não precisar ser
--  reescrita em cima de dados reais quando a secretária entrar.
--
--  Diferença importante para as listas: o que se compartilha
--  aqui é A AGENDA DA PESSOA INTEIRA, não um atendimento
--  isolado. Foi o que ele descreveu — "compartilho a agenda com
--  ela e ela põe paciente lá". Por isso o convite é por dono, e
--  não por linha.
-- ============================================================


-- ------------------------------------------------------------
-- 1. appointments — um atendimento marcado
--
--    day_date em vez de "day" porque day é unidade de intervalo
--    no Postgres e vira armadilha em consulta; o mesmo cuidado
--    que fez "date" virar "due_date" nas tarefas.
--
--    Cada atendimento é AVULSO, decisão dele: paciente fixo é
--    marcado de novo a cada semana. Não existe recorrência aqui,
--    e é de propósito.
-- ------------------------------------------------------------
create table public.appointments (
  id          text        primary key,
  owner_id    uuid        not null references auth.users(id) on delete cascade,
  day_date    date        not null,
  time_of_day text        not null default '',   -- "HH:MM" ou vazio
  name        text        not null default '',   -- quem é atendido
  kind        text        not null default '',   -- tipo de sessão, texto livre
  note        text        not null default '',
  done        boolean     not null default false,-- já atendido
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index appointments_owner_day_idx on public.appointments (owner_id, day_date);


-- ------------------------------------------------------------
-- 2. agenda_shares — quem mais enxerga a agenda de alguém
--    can_edit false = só olha.
-- ------------------------------------------------------------
create table public.agenda_shares (
  owner_id   uuid        not null references auth.users(id) on delete cascade,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  can_edit   boolean     not null default false,
  created_at timestamptz not null default now(),
  primary key (owner_id, user_id)
);

create index agenda_shares_user_idx on public.agenda_shares (user_id);


-- ============================================================
--  As duas perguntas da segurança
--
--  Aqui não existe o risco de recursão que houve nas listas: a
--  regra de agenda_shares não consulta appointments. Mesmo
--  assim as perguntas ficam em função, para a regra ser uma
--  frase só e mudar num lugar só.
-- ============================================================

create or replace function public.agenda_visivel(dono uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select dono = (select auth.uid())
      or exists (
        select 1 from public.agenda_shares s
        where s.owner_id = dono and s.user_id = (select auth.uid())
      );
$fn$;

create or replace function public.agenda_editavel(dono uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select dono = (select auth.uid())
      or exists (
        select 1 from public.agenda_shares s
        where s.owner_id = dono and s.user_id = (select auth.uid()) and s.can_edit
      );
$fn$;

grant execute on function public.agenda_visivel(uuid)  to authenticated;
grant execute on function public.agenda_editavel(uuid) to authenticated;


-- ============================================================
--  RLS
-- ============================================================

alter table public.appointments  enable row level security;
alter table public.agenda_shares enable row level security;

-- ---- appointments ----
create policy "ver atendimento" on public.appointments
  for select using ( public.agenda_visivel(owner_id) );

-- A secretária marca paciente NA AGENDA DELE: o dono da linha é
-- o dono da agenda, não quem digitou. Por isso a checagem é
-- "posso editar a agenda desse dono", e não "sou eu".
create policy "criar atendimento" on public.appointments
  for insert with check ( public.agenda_editavel(owner_id) );

create policy "alterar atendimento" on public.appointments
  for update using ( public.agenda_editavel(owner_id) )
              with check ( public.agenda_editavel(owner_id) );

create policy "excluir atendimento" on public.appointments
  for delete using ( public.agenda_editavel(owner_id) );

-- ---- agenda_shares ----
-- Sem função aqui de propósito: se a regra de agenda_shares
-- chamasse uma função que lê agenda_shares, uma chamaria a
-- outra para sempre.
create policy "ver convidados da agenda" on public.agenda_shares
  for select using (
    owner_id = (select auth.uid()) or user_id = (select auth.uid())
  );

-- Por decisão dele (28/08/2026): só o dono convida.
create policy "convidar na agenda" on public.agenda_shares
  for insert with check ( owner_id = (select auth.uid()) );

create policy "desconvidar da agenda" on public.agenda_shares
  for delete using (
    owner_id = (select auth.uid())     -- o dono tira quem quiser
    or user_id = (select auth.uid())   -- o convidado sai sozinho
  );


-- ============================================================
--  updated_at automático
-- ============================================================

create trigger appointments_touch before update on public.appointments
  for each row execute function public.touch_updated_at();


-- ============================================================
--  Tempo real — sem filtro por dono, pelo mesmo motivo das
--  listas: numa agenda compartilhada a linha é do OUTRO.
-- ============================================================

alter table public.appointments  replica identity full;
alter table public.agenda_shares replica identity full;

alter publication supabase_realtime add table public.appointments;
alter publication supabase_realtime add table public.agenda_shares;
