// SinMail — frontend v2
'use strict';
const $ = (s) => document.querySelector(s);

// ─── Constantes ───────────────────────────────────────────────────────────────
const NOMBRES = {
  urgente: 'Urgente', por_responder: 'Por responder', para_leer: 'Para leer',
  boletines: 'Boletines', archivo: 'Archivo', otros: 'Otros', papelera: 'Papelera',
};
const EMPTY_TITLES = {
  urgente: 'Todo en calma.', por_responder: 'Nada pendiente.',
  para_leer: 'La bandeja respira.', boletines: 'Sin novedades.',
  archivo: 'El archivo descansa.', otros: 'Sin incertidumbre.',
  papelera: 'La papelera está vacía.',
};
const EMPTY_SUBS = {
  urgente: 'Nada requiere tu atención inmediata.',
  por_responder: 'No hay mensajes esperando respuesta.',
  para_leer: 'No hay nada nuevo para leer.',
  boletines: 'Sin boletines por ahora.',
  archivo: 'El archivo está en orden.',
  otros: 'No hay nada esperando una categoría.',
  papelera: 'Los correos eliminados aparecen aquí durante 30 días.',
};
const FRASES_ARCHIVO = ['Cerrado.', 'Resuelto.', 'Guardado.', 'Ciclo completado.', 'Todo en su lugar.'];
const PAGE = 50;

// ─── Estado ───────────────────────────────────────────────────────────────────
let categoriaActual = 'urgente';
let emailActual     = null;
let threadActual    = null;
let deleteConfirm   = false;
let paginaOffset    = 0;
let paginaTotal     = 0;
let searchActive    = false;
let searchTimer     = null;
let threadMode      = false;
let undoTimer       = null;

// ─── PWA: Service Worker ──────────────────────────────────────────────────────
if ('serviceWorker' in navigator) {
  window.addEventListener('load', async () => {
    try {
      const reg = await navigator.serviceWorker.register('/sw.js');
      reg.addEventListener('updatefound', () => {
        const worker = reg.installing;
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'installed' && navigator.serviceWorker.controller) {
            showUpdateBanner(reg);
          }
        });
      });
    } catch {}
  });
}

function showUpdateBanner(reg) {
  const banner = document.createElement('div');
  banner.style.cssText = `position:fixed;bottom:90px;left:50%;transform:translateX(-50%);
    background:#0F172A;color:#fff;padding:10px 16px;border-radius:12px;font-size:13.5px;
    display:flex;align-items:center;gap:10px;z-index:600;box-shadow:0 4px 20px rgba(0,0,0,.2)`;
  banner.innerHTML = `<span>Hay una actualización disponible.</span>
    <button onclick="location.reload()" style="background:rgba(255,255,255,.15);border:none;
      border-radius:8px;padding:4px 10px;color:#fff;cursor:pointer;font-size:13px">Actualizar</button>
    <button onclick="this.parentElement.remove()" style="background:none;border:none;
      color:rgba(255,255,255,.5);cursor:pointer;font-size:16px">×</button>`;
  document.body.appendChild(banner);
}

// ─── Conexión ─────────────────────────────────────────────────────────────────
const offlineBanner = document.getElementById('offline-banner');
window.addEventListener('online',  () => offlineBanner?.classList.add('hidden'));
window.addEventListener('offline', () => offlineBanner?.classList.remove('hidden'));
if (!navigator.onLine) offlineBanner?.classList.remove('hidden');

// ─── Utilidades ───────────────────────────────────────────────────────────────
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (res.status === 401) { show('welcome'); throw new Error('Sesión expirada.'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
  return data;
}

function toast(msg, ms = 3200) {
  const t = $('#toast');
  const msgEl = t.querySelector('.toast-msg');
  if (msgEl) msgEl.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.add('hidden'), ms);
}

function toastWithUndo(msg, onUndo, ms = 5000) {
  const t = $('#toast');
  t.innerHTML = `<span class="toast-msg">${escapeHtml(msg)}</span>
    <button class="toast-undo" onclick="void 0">Deshacer</button>`;
  t.classList.remove('hidden');
  clearTimeout(t._timer);
  const undoBtn = t.querySelector('.toast-undo');
  undoBtn.onclick = () => { clearTimeout(t._timer); t.classList.add('hidden'); onUndo(); };
  t._timer = setTimeout(() => t.classList.add('hidden'), ms);
}

