// Cumpre — função do servidor (Supabase Edge Function, nome: cumpre)
// Faz o que o browser não consegue fazer sozinho:
//   1. vai buscar o calendário da escola pelo link (o site da escola não deixa o browser lê-lo diretamente);
//   2. lê com IA (Claude) a foto do horário ou do quadro e devolve as aulas ou as tarefas para o aluno confirmar;
//   3. envia os lembretes para o telemóvel (chamada de 10 em 10 minutos pelo agendador do Supabase);
//   4. apaga a conta de um aluno quando ele pede, com tudo o que guardou.
// Tirando os lembretes (que trazem um segredo próprio), só aceita pedidos de alunos com sessão iniciada.
import { createClient } from 'npm:@supabase/supabase-js@2.110.9';

const cors: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(corpo: unknown, estado = 200) {
  return new Response(JSON.stringify(corpo), { status: estado, headers: { ...cors, 'Content-Type': 'application/json' } });
}

// A chave secreta é posta pelo próprio Supabase dentro da função: não há nada para copiar.
function chaveSecreta(): string {
  try {
    const novas = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}');
    const k = novas.default || Object.values(novas)[0];
    if (typeof k === 'string' && k) return k;
  } catch { /* projeto só com as chaves antigas */ }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
}

const admin = createClient(Deno.env.get('SUPABASE_URL')!, chaveSecreta(), {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Não deixa usar a função para chegar a endereços internos.
function linkSeguro(texto: string): URL | null {
  let u: URL;
  try {
    u = new URL(String(texto || '').trim().replace(/^webcals?:\/\//i, 'https://'));
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  const h = u.hostname.toLowerCase();
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h.endsWith('.supabase.co')) return null;
  if (/^(127\.|10\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(h) || h.includes(':')) return null;
  return u;
}

async function lerAte(resposta: Response, maximo: number): Promise<string | null> {
  const leitor = resposta.body?.getReader();
  if (!leitor) return '';
  const partes: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await leitor.read();
    if (done) break;
    total += value.length;
    if (total > maximo) {
      await leitor.cancel();
      return null;
    }
    partes.push(value);
  }
  const tudo = new Uint8Array(total);
  let i = 0;
  for (const p of partes) { tudo.set(p, i); i += p.length; }
  return new TextDecoder('utf-8').decode(tudo);
}

// ---------- Ler o horário de uma foto ----------
// Precisa do segredo ANTHROPIC_API_KEY (Edge Functions → Secrets). Opcional: CUMPRE_MODELO_IA, CUMPRE_LIMITE_IA.
const REGRAS_HORARIO = `Regras:
- dia: 1 = segunda, 2 = terça, 3 = quarta, 4 = quinta, 5 = sexta, 6 = sábado.
- inicio e fim no formato HH:MM (24 horas). Se a mesma disciplina ocupa vários tempos seguidos no mesmo dia, junta-os numa aula só, do início do primeiro ao fim do último.
- disc: o id da lista quando a aula é dessa disciplina. Os horários usam siglas e abreviaturas (Port = Português, Mat ou MAT A = Matemática A, FQ = Física e Química A, BG = Biologia e Geologia, Ing = Inglês, EF = Educação Física, Fil = Filosofia, HGP = História e Geografia de Portugal, CN = Ciências Naturais). Se não for nenhuma da lista, disc = "".
- nome: o nome completo da disciplina (o da lista, ou o mais provável se não estiver na lista).
- texto: o que está escrito na célula, tal como aparece.
- sala: a sala, se aparecer; senão "".
- Ignora intervalos, almoço e células vazias. Não inventes aulas que não estejam no horário.
- Se não for um horário escolar, horario = false e aulas = [].
- duvidas: uma frase curta sobre o que não deu para ler bem, ou "".`;

const FERRAMENTA_HORARIO = {
  name: 'guardar_horario',
  description: 'Guarda as aulas lidas no horário semanal do aluno.',
  input_schema: {
    type: 'object',
    properties: {
      horario: { type: 'boolean', description: 'false se não for um horário escolar' },
      aulas: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            dia: { type: 'integer', description: '1 = segunda ... 6 = sábado' },
            inicio: { type: 'string', description: 'HH:MM' },
            fim: { type: 'string', description: 'HH:MM' },
            disc: { type: 'string', description: 'id da disciplina na lista, ou "" se não estiver' },
            nome: { type: 'string', description: 'nome completo da disciplina' },
            texto: { type: 'string', description: 'o que está escrito na célula' },
            sala: { type: 'string', description: 'a sala, ou ""' },
          },
          required: ['dia', 'inicio', 'fim', 'nome'],
        },
      },
      duvidas: { type: 'string', description: 'o que não deu para ler bem, ou ""' },
    },
    required: ['horario', 'aulas'],
  },
};
const TIPOS_HORARIO = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf'];

function curto(v: unknown, max = 80): string {
  return String(v ?? '').replace(/[\r\n\t]+/g, ' ').trim().slice(0, max);
}

// deno-lint-ignore no-explicit-any
async function lerHorario(corpo: any, alunoId: string): Promise<Response> { return await lerComIA(corpo, alunoId, 'horario'); }

const REGRAS_QUADRO = `Regras:
- texto: a tarefa, curta e clara, como o aluno a escreveria (ex.: "Fazer os exercícios 3 a 7 da página 45").
- disc: o id da disciplina da lista quando dá para perceber (siglas: Port, Mat, FQ, BG, Ing, HGP, CN…); senão "".
- ate: a data de entrega no formato AAAA-MM-DD, se aparecer (ex.: "para quinta" = a próxima quinta-feira); senão "".
- Não inventes tarefas que não estejam na imagem. Se não houver tarefas, tarefas = [].
- duvidas: uma frase curta sobre o que não deu para ler bem, ou "".`;

const FERRAMENTA_QUADRO = {
  name: 'guardar_tarefas',
  description: 'Guarda as tarefas e trabalhos de casa lidos na imagem.',
  input_schema: {
    type: 'object',
    properties: {
      tarefas: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            texto: { type: 'string', description: 'a tarefa, curta e clara' },
            disc: { type: 'string', description: 'id da disciplina na lista, ou ""' },
            ate: { type: 'string', description: 'data de entrega AAAA-MM-DD, ou ""' },
          },
          required: ['texto'],
        },
      },
      duvidas: { type: 'string', description: 'o que não deu para ler bem, ou ""' },
    },
    required: ['tarefas'],
  },
};

