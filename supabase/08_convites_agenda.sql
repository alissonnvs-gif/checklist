-- ============================================================
--  Checklist — convite da AGENDA por código de 6 dígitos
--  Rodar UMA vez, no SQL Editor, depois do 06_agenda.sql.
--
--  Decisão dele (28/08/2026): o convite é um NÚMERO DE 6 DÍGITOS
--  DE USO ÚNICO. Usou, morre; para convidar outra pessoa, gera
--  outro. Nada de link de WhatsApp e nada de convite por e-mail.
--
--  ⚠️ Ainda não existe tela para isto. Este arquivo é só o banco.
-- ============================================================


-- ------------------------------------------------------------
--  Por que existe prazo de validade
--
--  Seis dígitos são um milhão de combinações — parece muito, mas
--  um programa tentando códigos aleatórios acerta um dia. As
--  três defesas juntas é que resolvem:
--    1. o código morre ao ser usado
--    2. o código expira em 30 minutos
--    3. cada pessoa só tem UM convite ativo por vez (gerar um
--       novo apaga o anterior)
--  Com isso, a qualquer instante existe um punhado de códigos
--  válidos no sistema inteiro, e chutar vira perda de tempo.
-- ------------------------------------------------------------
create table public.agenda_invites (
  code       text        primary key,
  owner_id   uuid        not null references auth.users(id) on delete cascade,
  can_edit   boolean     not null default false,
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    uuid        references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index agenda_invites_owner_idx on public.agenda_invites (owner_id);

alter table public.agenda_invites enable row level security;

-- Só o dono enxerga os próprios convites. Quem RECEBE o código nunca
-- lê esta tabela: quem confere o código é a função lá embaixo, que roda
-- por fora do RLS. Sem isso, para conferir um código o convidado
-- precisaria poder ler os convites dos outros — exatamente o que não pode.
create policy "meus convites" on public.agenda_invites
  for select using ( owner_id = (select auth.uid()) );

create policy "apagar meus convites" on public.agenda_invites
  for delete using ( owner_id = (select auth.uid()) );


-- ------------------------------------------------------------
--  Gerar um convite
--  Devolve o código pronto. Apaga o convite anterior não usado do
--  mesmo dono: um convite ativo por vez, por pessoa.
-- ------------------------------------------------------------
create or replace function public.criar_convite_agenda(pode_editar boolean)
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

  delete from public.agenda_invites
   where owner_id = eu and used_at is null;

  loop
    tentei := tentei + 1;
    codigo := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.agenda_invites where code = codigo);
    -- Colisão com um código ainda vivo é raríssima, mas um laço sem saída
    -- seria pior que o problema: desiste e deixa a tela pedir de novo.
    if tentei > 20 then
      return json_build_object('ok', false, 'erro', 'tente de novo');
    end if;
  end loop;

  insert into public.agenda_invites (code, owner_id, can_edit, expires_at)
  values (codigo, eu, coalesce(pode_editar, false), now() + interval '30 minutes');

  return json_build_object(
    'ok', true,
    'codigo', codigo,
    'pode_editar', coalesce(pode_editar, false),
    'expira_em', (now() + interval '30 minutes')
  );
end;
$fn$;


-- ------------------------------------------------------------
--  Usar um convite
--  É por aqui que o convidado entra. A função roda por fora do
--  RLS de propósito: é o único jeito de conferir um código sem
--  dar a ninguém o direito de ler os convites alheios.
-- ------------------------------------------------------------
create or replace function public.usar_convite_agenda(codigo text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  eu uuid := (select auth.uid());
  cv public.agenda_invites%rowtype;
begin
  if eu is null then
    return json_build_object('ok', false, 'erro', 'nao logado');
  end if;

  select * into cv
    from public.agenda_invites
   where code = codigo
     and used_at is null
     and expires_at > now();

  -- Mensagem única para código errado, já usado e vencido, de propósito:
  -- distinguir os três contaria a quem está chutando que o número existe.
  if not found then
    return json_build_object('ok', false, 'erro', 'invalido');
  end if;

  if cv.owner_id = eu then
    return json_build_object('ok', false, 'erro', 'proprio');
  end if;

  insert into public.agenda_shares (owner_id, user_id, can_edit)
  values (cv.owner_id, eu, cv.can_edit)
  on conflict (owner_id, user_id) do update set can_edit = excluded.can_edit;

  update public.agenda_invites
     set used_at = now(), used_by = eu
   where code = cv.code;

  return json_build_object('ok', true, 'pode_editar', cv.can_edit);
end;
$fn$;


-- ------------------------------------------------------------
--  Quem tem acesso à minha agenda / de quem eu tenho acesso
--
--  Precisam ser funções porque o nome da pessoa mora em profiles,
--  e o RLS de profiles só deixa cada um ler a própria linha — o
--  que é certo. Estas duas devolvem SÓ o nome, e só de quem já
--  está ligado a você por um convite aceito.
-- ------------------------------------------------------------
create or replace function public.convidados_da_agenda()
returns table (user_id uuid, nome text, can_edit boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select s.user_id, coalesce(nullif(p.display_name, ''), 'Sem nome'), s.can_edit
    from public.agenda_shares s
    left join public.profiles p on p.id = s.user_id
   where s.owner_id = (select auth.uid());
$fn$;

create or replace function public.agendas_comigo()
returns table (owner_id uuid, nome text, can_edit boolean)
language sql
stable
security definer
set search_path = public
as $fn$
  select s.owner_id, coalesce(nullif(p.display_name, ''), 'Sem nome'), s.can_edit
    from public.agenda_shares s
    left join public.profiles p on p.id = s.owner_id
   where s.user_id = (select auth.uid());
$fn$;


grant execute on function public.criar_convite_agenda(boolean) to authenticated;
grant execute on function public.usar_convite_agenda(text)     to authenticated;
grant execute on function public.convidados_da_agenda()        to authenticated;
grant execute on function public.agendas_comigo()              to authenticated;

-- Ninguém anônimo chama nada disso.
revoke execute on function public.criar_convite_agenda(boolean) from anon;
revoke execute on function public.usar_convite_agenda(text)     from anon;
revoke execute on function public.convidados_da_agenda()        from anon;
revoke execute on function public.agendas_comigo()              from anon;


-- ------------------------------------------------------------
--  Faxina: convite vencido não usado não precisa ficar guardado.
--  Roda junto do agendamento que já existe, de hora em hora.
-- ------------------------------------------------------------
select cron.schedule(
  'checklist-convites-vencidos',
  '7 * * * *',
  $cron$
  delete from public.agenda_invites
   where used_at is null and expires_at < now() - interval '1 day';
  $cron$
);