function show(screenId) {
  for (const id of ['welcome', 'inbox', 'reader', 'thread', 'composer', 'rules']) {
    const el = document.getElementById(id);
    if (el) el.classList.toggle('hidden', id !== screenId);
  }
  window.scrollTo(0, 0);
}

function fmtFecha(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const hoy = new Date();
  if (d.toDateString() === hoy.toDateString())
    return d.toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' });
  const ayer = new Date(hoy); ayer.setDate(hoy.getDate() - 1);
  if (d.toDateString() === ayer.toDateString()) return 'Ayer';
  if (d.getFullYear() === hoy.getFullYear())
    return d.toLocaleDateString('es', { day: 'numeric', month: 'short' });
  return d.toLocaleDateString('es', { day: 'numeric', month: 'short', year: '2-digit' });
}

function escapeHtml(s) {
  return (s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

// ─── Skeletons ────────────────────────────────────────────────────────────────
function renderSkeletons(n = 5) {
  $('#email-list').innerHTML = Array.from({ length: n }, () => `
    <li class="email-row" aria-hidden="true">
      <span class="skeleton sk-dot"></span>
      <div class="email-main">
        <div class="email-top">
          <span class="skeleton sk-from"></span><span class="skeleton sk-date"></span>
        </div>
        <div class="skeleton sk-subject"></div>
        <div class="skeleton sk-preview"></div>
      </div>
    </li>`).join('');
}

// ─── Render de emails ─────────────────────────────────────────────────────────
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
  const esPapelera = categoriaActual === 'papelera';

  for (const e of emails) {
    const li = document.createElement('li');
    li.className = 'email-row' + (esOtros ? ' otros-row' : '');
    li.setAttribute('role', 'listitem');
    li.dataset.id        = String(e.id);
    li.dataset.destacado = e.destacado ? '1' : '0';

    const hiloHtml = e.thread_count > 1
      ? `<span class="thread-count">${e.thread_count}</span>` : '';
    const starHtml = e.destacado
      ? '<span class="row-star" aria-label="Destacado" aria-hidden="true">★</span>' : '';
    const trashHtml = esPapelera
      ? `<button class="row-restore icon-btn" data-id="${e.id}" title="Restaurar" aria-label="Restaurar correo">
           <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 .49-4.5"/></svg>
         </button>` : '';

    li.innerHTML = `
      <span class="dot d-${e.categoria || 'otros'}${e.leido ? ' read' : ''}" aria-hidden="true"></span>
      <div class="email-main">
        <div class="email-top">
          <span class="email-from">${escapeHtml(e.remitente || e.remitente_email || '(desconocido)')}${hiloHtml}</span>
          <span class="email-date">${fmtFecha(e.fecha)}</span>
        </div>
        <div class="email-subject${e.leido ? ' read' : ''}">${escapeHtml(e.asunto || '(sin asunto)')}</div>
        <div class="email-preview">${escapeHtml(e.resumen || e.snippet || '')}</div>
      </div>
      ${starHtml}${trashHtml}`;

    if (esPapelera) {
      li.querySelector('.row-restore')?.addEventListener('click', async (ev) => {
        ev.stopPropagation();
        await api(`/api/emails/${e.id}/restore`, { method: 'POST' });
        li.remove();
        toast('Correo restaurado.');
      });
      li.onclick = () => abrirEmail(e.id);
    } else {
      li.onclick = () => {
        // Si hay hilos, abrir vista de hilo; si no, abrir email
        if (e.thread_count > 1 && e.thread_id && threadMode) {
          abrirHilo(e.thread_id);
        } else {
          abrirEmail(e.id);
        }
      };
      agregarSwipe(li, e);
    }
    list.appendChild(li);
  }
}

// ─── Swipe gestos ─────────────────────────────────────────────────────────────
function agregarSwipe(li, e) {
  let startX = 0, startY = 0, moved = false;

  li.addEventListener('touchstart', (ev) => {
    startX = ev.touches[0].clientX; startY = ev.touches[0].clientY;
    moved = false; li.style.transition = 'none';
  }, { passive: true });

  li.addEventListener('touchmove', (ev) => {
    const dx = ev.touches[0].clientX - startX;
    const dy = ev.touches[0].clientY - startY;
    if (!moved && Math.abs(dy) > Math.abs(dx)) return;
    moved = true;
    const x = Math.max(-110, Math.min(110, dx));
    li.style.transform = `translateX(${x}px)`;
    li.dataset.swipe   = dx < -60 ? 'left' : dx > 60 ? 'right' : '';
  }, { passive: true });

  li.addEventListener('touchend', async () => {
    li.style.transition = 'transform 0.2s var(--ease), opacity 0.2s';
    li.style.transform  = '';
    if (!moved) return;
    const dir = li.dataset.swipe;
    li.dataset.swipe = '';
    if (dir === 'left') {
      // Archivar con undo
      const prev = e.categoria;
      li.style.opacity = '0';
      setTimeout(() => li.remove(), 210);
      try {
        await api(`/api/emails/${e.id}/archivar`, { method: 'POST' });
        toastWithUndo(FRASES_ARCHIVO[Math.floor(Math.random() * FRASES_ARCHIVO.length)], async () => {
          await api(`/api/emails/${e.id}/reclasificar`, { method: 'POST', body: { categoria: prev } });
          cargarBandeja();
        });
      } catch {}
    } else if (dir === 'right') {
      const nuevo = li.dataset.destacado !== '1';
      try {
        await api(`/api/emails/${e.id}/destacar`, { method: 'POST', body: { destacado: nuevo } });
        li.dataset.destacado = nuevo ? '1' : '0';
        const star = li.querySelector('.row-star');
        if (nuevo && !star) {
          const s = document.createElement('span');
          s.className = 'row-star'; s.setAttribute('aria-hidden', 'true'); s.textContent = '★';
          li.appendChild(s);
        } else if (!nuevo && star) { star.remove(); }
        toast(nuevo ? '★ Destacado' : 'Eliminado de destacados');
      } catch {}
    }
  });
}

// ─── Bandeja ──────────────────────────────────────────────────────────────────
async function cargarBandeja(mostrarSkeleton = false) {
  if (searchActive) return;
  paginaOffset = 0;
  if (mostrarSkeleton) renderSkeletons();

  if (categoriaActual === 'papelera') {
    const { emails } = await api('/api/emails/trashed');
    paginaTotal = emails.length;
    $('#cat-title').textContent = 'Papelera';
    renderEmails(emails);
    $('#btn-load-more').classList.add('hidden');
    // Mostrar botón vaciar si hay correos
    const vaciar = $('#btn-vaciar-papelera');
    if (vaciar) vaciar.classList.toggle('hidden', emails.length === 0);
    actualizarContadores();
    return;
  }

  const url = `/api/emails?categoria=${categoriaActual}&limit=${PAGE}&offset=0${threadMode ? '&threads=1' : ''}`;
  const [{ emails, total }, { counts, trashCount }] = await Promise.all([
    api(url),
    api('/api/emails/counts'),
  ]);

  paginaTotal = total;
  $('#cat-title').textContent = NOMBRES[categoriaActual];

  document.querySelectorAll('.pill-item').forEach((btn) => {
    const cat = btn.dataset.cat;
    if (cat === 'papelera') {
      const badge = btn.querySelector('.badge');
      if (badge) {
        badge.textContent = String(trashCount || '');
        badge.classList.toggle('hidden', !trashCount);
      }
      return;
    }
    const c = counts[cat];
    const badge = btn.querySelector('.badge');
    if (!badge) return;
    if (c?.no_leidos > 0) {
      badge.textContent = String(c.no_leidos);
      badge.classList.remove('hidden');
    } else {
      badge.classList.add('hidden');
    }
  });

  renderEmails(emails);
  $('#btn-load-more').classList.toggle('hidden', emails.length >= total);
  $('#btn-vaciar-papelera')?.classList.add('hidden');
}

function actualizarContadores() {
  api('/api/emails/counts').then(({ counts, trashCount }) => {
    document.querySelectorAll('.pill-item').forEach((btn) => {
      const cat = btn.dataset.cat;
      const badge = btn.querySelector('.badge');
      if (!badge) return;
      if (cat === 'papelera') {
        badge.textContent = String(trashCount || '');
        badge.classList.toggle('hidden', !trashCount);
        return;
      }
      const c = counts[cat];
      if (c?.no_leidos > 0) { badge.textContent = String(c.no_leidos); badge.classList.remove('hidden'); }
      else badge.classList.add('hidden');
    });
  }).catch(() => {});
}

async function cargarMas() {
  paginaOffset += PAGE;
  const btn = $('#btn-load-more');
  btn.disabled = true;
  try {
    const url = `/api/emails?categoria=${categoriaActual}&limit=${PAGE}&offset=${paginaOffset}${threadMode ? '&threads=1' : ''}`;
    const { emails, total } = await api(url);
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

// ─── Búsqueda ─────────────────────────────────────────────────────────────────
async function buscar(q) {
  const intent = q.length > 15 && /[a-záéíóúñ ]{10}/i.test(q);
  try {
    const { emails, explanation } = await api(
      `/api/emails/search?q=${encodeURIComponent(q)}${intent ? '&intent=1' : ''}`
    );
    const label = explanation ? `${explanation}` : `"${q}"`;
    $('#cat-title').textContent = label;
    renderEmails(emails, false, 'Sin resultados.', `No encontramos nada para "${q}".`);
    $('#btn-load-more').classList.add('hidden');
  } catch (e) { toast(e.message, 5000); }
}

// ─── Sincronización ───────────────────────────────────────────────────────────
async function sincronizar() {
  const btnR   = $('#btn-refresh');
  const banner = $('#sync-banner');
  if (btnR.disabled) return;
  btnR.disabled = true;
  banner.classList.remove('hidden');
  banner.textContent = 'Buscando correos nuevos…';
  try {
    const { started } = await api('/api/sync', { method: 'POST' });
    if (!started) { banner.textContent = 'Sincronización ya en curso…'; return; }
    const poll = setInterval(async () => {
      try {
        const st = await api('/api/sync/status');
        if (st.error) {
          clearInterval(poll);
          banner.classList.add('hidden');
          btnR.disabled = false;
          toast('No se pudo sincronizar: ' + st.error, 6000);
          return;
        }
        if (st.running) {
          banner.textContent = st.total
            ? `Clasificando… ${st.done} de ${st.total}`
            : 'Buscando correos nuevos…';
          if (st.done > 0 && st.done % 5 === 0) cargarBandeja();
        } else {
          clearInterval(poll);
          banner.classList.add('hidden');
          btnR.disabled = false;
          toast(st.total > 0 ? `${st.total} correo${st.total > 1 ? 's' : ''} nuevo${st.total > 1 ? 's' : ''}.` : 'Tu bandeja está al día.');
          cargarBandeja();
        }
      } catch { /* red momentánea */ }
    }, 1500);
  } catch (e) {
    banner.classList.add('hidden');
    btnR.disabled = false;
    toast(e.message, 5000);
  }
}

// ─── Vista de hilo ────────────────────────────────────────────────────────────
async function abrirHilo(threadId) {
  const { emails } = await api(`/api/threads/${threadId}`);
  threadActual = emails;
  const list = $('#thread-list');
  list.innerHTML = '';
  const first = emails[0];
  $('#thread-title').textContent = first?.asunto || '(sin asunto)';

  for (const e of emails) {
    const div = document.createElement('div');
    div.className = 'thread-message';
    div.innerHTML = `
      <div class="thread-msg-header">
        <span class="thread-msg-from">${escapeHtml(e.remitente || e.remitente_email || '(desconocido)')}</span>
        <span class="thread-msg-date">${fmtFecha(e.fecha)}</span>
      </div>
      <div class="thread-msg-body">${escapeHtml(e.cuerpo || e.snippet || '')}</div>
      <div class="thread-msg-actions">
        <button class="text-btn" onclick="abrirEmailDesdeHilo(${e.id})">Responder</button>
        <button class="text-btn muted" onclick="archivarDesdeHilo(${e.id})">Archivar</button>
      </div>`;
    list.appendChild(div);
  }
  show('thread');
}

window.abrirEmailDesdeHilo = async (id) => {
  await abrirEmail(id);
};
window.archivarDesdeHilo = async (id) => {
  await api(`/api/emails/${id}/archivar`, { method: 'POST' });
  toast('Archivado.');
  show('inbox');
  cargarBandeja();
};

// ─── Lector ───────────────────────────────────────────────────────────────────
async function abrirEmail(id) {
  deleteConfirm = false;
  const btnDel = $('#btn-delete');
  if (btnDel) { btnDel.textContent = 'Eliminar'; btnDel.classList.remove('btn-danger-text'); }

  const { email } = await api(`/api/emails/${id}`);
  emailActual = email;

  $('#r-resumen').textContent = email.resumen || '';
  const chip  = $('#cat-chip');
  const catKey = email.categoria || 'otros';
  chip.textContent = NOMBRES[catKey] || catKey;
  chip.className   = `cat-chip cat-${catKey}`;
  $('#otros-hint')?.classList.toggle('hidden', catKey !== 'otros');

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

  // Mostrar/ocultar botón de snooze (no en papelera)
  const snoozeBtn = $('#btn-snooze');
  if (snoozeBtn) snoozeBtn.classList.toggle('hidden', !!email.trashed);

  $('#reader').classList.remove('focus-mode');
  $('#btn-focus')?.classList.remove('active');
  show('reader');

  if (!email.leido) {
    emailActual.leido = 1;
    api(`/api/emails/${id}/leido`, { method: 'POST', body: { leido: true } }).catch(() => {});
  }
}

function actualizarBtnLeido(leido) {
  const btn = $('#btn-toggle-read');
  if (btn) btn.textContent = leido ? 'No leído' : 'Leído';
}
function actualizarBtnDestacado(destacado) {
  const btn = $('#btn-destacar');
  if (!btn) return;
  const svg = btn.querySelector('svg');
  if (svg) svg.setAttribute('fill', destacado ? 'currentColor' : 'none');
  btn.classList.toggle('starred', destacado);
  btn.setAttribute('aria-pressed', String(destacado));
}

// ─── Reclasificar ────────────────────────────────────────────────────────────
function renderReclassifyGrid(catActual) {
  const grid = $('#reclassify-grid');
  if (!grid) return;
  grid.innerHTML = '';
  for (const [key, nombre] of Object.entries(NOMBRES)) {
    if (key === 'papelera') continue;
    const btn = document.createElement('button');
    btn.className = 'recat-btn' + (key === catActual ? ' current' : '');
    btn.textContent = nombre; btn.dataset.cat = key;
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
    chip.textContent = NOMBRES[nuevaCat]; chip.className = `cat-chip cat-${nuevaCat}`;
    $('#otros-hint')?.classList.add('hidden');
    toast(`Movido a ${NOMBRES[nuevaCat]}`);
    if (catAnterior === 'otros' && remitente_email && nuevaCat !== 'otros') {
      ofrecerRegla(remitente_email, nuevaCat);
    }
  } catch (e) { toast(e.message, 5000); }
}

function ofrecerRegla(remitente_email, categoria) {
  const t = $('#toast');
  const dominio = remitente_email.split('@')[1] || remitente_email;
  t.innerHTML = `<span class="toast-msg">¿Clasificar siempre correos de <strong>${escapeHtml(dominio)}</strong> como ${NOMBRES[categoria]}?</span>
    <button class="toast-undo" onclick="crearRegla('${escapeHtml(remitente_email)}','${categoria}')">Sí</button>
    <button onclick="document.getElementById('toast').classList.add('hidden')" style="background:none;border:none;color:rgba(255,255,255,.6);cursor:pointer;margin-left:4px;font-size:16px">×</button>`;
  t.classList.remove('hidden');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.add('hidden'), 8000);
}

window.crearRegla = async (remitente_email, categoria) => {
  try {
    await api('/api/rules', { method: 'POST', body: { remitente_email, categoria } });
    toast(`Regla guardada para ${remitente_email.split('@')[1] || remitente_email}`);
  } catch { toast('No se pudo guardar la regla'); }
};

// ─── Snooze (posponer) ───────────────────────────────────────────────────────
function mostrarSnoozeDialog() {
  const dialog = $('#snooze-dialog');
  if (!dialog) return;
  dialog.classList.remove('hidden');
  // precargar las opciones con fechas reales
  const now = new Date();
  const hoy17 = new Date(now); hoy17.setHours(17, 0, 0, 0);
  const manana9 = new Date(now); manana9.setDate(now.getDate() + 1); manana9.setHours(9, 0, 0, 0);
  const prox9 = new Date(now); prox9.setDate(now.getDate() + 7); prox9.setHours(9, 0, 0, 0);

  document.getElementById('snooze-tarde')?.setAttribute('data-until', hoy17.toISOString());
  document.getElementById('snooze-manana')?.setAttribute('data-until', manana9.toISOString());
  document.getElementById('snooze-semana')?.setAttribute('data-until', prox9.toISOString());
}

async function aplicarSnooze(until) {
  if (!emailActual) return;
  try {
    await api(`/api/emails/${emailActual.id}/snooze`, { method: 'POST', body: { until } });
    const d = new Date(until);
    const label = d.toLocaleString('es', { weekday: 'short', hour: '2-digit', minute: '2-digit' });
    toast(`Recordatorio: ${label}`);
    $('#snooze-dialog')?.classList.add('hidden');
    show('inbox');
    cargarBandeja();
  } catch (e) { toast(e.message, 5000); }
}

// ─── Papelera ─────────────────────────────────────────────────────────────────
async function moverAPapelera(id) {
  const prevCat = emailActual?.categoria;
  await api(`/api/emails/${id}/trash`, { method: 'POST' });
  toastWithUndo('Movido a papelera.', async () => {
    await api(`/api/emails/${id}/restore`, { method: 'POST' });
    if (prevCat) await api(`/api/emails/${id}/reclasificar`, { method: 'POST', body: { categoria: prevCat } });
    cargarBandeja();
  });
  show('inbox');
  cargarBandeja();
}

// ─── Reglas ───────────────────────────────────────────────────────────────────
async function cargarReglas() {
  try {
    const { rules } = await api('/api/rules');
    const list  = $('#rules-list');
    const empty = $('#rules-empty');
    list.innerHTML = '';
    if (rules.length === 0) { empty.classList.remove('hidden'); return; }
    empty.classList.add('hidden');
    for (const r of rules) {
      const li = document.createElement('li');
      li.className = 'rule-item';
      li.innerHTML = `
        <div class="rule-info">
          <span class="rule-email">${escapeHtml(r.remitente_email)}</span>
          <span class="rule-cat cat-chip cat-${r.categoria}">${NOMBRES[r.categoria] || r.categoria}</span>
        </div>
        <button class="rule-delete icon-btn" data-id="${r.id}" aria-label="Eliminar regla">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>`;
      list.appendChild(li);
    }
    list.querySelectorAll('.rule-delete').forEach((btn) => {
      btn.onclick = async () => {
        try {
          await api(`/api/rules/${btn.dataset.id}`, { method: 'DELETE' });
          toast('Regla eliminada.');
          cargarReglas();
        } catch (e) { toast(e.message, 5000); }
      };
    });
  } catch (e) { toast(e.message, 5000); }
}

// ─── Pill / Navegación ────────────────────────────────────────────────────────
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
  if (searchActive) { $('#search-input').focus(); $('#cat-title').textContent = 'Buscar'; }
  else { $('#search-input').value = ''; cargarBandeja(true); }
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

// Toggle modo hilos
$('#btn-threads')?.addEventListener('click', () => {
  threadMode = !threadMode;
  $('#btn-threads')?.classList.toggle('active', threadMode);
  cargarBandeja(true);
});

// Papelera: vaciar
$('#btn-vaciar-papelera')?.addEventListener('click', async () => {
  if (!confirm('¿Eliminar definitivamente todos los correos de la papelera?')) return;
  await api('/api/emails/trashed/all', { method: 'DELETE' });
  toast('Papelera vaciada.');
  cargarBandeja(true);
});

// Hilo: back
$('#btn-thread-back')?.addEventListener('click', () => show('inbox'));

// ─── Lector: acciones ─────────────────────────────────────────────────────────
$('#btn-back').onclick = () => {
  $('#reader').classList.remove('focus-mode');
  $('#btn-focus')?.classList.remove('active');
  show('inbox');
  cargarBandeja();
};

$('#btn-focus')?.addEventListener('click', () => {
  const active = $('#reader').classList.toggle('focus-mode');
  $('#btn-focus').classList.toggle('active', active);
});

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
    actualizarBtnLeido(!nuevo); toast('No se pudo actualizar');
  }
};