// deno-lint-ignore no-explicit-any
function listaDisciplinas(cx: any): string {
  return (Array.isArray(cx.disciplinas) ? cx.disciplinas : []).slice(0, 40)
    // deno-lint-ignore no-explicit-any
    .map((d: any) => `- ${curto(d?.id, 24)}: ${curto(d?.n)}`).join('\n') || '(nenhuma)';
}

// Lê uma foto (ou PDF) com a IA e devolve o que a ferramenta pedida trouxer.
// deno-lint-ignore no-explicit-any
async function lerComIA(corpo: any, alunoId: string, modo: 'horario' | 'quadro'): Promise<Response> {
  const chaveIA = Deno.env.get('ANTHROPIC_API_KEY');
  const coisa = modo === 'quadro' ? 'das tarefas' : 'de horários';
  if (!chaveIA) return json({ erro: `A leitura ${coisa} ainda não está ligada. Por agora, junta-as à mão.` }, 503);
  const tipo = String(corpo.tipo || '');
  const dados = String(corpo.dados || '');
  const tipos = modo === 'quadro' ? TIPOS_HORARIO.filter((t) => t !== 'application/pdf') : TIPOS_HORARIO;
  if (!tipos.includes(tipo) || !dados || !/^[A-Za-z0-9+/=]+$/.test(dados.slice(0, 400))) {
    return json({ erro: modo === 'quadro' ? 'Escolhe uma foto do quadro ou do caderno.' : 'Escolhe uma foto, um print ou um PDF do horário.' }, 400);
  }
  if (dados.length > 7_500_000) return json({ erro: 'O ficheiro é demasiado grande. Tira uma foto mais pequena.' }, 413);

  const limite = Number(Deno.env.get('CUMPRE_LIMITE_IA') || 10);
  const { data: vezes, error: erroUso } = await admin.rpc('usar_ia', { p_user: alunoId });
  if (erroUso) return json({ erro: 'O servidor da Cumpre não respondeu. Tenta daqui a pouco.' }, 500);
  if (Number(vezes) > limite) return json({ erro: `Já usaste as ${limite} leituras de hoje. Tenta outra vez amanhã.` }, 429);

  const cx = corpo.contexto && typeof corpo.contexto === 'object' ? corpo.contexto : {};
  let pedido: string;
  let ferramenta: typeof FERRAMENTA_HORARIO | typeof FERRAMENTA_QUADRO;
  if (modo === 'quadro') {
    const hoje = /^\d{4}-\d{2}-\d{2}$/.test(String(cx.hoje || '')) ? String(cx.hoje) : new Date().toISOString().slice(0, 10);
    pedido = `A imagem é uma foto do quadro, do caderno ou da plataforma da escola com trabalhos de casa ou tarefas de um aluno em Portugal. Tira todas as tarefas e guarda-as com a ferramenta guardar_tarefas (usa sempre a ferramenta; não respondas com texto).
Hoje é ${hoje}${cx.diaSemana ? ` (${curto(cx.diaSemana, 20)})` : ''}.
Disciplinas do aluno (id: nome):
${listaDisciplinas(cx)}

${REGRAS_QUADRO}`;
    ferramenta = FERRAMENTA_QUADRO;
  } else {
    const quem = [cx.nivel, cx.ano ? `${curto(cx.ano, 4)}.º ano` : '', cx.curso, cx.escola].map((v) => curto(v, 120)).filter(Boolean).join(', ');
    pedido = `${tipo === 'application/pdf' ? 'O ficheiro' : 'A imagem'} é o horário semanal de um aluno em Portugal. Tira todas as aulas e guarda-as com a ferramenta guardar_horario (usa sempre a ferramenta; não respondas com texto).
Aluno: ${quem || 'sem dados'}.
Disciplinas que o aluno tem (id: nome):
${listaDisciplinas(cx)}

${REGRAS_HORARIO}`;
    ferramenta = FERRAMENTA_HORARIO;
  }
  const ficheiro = tipo === 'application/pdf'
    ? { type: 'document', source: { type: 'base64', media_type: tipo, data: dados } }
    : { type: 'image', source: { type: 'base64', media_type: tipo, data: dados } };

  let resposta: Response;
  try {
    resposta = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': chaveIA, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: Deno.env.get('CUMPRE_MODELO_IA') || 'claude-sonnet-5-5',
        max_tokens: 8000,
        tools: [ferramenta],
        // Os modelos novos não aceitam obrigar a usar uma ferramenta: pede-se no texto e lê-se também JSON escrito.
        tool_choice: { type: 'auto' },
        messages: [{ role: 'user', content: [ficheiro, { type: 'text', text: pedido }] }],
      }),
      signal: AbortSignal.timeout(100000),
    });
  } catch {
    return json({ erro: 'A leitura demorou demasiado. Tenta outra vez.' }, 504);
  }
  if (!resposta.ok) {
    const texto = (await resposta.text()).slice(0, 600);
    console.error('Anthropic', resposta.status, texto);
    if (resposta.status === 401 || resposta.status === 403 || /credit balance/i.test(texto)) {
      return json({ erro: 'A leitura por foto está em pausa. Avisa a equipa da Cumpre.' }, 503);
    }
    if (resposta.status === 400) return json({ erro: 'Este ficheiro não dá para ler. Tenta com outra foto ou um print.' }, 422);
    return json({ erro: 'Não deu para ler a foto agora. Tenta daqui a pouco.' }, 502);
  }
  const r = await resposta.json();
  // deno-lint-ignore no-explicit-any
  const uso = Array.isArray(r.content) ? r.content.find((c: any) => c.type === 'tool_use') : null;
  if (uso?.input) return json(uso.input);
  // Sem ferramenta: procura um objeto JSON no texto da resposta.
  // deno-lint-ignore no-explicit-any
  const texto = Array.isArray(r.content) ? r.content.filter((c: any) => c.type === 'text').map((c: any) => c.text).join('\n') : '';
  const i = texto.indexOf('{'), f = texto.lastIndexOf('}');
  if (i >= 0 && f > i) {
    try { return json(JSON.parse(texto.slice(i, f + 1))); } catch { /* segue */ }
  }
  console.error('Resposta sem dados', r.stop_reason, texto.slice(0, 300));
  return json({ erro: 'Não deu para ler esta foto. Tenta com uma foto mais nítida.' }, 502);
}

