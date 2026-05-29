const headers = { 'Content-Type': 'application/json' };

const qs = (id) => document.getElementById(id);

// [FIX] 401 응답 시 토큰 자동 갱신을 한 번 시도하는 래퍼
// refresh도 실패하면 로그인 화면으로 전환
let _refreshing = null;

async function request(path, options = {}) {
  const response = await fetch(path, { credentials: 'include', headers, ...options });

  if (response.status === 401) {
    // refresh 자체를 호출 중에 또 401이 오면 무한 루프 방지
    if (path === '/auth/refresh') {
      throw new Error('SESSION_EXPIRED');
    }

    // 동시에 여러 요청이 갱신을 시도하지 않도록 단일 Promise로 직렬화
    if (!_refreshing) {
      _refreshing = fetch('/auth/refresh', {
        method: 'POST',
        credentials: 'include',
        headers,
      }).finally(() => { _refreshing = null; });
    }

    const refreshRes = await _refreshing;
    if (!refreshRes.ok) {
      throw new Error('SESSION_EXPIRED');
    }

    // 갱신 성공 → 원래 요청 재시도
    const retryRes = await fetch(path, { credentials: 'include', headers, ...options });
    if (!retryRes.ok) {
      const body = await retryRes.json().catch(() => ({}));
      throw new Error(body.detail || '요청을 처리하지 못했습니다.');
    }
    if (retryRes.status === 204) return null;
    return retryRes.json();
  }

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.detail || '요청을 처리하지 못했습니다.');
  }
  if (response.status === 204) return null;
  return response.json();
}

function setMessage(id, text, isError = false) {
  const el = qs(id);
  el.textContent = text;
  el.classList.toggle('error', isError);
}

function option(value, label) {
  const el = document.createElement('option');
  el.value = value;
  el.textContent = label;
  return el;
}

// 세션 만료 처리: 로그인 화면으로 전환
function handleSessionExpired() {
  qs('appPanel').classList.add('hidden');
  qs('logoutBtn').classList.add('hidden');
  qs('loginPanel').classList.remove('hidden');
  setMessage('loginMessage', '세션이 만료되었습니다. 다시 로그인해 주세요.', true);
}

async function bootstrap() {
  const me = await request('/portal/me');
  qs('userLabel').textContent = me.password_expired
    ? `${me.email} 계정으로 접속 중 · 비밀번호 변경 필요`
    : `${me.email} 계정으로 접속 중`;
  qs('loginPanel').classList.add('hidden');
  qs('appPanel').classList.remove('hidden');
  qs('logoutBtn').classList.remove('hidden');
  await Promise.all([loadTypes(), loadDepartments(), loadAppointments()]);
  await loadSlots();
}

async function loadTypes() {
  const rows = await request('/portal/appointment-types');
  qs('typeCode').replaceChildren(...rows.map((row) => option(row.type_code, row.type_name)));
}

async function loadDepartments() {
  const rows = await request('/portal/departments');
  qs('departmentCode').replaceChildren(...rows.map((row) => option(row.department_code, row.department_name)));
  await loadDoctors();
}

async function loadDoctors() {
  const dept = qs('departmentCode').value;
  const rows = await request(`/portal/doctors?department_code=${encodeURIComponent(dept)}`);
  qs('doctorId').replaceChildren(option('', '선택 안 함'), ...rows.map((row) => option(row.doctor_id, row.doctor_name)));
}

async function loadSlots() {
  const date = qs('appointmentDate').value;
  const dept = qs('departmentCode').value;
  const doctor = qs('doctorId').value;
  if (!date || !dept) return;
  const params = new URLSearchParams({ date, department_code: dept });
  if (doctor) params.set('doctor_id', doctor);
  const rows = await request(`/portal/appointments/available-slots?${params.toString()}`);
  const available = rows.filter((row) => row.available);
  qs('appointmentTime').replaceChildren(...available.map((row) => option(row.time, row.time)));
}

async function loadAppointments() {
  const rows = await request('/portal/appointments');
  const container = qs('appointments');
  if (!rows.length) {
    container.innerHTML = '<p class="empty">예약 내역이 없습니다.</p>';
    return;
  }
  container.replaceChildren(...rows.map((row) => {
    const item = document.createElement('article');
    item.className = 'appointment';
    const canCancel = ['pending', 'confirmed'].includes(row.status_code);
    const cancelButton = canCancel
      ? `<button class="danger-button" data-cancel="${row.appointment_id}" type="button">취소</button>`
      : '';

    // [FIX] doctor_name이 있으면 표시, 없으면 department_code만 표시
    const doctorLabel = row.doctor_name ? ` · ${row.doctor_name}` : '';

    item.innerHTML = `
      <div class="appointment-main">
        <strong>${row.appointment_date} ${row.appointment_time}</strong>
        <span>${row.type_name || row.type_code} / ${row.department_code}${doctorLabel}</span>
        <small class="status status-${row.status_code}">${row.status_name || row.status_code}</small>
      </div>
      ${cancelButton}
    `;
    return item;
  }));
}

async function cancelAppointment(id) {
  const reason = window.prompt('예약 취소 사유를 입력하세요.', 'GCP DR 환자 요청');
  if (reason === null) return;
  try {
    await request(`/portal/appointments/${id}/cancel`, {
      method: 'POST',
      body: JSON.stringify({ cancel_reason: reason || 'GCP DR 환자 요청' }),
    });
    setMessage('appointmentMessage', '예약이 취소되었습니다.');
    await Promise.all([loadSlots(), loadAppointments()]);
  } catch (error) {
    if (error.message === 'SESSION_EXPIRED') { handleSessionExpired(); return; }
    setMessage('appointmentMessage', error.message, true);
  }
}

// ── 이벤트 리스너 ──────────────────────────────────────────────────────────────

qs('loginForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    await request('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email: qs('email').value, password: qs('password').value }),
    });
    setMessage('loginMessage', '');
    await bootstrap();
  } catch (error) {
    setMessage('loginMessage', error.message, true);
  }
});

qs('appointmentForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    await request('/portal/appointments', {
      method: 'POST',
      body: JSON.stringify({
        type_code: qs('typeCode').value,
        department_code: qs('departmentCode').value,
        doctor_id: qs('doctorId').value || null,
        appointment_date: qs('appointmentDate').value,
        appointment_time: qs('appointmentTime').value,
        notes: qs('notes').value,
      }),
    });
    setMessage('appointmentMessage', '예약이 접수되었습니다.');
    await Promise.all([loadSlots(), loadAppointments()]);
  } catch (error) {
    if (error.message === 'SESSION_EXPIRED') { handleSessionExpired(); return; }
    setMessage('appointmentMessage', error.message, true);
  }
});

qs('departmentCode').addEventListener('change', async () => {
  await loadDoctors();
  await loadSlots();
});
qs('doctorId').addEventListener('change', loadSlots);
qs('appointmentDate').addEventListener('change', loadSlots);
qs('refreshBtn').addEventListener('click', loadAppointments);

qs('appointments').addEventListener('click', async (event) => {
  const button = event.target.closest('[data-cancel]');
  if (!button) return;
  await cancelAppointment(button.dataset.cancel);
});

qs('logoutBtn').addEventListener('click', async () => {
  await request('/auth/logout', { method: 'POST' }).catch(() => {});
  window.location.reload();
});

// ── 초기화 ─────────────────────────────────────────────────────────────────────

const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
qs('appointmentDate').value = tomorrow;

bootstrap().catch((error) => {
  if (error.message === 'SESSION_EXPIRED') {
    handleSessionExpired();
  } else {
    qs('loginPanel').classList.remove('hidden');
  }
});