$('#btn-archive').onclick = async () => {
  const prev = emailActual.categoria;
  try {
    await api(`/api/emails/${emailActual.id}/archivar`, { method: 'POST' });
    toastWithUndo(FRASES_ARCHIVO[Math.floor(Math.random() * FRASES_ARCHIVO.length)], async () => {
      await api(`/api/emails/${emailActual.id}/reclasificar`, { method: 'POST', body: { categoria: prev } });
      cargarBandeja();
    });
    show('inbox'); cargarBandeja();
  } catch (e) { toast(e.message, 5000); }
};

$('#btn-delete').onclick = async () => {
  if (emailActual?.trashed) {
    // En papelera: eliminar definitivamente
    if (!deleteConfirm) {
      deleteConfirm = true;
      $('#btn-delete').textContent = '¿Eliminar para siempre?';
      $('#btn-delete').classList.add('btn-danger-text');
      setTimeout(() => { deleteConfirm = false; $('#btn-delete').textContent = 'Eliminar'; $('#btn-delete').classList.remove('btn-danger-text'); }, 3000);
      return;
    }
    deleteConfirm = false;
    await api(`/api/emails/${emailActual.id}`, { method: 'DELETE' });
    toast('Eliminado definitivamente.');
    show('inbox'); cargarBandeja();
  } else {
    // Fuera de papelera: mover a papelera
    await moverAPapelera(emailActual.id);
  }
};

