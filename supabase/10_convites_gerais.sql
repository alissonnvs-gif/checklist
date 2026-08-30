-- ============================================================
--  Checklist — o convite passa a servir para LISTA e AGENDA
--  Rodar UMA vez, no SQL Editor, depois do 09.
--
--  Por que generalizar em vez de criar uma tabela de convites
--  para listas ao lado da de agendas:
--
--  Quem recebe seis dígitos por WhatsApp não sabe — e não tem
--  que saber — se aquilo é uma lista ou uma agenda. Com dois
--  sistemas paralelos, o app precisaria de dois campos "digite
--  o número", e errar o campo daria "número inválido" numa
--  situação em que o número está certo. Um sistema só resolve
--  isso na origem.
--
--  Os convites são de uso único e vivem 30 minutos, então
--  trocar a tabela não perde nada que importe.
-- ============================================================


-- ------------------------------------------------------------
-- 1. A tabela nova
-- ------------------------------------------------------------
create table public.convites (
  code       text        primary key,
  owner_id   uuid        not null references auth.users(id) on delete cascade,
  tipo       text        not null check (tipo in ('agenda', 'lista')),
  alvo_id    text        not null,   -- id da agenda ou da lista
  can_edit   boolean     not null default false,
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    uuid        references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index convites_owner_idx on public.convites (owner_id);
create index convites_alvo_idx  on public.convites (tipo, alvo_id);

alter table public.convites enable row level security;

-- Só o dono enxerga os próprios convites. Quem RECEBE o número nunca lê esta
-- tabela: quem confere é a função abaixo, que roda por fora do RLS. Sem isso,
-- conferir um número exigiria poder ler os convites dos outros.
create policy "meus convites" on public.convites
  for select using ( owner_id = (select auth.uid()) );

create policy "apagar meus convites" on public.convites
  for delete using ( owner_id = (select auth.uid()) );


-- ------------------------------------------------------------
-- 2. Gerar um convite (agenda ou lista)
--    Um convite ativo por alvo: gerar um novo mata o anterior.
-- ------------------------------------------------------------
create or replace function public.criar_convite(tipo text, alvo text, pode_editar boolean)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu     uuid := (select auth.uid());
  codigo text;
  tentei int := 0;
  meu    boolean;
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;

  if tipo not in ('agenda', 'lista') then
    return json_build_object('ok', false, 'erro', 'tipo invalido');
  end if;

  -- Só o dono convida para o que é dele.
  if tipo = 'agenda' then
    select exists (select 1 from public.agendas a where a.id = alvo and a.owner_id = eu) into meu;
  else
    select exists (select 1 from public.lists l where l.id = alvo and l.owner_id = eu) into meu;
  end if;

  if not meu then
    return json_build_object('ok', false, 'erro', 'nao e sua');
  end if;

  delete from public.convites
   where tipo = criar_convite.tipo and alvo_id = alvo and used_at is null;

  loop
    tentei := tentei + 1;
    codigo := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.convites c where c.code = codigo);
    if tentei > 20 then
      return json_build_object('ok', false, 'erro', 'tente de novo');
    end if;
  end loop;

  insert into public.convites (code, owner_id, tipo, alvo_id, can_edit, expires_at)
  values (codigo, eu, criar_convite.tipo, alvo, coalesce(pode_editar, false), now() + interval '30 minutes');

  return json_build_object('ok', true, 'codigo', codigo, 'pode_editar', coalesce(pode_editar, false));
end;
$fn$;


