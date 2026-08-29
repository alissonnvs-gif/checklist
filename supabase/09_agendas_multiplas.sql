-- ============================================================
--  Checklist — VÁRIAS agendas por pessoa
--  Rodar UMA vez, no SQL Editor, depois do 08_convites_agenda.sql.
--
--  O que muda e por quê
--  --------------------
--  A Agenda nasceu como UMA por pessoa: o atendimento apontava
--  direto para o dono, e compartilhar era compartilhar "a agenda
--  do fulano". Ele pediu VÁRIAS (uma por negócio/finalidade), e
--  pediu que o convite seja DE CADA AGENDA — a secretária entra
--  na "Atendimentos" sem enxergar a pessoal.
--
--  Isso não é ajuste: é trocar o alicerce. Por isso este arquivo
--  MIGRA em vez de recriar — os atendimentos que já existem vão
--  todos para uma agenda chamada "Atendimentos", e nada se perde.
--
--  ⚠️ Rode o arquivo INTEIRO de uma vez. Ele mexe em tabela viva.
-- ============================================================


-- ------------------------------------------------------------
-- 1. A agenda em si
-- ------------------------------------------------------------
create table public.agendas (
  id         text        primary key,
  owner_id   uuid        not null references auth.users(id) on delete cascade,
  title      text        not null default 'Nova agenda',
  sort_order int         not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index agendas_owner_idx on public.agendas (owner_id);


-- ------------------------------------------------------------
-- 2. Quem já tem atendimento ganha a agenda "Atendimentos"
--    O id é derivado do id da pessoa para ser previsível: o
--    passo 3 precisa reencontrá-lo sem tabela auxiliar.
-- ------------------------------------------------------------
insert into public.agendas (id, owner_id, title, sort_order)
select 'g' || replace(d.owner_id::text, '-', ''), d.owner_id, 'Atendimentos', 0
  from (select distinct owner_id from public.appointments) d
on conflict (id) do nothing;


-- ------------------------------------------------------------
-- 3. O atendimento passa a pertencer a uma agenda
--    owner_id CONTINUA na linha de propósito: a função que manda
--    os avisos filtra por dono, e um join a mais lá dentro seria
--    custo sem ganho.
-- ------------------------------------------------------------
alter table public.appointments
  add column agenda_id text references public.agendas(id) on delete cascade;

update public.appointments
   set agenda_id = 'g' || replace(owner_id::text, '-', '')
 where agenda_id is null;

-- Se sobrou algum sem agenda, foi porque não tinha dono válido —
-- não deveria existir. Some antes de virar linha órfã eterna.
delete from public.appointments where agenda_id is null;

alter table public.appointments alter column agenda_id set not null;

create index appointments_agenda_day_idx on public.appointments (agenda_id, day_date);


-- ------------------------------------------------------------
-- 4. O convite passa a ser DE UMA AGENDA
-- ------------------------------------------------------------

-- 4a. as regras antigas apontam para as funções antigas: saem primeiro
drop policy if exists "ver atendimento"       on public.appointments;
drop policy if exists "criar atendimento"     on public.appointments;
drop policy if exists "alterar atendimento"   on public.appointments;
drop policy if exists "excluir atendimento"   on public.appointments;
drop policy if exists "ver convidados da agenda" on public.agenda_shares;
drop policy if exists "convidar na agenda"       on public.agenda_shares;
drop policy if exists "desconvidar da agenda"    on public.agenda_shares;

drop function if exists public.agenda_visivel(uuid);
drop function if exists public.agenda_editavel(uuid);

-- 4b. agenda_shares troca de chave: era (dono, convidado), vira
--     (agenda, convidado). Os convites que já existiam viram um
--     convite para CADA agenda daquele dono — hoje, no máximo uma.
alter table public.agenda_shares rename to agenda_shares_antiga;

-- Renomear a TABELA não renomeia os índices dela: os nomes antigos continuam
-- ocupados no schema e derrubam a criação da tabela nova com
-- "42P07: relation already exists". Por isso os índices vão junto.
alter index if exists public.agenda_shares_user_idx rename to agenda_shares_antiga_user_idx;
alter index if exists public.agenda_shares_pkey     rename to agenda_shares_antiga_pkey;

create table public.agenda_shares (
  agenda_id  text        not null references public.agendas(id) on delete cascade,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  can_edit   boolean     not null default false,
  created_at timestamptz not null default now(),
  primary key (agenda_id, user_id)
);

create index agenda_shares_user_idx on public.agenda_shares (user_id);

insert into public.agenda_shares (agenda_id, user_id, can_edit, created_at)
select a.id, v.user_id, v.can_edit, v.created_at
  from public.agenda_shares_antiga v
  join public.agendas a on a.owner_id = v.owner_id
on conflict do nothing;

drop table public.agenda_shares_antiga;

-- 4c. o convite carrega a agenda
alter table public.agenda_invites
  add column agenda_id text references public.agendas(id) on delete cascade;

-- Convite pendente da regra antiga não tem como saber de qual agenda era.
-- São de uso único e valem 30 minutos: apagar é mais honesto que adivinhar.
delete from public.agenda_invites where agenda_id is null;

alter table public.agenda_invites alter column agenda_id set not null;


-- ------------------------------------------------------------
-- 5. As perguntas da segurança, agora por AGENDA
-- ------------------------------------------------------------
create or replace function public.agenda_visivel(ag text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.agendas a
     where a.id = ag and a.owner_id = (select auth.uid())
  ) or exists (
    select 1 from public.agenda_shares s
     where s.agenda_id = ag and s.user_id = (select auth.uid())
  );
$fn$;

create or replace function public.agenda_editavel(ag text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.agendas a
     where a.id = ag and a.owner_id = (select auth.uid())
  ) or exists (
    select 1 from public.agenda_shares s
     where s.agenda_id = ag and s.user_id = (select auth.uid()) and s.can_edit
  );
$fn$;

grant execute on function public.agenda_visivel(text)  to authenticated;
grant execute on function public.agenda_editavel(text) to authenticated;


-- ------------------------------------------------------------
-- 6. RLS
-- ------------------------------------------------------------
alter table public.agendas       enable row level security;
alter table public.agenda_shares enable row level security;

-- ---- agendas ----
create policy "ver agenda" on public.agendas
  for select using ( public.agenda_visivel(id) );

create policy "criar agenda" on public.agendas
  for insert with check ( owner_id = (select auth.uid()) );

create policy "renomear agenda" on public.agendas
  for update using ( owner_id = (select auth.uid()) )
              with check ( owner_id = (select auth.uid()) );

create policy "excluir agenda" on public.agendas
  for delete using ( owner_id = (select auth.uid()) );

-- ---- appointments ----
-- A secretária cria linha NA AGENDA DELE: a pergunta é "posso editar esta
-- agenda", não "sou eu o dono".
create policy "ver atendimento" on public.appointments
  for select using ( public.agenda_visivel(agenda_id) );

create policy "criar atendimento" on public.appointments
  for insert with check ( public.agenda_editavel(agenda_id) );

create policy "alterar atendimento" on public.appointments
  for update using ( public.agenda_editavel(agenda_id) )
              with check ( public.agenda_editavel(agenda_id) );

create policy "excluir atendimento" on public.appointments
  for delete using ( public.agenda_editavel(agenda_id) );

-- ---- agenda_shares ----
-- Sem função aqui: uma regra de agenda_shares que chamasse uma função
-- que lê agenda_shares chamaria a si mesma para sempre.
create policy "ver convidados da agenda" on public.agenda_shares
  for select using (
    user_id = (select auth.uid())
    or exists (select 1 from public.agendas a
                where a.id = agenda_id and a.owner_id = (select auth.uid()))
  );

create policy "convidar na agenda" on public.agenda_shares
  for insert with check (
    exists (select 1 from public.agendas a
             where a.id = agenda_id and a.owner_id = (select auth.uid()))
  );

create policy "desconvidar da agenda" on public.agenda_shares
  for delete using (
    exists (select 1 from public.agendas a
             where a.id = agenda_id and a.owner_id = (select auth.uid()))
    or user_id = (select auth.uid())   -- o convidado sai sozinho
  );


-- ------------------------------------------------------------
-- 7. Teto de agendas por pessoa
--    Escolha dele: 10. Para mudar, altere o número e rode de
--    novo só esta função — e mude LIMITE_AGENDAS no app junto.
-- ------------------------------------------------------------
create or replace function public.limite_de_agendas()
returns trigger
language plpgsql
as $fn$
declare
  quantas int;
  teto    int := 10;
begin
  select count(*) into quantas from public.agendas where owner_id = new.owner_id;
  if quantas >= teto then
    raise exception 'Você chegou ao limite de % agendas. Exclua uma para criar outra.', teto
      using errcode = 'P0001';
  end if;
  return new;
end;
$fn$;

create trigger agendas_limite
  before insert on public.agendas
  for each row execute function public.limite_de_agendas();

create trigger agendas_touch before update on public.agendas
  for each row execute function public.touch_updated_at();


-- ------------------------------------------------------------
-- 8. As funções do convite, agora por agenda
-- ------------------------------------------------------------
drop function if exists public.criar_convite_agenda(boolean);

create or replace function public.criar_convite_agenda(agenda text, pode_editar boolean)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu     uuid := (select auth.uid());
  codigo text;
  tentei int := 0;
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;

  -- Só o dono convida para a própria agenda.
  if not exists (select 1 from public.agendas a where a.id = agenda and a.owner_id = eu) then
    return json_build_object('ok', false, 'erro', 'nao e sua');
  end if;

  -- Um convite ativo por agenda: gerar um novo mata o anterior.
  delete from public.agenda_invites
   where agenda_id = agenda and used_at is null;

  loop
    tentei := tentei + 1;
    codigo := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.agenda_invites where code = codigo);
    if tentei > 20 then
      return json_build_object('ok', false, 'erro', 'tente de novo');
    end if;
  end loop;

  insert into public.agenda_invites (code, owner_id, agenda_id, can_edit, expires_at)
  values (codigo, eu, agenda, coalesce(pode_editar, false), now() + interval '30 minutes');

  return json_build_object(
    'ok', true, 'codigo', codigo,
    'pode_editar', coalesce(pode_editar, false)
  );
