// ============================================================
//  Checklist — a função que manda os avisos
//
//  Acorda de 5 em 5 minutos (chamada pelo agendamento do passo 6) e
//  pergunta: tem alguém para avisar agora?
//
//  Quatro avisos possíveis:
//    - resumo do dia, no horário que a pessoa escolheu
//    - resumo da AGENDA do dia, no MESMO horário, como aviso
//      separado (dois alertas, não um com as duas coisas dentro)
//    - 1 hora antes de uma tarefa com horário
//    - 30 minutos antes da mesma tarefa
//
//  Roda com a chave de administrador, então enxerga todas as contas.
//  É por isso que ela NUNCA deve receber dado vindo do app: ela só lê o
//  banco e envia.
// ============================================================

import webpush from "npm:web-push@3.6.7";
import { createClient } from "jsr:@supabase/supabase-js@2";

const VAPID_PUBLICA = "BKVu_U7VAoHVPnkS0dwSwcDCgFxgZ_Jp795Kscb-Dz_iRIdylRAUhtJubSJynVvOvbyHVoCB4H1dlrCf1MVBJwg";
const VAPID_PRIVADA = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const ASSUNTO = "mailto:alisson.nvs@gmail.com";

// Senha combinada com o agendamento. A verificação de token do painel fica
// desligada (ela exige chave no formato antigo, que este projeto não usa),
// então a porta é esta. Sem ela, qualquer um na internet conseguiria pedir
// um disparo de teste para o celular de qualquer usuário.
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

webpush.setVapidDetails(ASSUNTO, VAPID_PUBLICA, VAPID_PRIVADA);

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// O agendamento roda a cada 5 minutos. A janela é de 6 para tolerar um
// atraso de alguns segundos sem nunca deixar um horário passar em branco;
// o registro em push_sent garante que a sobreposição não vire aviso dobrado.
const JANELA_MIN = 6;
// O resumo do dia aceita atraso maior: se o servidor engasgar às 7h, ainda
// vale mandar às 7h20. Depois disso, não faz mais sentido.
const JANELA_RESUMO_MIN = 30;

/* ---------- tempo, que é onde mora o perigo ---------- */

// O servidor pensa em UTC. Tudo aqui converte para o fuso da pessoa antes
// de comparar qualquer horário.
function agoraLocal(tz: string, instante: Date) {
  let partes: Record<string, string> = {};
  try {
    const f = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", hour12: false,
    });
    for (const p of f.formatToParts(instante)) partes[p.type] = p.value;
  } catch {
    return agoraLocal("America/Sao_Paulo", instante);
  }
  const data = `${partes.year}-${partes.month}-${partes.day}`;
  const hora = partes.hour === "24" ? "00" : partes.hour;
  return {
    data,
    minutos: parseInt(hora, 10) * 60 + parseInt(partes.minute, 10),
    diaSemana: new Date(`${data}T12:00:00Z`).getUTCDay(),
  };
}

function segundaDe(dataISO: string) {
  const d = new Date(`${dataISO}T12:00:00Z`);
  const wd = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() + ((wd === 0 ? -6 : 1) - wd));
  return d.toISOString().slice(0, 10);
}

function emMinutos(hhmm: string) {
  const [h, m] = (hhmm || "").split(":").map(Number);
  if (isNaN(h) || isNaN(m)) return null;
  return h * 60 + m;
}

/* ---------- envio ---------- */

async function enviar(insc: any, corpo: unknown) {
  try {
    await webpush.sendNotification(
      { endpoint: insc.endpoint, keys: { p256dh: insc.p256dh, auth: insc.auth } },
      JSON.stringify(corpo),
    );
    return true;
  } catch (e: any) {
    // 404/410 = o aparelho sumiu de vez (app desinstalado, permissão
    // revogada). Limpa em vez de tentar de novo para sempre.
    if (e?.statusCode === 404 || e?.statusCode === 410) {
      await sb.from("push_subscriptions").delete().eq("endpoint", insc.endpoint);
    }
    console.error("falha ao enviar:", e?.statusCode, e?.body ?? e?.message);
    return false;
  }
}

/* ---------- rotina ---------- */

