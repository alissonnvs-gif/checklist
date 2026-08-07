-- ============================================================
--  Checklist — passo 1 das notificações
--  Rodar UMA vez, no SQL Editor, depois do 01 e do 02.
-- ============================================================


-- ------------------------------------------------------------
-- 1. push_subscriptions — o "endereço" de cada aparelho
--
--    Quando você toca em "Ativar notificações", o navegador devolve
--    um endereço único e duas chaves. É para esse endereço que o
--    servidor manda o aviso. Cada aparelho gera o seu, então a mesma
--    conta pode ter vários — por isso a chave é a dupla conta+endereço.
--
--    device_kind existe para a regra que você escolheu: avisar só no
--    celular. Hoje o app nem oferece o botão no computador, então na
--    prática só entram celulares aqui; a coluna é o que permite mudar
--    de ideia depois sem remodelar nada.
-- ------------------------------------------------------------
create table public.push_subscriptions (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  endpoint    text        not null,
  p256dh      text        not null,
  auth        text        not null,
  device_kind text        not null default 'celular'
                          check (device_kind in ('celular', 'computador')),
  user_agent  text        not null default '',
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  primary key (user_id, endpoint)
);


-- ------------------------------------------------------------
-- 2. Preferências, junto do resto do seu perfil
--
--    timezone é a coluna mais importante daqui. O servidor pensa em
--    UTC e seus horários são de Brasília — três horas de diferença.
--    Sem guardar o fuso, o resumo das 7h chegaria às 4h.
-- ------------------------------------------------------------
alter table public.profiles
  add column notif_resumo      boolean not null default true,
  add column notif_resumo_hora text    not null default '07:00',
  add column notif_60          boolean not null default true,
  add column notif_30          boolean not null default true,
  add column timezone          text    not null default 'America/Sao_Paulo';


-- ------------------------------------------------------------
-- 3. push_sent — o que já foi enviado
--
--    A função acorda de 5 em 5 minutos. Sem este registro, o aviso
--    das 7h sairia doze vezes entre 7h e 8h. Cada aviso tem uma chave
--    única do tipo "resumo:2026-08-07" ou "60:<id da tarefa>:2026-08-07";
--    se a chave já está aqui, não manda de novo.
-- ------------------------------------------------------------
create table public.push_sent (
  user_id    uuid        not null references auth.users(id) on delete cascade,
  chave      text        not null,
  enviado_em timestamptz not null default now(),
  primary key (user_id, chave)
);

create index push_sent_limpeza_idx on public.push_sent (enviado_em);


-- ============================================================
--  RLS
-- ============================================================

alter table public.push_subscriptions enable row level security;
alter table public.push_sent          enable row level security;

-- O app precisa cadastrar e apagar o próprio aparelho.
create policy "dono do aparelho" on public.push_subscriptions
  for all
  using       ((select auth.uid()) = user_id)
  with check  ((select auth.uid()) = user_id);

-- push_sent fica com RLS ligado e NENHUMA regra, de propósito: isto é
-- registro interno do servidor e o app não tem o que fazer com ele.
-- Sem regra, ninguém logado enxerga nada — e a função agendada continua
-- funcionando porque roda com a chave de administrador, que passa por
-- cima do RLS. Não é esquecimento; é o mais seguro.
