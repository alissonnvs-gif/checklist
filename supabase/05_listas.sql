-- ============================================================
--  Checklist — Listas (a "terceira faceta")
--  Rodar UMA vez, no SQL Editor do projeto, depois dos anteriores.
--
--  Estas tabelas já nascem com o conceito de CONVIDADO, mesmo que
--  a tela de compartilhar só chegue depois. O motivo é o custo:
--  nascer com dono único e emendar convidado depois obrigaria a
--  reescrever a regra de segurança em cima de dados reais, que é
--  exatamente a parte perigosa. Aqui a regra já é a definitiva.
-- ============================================================


-- ------------------------------------------------------------
-- 1. lists — a lista em si ("Mercado", "Farmácia")
--    O id é texto porque quem inventa o id é o app, antes de
--    falar com o servidor — é o que permite criar uma lista sem
--    internet e ela subir depois com o mesmo id.
-- ------------------------------------------------------------
create table public.lists (
  id         text        primary key,
  owner_id   uuid        not null references auth.users(id) on delete cascade,
  title      text        not null default 'Nova lista',
  sort_order int         not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index lists_owner_idx on public.lists (owner_id);


-- ------------------------------------------------------------
-- 2. list_items — os itens
--    qty é TEXTO de propósito: "2 kg", "meia dúzia", "3" e ""
--    são todos respostas válidas do usuário. Número obrigaria a
--    escolher unidade, e não é isso que ele pediu.
-- ------------------------------------------------------------
create table public.list_items (
  id         text        primary key,
  list_id    text        not null references public.lists(id) on delete cascade,
  qty        text        not null default '',
  name       text        not null default '',
  done       boolean     not null default false,
  sort_order int         not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index list_items_list_idx on public.list_items (list_id);


-- ------------------------------------------------------------
-- 3. list_shares — quem mais enxerga esta lista
--    Uma linha por convidado. can_edit false = só olha.
--    Ainda não tem tela; a tabela existe para a regra abaixo já
--    ser a definitiva.
-- ------------------------------------------------------------
create table public.list_shares (
  list_id    text        not null references public.lists(id) on delete cascade,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  can_edit   boolean     not null default false,
  created_at timestamptz not null default now(),
  primary key (list_id, user_id)
);

create index list_shares_user_idx on public.list_shares (user_id);


-- ============================================================
--  As duas perguntas que a segurança faz
--
--  Estão em função separada por um motivo técnico com nome:
--  recursão infinita. A regra de lists precisa consultar
--  list_shares, e a regra de list_shares precisa consultar
--  lists — uma chamaria a outra pra sempre. "security definer"
--  faz a consulta rodar por fora do RLS e corta o laço.
-- ============================================================

create or replace function public.lista_visivel(lid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.lists l
    where l.id = lid and l.owner_id = (select auth.uid())
  ) or exists (
    select 1 from public.list_shares s
    where s.list_id = lid and s.user_id = (select auth.uid())
  );
$fn$;

create or replace function public.lista_editavel(lid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1 from public.lists l
    where l.id = lid and l.owner_id = (select auth.uid())
  ) or exists (
    select 1 from public.list_shares s
    where s.list_id = lid and s.user_id = (select auth.uid()) and s.can_edit
  );
$fn$;

grant execute on function public.lista_visivel(text)  to authenticated;
grant execute on function public.lista_editavel(text) to authenticated;


-- ============================================================
--  RLS
-- ============================================================

alter table public.lists       enable row level security;
alter table public.list_items  enable row level security;
alter table public.list_shares enable row level security;

-- ---- lists ----
create policy "ver lista" on public.lists
  for select using ( public.lista_visivel(id) );

-- Criar lista é sempre em nome próprio: ninguém cria lista no nome de outro.
create policy "criar lista" on public.lists
  for insert with check ( owner_id = (select auth.uid()) );

-- Renomear pode quem edita; o convidado só-leitura não passa aqui.
create policy "renomear lista" on public.lists
  for update using ( public.lista_editavel(id) )
              with check ( public.lista_editavel(id) );

-- Excluir a lista inteira é só do dono, mesmo que o convidado edite.
create policy "excluir lista" on public.lists
  for delete using ( owner_id = (select auth.uid()) );

-- ---- list_items ----
create policy "ver itens" on public.list_items
  for select using ( public.lista_visivel(list_id) );

create policy "criar item" on public.list_items
  for insert with check ( public.lista_editavel(list_id) );

create policy "alterar item" on public.list_items
  for update using ( public.lista_editavel(list_id) )
              with check ( public.lista_editavel(list_id) );

create policy "excluir item" on public.list_items
  for delete using ( public.lista_editavel(list_id) );

-- ---- list_shares ----
-- Quem participa da lista enxerga quem mais participa.
create policy "ver convidados" on public.list_shares
  for select using ( public.lista_visivel(list_id) );

-- Por decisão do Alisson (28/08/2026): SÓ O DONO convida e desconvida.
-- Se um dia virar "quem edita também convida", é aqui que muda.
create policy "convidar" on public.list_shares
  for insert with check (
    exists (select 1 from public.lists l where l.id = list_id and l.owner_id = (select auth.uid()))
  );

create policy "desconvidar" on public.list_shares
  for delete using (
    exists (select 1 from public.lists l where l.id = list_id and l.owner_id = (select auth.uid()))
    or user_id = (select auth.uid())   -- o convidado pode sair sozinho
  );


-- ============================================================
--  Limite de listas por pessoa
--
--  O app também segura isso na tela, mas a regra de verdade
--  mora aqui: tela pode ter bug, banco não deixa passar.
--  Para mudar o limite, altere o número abaixo e rode de novo
--  só a função (create or replace).
-- ============================================================

create or replace function public.limite_de_listas()
returns trigger
language plpgsql
as $fn$
declare
  quantas int;
  teto    int := 5;
begin
  select count(*) into quantas from public.lists where owner_id = new.owner_id;
  if quantas >= teto then
    raise exception 'Você chegou ao limite de % listas. Exclua uma para criar outra.', teto
      using errcode = 'P0001';
  end if;
  return new;
end;
$fn$;

create trigger lists_limite
  before insert on public.lists
  for each row execute function public.limite_de_listas();


-- ============================================================
--  updated_at automático (mesma função dos outros)
-- ============================================================

create trigger lists_touch      before update on public.lists
  for each row execute function public.touch_updated_at();
create trigger list_items_touch before update on public.list_items
  for each row execute function public.touch_updated_at();


-- ============================================================
--  Tempo real
--  Sem filtro por dono de propósito: numa lista compartilhada o
--  item pertence à lista do OUTRO, e um filtro por dono deixaria
--  o convidado sem receber aviso nenhum. Quem decide o que cada
--  um recebe é o RLS acima, linha por linha.
-- ============================================================

alter table public.lists       replica identity full;
alter table public.list_items  replica identity full;
alter table public.list_shares replica identity full;

alter publication supabase_realtime add table public.lists;
alter publication supabase_realtime add table public.list_items;
alter publication supabase_realtime add table public.list_shares;