-- ------------------------------------------------------------
-- 3. Usar um convite — o app não precisa saber de que é
--    A resposta diz o tipo e o nome, para a tela avisar
--    "pronto, a lista Mercado apareceu".
-- ------------------------------------------------------------
create or replace function public.usar_convite(codigo text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu   uuid := (select auth.uid());
  cv   public.convites%rowtype;
  nome text;
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;

  select * into cv
    from public.convites c
   where c.code = codigo and c.used_at is null and c.expires_at > now();

  -- Mensagem única para errado, usado e vencido: separar os três contaria a
  -- quem está chutando que o número existe.
  if not found then
    return json_build_object('ok', false, 'erro', 'invalido');
  end if;

  if cv.owner_id = eu then
    return json_build_object('ok', false, 'erro', 'proprio');
  end if;

  if cv.tipo = 'agenda' then
    insert into public.agenda_shares (agenda_id, user_id, can_edit)
    values (cv.alvo_id, eu, cv.can_edit)
    on conflict (agenda_id, user_id) do update set can_edit = excluded.can_edit;
    select a.title into nome from public.agendas a where a.id = cv.alvo_id;
  else
    insert into public.list_shares (list_id, user_id, can_edit)
    values (cv.alvo_id, eu, cv.can_edit)
    on conflict (list_id, user_id) do update set can_edit = excluded.can_edit;
    select l.title into nome from public.lists l where l.id = cv.alvo_id;
  end if;

  update public.convites set used_at = now(), used_by = eu where code = cv.code;

  return json_build_object('ok', true, 'tipo', cv.tipo, 'nome', nome, 'pode_editar', cv.can_edit);
end;
$fn$;


-- ------------------------------------------------------------
-- 4. Quem tem acesso à minha lista / de quem eu tenho acesso
--    Funções pelo mesmo motivo das da agenda: o nome da pessoa
--    mora em profiles, e o RLS de profiles só deixa cada um ler
--    a própria linha — o que está certo.
-- ------------------------------------------------------------
create or replace function public.convidados_da_lista(lista text)
returns table (user_id uuid, nome text, can_edit boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select s.user_id, coalesce(nullif(p.display_name, ''), 'Sem nome'), s.can_edit
    from public.list_shares s
    left join public.profiles p on p.id = s.user_id
   where s.list_id = lista
     and exists (select 1 from public.lists l
                  where l.id = lista and l.owner_id = (select auth.uid()));
$fn$;

create or replace function public.listas_comigo()
returns table (list_id text, titulo text, dono text, can_edit boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select s.list_id,
         l.title,
         coalesce(nullif(p.display_name, ''), 'Sem nome'),
         s.can_edit
    from public.list_shares s
    join public.lists l on l.id = s.list_id
    left join public.profiles p on p.id = l.owner_id
   where s.user_id = (select auth.uid());
$fn$;


-- ------------------------------------------------------------
-- 5. As funções antigas da agenda viram atalhos para as novas
--    Um aparelho com a versão anterior do app guardada continua
--    funcionando enquanto não atualiza. Sem isso, quem abrisse
--    o app velho receberia "função não existe".
-- ------------------------------------------------------------
create or replace function public.criar_convite_agenda(agenda text, pode_editar boolean)
returns json
language sql
security definer
set search_path = public
as $fn$
  select public.criar_convite('agenda', agenda, pode_editar);
$fn$;

create or replace function public.usar_convite_agenda(codigo text)
returns json
language sql
security definer
set search_path = public
as $fn$
  select public.usar_convite(codigo);
$fn$;


-- ------------------------------------------------------------
-- 6. A tabela antiga sai, junto com a faxina dela
-- ------------------------------------------------------------
select cron.unschedule('checklist-convites-vencidos');
drop table if exists public.agenda_invites;

select cron.schedule(
  'checklist-convites-vencidos',
  '7 * * * *',
  $cron$
  delete from public.convites
   where used_at is null and expires_at < now() - interval '1 day';
  $cron$
);


grant execute on function public.criar_convite(text, text, boolean) to authenticated;
grant execute on function public.usar_convite(text)                 to authenticated;
grant execute on function public.convidados_da_lista(text)          to authenticated;
grant execute on function public.listas_comigo()                    to authenticated;

revoke execute on function public.criar_convite(text, text, boolean) from anon;
revoke execute on function public.usar_convite(text)                 from anon;
revoke execute on function public.convidados_da_lista(text)          from anon;
revoke execute on function public.listas_comigo()                    from anon;