// ---------- Lembretes no telemóvel (Web Push, RFC 8291 + VAPID RFC 8292) ----------
const enc = new TextEncoder();
export function b64u(b: Uint8Array): string {
  let t = '';
  for (const x of b) t += String.fromCharCode(x);
  return btoa(t).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function deB64u(t: string): Uint8Array {
  let u = t.replace(/-/g, '+').replace(/_/g, '/');
  while (u.length % 4) u += '=';
  const b = atob(u);
  const r = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) r[i] = b.charCodeAt(i);
  return r;
}
function juntar(...partes: Uint8Array[]): Uint8Array {
  const r = new Uint8Array(partes.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of partes) { r.set(p, i); i += p.length; }
  return r;
}
async function hmac(chave: Uint8Array, dados: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', chave, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, dados));
}
// Cifra a mensagem para um aparelho (aes128gcm). "opc" só serve para os testes com os valores do RFC.
export async function cifrarPush(uaPub: Uint8Array, auth: Uint8Array, texto: Uint8Array, opc?: { asPriv: JsonWebKey; asPub: Uint8Array; salt: Uint8Array }): Promise<Uint8Array> {
  let asPub: Uint8Array;
  let asPriv: CryptoKey;
  if (opc) {
    asPub = opc.asPub;
    asPriv = await crypto.subtle.importKey('jwk', opc.asPriv, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  } else {
    const par = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
    asPriv = par.privateKey;
    asPub = new Uint8Array(await crypto.subtle.exportKey('raw', par.publicKey));
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asPriv, 256));
  const prkKey = await hmac(auth, ecdh);
  const ikm = await hmac(prkKey, juntar(enc.encode('WebPush: info\0'), uaPub, asPub, new Uint8Array([1])));
  const salt = opc ? opc.salt : crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, juntar(enc.encode('Content-Encoding: aes128gcm\0'), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, juntar(enc.encode('Content-Encoding: nonce\0'), new Uint8Array([1])))).slice(0, 12);
  const k = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cifra = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, k, juntar(texto, new Uint8Array([2]))));
  return juntar(salt, new Uint8Array([0, 0, 16, 0]), new Uint8Array([asPub.length]), asPub, cifra);
}
export async function jwtVapid(aud: string, priv: JsonWebKey): Promise<string> {
  const cab = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const corpo = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: 'https://app.cumpre.pt' })));
  const k = await crypto.subtle.importKey('jwk', { ...priv, key_ops: ['sign'] }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const ass = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k, enc.encode(cab + '.' + corpo)));
  return cab + '.' + corpo + '.' + b64u(ass);
}
// As chaves VAPID criam-se sozinhas na primeira vez e ficam guardadas na base de dados (só o servidor as lê).
async function chavesVapid(): Promise<{ priv: JsonWebKey; pub: string }> {
  const { data } = await admin.from('config_privada').select('valor').eq('chave', 'vapid').maybeSingle();
  if (data?.valor?.pub) return data.valor;
  const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const valor = { priv: await crypto.subtle.exportKey('jwk', par.privateKey), pub: b64u(new Uint8Array(await crypto.subtle.exportKey('raw', par.publicKey))) };
  await admin.from('config_privada').upsert({ chave: 'vapid', valor }, { onConflict: 'chave', ignoreDuplicates: true });
  const { data: d2 } = await admin.from('config_privada').select('valor').eq('chave', 'vapid').maybeSingle();
  return d2?.valor?.pub ? d2.valor : valor;
}
// Só se envia para os serviços de notificações conhecidos (Apple, Google, Mozilla, Microsoft).
export function pushPermitido(endpoint: string): boolean {
  try {
    const u = new URL(endpoint);
    return u.protocol === 'https:' && /(^|\.)(push\.apple\.com|fcm\.googleapis\.com|push\.services\.mozilla\.com|notify\.windows\.com|android\.googleapis\.com)$/.test(u.hostname);
  } catch { return false; }
}
async function enviarPush(sub: { endpoint: string; p256dh: string; auth: string }, dados: unknown, vapid: { priv: JsonWebKey; pub: string }): Promise<number> {
  const corpo = await cifrarPush(deB64u(sub.p256dh), deB64u(sub.auth), enc.encode(JSON.stringify(dados)));
  const jwt = await jwtVapid(new URL(sub.endpoint).origin, vapid.priv);
  const r = await fetch(sub.endpoint, {
    method: 'POST',
    headers: { 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '86400', Urgency: 'normal', Authorization: `vapid t=${jwt}, k=${vapid.pub}` },
    body: corpo,
    signal: AbortSignal.timeout(10000),
  });
  return r.status;
}
async function enviarLembretes(req: Request): Promise<Response> {
  const { data: cfg } = await admin.from('config_privada').select('valor').eq('chave', 'cron').maybeSingle();
  const segredo = typeof cfg?.valor === 'string' ? cfg.valor : '';
  if (!segredo || req.headers.get('x-cumpre-cron') !== segredo) return json({ erro: 'Sem autorização.' }, 401);
  const agora = Date.now();
  const { data: devidos } = await admin.from('lembretes').select('id, user_id, chave, titulo, corpo, quando')
    .eq('enviado', false).lte('quando', new Date(agora).toISOString()).order('quando').limit(300);
  let enviados = 0;
  if (devidos?.length) {
    const alunos = [...new Set(devidos.map((l) => l.user_id))];
    const { data: subs } = await admin.from('push_subs').select('id, user_id, endpoint, p256dh, auth').in('user_id', alunos);
    const vapid = await chavesVapid();
    const mortos = new Set<number>();
    for (const l of devidos) {
      if (agora - Date.parse(l.quando) > 6 * 3600000) continue; // atrasado demais: já não faz sentido
      for (const s of (subs || []).filter((x) => x.user_id === l.user_id && !mortos.has(x.id))) {
        if (!pushPermitido(s.endpoint)) { mortos.add(s.id); continue; }
        try {
          const st = await enviarPush(s, { titulo: l.titulo, corpo: l.corpo, tag: l.chave, url: './' }, vapid);
          if (st === 404 || st === 410) mortos.add(s.id);
          else if (st < 300) enviados++;
        } catch { /* falhou este aparelho; os outros continuam */ }
      }
    }
    await admin.from('lembretes').update({ enviado: true }).in('id', devidos.map((l) => l.id));
    if (mortos.size) await admin.from('push_subs').delete().in('id', [...mortos]);
  }
  await admin.from('lembretes').delete().eq('enviado', true).lt('quando', new Date(agora - 30 * 86400000).toISOString());
  return json({ ok: true, enviados });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    const pedidos = req.headers.get('Access-Control-Request-Headers');
    return new Response('ok', { headers: pedidos ? { ...cors, 'Access-Control-Allow-Headers': pedidos } : cors });
  }
  if (req.method !== 'POST') return json({ erro: 'Pedido inválido.' }, 405);

  // deno-lint-ignore no-explicit-any
  let corpo: any = {};
  try { corpo = await req.json(); } catch { /* corpo vazio */ }

  // O agendador do Supabase chama isto de 10 em 10 minutos, com o segredo guardado na base de dados.
  if (corpo.acao === 'enviar-lembretes') return await enviarLembretes(req);

  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: quem } = await admin.auth.getUser(token);
  const aluno = quem?.user;
  if (!aluno) return json({ erro: 'A tua sessão terminou. Entra outra vez.' }, 401);

  if (corpo.acao === 'calendario') {
    const link = linkSeguro(corpo.url || '');
    if (!link) return json({ erro: 'Este link não parece um link de calendário. Confirma que o copiaste inteiro.' }, 400);
    let resposta: Response;
    try {
      resposta = await fetch(link.toString(), {
        headers: { 'User-Agent': 'Mozilla/5.0 (Cumpre; calendario)', Accept: 'text/calendar, text/plain, */*' },
        redirect: 'follow',
        signal: AbortSignal.timeout(15000),
      });
    } catch {
      return json({ erro: 'O site da escola não respondeu. Tenta daqui a pouco.' }, 502);
    }
    if (!resposta.ok) return json({ erro: 'O site da escola respondeu com o erro ' + resposta.status + '. Confirma que o link ainda funciona.' }, 502);
    const texto = await lerAte(resposta, 5 * 1024 * 1024);
    if (texto === null) return json({ erro: 'O calendário é demasiado grande (mais de 5 MB).' }, 413);
    if (!/BEGIN:VCALENDAR/i.test(texto)) return json({ erro: 'Este link não devolve um calendário. Confirma que é o link de sincronização do calendário.' }, 422);
    return new Response(texto, { headers: { ...cors, 'Content-Type': 'text/calendar; charset=utf-8' } });
  }

  if (corpo.acao === 'horario-foto') return await lerHorario(corpo, aluno.id);
  if (corpo.acao === 'quadro-foto') return await lerComIA(corpo, aluno.id, 'quadro');
  if (corpo.acao === 'vapid') return json({ chave: (await chavesVapid()).pub });

  if (corpo.acao === 'apagar-conta') {
    const pasta = aluno.id;
    for (let volta = 0; volta < 20; volta++) {
      const { data: ficheiros } = await admin.storage.from('anexos').list(pasta, { limit: 1000 });
      if (!ficheiros || !ficheiros.length) break;
      await admin.storage.from('anexos').remove(ficheiros.map((f) => pasta + '/' + f.name));
    }
    await admin.from('estado').delete().eq('user_id', aluno.id);
    const { error } = await admin.auth.admin.deleteUser(aluno.id);
    if (error) return json({ erro: 'Apagámos os teus dados, mas não deu para apagar o login. Tenta outra vez.' }, 500);
    return json({ ok: true });
  }

  return json({ erro: 'Pedido desconhecido.' }, 400);
});
