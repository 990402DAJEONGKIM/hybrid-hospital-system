// ── 사이드바 렌더링 ──────────────────────────────────────────
async function renderSidebar(activePage) {
    const el = document.getElementById('portalSidebar');
    if (!el) return;

    const links = [
        { href: 'appointment.html',       icon: 'fa-calendar-plus',  label: '예약 신청' },
        { href: 'my-appointments.html',   icon: 'fa-calendar-check', label: '예약조회·변경' },
        { href: 'my-records.html',        icon: 'fa-notes-medical',  label: '진료기록' },
        { href: 'mypage.html',            icon: 'fa-user-circle',    label: '내 정보' },
        { href: 'change-password.html',   icon: 'fa-key',            label: '비밀번호 변경' },
    ];

    let patientName = '';
    let memberNumber = '';
    try {
        const [meRes, profileRes] = await Promise.all([
            fetch(`${BASE_URL}/auth/me`, { credentials: 'include', headers: { 'X-API-Key': API_KEY } }),
            fetch(`${BASE_URL}/portal/my-profile`, { credentials: 'include', headers: { 'X-API-Key': API_KEY } }),
        ]);
        if (meRes.ok) { const me = await meRes.json(); memberNumber = me.member_number || ''; }
        if (profileRes.ok) { const p = await profileRes.json(); patientName = p.patient_name || ''; }
    } catch {}

    el.innerHTML = `
        <div style="padding:14px 20px 12px;border-bottom:1px solid #e8ecf0;">
            <a href="index.html" style="display:flex;align-items:center;gap:7px;font-size:14px;font-weight:700;color:var(--primary);text-decoration:none;">
                <i class="fas fa-heartbeat"></i>김이박 클리닉
            </a>
            <a href="index.html" style="display:inline-flex;align-items:center;gap:5px;margin-top:6px;font-size:12px;color:#90a4ae;text-decoration:none;">
                <i class="fas fa-arrow-left" style="font-size:10px;"></i>홈으로
            </a>
        </div>
        <div class="sidebar-patient">
            <div class="name">${patientName ? patientName + '님' : '환자 포털'}</div>
            ${memberNumber ? `<div class="member">회원번호: ${memberNumber}</div>` : ''}
        </div>
        <div class="sidebar-label">메뉴</div>
        ${links.map(l => `
            <a href="${l.href}" class="sidebar-link${activePage === l.href ? ' active' : ''}">
                <i class="fas ${l.icon}"></i>${l.label}
            </a>`).join('')}
        <div style="margin-top:auto;padding:20px 20px 0;">
            <button onclick="logout()" style="width:100%;padding:8px;background:#f5f5f5;border:1px solid #e0e0e0;border-radius:6px;font-size:12px;color:#546e7a;cursor:pointer;">
                <i class="fas fa-sign-out-alt" style="margin-right:6px;"></i>로그아웃
            </button>
        </div>`;
}

// ── 공통 fetch 옵션 ────────────────────────────────────────
const _fetchDefaults = {
    credentials: 'include',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
};

async function _refreshTokens() {
    try {
        const res = await fetch(`${BASE_URL}/auth/refresh`, { method: 'POST', ..._fetchDefaults });
        return res.ok;
    } catch { return false; }
}

let _sessionWarnShown = false;
function _showSessionWarning(remaining) {
    if (_sessionWarnShown) return;
    _sessionWarnShown = true;
    const mins = Math.ceil(remaining / 60);
    // 배너가 없으면 동적 생성
    let banner = document.getElementById('_sessionWarnBanner');
    if (!banner) {
        banner = document.createElement('div');
        banner.id = '_sessionWarnBanner';
        banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;background:#ff9800;color:#fff;text-align:center;padding:10px;font-weight:bold;';
        banner.innerHTML = `세션이 약 ${mins}분 후 만료됩니다.
            <button onclick="extendSession()" style="margin-left:12px;padding:4px 12px;background:#fff;color:#ff9800;border:none;border-radius:4px;font-weight:bold;cursor:pointer;">세션 연장</button>`;
        document.body.prepend(banner);
    }
}
async function extendSession() {
    const ok = await _refreshTokens();
    if (ok) {
        _sessionWarnShown = false;
        const b = document.getElementById('_sessionWarnBanner');
        if (b) b.remove();
    } else {
        logout();
    }
}