// Snooze
$('#btn-snooze')?.addEventListener('click', mostrarSnoozeDialog);
$('#snooze-close')?.addEventListener('click', () => $('#snooze-dialog')?.classList.add('hidden'));
document.querySelectorAll('[data-snooze]').forEach((btn) => {
  btn.addEventListener('click', () => {
    const until = btn.getAttribute('data-until');
    if (until) aplicarSnooze(until);
  });
});
document.getElementById('snooze-custom')?.addEventListener('change', (e) => {
  if (e.target.value) aplicarSnooze(new Date(e.target.value).toISOString());
});

// ─── IA: borrador ─────────────────────────────────────────────────────────────
$('#btn-gen-reply').onclick = async () => {
  const instruccion = $('#reply-instruction').value.trim();
  if (!instruccion) return toast('Escribe una instrucción primero');
  const btn = $('#btn-gen-reply');
  btn.disabled = true; btn.textContent = 'Generando…';
  try {
    const { borrador } = await api('/api/draft', { method: 'POST', body: { instruccion, emailId: emailActual.id } });
    $('#draft-body').value = borrador;
    $('#draft-area').classList.remove('hidden');
    $('#draft-body').focus();
  } catch (e) { toast(e.message, 5000); }
  finally { btn.disabled = false; btn.textContent = 'Generar borrador'; }
};