Deno.serve(async (req) => {
  // Porta de entrada: só quem sabe a senha combinada passa. Recusa também
  // quando o segredo não está configurado — melhor não funcionar do que
  // ficar aberta sem ninguém perceber.
  if (!CRON_SECRET || req.headers.get("x-checklist-cron") !== CRON_SECRET) {
    return new Response(JSON.stringify({ erro: "nao autorizado" }), {
      status: 401, headers: { "Content-Type": "application/json" },
    });
  }

  if (!VAPID_PRIVADA) {
    return new Response(
      JSON.stringify({ erro: "VAPID_PRIVATE_KEY nao configurada nos segredos" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  // Permite forçar um disparo de teste sem esperar horário nenhum.
  let teste = false;
  try {
    const corpo = await req.json();
    teste = corpo?.teste === true;
  } catch { /* sem corpo, rotina normal */ }

  const instante = new Date();

  const { data: inscricoes, error: e1 } = await sb
    .from("push_subscriptions")
    .select("user_id,endpoint,p256dh,auth")
    .eq("device_kind", "celular");
  if (e1) throw e1;
  if (!inscricoes?.length) return resposta({ aparelhos: 0, enviados: 0 });

  const usuarios = [...new Set(inscricoes.map((i) => i.user_id))];

  const [perfis, tarefas, marcas, jaEnviados] = await Promise.all([
    // "*" em vez da lista de colunas de propósito: pedir uma coluna que ainda
    // não existe derruba a função inteira, e derrubar esta função significa
    // ninguém receber aviso nenhum. Com "*" ela funciona antes e depois de o
    // notif_agenda existir, e a ordem entre rodar o SQL e publicar a função
    // deixa de ser uma armadilha.
    sb.from("profiles").select("*").in("id", usuarios),
    sb.from("tasks")
      .select("user_id,id,kind,title,days,due_date,time_of_day,done")
      .in("user_id", usuarios),
    sb.from("task_checks")
      .select("user_id,task_id,week_monday,weekday")
      .in("user_id", usuarios),
    sb.from("push_sent").select("user_id,chave").in("user_id", usuarios),
  ]);
  for (const r of [perfis, tarefas, marcas, jaEnviados]) if (r.error) throw r.error;

  // Atendimentos da agenda. Consulta separada e que engole o próprio erro: se
  // a agenda ainda não existir neste banco, os avisos das tarefas continuam
  // saindo normalmente em vez de a função inteira parar.
  let atendimentos: any[] = [];
  {
    const dia = 86400000;
    const de = new Date(instante.getTime() - dia).toISOString().slice(0, 10);
    // Um dia para trás e um para frente porque o "hoje" de cada pessoa depende
    // do fuso dela, e o servidor pensa em UTC. O filtro exato por L.data
    // acontece lá embaixo, já dentro do fuso certo.
    const ate = new Date(instante.getTime() + dia).toISOString().slice(0, 10);
    const r = await sb
      .from("appointments")
      .select("owner_id,day_date,time_of_day,name,done")
      .in("owner_id", usuarios)
      .gte("day_date", de)
      .lte("day_date", ate);
    if (r.error) console.error("agenda indisponivel:", r.error.message);
    else atendimentos = r.data ?? [];
  }

  const enviadoAntes = new Set(
    (jaEnviados.data ?? []).map((r) => `${r.user_id}|${r.chave}`),
  );
  const marcado = new Set(
    (marcas.data ?? []).map((m) => `${m.user_id}|${m.task_id}|${m.week_monday}|${m.weekday}`),
  );

  const novasChaves: { user_id: string; chave: string }[] = [];
  let enviados = 0;

  for (const perfil of perfis.data ?? []) {
    const aparelhos = inscricoes.filter((i) => i.user_id === perfil.id);
    if (!aparelhos.length) continue;

    const L = agoraLocal(perfil.timezone || "America/Sao_Paulo", instante);
    const segunda = segundaDe(L.data);
    const minhas = (tarefas.data ?? []).filter((t) => t.user_id === perfil.id);

    // Tudo que cai no dia de hoje, já sabendo o que foi concluído.
    const hoje = minhas
      .filter((t) =>
        t.kind === "schedule"
          ? (t.days ?? []).includes(L.diaSemana)
          : t.due_date === L.data
      )
      .map((t) => ({
        ...t,
        feita: t.kind === "schedule"
          ? marcado.has(`${perfil.id}|${t.id}|${segunda}|${L.diaSemana}`)
          : !!t.done,
      }));

    const abertas = hoje.filter((t) => !t.feita);

    const pendente = (chave: string) =>
      !enviadoAntes.has(`${perfil.id}|${chave}`) &&
      !novasChaves.some((n) => n.user_id === perfil.id && n.chave === chave);

    const disparar = async (chave: string, titulo: string, corpo: string, tag: string) => {
      if (!pendente(chave)) return;
      let algumOk = false;
      for (const ap of aparelhos) {
        if (await enviar(ap, { titulo, corpo, tag })) algumOk = true;
      }
      if (algumOk) {
        novasChaves.push({ user_id: perfil.id, chave });
        enviados++;
      }
    };

    if (teste) {
      await disparar(
        `teste:${instante.toISOString()}`,
        "Checklist",
        abertas.length
          ? `Teste funcionando. Você tem ${abertas.length} ${abertas.length === 1 ? "tarefa aberta" : "tarefas abertas"} hoje.`
          : "Teste funcionando. Nada aberto para hoje.",
        "teste",
      );
      continue;
    }

    // 1. Resumo do dia
    const horaResumo = emMinutos(perfil.notif_resumo_hora || "07:00");
    if (
      perfil.notif_resumo && horaResumo !== null && abertas.length > 0 &&
      L.minutos >= horaResumo && L.minutos < horaResumo + JANELA_RESUMO_MIN
    ) {
      const nome = (perfil.display_name || "").trim();
      const comHora = abertas.filter((t) => t.time_of_day).length;
      await disparar(
        `resumo:${L.data}`,
        nome ? `Bom dia, ${nome}` : "Seu dia",
        `${abertas.length} ${abertas.length === 1 ? "tarefa" : "tarefas"} hoje` +
          (comHora ? `, ${comHora} com horário marcado.` : "."),
        `resumo-${L.data}`,
      );
    }

    // 1b. Resumo da AGENDA — mesmo horário do resumo das tarefas, aviso à
    //     parte. Interruptor próprio: quem desliga o resumo das tarefas pode
    //     querer continuar recebendo a agenda, e vice-versa. Como as tarefas,
    //     só sai se houver algo — ninguém precisa de um aviso para dizer que
    //     não tem ninguém marcado.
    const meusAtend = atendimentos
      .filter((a) => a.owner_id === perfil.id && a.day_date === L.data && !a.done)
      .sort((x, y) =>
        (x.time_of_day || "99:99") < (y.time_of_day || "99:99") ? -1 : 1
      );

    if (
      perfil.notif_agenda !== false && horaResumo !== null && meusAtend.length > 0 &&
      L.minutos >= horaResumo && L.minutos < horaResumo + JANELA_RESUMO_MIN
    ) {
      const primeiro = meusAtend.find((a) => a.time_of_day);
      await disparar(
        `agenda:${L.data}`,
        "Sua agenda hoje",
        `${meusAtend.length} ${meusAtend.length === 1 ? "atendimento" : "atendimentos"}` +
          (primeiro ? `, o primeiro às ${primeiro.time_of_day}.` : "."),
        // Tag diferente da do resumo das tarefas, senão um substituiria o
        // outro na barra de notificações e só um dos dois apareceria.
        `agenda-${L.data}`,
      );
    }

    // 2 e 3. Avisos antes de cada tarefa com horário
    for (const t of abertas) {
      const alvo = emMinutos(t.time_of_day);
      if (alvo === null) continue;

      const antecedencias: [number, boolean, string][] = [
        [60, !!perfil.notif_60, "1 hora"],
        [30, !!perfil.notif_30, "30 minutos"],
      ];

      for (const [min, ligado, texto] of antecedencias) {
        if (!ligado) continue;
        const quando = alvo - min;
        if (quando < 0) continue;
        if (L.minutos < quando || L.minutos >= quando + JANELA_MIN) continue;
        await disparar(
          `${min}:${t.id}:${L.data}`,
          `Em ${texto}`,
          `${t.title} — ${t.time_of_day}`,
          `t-${t.id}-${L.data}`,
        );
      }
    }
  }

  if (novasChaves.length) {
    const { error } = await sb.from("push_sent").insert(novasChaves);
    if (error) console.error("falha ao registrar envio:", error.message);
  }

  // Faxina: o registro só serve para não repetir dentro do dia.
  const corte = new Date(instante.getTime() - 14 * 86400000).toISOString();
  await sb.from("push_sent").delete().lt("enviado_em", corte);

  return resposta({ aparelhos: inscricoes.length, enviados, teste });
});

function resposta(dados: unknown) {
  return new Response(JSON.stringify(dados), {
    headers: { "Content-Type": "application/json" },
  });
}
