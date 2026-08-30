-- ============================================================
--  Checklist — conserta criar_convite
--  Rodar UMA vez, no SQL Editor, depois do 10.
--
--  O defeito: o parâmetro da função se chama "tipo" e a tabela
--  convites TAMBÉM tem uma coluna "tipo". No DELETE, o banco não
--  sabia a qual dos dois o nome se referia e recusava a chamada
--  inteira com "column reference tipo is ambiguous" — por isso
--  gerar número dava erro.
--
--  Só isso muda: a tabela ganha um apelido (c) no DELETE, e cada
--  lado do "=" fica sem dúvida de quem é. O resto é igual.
-- ============================================================

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

  if criar_convite.tipo not in ('agenda', 'lista') then
    return json_build_object('ok', false, 'erro', 'tipo invalido');
  end if;

  -- Só o dono convida para o que é dele.
  if criar_convite.tipo = 'agenda' then
    select exists (select 1 from public.agendas a where a.id = alvo and a.owner_id = eu) into meu;
  else
    select exists (select 1 from public.lists l where l.id = alvo and l.owner_id = eu) into meu;
  end if;

  if not meu then
    return json_build_object('ok', false, 'erro', 'nao e sua');
  end if;

  -- Um convite ativo por alvo: gerar um novo mata o anterior.
  -- O apelido "c" é o conserto: sem ele, "tipo" ficava ambíguo.
  delete from public.convites c
   where c.tipo = criar_convite.tipo
     and c.alvo_id = criar_convite.alvo
     and c.used_at is null;

  loop
    tentei := tentei + 1;
    codigo := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.convites c2 where c2.code = codigo);
    if tentei > 20 then
      return json_build_object('ok', false, 'erro', 'tente de novo');
    end if;
  end loop;

  insert into public.convites (code, owner_id, tipo, alvo_id, can_edit, expires_at)
  values (codigo, eu, criar_convite.tipo, criar_convite.alvo,
          coalesce(criar_convite.pode_editar, false), now() + interval '30 minutes');

  return json_build_object('ok', true, 'codigo', codigo,
                           'pode_editar', coalesce(criar_convite.pode_editar, false));
end;
$fn$;

grant execute on function public.criar_convite(text, text, boolean) to authenticated;
revoke execute on function public.criar_convite(text, text, boolean) from anon;