end;
$fn$;

create or replace function public.usar_convite_agenda(codigo text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu uuid := (select auth.uid());
  cv public.agenda_invites%rowtype;
  nome_agenda text;
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;

  select * into cv
    from public.agenda_invites
   where code = codigo and used_at is null and expires_at > now();

  -- Mensagem única para errado, usado e vencido: separar os três contaria a
  -- quem está chutando que o número existe.
  if not found then
    return json_build_object('ok', false, 'erro', 'invalido');
  end if;

  if cv.owner_id = eu then
    return json_build_object('ok', false, 'erro', 'proprio');
  end if;

  insert into public.agenda_shares (agenda_id, user_id, can_edit)
  values (cv.agenda_id, eu, cv.can_edit)
  on conflict (agenda_id, user_id) do update set can_edit = excluded.can_edit;

  update public.agenda_invites
     set used_at = now(), used_by = eu
   where code = cv.code;

  select a.title into nome_agenda from public.agendas a where a.id = cv.agenda_id;

  return json_build_object('ok', true, 'pode_editar', cv.can_edit, 'agenda', nome_agenda);
end;
$fn$;


-- ------------------------------------------------------------
-- 9. Quem tem acesso / de quem eu tenho acesso — por agenda
--    Continuam sendo funções porque o nome da pessoa mora em
--    profiles, e o RLS de profiles só deixa cada um ler a
--    própria linha. Devolvem só o nome, e só de quem já está
--    ligado a você por um convite aceito.
-- ------------------------------------------------------------
drop function if exists public.convidados_da_agenda();
drop function if exists public.agendas_comigo();

create or replace function public.convidados_da_agenda(agenda text)
returns table (user_id uuid, nome text, can_edit boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select s.user_id, coalesce(nullif(p.display_name, ''), 'Sem nome'), s.can_edit
    from public.agenda_shares s
    left join public.profiles p on p.id = s.user_id
   where s.agenda_id = agenda
     and exists (select 1 from public.agendas a
                  where a.id = agenda and a.owner_id = (select auth.uid()));
$fn$;

create or replace function public.agendas_comigo()
returns table (agenda_id text, titulo text, dono text, can_edit boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select s.agenda_id,
         a.title,
         coalesce(nullif(p.display_name, ''), 'Sem nome'),
         s.can_edit
    from public.agenda_shares s
    join public.agendas a on a.id = s.agenda_id
    left join public.profiles p on p.id = a.owner_id
   where s.user_id = (select auth.uid());
$fn$;

grant execute on function public.criar_convite_agenda(text, boolean) to authenticated;
grant execute on function public.convidados_da_agenda(text)          to authenticated;
grant execute on function public.agendas_comigo()                    to authenticated;

revoke execute on function public.criar_convite_agenda(text, boolean) from anon;
revoke execute on function public.convidados_da_agenda(text)          from anon;
revoke execute on function public.agendas_comigo()                    from anon;


-- ------------------------------------------------------------
-- 10. Tempo real da tabela nova
-- ------------------------------------------------------------
alter table public.agendas       replica identity full;
alter table public.agenda_shares replica identity full;

alter publication supabase_realtime add table public.agendas;
-- agenda_shares saiu e voltou como tabela nova; precisa entrar de novo.
alter publication supabase_realtime add table public.agenda_shares;