async function apiCall(path, options = {}) {
    const res = await fetch(`${BASE_URL}${path}`, {
        ..._fetchDefaults,
        ...options,
        headers: { ..._fetchDefaults.headers, ...(options.headers || {}) },
    });
    if (res && res.headers.get('X-Session-Expiring-Soon') === 'true') {
        _showSessionWarning(parseInt(res.headers.get('X-Session-Remaining-Seconds') || '300'));
    }
    if (res.status === 401) {
        const ok = await _refreshTokens();
        if (!ok) { logout(); return null; }
        return fetch(`${BASE_URL}${path}`, {
            ..._fetchDefaults,
            ...options,
            headers: { ..._fetchDefaults.headers, ...(options.headers || {}) },
        });
    }
    return res;
}

async function logout() {
    try { await fetch(`${BASE_URL}/auth/logout`, { method: 'POST', ..._fetchDefaults }); } catch {}
    window.location.href = 'login.html';
}

async function requireLogin() {
    try {
        const res = await apiCall('/auth/me');
        if (!res || !res.ok) { window.location.href = 'login.html'; return null; }
        const me = await res.json();
        if (me.role !== 'patient') { window.location.href = 'login.html'; return null; }
        // must_change_password=true 또는 비밀번호 만료 시 변경 페이지 강제 이동 (SFR-038)
        if (me.must_change_password || me.password_expired) {
            if (!window.location.pathname.includes('change-password.html')) {
                window.location.href = 'change-password.html';
            }
            return null;
        }
        return me;
    } catch {
        window.location.href = 'login.html';
        return null;
    }
}

