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

const EMPTY_TITLES = {
  urgente:       'Todo en calma.',
  por_responder: 'Nada pendiente.',
  para_leer:     'La bandeja respira.',
  boletines:     'Sin novedades.',
  archivo:       'El archivo descansa.',
  otros:         'Sin incertidumbre.',
};

const EMPTY_SUBS = {
  urgente:       'Nada requiere tu atención inmediata.',
  por_responder: 'No hay mensajes esperando respuesta.',
  para_leer:     'No hay nada nuevo para leer.',
  boletines:     'Sin boletines por ahora.',
  archivo:       'El archivo está en orden.',
  otros:         'No hay nada esperando una categoría.',
};

const FRASES_ARCHIVO = ['Cerrado.', 'Resuelto.', 'Guardado.', 'Ciclo completado.', 'Todo en su lugar.'];

const PAGE = 50;

let categoriaActual = 'urgente';
let emailActual     = null;
let deleteConfirm   = false;
let paginaOffset    = 0;
let paginaTotal     = 0;
let searchActive    = false;
let searchTimer     = null;

// ---------- utilidades ----------
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (res.status === 401) {
    show('welcome');
    throw new Error('Sesión expirada. Vuelve a iniciar sesión.');
  }
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
  for (const id of ['welcome', 'inbox', 'reader', 'composer', 'rules']) {
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

// ---------- skeleton ----------
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
        <div class="skeleton sk-preview"></div>
      </div>
    </li>`).join('');
}

// ---------- renderizar filas ----------
function renderEmails(emails, append = false, emptyTitle, emptySub) {
  const list  = $('#email-list');
  const empty = $('#empty-state');

  if (!append) {
    list.innerHTML = '';
    if (emails.length === 0) {
      empty.classList.remove('hidden');
      $('#empty-title').textContent = emptyTitle ?? EMPTY_TITLES[categoriaActual] ?? 'Nada por aquí';
      $('#empty-sub').textContent   = emptySub   ?? EMPTY_SUBS[categoriaActual]   ?? '';
      return;
    }
    empty.classList.add('hidden');
  }

  const esOtros = categoriaActual === 'otros';

  for (const e of emails) {
    const li = document.createElement('li');
    li.className = 'email-row' + (esOtros ? ' otros-row' : '');
    li.setAttribute('role', 'listitem');
    li.dataset.id        = String(e.id);
    li.dataset.destacado = e.destacado ? '1' : '0';

    const starHtml = e.destacado
      ? '<span class="row-star" aria-label="Destacado" aria-hidden="true">★</span>'
      : '';
    li.innerHTML = `
      <span class="dot d-${e.categoria || 'otros'}${e.leido ? ' read' : ''}" aria-hidden="true"></span>
      <div class="email-main">
        <div class="email-top">
          <span class="email-from">${escapeHtml(e.remitente || e.remitente_email || '(desconocido)')}</span>
          <span class="email-date">${fmtFecha(e.fecha)}</span>
        </div>
        <div class="email-subject${e.leido ? ' read' : ''}">${escapeHtml(e.asunto || '(sin asunto)')}</div>
        <div class="email-preview">${escapeHtml(e.resumen || e.snippet || '')}</div>
      </div>
      ${starHtml}`;

    li.onclick = () => abrirEmail(e.id);
    agregarSwipe(li, e);
    list.appendChild(li);
  }
}

// ---------- gestos swipe (móvil) ----------
function agregarSwipe(li, e) {
  let startX = 0, startY = 0, moved = false;

  li.addEventListener('touchstart', (ev) => {
    startX = ev.touches[0].clientX;
    startY = ev.touches[0].clientY;
    moved = false;
    li.style.transition = 'none';
  }, { passive: true });

  li.addEventListener('touchmove', (ev) => {
    const dx = ev.touches[0].clientX - startX;
    const dy = ev.touches[0].clientY - startY;
    if (!moved && Math.abs(dy) > Math.abs(dx)) return;
    moved = true;
    const x = Math.max(-110, Math.min(110, dx));
    li.style.transform  = `translateX(${x}px)`;
    li.dataset.swipe = dx < -60 ? 'left' : dx > 60 ? 'right' : '';
  }, { passive: true });

  li.addEventListener('touchend', async () => {
    li.style.transition = 'transform 0.2s var(--ease), opacity 0.2s';
    li.style.transform  = '';
    if (!moved) return;
    const dir = li.dataset.swipe;
    li.dataset.swipe = '';

    if (dir === 'left') {
      try {
        await api(`/api/emails/${e.id}/archivar`, { method: 'POST' });
        li.style.opacity = '0';
        setTimeout(() => li.remove(), 210);
        toast(FRASES_ARCHIVO[Math.floor(Math.random() * FRASES_ARCHIVO.length)]);
      } catch {}
    } else if (dir === 'right') {
      const nuevo = li.dataset.destacado !== '1';
      try {
        await api(`/api/emails/${e.id}/destacar`, { method: 'POST', body: { destacado: nuevo } });
        li.dataset.destacado = nuevo ? '1' : '0';
        const star = li.querySelector('.row-star');
        if (nuevo && !star) {
          const s = document.createElement('span');
          s.className = 'row-star';
          s.setAttribute('aria-hidden', 'true');
          s.textContent = '★';
          li.appendChild(s);
        } else if (!nuevo && star) {
          star.remove();
        }
        toast(nuevo ? '★ Destacado' : 'Eliminado de destacados');
      } catch {}
    }
  });
}

// ---------- bandeja ----------
async function cargarBandeja(mostrarSkeleton = false) {
  if (searchActive) return;
  paginaOffset = 0;
  if (mostrarSkeleton) renderSkeletons();

  const [{ emails, total }, { counts }] = await Promise.all([
    api(`/api/emails?categoria=${categoriaActual}&limit=${PAGE}&offset=0`),
    api('/api/emails/counts'),
  ]);

  paginaTotal = total;
  $('#cat-title').textContent = NOMBRES[categoriaActual];

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

  renderEmails(emails);
  $('#btn-load-more').classList.toggle('hidden', emails.length >= total);
}

async function cargarMas() {
  paginaOffset += PAGE;
  const btn = $('#btn-load-more');
  btn.disabled = true;
  try {
    const { emails, total } = await api(
      `/api/emails?categoria=${categoriaActual}&limit=${PAGE}&offset=${paginaOffset}`
    );
    paginaTotal = total;
    renderEmails(emails, true);
    btn.classList.toggle('hidden', paginaOffset + emails.length >= total);
  } catch (e) {
    toast(e.message, 5000);
    paginaOffset -= PAGE;
  } finally {
    btn.disabled = false;
  }
}

// ---------- búsqueda ----------
async function buscar(q) {
  try {
    $('#cat-title').textContent = `"${q}"`;
    const { emails } = await api(`/api/emails/search?q=${encodeURIComponent(q)}`);
    renderEmails(emails, false, 'Sin resultados.', `Nada coincide con "${q}".`);
    $('#btn-load-more').classList.add('hidden');
  } catch (e) {
    toast(e.message, 5000);
  }
}

// ---------- sincronización ----------
async function sincronizar() {
  const btnR   = $('#btn-refresh');
  const banner = $('#sync-banner');
  btnR.disabled = true;
  banner.classList.remove('hidden');
  banner.textContent = 'Buscando correos nuevos…';
  try {
    await api('/api/sync', { method: 'POST' });
    const poll = setInterval(async () => {
      try {
        const st = await api('/api/sync/status');
        if (st.error) {
          clearInterval(poll);
          banner.classList.add('hidden');
          btnR.disabled = false;
          toast('Error al sincronizar: ' + st.error, 6000);
          return;
        }
        if (st.running) {
          banner.textContent = st.total
            ? `Clasificando… ${st.done}/${st.total}`
            : 'Buscando correos nuevos…';
          if (st.done > 0 && st.done % 5 === 0) cargarBandeja();
        } else {
          clearInterval(poll);
          banner.classList.add('hidden');
          btnR.disabled = false;
          toast(st.total > 0
            ? `${st.total} correo${st.total > 1 ? 's' : ''} nuevo${st.total > 1 ? 's' : ''}.`
            : 'Tu bandeja está al día.');
          cargarBandeja();
        }
      } catch {
        // red momentáneamente caída — continuar polling
      }
    }, 1500);
  } catch (e) {
    banner.classList.add('hidden');
    btnR.disabled = false;
    toast(e.message, 5000);
  }
}

// ---------- lector ----------
async function abrirEmail(id) {
  // Resetear estado de eliminación
  deleteConfirm = false;
  const btnDel = $('#btn-delete');
  btnDel.textContent = 'Eliminar';
  btnDel.classList.remove('btn-danger-text');

  const { email } = await api(`/api/emails/${id}`);
  emailActual = email;

  $('#r-resumen').textContent = email.resumen || '';
  const chip  = $('#cat-chip');
  const catKey = email.categoria || 'otros';
  chip.textContent = NOMBRES[catKey] || catKey;
  chip.className   = `cat-chip cat-${catKey}`;
  $('#otros-hint').classList.toggle('hidden', catKey !== 'otros');

  $('#r-asunto').textContent = email.asunto || '(sin asunto)';
  $('#r-remitente').textContent = email.remitente
    ? `${email.remitente} · ${email.remitente_email || ''}`
    : (email.remitente_email || '(desconocido)');
  $('#r-fecha').textContent = email.fecha
    ? new Date(email.fecha).toLocaleString('es', { dateStyle: 'medium', timeStyle: 'short' })
    : '';

  $('#r-cuerpo').textContent = email.cuerpo || email.snippet || '';
  $('#reply-instruction').value = '';
  $('#draft-area').classList.add('hidden');
  $('#draft-body').value = '';

  actualizarBtnDestacado(!!email.destacado);
  actualizarBtnLeido(!!email.leido);
  renderReclassifyGrid(catKey);

  // Resetear modo enfoque
  $('#reader').classList.remove('focus-mode');
  $('#btn-focus').classList.remove('active');

  show('reader');

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
  const svg = btn.querySelector('svg');
  if (svg) svg.setAttribute('fill', destacado ? 'currentColor' : 'none');
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
    const chip = $('#cat-chip');
    chip.textContent = NOMBRES[nuevaCat];
    chip.className   = `cat-chip cat-${nuevaCat}`;
    $('#otros-hint').classList.add('hidden');
    toast(`Movido a ${NOMBRES[nuevaCat]}`);
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

// ---------- pantalla de reglas ----------
async function cargarReglas() {
  try {
    const { rules } = await api('/api/rules');
    const list  = $('#rules-list');
    const empty = $('#rules-empty');
    list.innerHTML = '';
    if (rules.length === 0) {
      empty.classList.remove('hidden');
      return;
    }
    empty.classList.add('hidden');
    for (const r of rules) {
      const li = document.createElement('li');
      li.className = 'rule-item';
      li.innerHTML = `
        <div class="rule-info">
          <span class="rule-email">${escapeHtml(r.remitente_email)}</span>
          <span class="rule-cat">${NOMBRES[r.categoria] || r.categoria}</span>
        </div>
        <button class="rule-delete icon-btn" data-id="${r.id}" aria-label="Eliminar regla">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>`;
      list.appendChild(li);
    }
    list.querySelectorAll('.rule-delete').forEach((btn) => {
      btn.onclick = async () => {
        try {
          await api(`/api/rules/${btn.dataset.id}`, { method: 'DELETE' });
          cargarReglas();
        } catch (e) { toast(e.message, 5000); }
      };
    });
  } catch (e) {
    toast(e.message, 5000);
  }
}

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

$('#btn-search').onclick = () => {
  searchActive = !searchActive;
  $('#search-bar').classList.toggle('hidden', !searchActive);
  $('#btn-search').classList.toggle('active', searchActive);
  if (searchActive) {
    $('#search-input').focus();
    $('#cat-title').textContent = 'Buscar';
  } else {
    $('#search-input').value = '';
    cargarBandeja(true);
  }
};

$('#search-input').addEventListener('input', () => {
  clearTimeout(searchTimer);
  const q = $('#search-input').value.trim();
  if (!q) { cargarBandeja(); return; }
  searchTimer = setTimeout(() => buscar(q), 350);
});

$('#btn-rules').onclick = () => { show('rules'); cargarReglas(); };
$('#btn-rules-back').onclick = () => show('inbox');
$('#btn-load-more').onclick = cargarMas;

// ---------- eventos del lector ----------
$('#btn-back').onclick = () => {
  $('#reader').classList.remove('focus-mode');
  $('#btn-focus').classList.remove('active');
  show('inbox');
  cargarBandeja();
};

$('#btn-focus').onclick = () => {
  const reader = $('#reader');
  const active = reader.classList.toggle('focus-mode');
  $('#btn-focus').classList.toggle('active', active);
};

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
    const frase = FRASES_ARCHIVO[Math.floor(Math.random() * FRASES_ARCHIVO.length)];
    toast(frase);
    show('inbox');
    cargarBandeja();
  } catch (e) {
    toast(e.message, 5000);
  }
};

$('#btn-delete').onclick = async () => {
  const btn = $('#btn-delete');
  if (!deleteConfirm) {
    deleteConfirm = true;
    btn.textContent = '¿Eliminar?';
    btn.classList.add('btn-danger-text');
    setTimeout(() => {
      if (deleteConfirm) {
        deleteConfirm = false;
        btn.textContent = 'Eliminar';
        btn.classList.remove('btn-danger-text');
      }
    }, 3000);
    return;
  }
  deleteConfirm = false;
  btn.textContent = 'Eliminar';
  btn.classList.remove('btn-danger-text');
  try {
    await api(`/api/emails/${emailActual.id}`, { method: 'DELETE' });
    toast('Eliminado.');
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
  btn._orig = btn.textContent;
  btn.disabled = true; btn.textContent = 'Generando…';
  try {
    const { borrador } = await api('/api/draft', { method: 'POST', body: { instruccion } });
    $('#c-body').value = borrador;
    $('#c-body').focus();
  } catch (e) {
    toast(e.message, 5000);
  } finally {
    btn.disabled = false; btn.textContent = btn._orig || 'Redactar con IA';
  }
};

$('#btn-compose-send').onclick = async () => {
  const to   = $('#c-to').value.trim();
  const body = $('#c-body').value.trim();
  if (!to)   return toast('Escribe un destinatario');
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

// Colapsar título en scroll
window.addEventListener('scroll', () => {
  const titulo = $('#cat-title');
  if (titulo) titulo.classList.toggle('collapsed', window.scrollY > 40);
}, { passive: true });

// Atajos de teclado
document.addEventListener('keydown', (e) => {
  const tag    = document.activeElement?.tagName;
  const typing = tag === 'INPUT' || tag === 'TEXTAREA';

  if (e.key === 'Escape') {
    if (!$('#reader').classList.contains('hidden')) {
      $('#reader').classList.remove('focus-mode');
      $('#btn-focus').classList.remove('active');
      show('inbox');
      cargarBandeja();
    } else if (!$('#composer').classList.contains('hidden')) {
      show('inbox');
    } else if (searchActive) {
      searchActive = false;
      $('#search-bar').classList.add('hidden');
      $('#btn-search').classList.remove('active');
      $('#search-input').value = '';
      cargarBandeja(true);
    }
  }

  if ((e.key === 'f' || e.key === 'F') && !typing && !$('#reader').classList.contains('hidden')) {
    const reader = $('#reader');
    const active = reader.classList.toggle('focus-mode');
    $('#btn-focus').classList.toggle('active', active);
  }
});

// ---------- arranque ----------
(async () => {
  try {
    const { user } = await api('/api/me');
    if (!user) return show('welcome');
    if (user.picture) {
      const av = $('#user-avatar');
      if (av) { av.src = user.picture; av.classList.remove('hidden'); }
    }
    show('inbox');
    await cargarBandeja(true);
    const { counts } = await api('/api/emails/counts');
    if (Object.values(counts).every(c => c.total === 0)) sincronizar();
  } catch {
    show('welcome');
  }
})();