$('#btn-send-reply').onclick = async () => {
  const body = $('#draft-body').value.trim();
  if (!body) return toast('El borrador está vacío');
  const btn = $('#btn-send-reply');
  btn.disabled = true; btn.textContent = 'Enviando…';
  try {
    const asunto = emailActual.asunto?.startsWith('Re:') ? emailActual.asunto : `Re: ${emailActual.asunto || ''}`;
    await api('/api/send', { method: 'POST', body: { to: emailActual.remitente_email, subject: asunto, body, emailId: emailActual.id } });
    toast('Respuesta enviada');
    show('inbox'); cargarBandeja();
  } catch (e) { toast(e.message, 6000); }
  finally { btn.disabled = false; btn.textContent = 'Enviar respuesta'; }
};

// ─── Redactar ─────────────────────────────────────────────────────────────────
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
    $('#c-body').value = borrador; $('#c-body').focus();
  } catch (e) { toast(e.message, 5000); }
  finally { btn.disabled = false; btn.textContent = 'Redactar con IA'; }
};

$('#btn-compose-send').onclick = async () => {
  const to   = $('#c-to').value.trim();
  const body = $('#c-body').value.trim();
  if (!to)   return toast('Escribe un destinatario');
  if (!body) return toast('El correo está vacío');
  const btn = $('#btn-compose-send');
  btn.disabled = true;
  try {
    await api('/api/send', { method: 'POST', body: { to, subject: $('#c-subject').value.trim(), body } });
    toast('Correo enviado');
    show('inbox');
  } catch (e) { toast(e.message, 6000); }
  finally { btn.disabled = false; }
};

