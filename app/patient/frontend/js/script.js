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
        if (me.password_expired) { window.location.href = 'change-password.html'; return null; }
        return me;
    } catch {
        window.location.href = 'login.html';
        return null;
    }
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

    const appointmentSection    = document.getElementById('appointment-section');
    const calendarGridContainer = document.querySelector('.calendar-grid-container');
    const calendarGrid          = document.getElementById('calendar-grid');
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
    const navHospitalIntro        = document.getElementById('nav-hospital-intro');
    const mobileNavHospitalIntro  = document.getElementById('mobile-nav-hospital-intro');
    const manageAppointmentsBtn   = document.getElementById('nav-manage-appointments');
    const manageAppointmentsModal = document.getElementById('manageAppointmentsModal');
    const myAppointmentList       = document.getElementById('myAppointmentList');
    const closeManageModal        = document.getElementById('closeManageModal');
    const manageModalCloseBtn     = document.getElementById('manageModalCloseBtn');
    const navNewAppointmentBtn    = document.getElementById('nav-new-appointment');
    const navEditProfile          = document.getElementById('nav-edit-profile');
    const headerAppointmentBtn    = document.getElementById('headerAppointmentBtn');
    const mobileAppointmentBtn    = document.getElementById('mobileAppointmentBtn');
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

    const newAppointmentModal = document.getElementById('newAppointmentModal');
    const newAppDateInput     = document.getElementById('newAppDate');
    const newAppDeptSelect    = document.getElementById('newAppDept');
    const newAppNoteInput     = document.getElementById('newAppNote');
    const closeNewAppModal    = document.getElementById('closeNewAppModal');
    const cancelNewAppBtn     = document.getElementById('cancelNewAppBtn');
    const saveNewAppBtn       = document.getElementById('saveNewAppBtn');

    const profileEditSection  = document.getElementById('profile-edit-section');
    const profileNameInput    = document.getElementById('profileName');
    const profileBirthInput   = document.getElementById('profileBirth');
    const profileGenderInput  = document.getElementById('profileGender');
    const profileContactInput = document.getElementById('profileContact');
    const saveProfileBtn      = document.getElementById('saveProfileBtn');
    const hospitalIntroSection = document.getElementById('hospital-intro-section');

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

    if (userWelcome)     userWelcome.textContent = '환영합니다';
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
    let DEPT_LABEL = {};   // API에서 동적 로드
    // 진료과 목록 미리 로드
    apiCall('/portal/departments').then(r => r && r.ok && r.json()).then(list => {
        if (list) list.forEach(d => { DEPT_LABEL[d.department_code] = d.department_name; });
        // 신규 예약 모달 옵션 채우기
        if (newAppDeptSelect && newAppDeptSelect.options.length <= 1) {
            if (list) list.forEach(d => {
                const o = document.createElement('option');
                o.value = d.department_code;
                o.textContent = d.department_name;
                newAppDeptSelect.appendChild(o);
            });
        }
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

    // ── 나의 예약 관리 모달 ─────────────────────────────────
    const renderMyAppointments = () => {
        myAppointmentList.innerHTML = '';
        const allAppts = Object.entries(appointmentsMap).flatMap(([date, list]) =>
            list.map(a => ({ ...a, visit_date: date }))
        );
        if (allAppts.length === 0) {
            myAppointmentList.innerHTML = '<p class="text-gray-500 text-center py-10">예약 내역이 없습니다.</p>';
            return;
        }
        allAppts.sort((a, b) => a.appointment_date.localeCompare(b.appointment_date)).forEach(appt => {
            const item = document.createElement('div');
            item.className = 'flex justify-between items-center p-4 bg-gray-50 border border-gray-100 rounded-lg';
            const isModifiable = appt.status_code === 'pending';
            item.innerHTML = `
                <div>
                    <p class="text-xs text-gray-500 font-bold">${appt.appointment_date} ${appt.appointment_time || ''}</p>
                    <p class="text-gray-800 font-medium">${DEPT_LABEL[appt.department_code] || appt.department_code || '-'}</p>
                    <p class="text-xs text-gray-500">${appt.type_name || ''} · ${STATUS_LABEL[appt.status_code] || appt.status_code}</p>
                </div>
                ${isModifiable ? `
                <div class="flex gap-2 ml-4 shrink-0">
                    <button data-id="${appt.appointment_id}" class="edit-appt-btn px-3 py-1 bg-blue-50 text-blue-600 border border-blue-200 rounded text-xs font-bold hover:bg-blue-100">수정</button>
                    <button data-id="${appt.appointment_id}" class="del-appt-btn px-3 py-1 bg-red-50 text-red-600 border border-red-200 rounded text-xs font-bold hover:bg-red-100">취소</button>
                </div>` : ''}
            `;
            myAppointmentList.appendChild(item);
        });
        myAppointmentList.querySelectorAll('.edit-appt-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const appt = allAppts.find(a => a.appointment_id === btn.dataset.id);
                if (appt) openEditModalFn(appt);
            });
        });
        myAppointmentList.querySelectorAll('.del-appt-btn').forEach(btn => {
            btn.addEventListener('click', () => deleteAppointment(btn.dataset.id));
        });
    };

    const openManageModal = (e) => {
        e.preventDefault();
        renderMyAppointments();
        manageAppointmentsModal.classList.remove('hidden');
        manageAppointmentsModal.classList.add('flex');
        document.body.style.overflow = 'hidden';
    };
    const closeManageModalFn = () => {
        manageAppointmentsModal.classList.add('hidden');
        manageAppointmentsModal.classList.remove('flex');
        document.body.style.overflow = '';
    };
    if (manageAppointmentsBtn) manageAppointmentsBtn.addEventListener('click', openManageModal);
    if (closeManageModal)      closeManageModal.addEventListener('click', closeManageModalFn);
    if (manageModalCloseBtn)   manageModalCloseBtn.addEventListener('click', closeManageModalFn);

    // ── 신규 예약 ───────────────────────────────────────────
    const openNewAppModal = (date) => {
        newAppDateInput.value = date;
        newAppointmentModal.classList.remove('hidden');
        newAppointmentModal.classList.add('flex');
    };
    const closeNewAppModalFn = () => {
        newAppointmentModal.classList.add('hidden');
        newAppointmentModal.classList.remove('flex');
    };
    if (closeNewAppModal) closeNewAppModal.addEventListener('click', closeNewAppModalFn);
    if (cancelNewAppBtn)  cancelNewAppBtn.addEventListener('click', closeNewAppModalFn);
    if (saveNewAppBtn) {
        saveNewAppBtn.addEventListener('click', async () => {
            const visitDate = newAppDateInput.value;
            const deptCode  = newAppDeptSelect.value;
            if (!visitDate) { alert('날짜를 선택해주세요.'); return; }
            saveNewAppBtn.disabled = true;
            const timeVal = document.getElementById('newAppTime')?.value || '09:00';
            const res = await apiCall('/portal/appointments', {
                method: 'POST',
                body: JSON.stringify({
                    type_code:        'outpatient_new',
                    department_code:  deptCode,
                    appointment_date: visitDate,
                    appointment_time: timeVal,
                    notes:            newAppNoteInput?.value || null,
                }),
            });
            saveNewAppBtn.disabled = false;
            if (!res || !res.ok) {
                const err = await res?.json().catch(() => ({}));
                alert(err.detail || '예약 등록에 실패했습니다.');
                return;
            }
            closeNewAppModalFn();
            await loadAppointments();
            renderCalendar();
            alert('예약이 등록되었습니다.');
        });
    }

    // ── 예약 수정 ───────────────────────────────────────────
    const openEditModalFn = (appt) => {
        currentEditEncounterId = appt.appointment_id;
        editAppDateInput.value = appt.appointment_date;
        if (editAppDeptSelect) editAppDeptSelect.value = appt.department_code || '';
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
            if (editAppDateInput.value)  body.appointment_date = editAppDateInput.value;
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

    // ── 개인정보 수정 ───────────────────────────────────────
    const renderUserProfile = async () => {
        const res = await apiCall('/auth/me');
        if (!res || !res.ok) return;
        const data = await res.json();
        if (profileNameInput)    profileNameInput.value    = data.user_id || '-';
        if (profileBirthInput)   profileBirthInput.value   = '-';
        if (profileGenderInput)  profileGenderInput.value  = data.role || '-';
        if (profileContactInput) profileContactInput.value = '';
    };
    if (saveProfileBtn) {
        saveProfileBtn.addEventListener('click', () => alert('수정 기능은 준비 중입니다.'));
    }

    // ── 섹션 전환 ───────────────────────────────────────────
    const showSection = async (sectionId) => {
        appointmentSection.classList.add('hidden');
        profileEditSection.classList.add('hidden');
        if (hospitalIntroSection) hospitalIntroSection.classList.add('hidden');

        if (sectionId === 'profile-edit') {
            profileEditSection.classList.remove('hidden');
            await renderUserProfile();
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

    const openNewAppToday = (e) => {
        e.preventDefault();
        const today = new Date();
        openNewAppModal(`${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`);
    };

    if (navNewAppointmentBtn)    navNewAppointmentBtn.addEventListener('click', (e) => { e.preventDefault(); openNewAppToday(e); });
    if (navEditProfile)          navEditProfile.addEventListener('click', async (e) => { e.preventDefault(); await showSection('profile-edit'); closeMenuIfOpen(); });
    if (manageAppointmentsBtn)   manageAppointmentsBtn.addEventListener('click', openManageModal);
    if (headerAppointmentBtn)    headerAppointmentBtn.addEventListener('click', openNewAppToday);
    if (mobileAppointmentBtn)    mobileAppointmentBtn.addEventListener('click', openNewAppToday);
    if (navHome)                 navHome.addEventListener('click', async (e) => { e.preventDefault(); await showSection('calendar'); closeMenuIfOpen(); });
    if (mobileNavHome)           mobileNavHome.addEventListener('click', async (e) => { e.preventDefault(); await showSection('calendar'); closeMenuIfOpen(); });
    if (navHospitalIntro)        navHospitalIntro.addEventListener('click', (e) => { e.preventDefault(); showSection('hospital-intro'); closeMenuIfOpen(); });
    if (mobileNavHospitalIntro)  mobileNavHospitalIntro.addEventListener('click', (e) => { e.preventDefault(); showSection('hospital-intro'); closeMenuIfOpen(); });

    // ── 초기 로드 ────────────────────────────────────────────
    await loadAppointments();
    renderCalendar();
});
