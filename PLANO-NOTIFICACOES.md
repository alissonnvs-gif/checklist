# Plano — Notificações no celular

Última atualização: 2026-08-07

Objetivo: o celular avisar sozinho, mesmo com o app fechado.

Três tipos de aviso:
1. **Resumo diário** num horário escolhido — "você tem N tarefas hoje".
2. **1 hora antes** de uma tarefa que tenha horário marcado.
3. **30 minutos antes** da mesma tarefa.

Decisões já tomadas:
- Os avisos vão **só para o celular**, nunca para o computador.
- Uma implementação só atende **Android e iPhone** (iOS 16.4+, com o app
  instalado na Tela de Início).
- Quem dispara é uma **função agendada dentro do Supabase**. A Vercel foi
  descartada: no plano gratuito ela roda tarefa agendada só uma vez por dia,
  o que inviabiliza o aviso de 30 minutos antes.

---

## Passo 1 — Onde guardar o aparelho e suas preferências

**Eu faço:** escrever o SQL com três coisas.
- `push_subscriptions` — o "endereço" de cada celular que aceitou receber aviso.
- Preferências no seu perfil — horário do resumo, quais avisos ligados, e o
  seu fuso horário.
- `push_sent` — registro do que já foi enviado. Sem isso, uma verificação a
  cada 5 minutos mandaria o mesmo aviso doze vezes por hora.

**Você faz:** colar no SQL Editor e rodar. Uma vez só.
Arquivo: `supabase/03_notificacoes.sql`

- [ ] **VOCÊ ESTÁ AQUI** — SQL escrito, esperando você rodar

---

## Passo 2 — As chaves de envio

Todo serviço de notificação exige um par de chaves que prova que o aviso
partiu mesmo de você, e não de um estranho.

**Eu faço:** gerar o par aqui na sua máquina. A pública vai dentro do app;
a privada nunca sai do servidor.

**Você faz:** colar a chave privada em Supabase → Edge Functions → Secrets,
com o nome `VAPID_PRIVATE_KEY`. Ela é sua e fica só aí.

- [x] Chaves geradas em `D:\PROJETOS\CLAUDE\checklist-chaves-vapid.txt`
      (fora do repositório, de propósito)
- [ ] Você colar a privada no painel

---

## Passo 3 — O app pedir permissão

**Eu faço:** um bloco "Notificações" dentro da engrenagem, com:
- No Android: botão "Ativar notificações", direto.
- No iPhone ainda não instalado: a instrução de adicionar à Tela de Início
  antes, em vez de um botão que não funcionaria.
- No iPhone instalado: botão normal.
- Em celular velho demais: aviso honesto de que não dá.

E as preferências: horário do resumo, e chaves de ligar/desligar para o
resumo, o aviso de 1 hora e o de 30 minutos.

**Você faz:** nada. Depois testa.

- [x] Escrito — falta testar (depende do passo 1 estar rodado)

---

## Passo 4 — O app saber mostrar o aviso

**Eu faço:** ensinar o `sw.js` (a parte do app que continua viva com ele
fechado) a receber o aviso e mostrar na tela, e a abrir o app no lugar certo
quando você tocar na notificação.

**Você faz:** nada.

- [x] Escrito (`sw.js`, cache subido para v7)

---

## Passo 5 — A função que dispara

O coração da coisa. A cada poucos minutos ela acorda e pergunta: tem alguém
para avisar agora?

**Eu faço:** escrever a função. Ela lê suas tarefas e horários, converte para
o horário de Brasília, decide o que está na hora, envia, e anota o que enviou
para não repetir.

**Você faz:** criar a função no painel (Edge Functions), colar o código e
publicar. Arquivo: `supabase/functions/avisos/index.ts`

- [x] Escrita
- [ ] Você publicar no painel

---

## Passo 6 — O agendamento

**Eu faço:** escrever o SQL que manda o banco chamar a função a cada 5
minutos. É isso que faz o aviso chegar mesmo com o celular guardado no bolso
e o app fechado.

**Você faz:** colar e rodar. Arquivo: `supabase/04_agendamento.sql`.
Ele tem um lugar para colar a chave `service_role` — preencha na hora,
não salve preenchido, e não mande essa chave para ninguém.

- [x] Escrito
- [ ] Você rodar

---

## Passo 7 — Teste de verdade, no seu Samsung

**Nós dois:** você ativa no celular, eu forço um aviso pelo servidor, e a
gente confirma que chegou. Depois um teste com horário real, para ver o
"1 hora antes" chegando sozinho.

- [ ] Concluído

---

## A armadilha que mais pode dar errado

**Fuso horário.** O servidor pensa em UTC; seus horários são de Brasília —
três horas de diferença. Um erro aqui faz o resumo das 7h chegar às 4h ou às
10h. Por isso o fuso é guardado junto com as preferências e a conversão
acontece num lugar só, e por isso o teste do passo 7 inclui um horário real,
não só um disparo forçado.

## Onde parar sem prejuízo

Cada passo termina num estado consistente. Se a sessão acabar no meio, os
passos concluídos continuam valendo e nada quebra no app que já está no ar —
até o passo 4 estar pronto, nada de novo aparece para você; a partir do 5,
começa a funcionar de verdade.
