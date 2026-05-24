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

// ── 세션 만료 경고 배너 ──────────────────────────────────────
let _sessionWarnShown = false;

function _showSessionWarning(remaining) {
    if (_sessionWarnShown) return;
    _sessionWarnShown = true;
    const mins = Math.ceil(remaining / 60);
    let banner = document.getElementById('_sessionWarnBanner');
    if (!banner) {
        banner = document.createElement('div');
        banner.id = '_sessionWarnBanner';
        banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;background:#ff9800;color:#fff;text-align:center;padding:10px 16px;font-weight:bold;font-size:14px;';
        banner.innerHTML = `세션이 약 ${mins}분 후 만료됩니다.
            <button onclick="extendSession()" style="margin-left:12px;padding:4px 14px;background:#fff;color:#ff9800;border:none;border-radius:4px;font-weight:bold;cursor:pointer;">세션 연장</button>`;
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
    const res = await apiCall('/auth/me');
    if (!res || !res.ok) { window.location.href = 'login.html'; return null; }
    const me = await res.json();
    if (!['doctor', 'nurse', 'admin'].includes(me.role)) { window.location.href = 'login.html'; return null; }
    if (me.password_expired) { window.location.href = 'change-password.html'; return null; }
    return me;
}

// ── DOMContentLoaded ──────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {

    const me = await requireLogin();
    if (!me) return;

    const header           = document.querySelector('.sass-header');
    const mobileMenuBtn    = document.getElementById('sassMobileMenuBtn');
    const mobileMenuClose  = document.getElementById('sassMobileMenuClose');
    const mobileMenu       = document.getElementById('sassMobileMenu');
    const overlay          = document.getElementById('sassOverlay');

    const appointmentSection       = document.getElementById('appointment-section');
    const patientManagementSection = document.getElementById('patient-management-section');
    const hospitalIntroSection     = document.getElementById('hospital-intro-section');
    const calendarGridContainer    = document.querySelector('.calendar-grid-container');
    const calendarGrid             = document.getElementById('calendar-grid');
    const monthYearDisplay         = document.getElementById('currentMonthYear');
    const prevMonthBtn             = document.getElementById('prevMonth');
    const nextMonthBtn             = document.getElementById('nextMonth');
    const calendarModal            = document.getElementById('calendarModal');
    const modalDateHeader          = document.getElementById('modalDateHeader');
    const modalAppointmentList     = document.getElementById('modalAppointmentList');
    const closeCalendarModal       = document.getElementById('closeCalendarModal');
    const modalConfirmBtn          = document.getElementById('modalConfirmBtn');

    const navHome                     = document.getElementById('nav-home');
    const mobileNavHome               = document.getElementById('mobile-nav-home');
    const navHospitalIntro            = document.getElementById('nav-hospital-intro');
    const mobileNavHospitalIntro      = document.getElementById('mobile-nav-hospital-intro');
    const navDoctorAppointmentsStatus = document.getElementById('nav-doctor-appointments-status');
    const navPatientInfoManagement    = document.getElementById('nav-patient-info-management');
    const logoutBtn                   = document.getElementById('logoutBtn');
    const userWelcomeItem             = document.getElementById('userWelcomeItem');
    const userWelcome                 = document.getElementById('userWelcome');

    const patientTableBody    = document.getElementById('patientTableBody');
    const patientSearchInput  = document.getElementById('patientSearchInput');
    const patientSearchBtn    = document.getElementById('patientSearchBtn');

    const patientDetailModal      = document.getElementById('patientDetailModal');
    const closePatientDetailModal = document.getElementById('closePatientDetailModal');
    const closePatientDetailBtn   = document.getElementById('closePatientDetailBtn');
    const patientAgeInput         = document.getElementById('patientAge');
    const patientDiagnosisInput   = document.getElementById('patientDiagnosis');

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

    if (userWelcome)     userWelcome.textContent = `${me.role} 님 환영합니다`;
    if (userWelcomeItem) userWelcomeItem.classList.remove('hidden');
    if (logoutBtn)       logoutBtn.classList.remove('hidden');
    if (logoutBtn)       logoutBtn.addEventListener('click', logout);

    // ── 달력 (의료진 — 전체 예약현황 조회) ─────────────────
    let currentDate   = new Date();
    let appointmentsMap = {};

    const STATUS_LABEL = {
        pending: '대기', confirmed: '확정',
        cancelled: '취소', completed: '완료', no_show: '미내원',
    };
    let DEPT_LABEL = {};
    apiCall('/portal/doctor/staff/departments').then(r => r && r.ok && r.json()).then(list => {
        if (list) list.forEach(d => { DEPT_LABEL[d.department_code] = d.department_name; });
    }).catch(() => {});

    async function loadAppointments() {
        appointmentsMap = {};
        try {
            const res = await apiCall('/portal/doctor/schedule');
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
                const deptLabel   = DEPT_LABEL[appt.department_code] || appt.department_code;
                const statusLabel = STATUS_LABEL[appt.status_code]   || appt.status_code;
                item.innerText = `${deptLabel} · ${statusLabel} | 환자 ${appt.patient_id_hash?.slice(0, 8) || '-'}…`;
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

    if (prevMonthBtn)       prevMonthBtn.addEventListener('click', () => { currentDate.setMonth(currentDate.getMonth() - 1); renderCalendar(); });
    if (nextMonthBtn)       nextMonthBtn.addEventListener('click', () => { currentDate.setMonth(currentDate.getMonth() + 1); renderCalendar(); });
    if (closeCalendarModal) closeCalendarModal.addEventListener('click', hideModal);
    if (modalConfirmBtn)    modalConfirmBtn.addEventListener('click', hideModal);

    // ── 환자 목록 ────────────────────────────────────────────
    let patientsList = [];

    async function loadPatients() {
        try {
            const res = await apiCall('/portal/doctor/patients');
            if (!res || !res.ok) return;
            patientsList = await res.json();
        } catch { patientsList = []; }
    }

    const GENDER_LABEL = { M: '남', F: '여' };

    const renderPatientList = (query = '') => {
        const filtered = patientsList.filter(p =>
            p.patient_id_hash.includes(query) || String(p.birth_year).includes(query)
        );
        patientTableBody.innerHTML = filtered.map(p => `
            <tr class="bg-white border-b hover:bg-gray-50">
                <td class="px-4 py-3 font-mono text-xs text-gray-500">${p.patient_id_hash}</td>
                <td class="px-4 py-3">${p.birth_year}년생</td>
                <td class="px-4 py-3">${GENDER_LABEL[p.gender_code] || p.gender_code}</td>
                <td class="px-4 py-3">${p.last_visit || '-'}</td>
                <td class="px-4 py-3">
                    <button onclick="viewPatientDetail('${p.patient_id_hash}')"
                        class="px-2 py-1 bg-blue-50 text-blue-600 border border-blue-200 rounded text-xs font-bold hover:bg-blue-100 transition-colors">
                        상세 조회
                    </button>
                </td>
            </tr>
        `).join('');
    };

    window.viewPatientDetail = async (patientIdHash) => {
        const res = await apiCall(`/portal/doctor/patients/${patientIdHash}`);
        if (!res || !res.ok) { alert('상세 정보를 불러올 수 없습니다.'); return; }
        const data = await res.json();
        const p       = data.patient;
        const allergy = data.allergies?.map(a => `${a.allergy_name}(${a.severity_code})`).join(', ') || '없음';
        const surgery = data.surgeries?.map(s => `${s.surgery_name}(${s.surgery_date})`).join(', ') || '없음';
        const diag    = data.diagnoses?.map(d => d.diagnosis_code).join(', ') || '없음';

        if (patientAgeInput)       patientAgeInput.value       = `${p.birth_year}년생`;
        if (patientDiagnosisInput) patientDiagnosisInput.value = `진단: ${diag}\n알레르기: ${allergy}\n수술: ${surgery}`;

        patientDetailModal.classList.remove('hidden');
        patientDetailModal.classList.add('flex');
        document.body.style.overflow = 'hidden';
    };

    const closePatientDetailFn = () => {
        patientDetailModal.classList.add('hidden');
        patientDetailModal.classList.remove('flex');
        document.body.style.overflow = '';
    };
    if (closePatientDetailModal) closePatientDetailModal.addEventListener('click', closePatientDetailFn);
    if (closePatientDetailBtn)   closePatientDetailBtn.addEventListener('click', closePatientDetailFn);

    if (patientSearchBtn) patientSearchBtn.addEventListener('click', () => renderPatientList(patientSearchInput.value.trim()));
    if (patientSearchInput) patientSearchInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') renderPatientList(patientSearchInput.value.trim());
    });

    // ── 섹션 전환 ───────────────────────────────────────────
    const showSection = async (sectionId) => {
        appointmentSection.classList.add('hidden');
        patientManagementSection.classList.add('hidden');
        if (hospitalIntroSection) hospitalIntroSection.classList.add('hidden');

        if (sectionId === 'patient-management') {
            patientManagementSection.classList.remove('hidden');
            await loadPatients();
            renderPatientList();
        } else if (sectionId === 'hospital-intro') {
            if (hospitalIntroSection) hospitalIntroSection.classList.remove('hidden');
        } else {
            appointmentSection.classList.remove('hidden');
            await loadAppointments();
            renderCalendar();
        }
    };

    const closeMenuIfOpen = () => {
        if (mobileMenu.classList.contains('sass-active')) toggleMenu();
    };

    if (navDoctorAppointmentsStatus) navDoctorAppointmentsStatus.addEventListener('click', async (e) => { e.preventDefault(); await showSection('calendar'); closeMenuIfOpen(); });
    if (navPatientInfoManagement)    navPatientInfoManagement.addEventListener('click', async (e) => { e.preventDefault(); await showSection('patient-management'); closeMenuIfOpen(); });
    if (navHome)                     navHome.addEventListener('click', async (e) => { e.preventDefault(); await showSection('calendar'); closeMenuIfOpen(); });
    if (mobileNavHome)               mobileNavHome.addEventListener('click', async (e) => { e.preventDefault(); await showSection('calendar'); closeMenuIfOpen(); });
    if (navHospitalIntro)            navHospitalIntro.addEventListener('click', (e) => { e.preventDefault(); showSection('hospital-intro'); closeMenuIfOpen(); });
    if (mobileNavHospitalIntro)      mobileNavHospitalIntro.addEventListener('click', (e) => { e.preventDefault(); showSection('hospital-intro'); closeMenuIfOpen(); });

    // ── 초기 로드 ────────────────────────────────────────────
    await loadAppointments();
    renderCalendar();
});