$('#btn-logout').onclick = async () => {
  await api('/api/auth/logout', { method: 'POST' });
  show('welcome');
};

// ─── Atajos de teclado ────────────────────────────────────────────────────────
document.addEventListener('keydown', (e) => {
  const tag    = document.activeElement?.tagName;
  const typing = tag === 'INPUT' || tag === 'TEXTAREA';
  const readerVisible = !$('#reader')?.classList.contains('hidden');
  const threadVisible = !$('#thread')?.classList.contains('hidden');

  if (e.key === 'Escape') {
    if (readerVisible) {
      $('#reader').classList.remove('focus-mode');
      $('#btn-focus')?.classList.remove('active');
      show('inbox'); cargarBandeja();
    } else if (threadVisible) { show('inbox'); }
    else if (!$('#composer').classList.contains('hidden')) { show('inbox'); }
    else if (!$('#snooze-dialog')?.classList.contains('hidden')) { $('#snooze-dialog').classList.add('hidden'); }
    else if (searchActive) {
      searchActive = false;
      $('#search-bar').classList.add('hidden');
      $('#btn-search').classList.remove('active');
      $('#search-input').value = '';
      cargarBandeja(true);
    }
  }

  if (typing) return;

  if ((e.key === 'f' || e.key === 'F') && readerVisible) {
    const active = $('#reader').classList.toggle('focus-mode');
    $('#btn-focus')?.classList.toggle('active', active);
  }
  if ((e.key === 'e' || e.key === 'E') && readerVisible && emailActual) {
    $('#btn-archive').click();
  }
  if ((e.key === 's' || e.key === 'S') && readerVisible && emailActual) {
    $('#btn-destacar').click();
  }
  if (e.key === '/' && !$('#inbox').classList.contains('hidden')) {
    e.preventDefault();
    $('#btn-search').click();
  }
});

// Colapsar título en scroll
window.addEventListener('scroll', () => {
  $('#cat-title')?.classList.toggle('collapsed', window.scrollY > 40);
}, { passive: true });

// ─── Arranque ─────────────────────────────────────────────────────────────────
(async () => {
  try {
    const { user } = await api('/api/me');
    if (!user) return show('welcome');
    if (user.picture) {
      const av = $('#user-avatar');
      if (av) { av.src = user.picture; av.classList.remove('hidden'); }
    }
    // Mostrar nombre de usuario en el avatar como fallback
    const av = $('#user-avatar');
    if (av && !user.picture) {
      av.alt = user.name?.[0] ?? user.email?.[0]?.toUpperCase() ?? '?';
    }
    show('inbox');
    await cargarBandeja(true);
    const { counts } = await api('/api/emails/counts');
    if (Object.values(counts).every(c => c.total === 0)) sincronizar();
  } catch { show('welcome'); }
})();