// ── DOMContentLoaded ──────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {

    // 소프트 인증: 미로그인 시 리다이렉트 대신 UI 분기
    let me = null;
    try {
        const res = await fetch(`${BASE_URL}/auth/me`, {
            credentials: 'include',
            headers: { 'X-API-Key': API_KEY },
        });
        if (res && res.ok) {
            const data = await res.json();
            if (data.role === 'patient') me = data;
        }
    } catch {}

    // 로그인 버튼 vs 사용자 정보 전환
    const loginBtnWrap = document.getElementById('nav-login-btn-wrap');
    const appointmentBtnWrap = document.getElementById('nav-appointment-btn-wrap');
    if (me) {
        if (loginBtnWrap)       loginBtnWrap.classList.add('hidden');
        if (appointmentBtnWrap) appointmentBtnWrap.classList.remove('hidden');
    } else {
        if (loginBtnWrap)       loginBtnWrap.classList.remove('hidden');
        if (appointmentBtnWrap) appointmentBtnWrap.classList.add('hidden');
    }

    // 미로그인 시: 랜딩 섹션만 표시하고 종료
    if (!me) {
        const landingSection = document.getElementById('landing-section');
        const appointmentSection = document.getElementById('appointment-section');
        if (landingSection)      landingSection.classList.remove('hidden');
        if (appointmentSection)  appointmentSection.classList.add('hidden');
        return;
    }

    // must_change_password 또는 비밀번호 만료 시 변경 페이지 강제 이동 (SFR-038)
    // 이미 change-password.html이면 리다이렉트 생략 (무한루프 방지)
    if (me.must_change_password || me.password_expired) {
        if (!window.location.pathname.includes('change-password.html')) {
            window.location.href = 'change-password.html';
        }
        return;
    }

    const header           = document.querySelector('.sass-header');
    const mobileMenuBtn    = document.getElementById('sassMobileMenuBtn');
    const mobileMenuClose  = document.getElementById('sassMobileMenuClose');
    const mobileMenu       = document.getElementById('sassMobileMenu');
    const overlay          = document.getElementById('sassOverlay');

    const appointmentSection    = document.getElementById('appointment-section');
    const calendarGridContainer = document.querySelector('.calendar-grid-container');
    const calendarGrid          = document.getElementById('calendar-grid');

    // 달력 요소가 없으면 index.html이 아닌 서브페이지 — 이 핸들러 종료
    if (!calendarGrid) return;
    const monthYearDisplay      = document.getElementById('currentMonthYear');
    const prevMonthBtn          = document.getElementById('prevMonth');
    const nextMonthBtn          = document.getElementById('nextMonth');
    const calendarModal         = document.getElementById('calendarModal');
    const modalDateHeader       = document.getElementById('modalDateHeader');
    const modalAppointmentList  = document.getElementById('modalAppointmentList');
    const closeCalendarModal    = document.getElementById('closeCalendarModal');
    const modalConfirmBtn       = document.getElementById('modalConfirmBtn');

    const navHome                 = document.getElementById('nav-home');
    const mobileNavHome           = document.getElementById('mobile-nav-home');
    const manageAppointmentsBtn   = document.getElementById('nav-manage-appointments');
    const navNewAppointmentBtn    = document.getElementById('nav-new-appointment');
    const navMyRecordsBtn         = document.getElementById('nav-my-records');
    const navMypageBtn            = document.getElementById('nav-mypage');
    const navChangePasswordBtn    = document.getElementById('nav-change-password');
    const logoutBtn               = document.getElementById('logoutBtn');
    const userWelcomeItem         = document.getElementById('userWelcomeItem');
    const userWelcome             = document.getElementById('userWelcome');

    const editAppointmentModal = document.getElementById('editAppointmentModal');
    const editAppDateInput     = document.getElementById('editAppDate');
    const editAppDeptSelect    = document.getElementById('editAppDept');
    const closeEditModal       = document.getElementById('closeEditModal');
    const cancelEditBtn        = document.getElementById('cancelEditBtn');
    const saveEditBtn          = document.getElementById('saveEditBtn');
    let currentEditEncounterId = null;



    // ── 헤더 ────────────────────────────────────────────────
    window.addEventListener('scroll', () => {
        header.classList.toggle('sass-header-scrolled', window.scrollY > 50);
    });
    const toggleMenu = () => {
        mobileMenu.classList.toggle('sass-active');
        overlay.classList.toggle('sass-active');
        document.body.style.overflow = mobileMenu.classList.contains('sass-active') ? 'hidden' : '';
    };
    if (mobileMenuBtn)   mobileMenuBtn.addEventListener('click', toggleMenu);
    if (mobileMenuClose) mobileMenuClose.addEventListener('click', toggleMenu);
    if (overlay)         overlay.addEventListener('click', toggleMenu);

    // 환자 이름 헤더 표시
    try {
        const profileRes = await apiCall('/portal/my-profile');
        if (profileRes && profileRes.ok) {
            const profile = await profileRes.json();
            if (userWelcome) {
                userWelcome.textContent = profile.patient_name
                    ? `${profile.patient_name}님`
                    : '환영합니다';
            }
        } else {
            if (userWelcome) userWelcome.textContent = '환영합니다';
        }
    } catch {
        if (userWelcome) userWelcome.textContent = '환영합니다';
    }
    if (userWelcomeItem) userWelcomeItem.classList.remove('hidden');
    if (logoutBtn)       logoutBtn.classList.remove('hidden');
    if (logoutBtn)       logoutBtn.addEventListener('click', logout);

    // ── 달력 ────────────────────────────────────────────────
    let currentDate   = new Date();
    let appointmentsMap = {};

    const STATUS_LABEL = {
        pending: '대기', confirmed: '확정',
        cancelled: '취소', completed: '완료', no_show: '미내원',
    };
    let DEPT_LABEL = {};
    let _deptList  = [];
    apiCall('/portal/departments').then(r => r && r.ok && r.json()).then(list => {
        if (!list) return;
        _deptList = list;
        list.forEach(d => { DEPT_LABEL[d.department_code] = d.department_name; });
    }).catch(() => {});

    async function loadAppointments() {
        appointmentsMap = {};
        try {
            const res = await apiCall('/portal/appointments');
            if (!res || !res.ok) return;
            const list = await res.json();
            list.forEach(appt => {
                const date = appt.appointment_date;
                if (!appointmentsMap[date]) appointmentsMap[date] = [];
                appointmentsMap[date].push(appt);
            });
        } catch {}
    }

    const renderCalendar = () => {
        calendarGrid.innerHTML = '';
        const year  = currentDate.getFullYear();
        const month = currentDate.getMonth();
        monthYearDisplay.innerText = `${year}년 ${month + 1}월`;
        const firstDay    = new Date(year, month, 1).getDay();
        const daysInMonth = new Date(year, month + 1, 0).getDate();
        const numWeeks    = Math.ceil((firstDay + daysInMonth) / 7);
        if (calendarGridContainer) calendarGridContainer.style.gridTemplateRows = `auto repeat(${numWeeks}, 1fr)`;
        const today       = new Date();
        const isThisMonth = today.getFullYear() === year && today.getMonth() === month;

        for (let i = 0; i < firstDay; i++) {
            const empty = document.createElement('div');
            empty.className = 'bg-gray-50/50 min-h-[120px] border-b border-r border-gray-100';
            calendarGrid.appendChild(empty);
        }
        for (let day = 1; day <= daysInMonth; day++) {
            const dateString = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
            const dayOfWeek  = new Date(year, month, day).getDay();
            const dayCell    = document.createElement('div');
            dayCell.className = 'calendar-day';
            if (dayOfWeek === 0) dayCell.classList.add('is-sunday');
            if (dayOfWeek === 6) dayCell.classList.add('is-saturday');
            if (isThisMonth && today.getDate() === day) dayCell.classList.add('is-today');
            dayCell.innerHTML = `<span class="day-number">${day}</span>`;
            const appts = appointmentsMap[dateString];
            if (appts && appts.length > 0) {
                const badge = document.createElement('div');
                badge.className = 'mt-1 w-full text-[10px] px-2 py-1 bg-blue-100 text-blue-700 rounded-md font-bold truncate';
                badge.innerText = `예약 ${appts.length}건`;
                dayCell.appendChild(badge);
            }
            dayCell.addEventListener('click', () => showAppointments(dateString));
            calendarGrid.appendChild(dayCell);
        }
    };

    const showAppointments = (date) => {
        modalDateHeader.innerText = date;
        modalAppointmentList.innerHTML = '';
        const appts = appointmentsMap[date];
        if (appts && appts.length > 0) {
            appts.forEach(appt => {
                const item = document.createElement('div');
                item.className = 'p-3 bg-blue-50 border-l-4 border-blue-500 text-blue-800 text-sm rounded';
                item.innerText = `${appt.appointment_time || ''} ${DEPT_LABEL[appt.department_code] || appt.department_code || '-'} · ${STATUS_LABEL[appt.status_code] || appt.status_code}`;
                modalAppointmentList.appendChild(item);
            });
        } else {
            modalAppointmentList.innerHTML = '<p class="text-gray-500 text-center py-4">해당 날짜에 예약 내역이 없습니다.</p>';
        }
        calendarModal.classList.remove('hidden');
        calendarModal.classList.add('flex');
        document.body.style.overflow = 'hidden';
    };

    const hideModal = () => {
        calendarModal.classList.add('hidden');
        calendarModal.classList.remove('flex');
        document.body.style.overflow = '';
    };

    if (prevMonthBtn)        prevMonthBtn.addEventListener('click', () => { currentDate.setMonth(currentDate.getMonth() - 1); renderCalendar(); });
    if (nextMonthBtn)        nextMonthBtn.addEventListener('click', () => { currentDate.setMonth(currentDate.getMonth() + 1); renderCalendar(); });
    if (closeCalendarModal)  closeCalendarModal.addEventListener('click', hideModal);
    if (modalConfirmBtn)     modalConfirmBtn.addEventListener('click', hideModal);

    if (manageAppointmentsBtn) manageAppointmentsBtn.addEventListener('click', (e) => { e.preventDefault(); window.location.href = 'my-appointments.html'; });


    // ── 예약 수정 ───────────────────────────────────────────
    const openEditModalFn = (appt) => {
        currentEditEncounterId = appt.appointment_id;
        editAppDateInput.value = appt.appointment_date;
        if (editAppDeptSelect) {
            editAppDeptSelect.innerHTML = '<option value="">진료과 선택</option>';
            _deptList.forEach(d => {
                const o = document.createElement('option');
                o.value = d.department_code;
                o.textContent = d.department_name;
                if (d.department_code === appt.department_code) o.selected = true;
                editAppDeptSelect.appendChild(o);
            });
        }
        editAppointmentModal.classList.remove('hidden');
        editAppointmentModal.classList.add('flex');
        document.body.style.overflow = 'hidden';
    };
    const closeEditModalFn = () => {
        currentEditEncounterId = null;
        editAppointmentModal.classList.add('hidden');
        editAppointmentModal.classList.remove('flex');
        document.body.style.overflow = '';
    };
    if (closeEditModal) closeEditModal.addEventListener('click', closeEditModalFn);
    if (cancelEditBtn)  cancelEditBtn.addEventListener('click', closeEditModalFn);
    if (saveEditBtn) {
        saveEditBtn.addEventListener('click', async () => {
            if (!currentEditEncounterId) return;
            const body = {};
            if (editAppDateInput.value)              body.appointment_date  = editAppDateInput.value;
            if (editAppDeptSelect && editAppDeptSelect.value) body.department_code = editAppDeptSelect.value;
            saveEditBtn.disabled = true;
            const res = await apiCall(`/portal/appointments/${currentEditEncounterId}`, {
                method: 'PATCH',
                body: JSON.stringify(body),
            });
            saveEditBtn.disabled = false;
            if (!res || !res.ok) {
                const err = await res?.json().catch(() => ({}));
                alert(err.detail || '수정에 실패했습니다.');
                return;
            }
            closeEditModalFn();
            await loadAppointments();
            renderCalendar();
            renderMyAppointments();
        });
    }

    window.deleteAppointment = async (encounterId) => {
        if (!confirm('예약을 취소하시겠습니까?')) return;
        const res = await apiCall(`/portal/appointments/${encounterId}`, { method: 'DELETE' });
        if (!res || !res.ok) {
            const err = await res?.json().catch(() => ({}));
            alert(err.detail || '취소에 실패했습니다.');
            return;
        }
        await loadAppointments();
        renderCalendar();
        renderMyAppointments();
    };

    const closeMenuIfOpen = () => {
        if (mobileMenu && mobileMenu.classList.contains('sass-active')) toggleMenu();
    };

    if (navNewAppointmentBtn)    navNewAppointmentBtn.addEventListener('click', (e) => { e.preventDefault(); window.location.href = 'appointment.html'; });
    if (navMyRecordsBtn)         navMyRecordsBtn.addEventListener('click', (e) => { e.preventDefault(); window.location.href = 'my-records.html'; });
    if (navMypageBtn)            navMypageBtn.addEventListener('click', (e) => { e.preventDefault(); window.location.href = 'mypage.html'; });
    if (navChangePasswordBtn)    navChangePasswordBtn.addEventListener('click', (e) => { e.preventDefault(); window.location.href = 'change-password.html'; });
    if (manageAppointmentsBtn)   manageAppointmentsBtn.addEventListener('click', (e) => { e.preventDefault(); window.location.href = 'my-appointments.html'; });
    if (navHome)                 navHome.addEventListener('click', async (e) => { e.preventDefault(); closeMenuIfOpen(); });
    if (mobileNavHome)           mobileNavHome.addEventListener('click', async (e) => { e.preventDefault(); closeMenuIfOpen(); });

    // ── 진료과 드롭다운 동적 로드 ────────────────────────────
    const deptDropdown = document.getElementById('deptDropdown');
    if (deptDropdown) {
        try {
            const r = await apiCall('/portal/departments');
            if (r && r.ok) {
                const depts = await r.json();
                deptDropdown.innerHTML = depts.map(d =>
                    `<a href="/department.html?code=${d.department_code}" class="sass-dropdown-link">${d.department_name}</a>`
                ).join('');
            }
        } catch (_) { /* 드롭다운 실패 시 무시 */ }
    }

    // ── 초기 로드 ────────────────────────────────────────────
    await loadAppointments();
    renderCalendar();
});
