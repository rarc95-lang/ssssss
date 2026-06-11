// SinMail — frontend
const $ = (s) => document.querySelector(s);

const NOMBRES = {
  urgente:       'Urgente',
  por_responder: 'Por responder',
  para_leer:     'Para leer',
  boletines:     'Boletines',
  archivo:       'Archivo',
  otros:         'Otros',
};

const EMPTY_SUBS = {
  urgente:       'No hay correos urgentes en este momento.',
  por_responder: 'No hay correos esperando tu respuesta.',
  para_leer:     'No hay contenido nuevo para leer.',
  boletines:     'Sin boletines.',
  archivo:       'El archivo está vacío.',
  otros:         'Los correos ambiguos o inusuales aparecen aquí para que decidas dónde van.',
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
  if (!iso) return '';
  const d = new Date(iso);
  const hoy = new Date();
  if (d.toDateString() === hoy.toDateString()) {
    return d.toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' });
  }
  const ayer = new Date(hoy); ayer.setDate(hoy.getDate() - 1);
  if (d.toDateString() === ayer.toDateString()) return 'Ayer';
  return d.toLocaleDateString('es', { day: 'numeric', month: 'short' });
}

function escapeHtml(s) {
  return (s || '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

// ---------- skeleton (estado de carga) ----------
function renderSkeletons(n = 5) {
  const list = $('#email-list');
  list.innerHTML = Array.from({ length: n }, () => `
    <li class="email-row" aria-hidden="true">
      <span class="skeleton sk-dot"></span>
      <div class="email-main">
        <div class="email-top">
          <span class="skeleton sk-from"></span>
          <span class="skeleton sk-date"></span>
        </div>
        <div class="skeleton sk-subject"></div>
        <div class="skeleton sk-summary"></div>
      </div>
    </li>`).join('');
}

// ---------- bandeja ----------
async function cargarBandeja(mostrarSkeleton = false) {
  if (mostrarSkeleton) renderSkeletons();

  const [{ emails }, { counts }] = await Promise.all([
    api(`/api/emails?categoria=${categoriaActual}`),
    api('/api/emails/counts'),
  ]);

  // Actualizar título
  $('#cat-title').textContent = NOMBRES[categoriaActual];

  // Contadores de no leídos en la píldora
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

  const empty = $('#empty-state');
  if (emails.length === 0) {
    empty.classList.remove('hidden');
    $('#empty-title').textContent = NOMBRES[categoriaActual] === 'Otros'
      ? 'Sin correos sin clasificar'
      : `Sin correos en ${NOMBRES[categoriaActual]}`;
    $('#empty-sub').textContent = EMPTY_SUBS[categoriaActual] || '';
  } else {
    empty.classList.add('hidden');
  }

  const esOtros = categoriaActual === 'otros';

  for (const e of emails) {
    const li = document.createElement('li');
    li.className = 'email-row' + (esOtros ? ' otros-row' : '');
    li.setAttribute('role', 'listitem');

    const starHtml = e.destacado ? '<span class="email-star" aria-label="Destacado">★</span>' : '';
    li.innerHTML = `
      <span class="dot ${e.leido ? 'read' : ''}" aria-hidden="true"></span>
      <div class="email-main">
        <div class="email-top">
          <span class="email-from">${escapeHtml(e.remitente || e.remitente_email || '(desconocido)')}</span>
          <span class="email-date">${fmtFecha(e.fecha)}</span>
        </div>
        <div class="email-subject${e.leido ? ' dimmed' : ''}">${escapeHtml(e.asunto || '(sin asunto)')}</div>
        <div class="email-summary">${escapeHtml(e.resumen || e.snippet || '')}</div>
      </div>
      ${starHtml}`;

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
      try {
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
          if (st.total > 0) toast(`${st.total} correo${st.total > 1 ? 's' : ''} nuevo${st.total > 1 ? 's' : ''} clasificado${st.total > 1 ? 's' : ''}`);
          cargarBandeja();
        }
      } catch {
        // Red momentáneamente caída — continuar polling
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

  // Resumen + chip de categoría
  $('#r-resumen').textContent = email.resumen || '';
  const chip = $('#cat-chip');
  const catKey = email.categoria || 'otros';
  chip.textContent = NOMBRES[catKey] || catKey;
  chip.className = `cat-chip cat-${catKey}`;

  // Pista especial para "Otros"
  $('#otros-hint').classList.toggle('hidden', catKey !== 'otros');

  // Cabecera
  $('#r-asunto').textContent = email.asunto || '(sin asunto)';
  $('#r-remitente').textContent =
    email.remitente
      ? `${email.remitente} · ${email.remitente_email || ''}`
      : (email.remitente_email || '(desconocido)');
  $('#r-fecha').textContent = email.fecha
    ? new Date(email.fecha).toLocaleString('es', { dateStyle: 'medium', timeStyle: 'short' })
    : '';

  // Cuerpo
  $('#r-cuerpo').textContent = email.cuerpo || email.snippet || '';

  // Borrador
  $('#reply-instruction').value = '';
  $('#draft-area').classList.add('hidden');
  $('#draft-body').value = '';

  // Estrella
  actualizarBtnDestacado(!!email.destacado);

  // Leído
  actualizarBtnLeido(!!email.leido);

  // Reclasificar
  renderReclassifyGrid(catKey);

  show('reader');

  // Marcar como leído si no lo está (optimista: actualizar estado local antes de la red)
  if (!email.leido) {
    emailActual.leido = 1;
    api(`/api/emails/${id}/leido`, { method: 'POST', body: { leido: true } }).catch(() => {});
  }
}

function actualizarBtnLeido(leido) {
  $('#btn-toggle-read').textContent = leido ? 'No leído' : 'Leído';
}

function actualizarBtnDestacado(destacado) {
  const btn = $('#btn-destacar');
  btn.textContent = destacado ? '★' : '☆';
  btn.classList.toggle('starred', destacado);
  btn.setAttribute('aria-pressed', String(destacado));
}

// ---------- reclasificar ----------
function renderReclassifyGrid(catActual) {
  const grid = $('#reclassify-grid');
  grid.innerHTML = '';
  for (const [key, nombre] of Object.entries(NOMBRES)) {
    const btn = document.createElement('button');
    btn.className = 'recat-btn' + (key === catActual ? ' current' : '');
    btn.textContent = nombre;
    btn.dataset.cat = key;
    btn.onclick = () => reclasificar(key);
    grid.appendChild(btn);
  }
}

async function reclasificar(nuevaCat) {
  if (!emailActual || nuevaCat === emailActual.categoria) return;
  try {
    const { remitente_email } = await api(`/api/emails/${emailActual.id}/reclasificar`, {
      method: 'POST', body: { categoria: nuevaCat },
    });
    const catAnterior = emailActual.categoria;
    emailActual.categoria = nuevaCat;
    renderReclassifyGrid(nuevaCat);

    // Actualizar chip
    const chip = $('#cat-chip');
    chip.textContent = NOMBRES[nuevaCat];
    chip.className = `cat-chip cat-${nuevaCat}`;
    $('#otros-hint').classList.add('hidden');

    toast(`Movido a ${NOMBRES[nuevaCat]}`);

    // Proponer regla personal si viene de "otros" y tiene remitente
    if (catAnterior === 'otros' && remitente_email && nuevaCat !== 'otros') {
      ofrecerRegla(remitente_email, nuevaCat);
    }
  } catch (e) {
    toast(e.message, 5000);
  }
}

function ofrecerRegla(remitente_email, categoria) {
  const t = $('#toast');
  const dominio = remitente_email.split('@')[1] || remitente_email;
  t.innerHTML = `¿Clasificar siempre correos de <strong>${escapeHtml(dominio)}</strong> como ${NOMBRES[categoria]}?
    <button onclick="crearRegla('${escapeHtml(remitente_email)}','${categoria}')" style="margin-left:10px;background:rgba(255,255,255,0.2);border:none;border-radius:6px;padding:3px 8px;color:#fff;cursor:pointer;font-size:13px;">Sí</button>
    <button onclick="document.getElementById('toast').classList.add('hidden')" style="margin-left:4px;background:none;border:none;color:rgba(255,255,255,0.7);cursor:pointer;font-size:13px;">No</button>`;
  t.classList.remove('hidden');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.add('hidden'), 8000);
}

window.crearRegla = async function (remitente_email, categoria) {
  try {
    await api('/api/rules', { method: 'POST', body: { remitente_email, categoria } });
    toast(`Regla guardada para ${remitente_email.split('@')[1]}`);
  } catch {
    toast('No se pudo guardar la regla');
  }
};

// ---------- eventos de la bandeja ----------
document.querySelectorAll('.pill-item').forEach((btn) => {
  btn.onclick = () => {
    document.querySelectorAll('.pill-item').forEach((b) => b.classList.remove('active'));
    btn.classList.add('active');
    categoriaActual = btn.dataset.cat;
    cargarBandeja(true);
  };
});

$('#btn-refresh').onclick = sincronizar;
$('#btn-back').onclick = () => { show('inbox'); cargarBandeja(); };

// ---------- eventos del lector ----------
$('#btn-destacar').onclick = async () => {
  const nuevo = !emailActual.destacado;
  emailActual.destacado = nuevo ? 1 : 0;
  actualizarBtnDestacado(nuevo);
  try {
    await api(`/api/emails/${emailActual.id}/destacar`, { method: 'POST', body: { destacado: nuevo } });
  } catch {
    emailActual.destacado = nuevo ? 0 : 1;
    actualizarBtnDestacado(!nuevo);
    toast('No se pudo actualizar');
  }
};

$('#btn-toggle-read').onclick = async () => {
  const nuevo = !emailActual.leido;
  emailActual.leido = nuevo ? 1 : 0;
  actualizarBtnLeido(nuevo);
  try {
    await api(`/api/emails/${emailActual.id}/leido`, { method: 'POST', body: { leido: nuevo } });
    toast(nuevo ? 'Marcado como leído' : 'Marcado como no leído');
  } catch {
    emailActual.leido = nuevo ? 0 : 1;
    actualizarBtnLeido(!nuevo);
    toast('No se pudo actualizar');
  }
};

$('#btn-archive').onclick = async () => {
  try {
    await api(`/api/emails/${emailActual.id}/archivar`, { method: 'POST' });
    toast('Movido a Archivo');
    show('inbox');
    cargarBandeja();
  } catch (e) {
    toast(e.message, 5000);
  }
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
    $('#draft-body').focus();
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
      ? emailActual.asunto
      : `Re: ${emailActual.asunto || ''}`;
    await api('/api/send', {
      method: 'POST',
      body: { to: emailActual.remitente_email, subject: asunto, body, emailId: emailActual.id },
    });
    toast('Respuesta enviada');
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
    $('#c-body').focus();
  } catch (e) {
    toast(e.message, 5000);
  } finally {
    btn.disabled = false; btn.textContent = 'Redactar con IA';
  }
};

$('#btn-compose-send').onclick = async () => {
  const to = $('#c-to').value.trim();
  const body = $('#c-body').value.trim();
  if (!to) return toast('Escribe un destinatario');
  if (!body) return toast('El correo está vacío');
  const btn = $('#btn-compose-send');
  btn.disabled = true;
  try {
    await api('/api/send', {
      method: 'POST',
      body: { to, subject: $('#c-subject').value.trim(), body },
    });
    toast('Correo enviado');
    show('inbox');
  } catch (e) {
    toast(e.message, 6000);
  } finally {
    btn.disabled = false;
  }
};

$('#btn-logout').onclick = async () => {
  await api('/api/auth/logout', { method: 'POST' });
  show('welcome');
};

// Título grande que colapsa al hacer scroll
window.addEventListener('scroll', () => {
  const titulo = $('#cat-title');
  if (titulo) titulo.classList.toggle('collapsed', window.scrollY > 40);
}, { passive: true });

// Atajos de teclado básicos
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (!$('#reader').classList.contains('hidden')) {
      show('inbox');
      cargarBandeja();
    } else if (!$('#composer').classList.contains('hidden')) {
      show('inbox');
    }
  }
});

// ---------- arranque ----------
(async () => {
  try {
    const { user } = await api('/api/me');
    if (!user) return show('welcome');
    show('inbox');
    await cargarBandeja(true);
    const { counts } = await api('/api/emails/counts');
    if (Object.values(counts).every(c => c.total === 0)) sincronizar();
  } catch {
    show('welcome');
  }
})();
