// ── 토큰 관리 ─────────────────────────────────────────────
function getAccessToken()  { return sessionStorage.getItem('access_token'); }
function getRefreshToken() { return sessionStorage.getItem('refresh_token'); }
function getTokenExpiresAt() { return parseInt(sessionStorage.getItem('token_expires_at') || '0', 10); }

function saveTokens(data) {
    sessionStorage.setItem('access_token',    data.access_token);
    sessionStorage.setItem('refresh_token',   data.refresh_token);
    sessionStorage.setItem('token_expires_at', Date.now() + data.expires_in * 1000);
}

function clearTokens() {
    sessionStorage.removeItem('access_token');
    sessionStorage.removeItem('refresh_token');
    sessionStorage.removeItem('token_expires_at');
}

function isTokenExpiringSoon() {
    // 만료 5분 전이면 true
    return getTokenExpiresAt() - Date.now() < 5 * 60 * 1000;
}

async function refreshTokens() {
    const refreshToken = getRefreshToken();
    if (!refreshToken) return false;

    try {
        const res = await fetch(`${BASE_URL}/auth/refresh`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
            body: JSON.stringify({ refresh_token: refreshToken }),
        });
        if (!res.ok) return false;
        saveTokens(await res.json());
        return true;
    } catch {
        return false;
    }
}

// ── 공통 API 호출 (토큰 자동 갱신 + 401 재시도) ────────────
async function apiCall(path, options = {}) {
    if (isTokenExpiringSoon()) {
        const ok = await refreshTokens();
        if (!ok) { logout(); return null; }
    }

    const res = await fetch(`${BASE_URL}${path}`, {
        ...options,
        headers: {
            'Content-Type': 'application/json',
            'X-API-Key': API_KEY,
            'Authorization': `Bearer ${getAccessToken()}`,
            ...(options.headers || {}),
        },
    });

    if (res.status === 401) {
        const ok = await refreshTokens();
        if (!ok) { logout(); return null; }
        return apiCall(path, options); // 한 번 재시도
    }

    return res;
}

// ── 로그아웃 ──────────────────────────────────────────────
async function logout() {
    const refreshToken = getRefreshToken();
    if (refreshToken) {
        try {
            await fetch(`${BASE_URL}/auth/logout`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
                body: JSON.stringify({ refresh_token: refreshToken }),
            });
        } catch { /* 서버 오류여도 클라이언트 토큰은 삭제 */ }
    }
    clearTokens();
    window.location.href = 'login.html';
}

// ── 로그인 가드 ───────────────────────────────────────────
async function requireLogin() {
    if (!getAccessToken()) {
        window.location.href = 'login.html';
        return null;
    }
    // 토큰 만료 임박 시 갱신
    if (isTokenExpiringSoon()) {
        const ok = await refreshTokens();
        if (!ok) { logout(); return null; }
    }
    // 내 계정 정보 조회
    const res = await apiCall('/auth/me');
    if (!res) return null;
    const me = await res.json();
    if (me.password_expired) {
        alert('비밀번호가 만료되었습니다. 비밀번호를 변경해주세요.');
        // TODO: 비밀번호 변경 페이지로 이동 (구현 시 경로 교체)
    }
    return me; // { user_id, role, patient_id_hash, password_expired }
}

