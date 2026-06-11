// SinMail — frontend
const $ = (s) => document.querySelector(s);

const NOMBRES = {
  urgente: 'Urgente',
  por_responder: 'Por responder',
  para_leer: 'Para leer',
  boletines: 'Boletines',
  archivo: 'Archivo',
};

let categoriaActual = 'urgente';
let emailActual = null;

// ---------- utilidades ----------
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
  return data;
}

function toast(msg, ms = 3000) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.add('hidden'), ms);
}

function show(screenId) {
  for (const id of ['welcome', 'inbox', 'reader', 'composer']) {
    $('#' + id).classList.toggle('hidden', id !== screenId);
  }
  window.scrollTo(0, 0);
}

function fmtFecha(iso) {
  const d = new Date(iso);
  const hoy = new Date();
  if (d.toDateString() === hoy.toDateString()) {
    return d.toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' });
  }
  return d.toLocaleDateString('es', { day: 'numeric', month: 'short' });
}

function escapeHtml(s) {
  return (s || '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

// ---------- bandeja ----------
async function cargarBandeja() {
  $('#cat-title').textContent = NOMBRES[categoriaActual];
  const [{ emails }, { counts }] = await Promise.all([
    api(`/api/emails?categoria=${categoriaActual}`),
    api('/api/emails/counts'),
  ]);

  // contadores de no leídos en la píldora
  document.querySelectorAll('.pill-item').forEach((btn) => {
    const c = counts[btn.dataset.cat];
    const badge = btn.querySelector('.badge');
    if (c && c.no_leidos > 0) {
      badge.textContent = c.no_leidos;
      badge.classList.remove('hidden');
    } else {
      badge.classList.add('hidden');
    }
  });

  const list = $('#email-list');
  list.innerHTML = '';
  $('#empty-state').classList.toggle('hidden', emails.length > 0);
  for (const e of emails) {
    const li = document.createElement('li');
    li.className = 'email-row';
    li.innerHTML = `
      <span class="dot ${e.leido ? 'read' : ''}"></span>
      <div class="email-main">
        <div class="email-top">
          <span class="email-from">${escapeHtml(e.remitente)}</span>
          <span class="email-date">${fmtFecha(e.fecha)}</span>
        </div>
        <div class="email-subject">${escapeHtml(e.asunto || '(sin asunto)')}</div>
        <div class="email-summary">${escapeHtml(e.resumen || e.snippet)}</div>
      </div>`;
    li.onclick = () => abrirEmail(e.id);
    list.appendChild(li);
  }
}

// ---------- sincronización ----------
async function sincronizar() {
  const banner = $('#sync-banner');
  banner.classList.remove('hidden');
  banner.textContent = 'Sincronizando con Gmail…';
  try {
    await api('/api/sync', { method: 'POST' });
    const poll = setInterval(async () => {
      const st = await api('/api/sync/status');
      if (st.error) {
        clearInterval(poll);
        banner.classList.add('hidden');
        toast('Error al sincronizar: ' + st.error, 6000);
        return;
      }
      if (st.running) {
        banner.textContent = st.total
          ? `Clasificando con IA… ${st.done}/${st.total}`
          : 'Sincronizando con Gmail…';
        if (st.done > 0 && st.done % 5 === 0) cargarBandeja();
      } else {
        clearInterval(poll);
        banner.classList.add('hidden');
        if (st.total > 0) toast(`${st.total} correos nuevos clasificados`);
        cargarBandeja();
      }
    }, 1500);
  } catch (e) {
    banner.classList.add('hidden');
    toast(e.message, 5000);
  }
}

// ---------- lector ----------
async function abrirEmail(id) {
  const { email } = await api(`/api/emails/${id}`);
  emailActual = email;
  $('#r-resumen').textContent = email.resumen || '';
  $('#r-asunto').textContent = email.asunto || '(sin asunto)';
  $('#r-remitente').textContent = `${email.remitente} · ${email.remitente_email}`;
  $('#r-fecha').textContent = new Date(email.fecha).toLocaleString('es');
  $('#r-cuerpo').textContent = email.cuerpo || email.snippet || '';
  $('#reply-instruction').value = '';
  $('#draft-area').classList.add('hidden');
  $('#draft-body').value = '';
  actualizarBtnLeido(true);
  show('reader');
  if (!email.leido) {
    await api(`/api/emails/${id}/leido`, { method: 'POST', body: { leido: true } });
    emailActual.leido = 1;
  }
}

function actualizarBtnLeido(leido) {
  $('#btn-toggle-read').textContent = leido ? 'No leído' : 'Leído';
}

// ---------- eventos ----------
document.querySelectorAll('.pill-item').forEach((btn) => {
  btn.onclick = () => {
    document.querySelectorAll('.pill-item').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    categoriaActual = btn.dataset.cat;
    cargarBandeja();
  };
});

$('#btn-refresh').onclick = sincronizar;
$('#btn-back').onclick = () => { show('inbox'); cargarBandeja(); };

$('#btn-toggle-read').onclick = async () => {
  const nuevo = emailActual.leido ? 0 : 1;
  await api(`/api/emails/${emailActual.id}/leido`, { method: 'POST', body: { leido: !!nuevo } });
  emailActual.leido = nuevo;
  actualizarBtnLeido(!!nuevo);
  toast(nuevo ? 'Marcado como leído' : 'Marcado como no leído');
};

$('#btn-archive').onclick = async () => {
  await api(`/api/emails/${emailActual.id}/archivar`, { method: 'POST' });
  toast('Movido a Archivo');
  show('inbox');
  cargarBandeja();
};

$('#btn-gen-reply').onclick = async () => {
  const instruccion = $('#reply-instruction').value.trim();
  if (!instruccion) return toast('Escribe una instrucción primero');
  const btn = $('#btn-gen-reply');
  btn.disabled = true; btn.textContent = 'Generando…';
  try {
    const { borrador } = await api('/api/draft', {
      method: 'POST', body: { instruccion, emailId: emailActual.id },
    });
    $('#draft-body').value = borrador;
    $('#draft-area').classList.remove('hidden');
  } catch (e) {
    toast(e.message, 5000);
  } finally {
    btn.disabled = false; btn.textContent = 'Generar borrador';
  }
};

$('#btn-send-reply').onclick = async () => {
  const body = $('#draft-body').value.trim();
  if (!body) return toast('El borrador está vacío');
  const btn = $('#btn-send-reply');
  btn.disabled = true; btn.textContent = 'Enviando…';
  try {
    const asunto = emailActual.asunto?.startsWith('Re:')
      ? emailActual.asunto : `Re: ${emailActual.asunto || ''}`;
    await api('/api/send', {
      method: 'POST',
      body: { to: emailActual.remitente_email, subject: asunto, body, emailId: emailActual.id },
    });
    toast('Respuesta enviada ✓');
    show('inbox');
    cargarBandeja();
  } catch (e) {
    toast(e.message, 6000);
  } finally {
    btn.disabled = false; btn.textContent = 'Enviar respuesta';
  }
};

// ---------- redactar nuevo ----------
$('#btn-compose').onclick = () => {
  $('#c-to').value = ''; $('#c-subject').value = '';
  $('#c-instruction').value = ''; $('#c-body').value = '';
  show('composer');
};
$('#btn-compose-back').onclick = () => show('inbox');

$('#btn-compose-ai').onclick = async () => {
  const instruccion = $('#c-instruction').value.trim();
  if (!instruccion) return toast('Escribe una instrucción para la IA');
  const btn = $('#btn-compose-ai');
  btn.disabled = true; btn.textContent = 'Generando…';
  try {
    const { borrador } = await api('/api/draft', { method: 'POST', body: { instruccion } });
    $('#c-body').value = borrador;
  } catch (e) {
    toast(e.message, 5000);
  } finally {
    btn.disabled = false; btn.textContent = 'Redactar con IA';
  }
};

$('#btn-compose-send').onclick = async () => {
  const to = $('#c-to').value.trim();
  const body = $('#c-body').value.trim();
  if (!to || !body) return toast('Faltan destinatario o cuerpo');
  try {
    await api('/api/send', {
      method: 'POST',
      body: { to, subject: $('#c-subject').value.trim(), body },
    });
    toast('Correo enviado ✓');
    show('inbox');
  } catch (e) {
    toast(e.message, 6000);
  }
};

$('#btn-logout').onclick = async () => {
  await api('/api/auth/logout', { method: 'POST' });
  show('welcome');
};

// título grande que colapsa al hacer scroll
window.addEventListener('scroll', () => {
  $('#cat-title').classList.toggle('collapsed', window.scrollY > 40);
});

// ---------- arranque ----------
(async () => {
  const { user } = await api('/api/me');
  if (!user) return show('welcome');
  show('inbox');
  await cargarBandeja();
  // primera sincronización automática al entrar
  const { counts } = await api('/api/emails/counts');
  if (Object.keys(counts).length === 0) sincronizar();
})();
