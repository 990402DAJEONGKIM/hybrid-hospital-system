document.addEventListener('DOMContentLoaded', () => {
  const header = document.querySelector('.sass-header');
  const mobileMenuBtn = document.getElementById('sassMobileMenuBtn');
  const mobileMenuClose = document.getElementById('sassMobileMenuClose');
  const mobileMenu = document.getElementById('sassMobileMenu');
  const overlay = document.getElementById('sassOverlay');
  
  const appointmentSection = document.getElementById('appointment-section');
  const calendarGridContainer = document.querySelector('.calendar-grid-container'); // calendarGridContainer 요소 가져오기
  // 달력 관련 요소
  const calendarGrid = document.getElementById('calendar-grid');
  const monthYearDisplay = document.getElementById('currentMonthYear');
  const prevMonthBtn = document.getElementById('prevMonth');
  const nextMonthBtn = document.getElementById('nextMonth');
  const calendarModal = document.getElementById('calendarModal');
  const modalDateHeader = document.getElementById('modalDateHeader');
  const modalAppointmentList = document.getElementById('modalAppointmentList');
  const closeCalendarModal = document.getElementById('closeCalendarModal');
  const modalConfirmBtn = document.getElementById('modalConfirmBtn'); // '닫기' 버튼으로 사용


  // 예약 관리 관련 요소
  const navHome = document.getElementById('nav-home');
  const mobileNavHome = document.getElementById('mobile-nav-home');
  const navHospitalIntro = document.getElementById('nav-hospital-intro');
  const mobileNavHospitalIntro = document.getElementById('mobile-nav-hospital-intro');
  const manageAppointmentsBtn = document.getElementById('nav-manage-appointments');
  const manageAppointmentsModal = document.getElementById('manageAppointmentsModal');
  const myAppointmentList = document.getElementById('myAppointmentList');
  const closeManageModal = document.getElementById('closeManageModal');
  const manageModalCloseBtn = document.getElementById('manageModalCloseBtn');
  const navNewAppointmentBtn = document.getElementById('nav-new-appointment'); // 신규 추가된 요소
  const navDoctorAppointmentsStatus = document.getElementById('nav-doctor-appointments-status'); // 의료진 탭 - 예약현황
  const navPatientInfoManagement = document.getElementById('nav-patient-info-management'); // 의료진 탭 - 환자 기본정보 관리
  const navEditProfile = document.getElementById('nav-edit-profile'); // 환자 탭 - 개인정보 수정
  const headerAppointmentBtn = document.getElementById('headerAppointmentBtn'); // 헤더 예약하기 버튼
  const loginBtn = document.getElementById('loginBtn'); // 로그인 버튼
  const mobileAppointmentBtn = document.getElementById('mobileAppointmentBtn'); // 모바일 메뉴 예약하기 버튼
  const logoutBtn = document.getElementById('logoutBtn');
  const userWelcomeItem = document.getElementById('userWelcomeItem');
  const userWelcome = document.getElementById('userWelcome');

  // 예약 수정 모달 관련 요소
  const editAppointmentModal = document.getElementById('editAppointmentModal');
  const editAppDateInput = document.getElementById('editAppDate');
  const editAppTimeSelect = document.getElementById('editAppTime');
  const editAppContentInput = document.getElementById('editAppContent');
  const closeEditModal = document.getElementById('closeEditModal');
  const cancelEditBtn = document.getElementById('cancelEditBtn');
  const saveEditBtn = document.getElementById('saveEditBtn');

  // 신규 예약 모달 관련 요소
  const newAppointmentModal = document.getElementById('newAppointmentModal');
  const newAppDateInput = document.getElementById('newAppDate');
  const newAppTimeSelect = document.getElementById('newAppTime');
  const newAppDeptSelect = document.getElementById('newAppDept');
  const newAppNoteInput = document.getElementById('newAppNote');
  const closeNewAppModal = document.getElementById('closeNewAppModal');
  const cancelNewAppBtn = document.getElementById('cancelNewAppBtn');
  const saveNewAppBtn = document.getElementById('saveNewAppBtn');

  // 환자 기본정보 관리 모달 관련 요소
  const patientEditModal = document.getElementById('patientEditModal');
  const closePatientEditModal = document.getElementById('closePatientEditModal');
  const cancelPatientEditBtn = document.getElementById('cancelPatientEditBtn');
  const savePatientInfoBtn = document.getElementById('savePatientInfoBtn');
  const patientNameInput = document.getElementById('patientName');
  const patientAgeInput = document.getElementById('patientAge');
  const patientAddressInput = document.getElementById('patientAddress');
  const patientContactInput = document.getElementById('patientContact');
  const patientDiagnosisInput = document.getElementById('patientDiagnosis');

  // 개인정보 수정 섹션 관련 요소
  const profileEditSection = document.getElementById('profile-edit-section');
  const profileNameInput = document.getElementById('profileName');
  const profileRrnInput = document.getElementById('profileRrn');
  const profileBirthInput = document.getElementById('profileBirth');
  const profileGenderInput = document.getElementById('profileGender');
  const profileContactInput = document.getElementById('profileContact');
  const saveProfileBtn = document.getElementById('saveProfileBtn');

  const patientManagementSection = document.getElementById('patient-management-section');
  const hospitalIntroSection = document.getElementById('hospital-intro-section');
  const patientTableBody = document.getElementById('patientTableBody');
  const backToCalendarBtn = document.getElementById('backToCalendarBtn');
  const patientSearchInput = document.getElementById('patientSearchInput');
  const patientSearchBtn = document.getElementById('patientSearchBtn');

  // 1. 스크롤 시 헤더 스타일 변경 (sass-header-scrolled 클래스 토글)
  window.addEventListener('scroll', () => {
    if (window.scrollY > 50) {
      header.classList.add('sass-header-scrolled');
    } else {
      header.classList.remove('sass-header-scrolled');
    }
  });

  // 2. 모바일 메뉴 토글 로직
  const toggleMenu = () => {
    mobileMenu.classList.toggle('sass-active');
    overlay.classList.toggle('sass-active');
    
    // 메뉴가 열려있을 때 바디 스크롤 방지
    if (mobileMenu.classList.contains('sass-active')) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }
  };

  if (mobileMenuBtn) mobileMenuBtn.addEventListener('click', toggleMenu);
  if (mobileMenuClose) mobileMenuClose.addEventListener('click', toggleMenu);
  if (overlay) overlay.addEventListener('click', toggleMenu);

  // 3. 달력 로직
  let currentDate = new Date();
  
  // 의료진 모드 여부 (상세 정보 노출 결정)
  let isMedicalStaffView = false;

  // 가상 예약 데이터
  // (김철수)는 환자 본인 예약, (이영희)는 다른 환자 예약으로 가정
  // 의료진 탭에서는 모든 예약을 볼 수 있어야 함
  const mockPatientsList = [
    { id: 1, name: "김철수", rrn: "910512-1******", birthDate: "1991-05-12", genderCode: "1", age: 35, address: "서울시 강남구 테헤란로 123", contact: "010-1234-5678", diagnosis: "고혈압 (비식별화)" },
    { id: 2, name: "이영희", rrn: "980324-2******", birthDate: "1998-03-24", genderCode: "2", age: 28, address: "서울시 서초구 반포대로 456", contact: "010-5678-1234", diagnosis: "당뇨 (비식별화)" },
    { id: 3, name: "박지성", rrn: "850715-1******", birthDate: "1985-07-15", genderCode: "1", age: 41, address: "경기도 수원시 팔달구 789", contact: "010-1111-2222", diagnosis: "부정맥 (비식별화)" },
    { id: 4, name: "최소아", rrn: "191201-4******", birthDate: "2019-12-01", genderCode: "4", age: 7, address: "서울시 송파구 올림픽로 101", contact: "010-9999-8888", diagnosis: "천식 (비식별화)" }
  ];

  const mockAppointments = {
    '2026-05-12': ['10:00 - 일반 검진 (김철수)', '14:00 - 내과 상담 (이영희)'],
    '2026-05-15': ['09:30 - 심장 초음파 (박지성)'],
    '2026-05-20': ['11:00 - 신경과 정기 검진', '15:30 - MRI 촬영'],
    '2026-05-25': ['13:00 - 재활 치료']
  };

  const renderCalendar = () => {
    calendarGrid.innerHTML = '';
    const year = currentDate.getFullYear();
    const month = currentDate.getMonth();

    monthYearDisplay.innerText = `${year}년 ${month + 1}월`;

    const firstDay = new Date(year, month, 1).getDay();
    const daysInMonth = new Date(year, month + 1, 0).getDate();

    const numWeeks = Math.ceil((firstDay + daysInMonth) / 7);

    if (calendarGridContainer) {
      calendarGridContainer.style.gridTemplateRows = `auto repeat(${numWeeks}, 1fr)`; // 요일 헤더(auto) + 각 주(1fr)
    }

    const today = new Date();
    const isThisMonth = today.getFullYear() === year && today.getMonth() === month;

    // 빈 칸 채우기 (이전 달 날짜)
    for (let i = 0; i < firstDay; i++) {
      const emptyCell = document.createElement('div');
      emptyCell.className = 'bg-gray-50/50 min-h-[120px] border-b border-r border-gray-100';
      calendarGrid.appendChild(emptyCell);
    }

    // 실제 날짜 채우기
    for (let day = 1; day <= daysInMonth; day++) {
      const dateString = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      const dayOfWeek = new Date(year, month, day).getDay();
      const dayCell = document.createElement('div');
      dayCell.className = 'calendar-day';

      // 일요일(0)과 토요일(6) 클래스 추가
      if (dayOfWeek === 0) dayCell.classList.add('is-sunday');
      if (dayOfWeek === 6) dayCell.classList.add('is-saturday');

      if (isThisMonth && today.getDate() === day) {
        dayCell.classList.add('is-today');
      }

      dayCell.innerHTML = `<span class="day-number">${day}</span>`;

      if (mockAppointments[dateString]) {
        const count = mockAppointments[dateString].length;
        const badge = document.createElement('div');
        badge.className = 'mt-1 w-full text-[10px] px-2 py-1 bg-blue-100 text-blue-700 rounded-md font-bold truncate';
        badge.innerText = `예약 ${count}건`;
        dayCell.appendChild(badge);
      }

      dayCell.addEventListener('click', () => showAppointments(dateString));
      calendarGrid.appendChild(dayCell);
    }
  };

  const showAppointments = (date) => {
    modalDateHeader.innerText = date;
    modalAppointmentList.innerHTML = '';

    const appointments = mockAppointments[date];
    if (appointments && appointments.length > 0) {
      appointments.forEach(app => {
        const item = document.createElement('div');
        item.className = 'p-3 bg-blue-50 border-l-4 border-blue-500 text-blue-800 text-sm rounded';

        if (isMedicalStaffView) {
          // 의료진 모드: 환자 상세 정보(이름, 나이, 연락처) 조회
          const nameMatch = app.match(/\(([^)]+)\)$/);
          const patientName = nameMatch ? nameMatch[1] : null;
          const patient = mockPatientsList.find(p => p.name === patientName);
          
          if (patient) {
            const cleanAppInfo = app.replace(/\s*\([^)]+\)$/, '');
            item.innerText = `${cleanAppInfo} | ${patient.name} (${patient.age}세, ${patient.contact})`;
          } else {
            item.innerText = app;
          }
        } else {
          // 일반 모드: 예약 정보 끝의 환자명(괄호 부분)을 제거하여 표시
          item.innerText = app.replace(/\s*\([^)]+\)$/, '');
        }
        
        modalAppointmentList.appendChild(item);
      });
    } else {
      modalAppointmentList.innerHTML = '<p class="text-gray-500 text-center py-4">해당 날짜에 예약 내역이 없습니다.</p>'; // 이미 한국어
    }

    calendarModal.classList.remove('hidden');
    calendarModal.classList.add('flex');
    document.body.style.overflow = 'hidden';
  };

  const openNewAppModal = (date) => {
    newAppDateInput.value = date;
    newAppointmentModal.classList.remove('hidden');
    newAppointmentModal.classList.add('flex');
  };

  const hideModal = () => {
    calendarModal.classList.add('hidden');
    calendarModal.classList.remove('flex');
    document.body.style.overflow = '';
  };

  if (prevMonthBtn) {
    prevMonthBtn.addEventListener('click', () => {
      currentDate.setMonth(currentDate.getMonth() - 1);
      renderCalendar();
    });
  }

  if (nextMonthBtn) {
    nextMonthBtn.addEventListener('click', () => {
      currentDate.setMonth(currentDate.getMonth() + 1);
      renderCalendar();
    });
  }

  if (closeCalendarModal) closeCalendarModal.addEventListener('click', hideModal);
  if (modalConfirmBtn) modalConfirmBtn.addEventListener('click', hideModal);

  // 로그인/로그아웃 버튼 가시성 제어
  const updateAuthButtons = () => {
    const loggedInUser = localStorage.getItem('hospital_logged_in_user');
    if (loggedInUser) {
      const user = JSON.parse(loggedInUser);
      if (userWelcome) userWelcome.textContent = `${user.name}님 환영합니다`;
      if (userWelcomeItem) userWelcomeItem.classList.remove('hidden');
      if (logoutBtn) logoutBtn.classList.remove('hidden');
      if (loginBtn) loginBtn.classList.add('hidden');
    } else {
      if (userWelcomeItem) userWelcomeItem.classList.add('hidden');
      if (logoutBtn) logoutBtn.classList.add('hidden');
      if (loginBtn) loginBtn.classList.remove('hidden');
    }
  };
  updateAuthButtons(); // 페이지 로드 시 초기 설정
  if (loginBtn) loginBtn.addEventListener('click', () => { window.location.href = 'login.html'; });

  // 4. 나의 예약 관리 로직 (조회, 수정, 삭제)
  const sessionUser = JSON.parse(localStorage.getItem('hospital_logged_in_user') || '{}');
  const currentUser = sessionUser.name || "익명";
  
  // 수정 중인 데이터의 상태를 저장
  let currentEditingInfo = { date: '', index: -1 };

  const renderMyAppointments = () => {
    myAppointmentList.innerHTML = '';
    let hasAppointments = false;

    Object.keys(mockAppointments).forEach(date => {
      mockAppointments[date].forEach((app, index) => {
        // 사용자의 이름이 포함된 예약만 필터링
        if (app.includes(currentUser)) {
          hasAppointments = true;
          const item = document.createElement('div');
          item.className = 'flex justify-between items-center p-4 bg-gray-50 border border-gray-100 rounded-lg';
          item.innerHTML = `
            <div>
              <p class="text-xs text-gray-500 font-bold">${date}</p>
              <p class="text-gray-800 font-medium">${app}</p>
            </div>
            <div class="flex space-x-2">
              <button onclick="editApp('${date}', ${index})" class="px-3 py-1 bg-blue-100 text-blue-600 rounded text-sm font-bold hover:bg-blue-200">수정</button>
              <button onclick="deleteApp('${date}', ${index})" class="px-3 py-1 bg-red-100 text-red-600 rounded text-sm font-bold hover:bg-red-200">삭제</button>
            </div>
          `;
          myAppointmentList.appendChild(item);
        }
      });
    });

    if (!hasAppointments) {
      myAppointmentList.innerHTML = '<p class="text-gray-500 text-center py-10">내역이 없습니다.</p>';
    }
  };

  // 전역 함수로 등록하여 HTML onclick에서 접근 가능하게 함
  window.deleteApp = (date, index) => {
    if (confirm('정말 삭제하시겠습니까?')) {
      mockAppointments[date].splice(index, 1);
      if (mockAppointments[date].length === 0) {
        delete mockAppointments[date];
      }
      renderMyAppointments();
      renderCalendar(); // 달력 갱신
    }
  };

  window.editApp = (date, index) => {
    const currentApp = mockAppointments[date][index];
    
    // 수정할 정보를 상태에 저장
    currentEditingInfo = { date, index };
    
    // 모달 필드 채우기
    editAppDateInput.value = date;
    
    // 시간과 내용 분리 (형식: "HH:mm - 내용")
    const parts = currentApp.split(' - ');
    if (parts.length >= 2) {
      editAppTimeSelect.value = parts[0];
      editAppContentInput.value = parts.slice(1).join(' - ');
    } else {
      editAppContentInput.value = currentApp;
    }
    
    // 수정 모달 열기
    editAppointmentModal.classList.remove('hidden');
    editAppointmentModal.classList.add('flex');
  };

  const closeEditModalFn = () => {
    editAppointmentModal.classList.add('hidden');
    editAppointmentModal.classList.remove('flex');
  };

  const saveEditAppFn = () => {
    const { date: oldDate, index } = currentEditingInfo;
    const newDate = editAppDateInput.value;
    const selectedTime = editAppTimeSelect.value;
    const newValue = editAppContentInput.value.trim();
    
    if (!newDate) {
      alert('날짜를 선택해주세요.');
      return;
    }

    if (newValue) {
      const updatedAppointment = `${selectedTime} - ${newValue}`;

      if (newDate !== oldDate) {
        // 날짜가 변경된 경우: 기존 날짜에서 제거
        mockAppointments[oldDate].splice(index, 1);
        if (mockAppointments[oldDate].length === 0) {
          delete mockAppointments[oldDate];
        }

        // 새로운 날짜에 추가
        if (!mockAppointments[newDate]) {
          mockAppointments[newDate] = [];
        }
        mockAppointments[newDate].push(updatedAppointment);
        mockAppointments[newDate].sort(); // 시간순 정렬
      } else {
        // 날짜가 동일한 경우: 해당 위치 업데이트
        mockAppointments[oldDate][index] = updatedAppointment;
      }

      renderMyAppointments();
      renderCalendar();
      closeEditModalFn();
    } else {
      alert('내용을 입력해주세요.');
    }
  };

  // 신규 예약 저장 로직
  const saveNewAppFn = () => {
    const date = newAppDateInput.value;
    const time = newAppTimeSelect.value;
    const dept = newAppDeptSelect.value;
    const note = newAppNoteInput.value.trim();

    if (!date) {
      alert('날짜를 선택해주세요.');
      return;
    }

    // 중복 예약 체크
    if (mockAppointments[date]) {
      const isDuplicate = mockAppointments[date].some(app => app.startsWith(`${time} -`));
      if (isDuplicate) {
        alert('해당 시간대에 이미 예약이 존재합니다. 다른 시간을 선택해주세요.');
        return;
      }
    }

    const newAppString = `${time} - ${dept}${note ? ' (' + note + ')' : ''} (${currentUser})`;

    if (!mockAppointments[date]) {
      mockAppointments[date] = [];
    }
    mockAppointments[date].push(newAppString);
    mockAppointments[date].sort();

    alert('예약이 성공적으로 등록되었습니다.');
    renderCalendar();
    closeNewAppModalFn();
  };

  const closeNewAppModalFn = () => {
    newAppointmentModal.classList.add('hidden');
    newAppointmentModal.classList.remove('flex');
  };
  // 섹션 전환 통합 관리 함수
  const showSection = (sectionId) => {
    // 모든 섹션 숨기기
    appointmentSection.classList.add('hidden');
    patientManagementSection.classList.add('hidden');
    profileEditSection.classList.add('hidden');
    if (hospitalIntroSection) hospitalIntroSection.classList.add('hidden');

    if (sectionId === 'patient-management') {
      isMedicalStaffView = false;
      patientManagementSection.classList.remove('hidden');
      renderPatientList();
    } else if (sectionId === 'profile-edit') {
      profileEditSection.classList.remove('hidden');
      renderUserProfile();
    } else if (sectionId === 'hospital-intro') {
      hospitalIntroSection.classList.remove('hidden');
    } else {
      isMedicalStaffView = false;
      appointmentSection.classList.remove('hidden');
      renderCalendar();
    }
  };

  // 환자 관리 페이지로 전환
  const openPatientManagement = (e) => {
    if (e) e.preventDefault();
    showSection('patient-management');
    if (mobileMenu.classList.contains('sass-active')) {
      toggleMenu();
    }
  };

  // 사용자 프로필 정보 렌더링
  const renderUserProfile = () => {
    const loggedInUser = JSON.parse(localStorage.getItem('hospital_logged_in_user'));
    if (!loggedInUser) {
      alert('로그인이 필요한 서비스입니다.');
      window.location.href = 'login.html';
      return;
    }

    // mockPatientsList에서 로그인한 사용자 이름으로 데이터 찾기
    const patient = mockPatientsList.find(p => p.name === loggedInUser.name);
    
    if (patient) {
      profileNameInput.value = patient.name;
      profileRrnInput.value = patient.rrn;
      profileBirthInput.value = patient.birthDate;
      profileGenderInput.value = patient.genderCode;
      profileContactInput.value = patient.contact;
    } else {
      // 환자 리스트에 없는 신규 회원일 경우 기본값 처리
      profileNameInput.value = loggedInUser.name;
      profileRrnInput.value = loggedInUser.rrn || "미등록";
      profileBirthInput.value = loggedInUser.birth || "미등록";
      profileGenderInput.value = loggedInUser.gender || "미등록";
      profileContactInput.value = loggedInUser.contact || "";
    }
  };

  // 개인정보(연락처) 저장
  if (saveProfileBtn) {
    saveProfileBtn.addEventListener('click', () => {
      const newContact = profileContactInput.value.trim();
      const patient = mockPatientsList.find(p => p.name === profileNameInput.value);
      
      if (patient) {
        patient.contact = newContact;
        alert('연락처가 성공적으로 수정되었습니다.');
      } else {
        alert('수정할 대상 정보를 찾을 수 없습니다.');
      }
    });
  }

  const renderPatientList = (query = "") => {
    const filtered = mockPatientsList.filter(p => 
      p.name.includes(query) || p.contact.includes(query)
    );

    patientTableBody.innerHTML = filtered.map(p => `
      <tr class="bg-white border-b hover:bg-gray-50">
        <td class="px-4 py-3 font-medium text-gray-900">${p.name}</td>
        <td class="px-4 py-3">${p.rrn}</td>
        <td class="px-4 py-3">${p.contact}</td>
        <td class="px-4 py-3">${p.birthDate}</td>
        <td class="px-4 py-3">${p.genderCode}</td>
        <td class="px-4 py-3 flex items-center justify-between">
          <span>${p.diagnosis}</span>
          <button onclick="editPatientInfo(${p.id})" class="ml-2 px-2 py-1 bg-blue-50 text-blue-600 border border-blue-200 rounded text-xs font-bold hover:bg-blue-100 transition-colors">수정</button>
        </td>
      </tr>
    `).join('');
  };

  // 검색 기능 이벤트 리스너
  if (patientSearchBtn) {
    patientSearchBtn.addEventListener('click', () => {
      renderPatientList(patientSearchInput.value.trim());
    });
  }
  if (patientSearchInput) {
    patientSearchInput.addEventListener('keypress', (e) => {
      if (e.key === 'Enter') {
        renderPatientList(patientSearchInput.value.trim());
      }
    });
  }

  let currentEditingPatientId = null;
  window.editPatientInfo = (id) => {
    const patient = mockPatientsList.find(p => p.id === id);
    if (patient) {
      currentEditingPatientId = id;
      patientNameInput.value = patient.name;
      patientAgeInput.value = patient.age;
      patientAddressInput.value = patient.address;
      patientContactInput.value = patient.contact;
      patientDiagnosisInput.value = patient.diagnosis;

      patientEditModal.classList.remove('hidden');
      patientEditModal.classList.add('flex');
      document.body.style.overflow = 'hidden';
    }
  };

  // 환자 정보 수정 모달 닫기
  const closePatientEditModalFn = () => {
    patientEditModal.classList.add('hidden');
    patientEditModal.classList.remove('flex');
    document.body.style.overflow = '';
  };

  // 환자 기본정보 저장
  const savePatientInfoFn = () => {
    const patient = mockPatientsList.find(p => p.id === currentEditingPatientId);
    if (patient) {
      patient.name = patientNameInput.value.trim();
      patient.age = parseInt(patientAgeInput.value);
      patient.address = patientAddressInput.value.trim();
      patient.contact = patientContactInput.value.trim();
      
      alert('환자 정보가 성공적으로 업데이트되었습니다.');
      closePatientEditModalFn();
      renderPatientList();
    }
  };

  // [의료진] > [예약현황] 메뉴 클릭 시 달력으로 스크롤
  if (navDoctorAppointmentsStatus) {
    navDoctorAppointmentsStatus.addEventListener('click', (e) => {
      e.preventDefault();
      showSection('calendar'); // 먼저 달력 섹션을 보이게 함
      isMedicalStaffView = true; // 의료진 상세 보기 모드 활성화
      appointmentSection.scrollIntoView({ behavior: 'smooth' });
      if (mobileMenu.classList.contains('sass-active')) { // 모바일 메뉴가 열려있으면 닫기
        toggleMenu();
      }
    });
  }

  // [환자] > [예약] 메뉴 클릭 시 신규 예약 모달 열기
  if (navNewAppointmentBtn) {
    navNewAppointmentBtn.addEventListener('click', (e) => {
      e.preventDefault(); // 기본 링크 동작(스크롤) 방지
      isMedicalStaffView = false;
      const today = new Date();
      const todayString = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
      openNewAppModal(todayString); // 오늘 날짜로 신규 예약 모달 열기
    });
  }

  // [홈] 메뉴 클릭 시 메인 예약 섹션으로 전환
  const handleHomeClick = (e) => {
    e.preventDefault();
    showSection('calendar');
    if (mobileMenu.classList.contains('sass-active')) {
      toggleMenu();
    }
  };
  if (navHome) navHome.addEventListener('click', handleHomeClick);
  if (mobileNavHome) mobileNavHome.addEventListener('click', handleHomeClick);

  // [병원소개] 메뉴 클릭 시 소개 섹션으로 전환
  const handleIntroClick = (e) => {
    e.preventDefault();
    showSection('hospital-intro');
    if (mobileMenu.classList.contains('sass-active')) {
      toggleMenu();
    }
  };
  if (navHospitalIntro) navHospitalIntro.addEventListener('click', handleIntroClick);
  if (mobileNavHospitalIntro) mobileNavHospitalIntro.addEventListener('click', handleIntroClick);

  // [환자] > [개인정보 수정] 메뉴 클릭 시 섹션 전환
  if (navEditProfile) {
    navEditProfile.addEventListener('click', (e) => {
      e.preventDefault();
      showSection('profile-edit');
      if (mobileMenu.classList.contains('sass-active')) {
        toggleMenu();
      }
    });
  }

  // 화면 최상단 '예약하기' 버튼 클릭 시 신규 예약 모달 열기
  const handleOpenNewAppModalToday = (e) => {
    e.preventDefault();
    isMedicalStaffView = false;
    const today = new Date();
    const todayString = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
    openNewAppModal(todayString);
  };
  if (headerAppointmentBtn) headerAppointmentBtn.addEventListener('click', handleOpenNewAppModalToday);
  if (mobileAppointmentBtn) mobileAppointmentBtn.addEventListener('click', handleOpenNewAppModalToday);

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
  if (closeManageModal) closeManageModal.addEventListener('click', closeManageModalFn);
  if (manageModalCloseBtn) manageModalCloseBtn.addEventListener('click', closeManageModalFn);
  
  // [의료진] > [환자 기본정보 관리] 메뉴 클릭 시 페이지 전환
  if (navPatientInfoManagement) {
    navPatientInfoManagement.addEventListener('click', openPatientManagement);
  }

  // 수정 모달 이벤트 리스너
  if (closeEditModal) closeEditModal.addEventListener('click', closeEditModalFn);
  if (cancelEditBtn) cancelEditBtn.addEventListener('click', closeEditModalFn);
  if (saveEditBtn) saveEditBtn.addEventListener('click', saveEditAppFn);

  // 신규 예약 모달 이벤트
  if (closeNewAppModal) closeNewAppModal.addEventListener('click', closeNewAppModalFn);
  if (cancelNewAppBtn) cancelNewAppBtn.addEventListener('click', closeNewAppModalFn);
  if (saveNewAppBtn) saveNewAppBtn.addEventListener('click', saveNewAppFn);

  // 환자 기본정보 관리 모달 이벤트 리스너
  if (closePatientEditModal) closePatientEditModal.addEventListener('click', closePatientEditModalFn);
  if (cancelPatientEditBtn) cancelPatientEditBtn.addEventListener('click', closePatientEditModalFn);
  if (savePatientInfoBtn) savePatientInfoBtn.addEventListener('click', savePatientInfoFn);

  // 로그아웃 이벤트
  if (logoutBtn) {
    logoutBtn.addEventListener('click', () => {
      localStorage.removeItem('hospital_logged_in_user');
      window.location.href = 'login.html';
      updateAuthButtons(); // 로그아웃 후 버튼 상태 업데이트
    });
  }

  renderCalendar();
});