// ── DOMContentLoaded ──────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {

    // 로그인 가드: 비로그인 시 login.html로 이동
    const me = await requireLogin();
    if (!me) return;

    const { role, patient_id_hash: patientIdHash } = me;

    const header = document.querySelector('.sass-header');
    const mobileMenuBtn   = document.getElementById('sassMobileMenuBtn');
    const mobileMenuClose = document.getElementById('sassMobileMenuClose');
    const mobileMenu      = document.getElementById('sassMobileMenu');
    const overlay         = document.getElementById('sassOverlay');

    const appointmentSection      = document.getElementById('appointment-section');
    const calendarGridContainer   = document.querySelector('.calendar-grid-container');
    const calendarGrid            = document.getElementById('calendar-grid');
    const monthYearDisplay        = document.getElementById('currentMonthYear');
    const prevMonthBtn            = document.getElementById('prevMonth');
    const nextMonthBtn            = document.getElementById('nextMonth');
    const calendarModal           = document.getElementById('calendarModal');
    const modalDateHeader         = document.getElementById('modalDateHeader');
    const modalAppointmentList    = document.getElementById('modalAppointmentList');
    const closeCalendarModal      = document.getElementById('closeCalendarModal');
    const modalConfirmBtn         = document.getElementById('modalConfirmBtn');

    const navHome                    = document.getElementById('nav-home');
    const mobileNavHome              = document.getElementById('mobile-nav-home');
    const navHospitalIntro           = document.getElementById('nav-hospital-intro');
    const mobileNavHospitalIntro     = document.getElementById('mobile-nav-hospital-intro');
    const manageAppointmentsBtn      = document.getElementById('nav-manage-appointments');
    const manageAppointmentsModal    = document.getElementById('manageAppointmentsModal');
    const myAppointmentList          = document.getElementById('myAppointmentList');
    const closeManageModal           = document.getElementById('closeManageModal');
    const manageModalCloseBtn        = document.getElementById('manageModalCloseBtn');
    const navNewAppointmentBtn       = document.getElementById('nav-new-appointment');
    const navDoctorAppointmentsStatus = document.getElementById('nav-doctor-appointments-status');
    const navPatientInfoManagement   = document.getElementById('nav-patient-info-management');
    const navEditProfile             = document.getElementById('nav-edit-profile');
    const headerAppointmentBtn       = document.getElementById('headerAppointmentBtn');
    const loginBtn                   = document.getElementById('loginBtn');
    const mobileAppointmentBtn       = document.getElementById('mobileAppointmentBtn');
    const logoutBtn                  = document.getElementById('logoutBtn');
    const userWelcomeItem            = document.getElementById('userWelcomeItem');
    const userWelcome                = document.getElementById('userWelcome');

    const editAppointmentModal  = document.getElementById('editAppointmentModal');
    const editAppDateInput      = document.getElementById('editAppDate');
    const editAppTimeSelect     = document.getElementById('editAppTime');
    const editAppContentInput   = document.getElementById('editAppContent');
    const closeEditModal        = document.getElementById('closeEditModal');
    const cancelEditBtn         = document.getElementById('cancelEditBtn');
    const saveEditBtn           = document.getElementById('saveEditBtn');

    const newAppointmentModal = document.getElementById('newAppointmentModal');
    const newAppDateInput     = document.getElementById('newAppDate');
    const newAppTimeSelect    = document.getElementById('newAppTime');
    const newAppDeptSelect    = document.getElementById('newAppDept');
    const newAppNoteInput     = document.getElementById('newAppNote');
    const closeNewAppModal    = document.getElementById('closeNewAppModal');
    const cancelNewAppBtn     = document.getElementById('cancelNewAppBtn');
    const saveNewAppBtn       = document.getElementById('saveNewAppBtn');

    const patientEditModal      = document.getElementById('patientEditModal');
    const closePatientEditModal = document.getElementById('closePatientEditModal');
    const cancelPatientEditBtn  = document.getElementById('cancelPatientEditBtn');
    const savePatientInfoBtn    = document.getElementById('savePatientInfoBtn');
    const patientAgeInput       = document.getElementById('patientAge');
    const patientAddressInput   = document.getElementById('patientAddress');
    const patientContactInput   = document.getElementById('patientContact');
    const patientDiagnosisInput = document.getElementById('patientDiagnosis');

    const profileEditSection  = document.getElementById('profile-edit-section');
    const profileNameInput    = document.getElementById('profileName');
    const profileBirthInput   = document.getElementById('profileBirth');
    const profileGenderInput  = document.getElementById('profileGender');
    const profileContactInput = document.getElementById('profileContact');
    const saveProfileBtn      = document.getElementById('saveProfileBtn');

    const patientManagementSection = document.getElementById('patient-management-section');
    const hospitalIntroSection     = document.getElementById('hospital-intro-section');
    const patientTableBody         = document.getElementById('patientTableBody');
    const patientSearchInput       = document.getElementById('patientSearchInput');
    const patientSearchBtn         = document.getElementById('patientSearchBtn');

    // ── 헤더 스크롤 효과 ────────────────────────────────────
    window.addEventListener('scroll', () => {
        header.classList.toggle('sass-header-scrolled', window.scrollY > 50);
    });

    // ── 모바일 메뉴 토글 ────────────────────────────────────
    const toggleMenu = () => {
        mobileMenu.classList.toggle('sass-active');
        overlay.classList.toggle('sass-active');
        document.body.style.overflow = mobileMenu.classList.contains('sass-active') ? 'hidden' : '';
    };
    if (mobileMenuBtn)   mobileMenuBtn.addEventListener('click', toggleMenu);
    if (mobileMenuClose) mobileMenuClose.addEventListener('click', toggleMenu);
    if (overlay)         overlay.addEventListener('click', toggleMenu);

    // ── 상단 로그인/로그아웃 버튼 ───────────────────────────
    if (userWelcome)     userWelcome.textContent = `환영합니다`;
    if (userWelcomeItem) userWelcomeItem.classList.remove('hidden');
    if (logoutBtn)       logoutBtn.classList.remove('hidden');
    if (loginBtn)        loginBtn.classList.add('hidden');

    if (logoutBtn) logoutBtn.addEventListener('click', logout);

    // ── 달력 ────────────────────────────────────────────────
    let currentDate = new Date();
    let isMedicalStaffView = false;

    // API에서 받아온 예약 데이터를 날짜 키로 인덱싱
    // { 'YYYY-MM-DD': [ { encounter_id, status_code, department_code }, ... ] }
    let appointmentsMap = {};

    const STATUS_LABEL = { OPEN: '대기', IN_PROGRESS: '진행 중', CLOSED: '완료' };
    const DEPT_LABEL = {
        NEURO: '신경과', CARDIO: '심장내과', ORTHO: '정형외과',
        INTERNAL: '내과', ANESTHESIA: '마취통증의학과',
    };

    async function loadAppointments() {
        appointmentsMap = {};
        try {
            const res = await apiCall('/portal/appointments');
            if (!res || !res.ok) return;
            const list = await res.json();
            list.forEach(appt => {
                const date = appt.visit_date;
                if (!appointmentsMap[date]) appointmentsMap[date] = [];
                appointmentsMap[date].push(appt);
            });
        } catch { /* 네트워크 오류 시 빈 달력 표시 */ }
    }

    const renderCalendar = () => {
        calendarGrid.innerHTML = '';
        const year  = currentDate.getFullYear();
        const month = currentDate.getMonth();

        monthYearDisplay.innerText = `${year}년 ${month + 1}월`;

        const firstDay    = new Date(year, month, 1).getDay();
        const daysInMonth = new Date(year, month + 1, 0).getDate();
        const numWeeks    = Math.ceil((firstDay + daysInMonth) / 7);

        if (calendarGridContainer) {
            calendarGridContainer.style.gridTemplateRows = `auto repeat(${numWeeks}, 1fr)`;
        }

        const today        = new Date();
        const isThisMonth  = today.getFullYear() === year && today.getMonth() === month;

        for (let i = 0; i < firstDay; i++) {
            const emptyCell = document.createElement('div');
            emptyCell.className = 'bg-gray-50/50 min-h-[120px] border-b border-r border-gray-100';
            calendarGrid.appendChild(emptyCell);
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
                item.innerText = `${deptLabel} · ${statusLabel}`;
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

    if (prevMonthBtn) prevMonthBtn.addEventListener('click', () => { currentDate.setMonth(currentDate.getMonth() - 1); renderCalendar(); });
    if (nextMonthBtn) nextMonthBtn.addEventListener('click', () => { currentDate.setMonth(currentDate.getMonth() + 1); renderCalendar(); });
    if (closeCalendarModal) closeCalendarModal.addEventListener('click', hideModal);
    if (modalConfirmBtn)    modalConfirmBtn.addEventListener('click', hideModal);

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

        allAppts.sort((a, b) => a.visit_date.localeCompare(b.visit_date)).forEach(appt => {
            const item = document.createElement('div');
            item.className = 'flex justify-between items-center p-4 bg-gray-50 border border-gray-100 rounded-lg';
            const deptLabel   = DEPT_LABEL[appt.department_code] || appt.department_code;
            const statusLabel = STATUS_LABEL[appt.status_code]   || appt.status_code;
            item.innerHTML = `
                <div>
                    <p class="text-xs text-gray-500 font-bold">${appt.visit_date}</p>
                    <p class="text-gray-800 font-medium">${deptLabel}</p>
                    <p class="text-xs text-gray-500">${statusLabel}</p>
                </div>
            `;
            myAppointmentList.appendChild(item);
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

    // ── 신규 예약 모달 (등록 기능은 추후 API 확정 후 연동) ──
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
        saveNewAppBtn.addEventListener('click', () => {
            // TODO: 예약 등록 API 연동 (현재 미제공)
            alert('예약 신청이 접수되었습니다. (API 연동 후 실제 저장됩니다.)');
            closeNewAppModalFn();
        });
    }

    // ── 예약 수정 모달 (수정 기능은 추후 API 확정 후 연동) ──
    const closeEditModalFn = () => {
        editAppointmentModal.classList.add('hidden');
        editAppointmentModal.classList.remove('flex');
    };
    if (closeEditModal) closeEditModal.addEventListener('click', closeEditModalFn);
    if (cancelEditBtn)  cancelEditBtn.addEventListener('click', closeEditModalFn);
    if (saveEditBtn) {
        saveEditBtn.addEventListener('click', () => {
            // TODO: 예약 수정 API 연동 (현재 미제공)
            alert('수정 기능은 준비 중입니다.');
            closeEditModalFn();
        });
    }

    // ── 의사용 환자 목록 ────────────────────────────────────
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
            p.patient_id_hash.includes(query) ||
            String(p.birth_year).includes(query)
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
        if (patientAddressInput)   patientAddressInput.value   = '-';
        if (patientContactInput)   patientContactInput.value   = '-';
        if (patientDiagnosisInput) patientDiagnosisInput.value = `진단: ${diag} | 알레르기: ${allergy} | 수술: ${surgery}`;

        patientEditModal.classList.remove('hidden');
        patientEditModal.classList.add('flex');
        document.body.style.overflow = 'hidden';
    };

    const closePatientEditModalFn = () => {
        patientEditModal.classList.add('hidden');
        patientEditModal.classList.remove('flex');
        document.body.style.overflow = '';
    };
    if (closePatientEditModal) closePatientEditModal.addEventListener('click', closePatientEditModalFn);
    if (cancelPatientEditBtn)  cancelPatientEditBtn.addEventListener('click', closePatientEditModalFn);
    if (savePatientInfoBtn) savePatientInfoBtn.addEventListener('click', closePatientEditModalFn);

    // ── 개인정보 수정 섹션 ──────────────────────────────────
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
        saveProfileBtn.addEventListener('click', () => {
            // TODO: 연락처 수정 API 연동 (현재 미제공)
            alert('수정 기능은 준비 중입니다.');
        });
    }

    // ── 검색 ────────────────────────────────────────────────
    if (patientSearchBtn) {
        patientSearchBtn.addEventListener('click', () => renderPatientList(patientSearchInput.value.trim()));
    }
    if (patientSearchInput) {
        patientSearchInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') renderPatientList(patientSearchInput.value.trim());
        });
    }

    // ── 섹션 전환 ───────────────────────────────────────────
    const showSection = async (sectionId) => {
        appointmentSection.classList.add('hidden');
        patientManagementSection.classList.add('hidden');
        profileEditSection.classList.add('hidden');
        if (hospitalIntroSection) hospitalIntroSection.classList.add('hidden');

        if (sectionId === 'patient-management') {
            isMedicalStaffView = true;
            patientManagementSection.classList.remove('hidden');
            await loadPatients();
            renderPatientList();
        } else if (sectionId === 'profile-edit') {
            profileEditSection.classList.remove('hidden');
            await renderUserProfile();
        } else if (sectionId === 'hospital-intro') {
            if (hospitalIntroSection) hospitalIntroSection.classList.remove('hidden');
        } else {
            isMedicalStaffView = false;
            appointmentSection.classList.remove('hidden');
            await loadAppointments();
            renderCalendar();
        }
    };

    const closeMenuIfOpen = () => {
        if (mobileMenu.classList.contains('sass-active')) toggleMenu();
    };

    if (navDoctorAppointmentsStatus) {
        navDoctorAppointmentsStatus.addEventListener('click', async (e) => {
            e.preventDefault();
            await showSection('calendar');
            isMedicalStaffView = true;
            appointmentSection.scrollIntoView({ behavior: 'smooth' });
            closeMenuIfOpen();
        });
    }
    if (navNewAppointmentBtn) {
        navNewAppointmentBtn.addEventListener('click', (e) => {
            e.preventDefault();
            isMedicalStaffView = false;
            const today = new Date();
            openNewAppModal(`${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`);
        });
    }
    if (navPatientInfoManagement) {
        navPatientInfoManagement.addEventListener('click', async (e) => {
            e.preventDefault();
            await showSection('patient-management');
            closeMenuIfOpen();
        });
    }
    if (navEditProfile) {
        navEditProfile.addEventListener('click', async (e) => {
            e.preventDefault();
            await showSection('profile-edit');
            closeMenuIfOpen();
        });
    }

    const handleHomeClick = async (e) => {
        e.preventDefault();
        await showSection('calendar');
        closeMenuIfOpen();
    };
    if (navHome)       navHome.addEventListener('click', handleHomeClick);
    if (mobileNavHome) mobileNavHome.addEventListener('click', handleHomeClick);

    const handleIntroClick = (e) => {
        e.preventDefault();
        showSection('hospital-intro');
        closeMenuIfOpen();
    };
    if (navHospitalIntro)       navHospitalIntro.addEventListener('click', handleIntroClick);
    if (mobileNavHospitalIntro) mobileNavHospitalIntro.addEventListener('click', handleIntroClick);

    const handleOpenNewAppModalToday = (e) => {
        e.preventDefault();
        isMedicalStaffView = false;
        const today = new Date();
        openNewAppModal(`${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`);
    };
    if (headerAppointmentBtn)  headerAppointmentBtn.addEventListener('click', handleOpenNewAppModalToday);
    if (mobileAppointmentBtn)  mobileAppointmentBtn.addEventListener('click', handleOpenNewAppModalToday);

    // ── 초기 로드 ────────────────────────────────────────────
    await loadAppointments();
    renderCalendar();
});
