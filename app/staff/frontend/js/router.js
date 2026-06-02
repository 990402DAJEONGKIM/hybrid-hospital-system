// by 김다정 — 역할 기반 페이지 라우팅 (웹 구조도 반영)
// 로그인 성공 후 역할에 맞는 기본 페이지로 이동시킬 때 사용.

const ROLE_HOME = {
    doctor:   '/doctor-schedule.html',
    nurse:    '/nurse-dashboard.html',
    admin:    '/admin-users.html',
    staff_op: '/staff_op/reception.html',  // by 김다정 — 원무과 기본 랜딩 페이지
    manager:  '/manager/stats.html',        // by 김다정 — 운영관리자 기본 랜딩 페이지
};

// 역할에 맞는 홈 페이지로 이동. index.html 대시보드에서 직접 링크 클릭 시에도 활용 가능.
function routeByRole(role) {
    const dest = ROLE_HOME[role] || '/index.html';
    window.location.href = dest;
}

// 로그인 후 me 객체를 받아 즉시 라우팅.
function routeAfterLogin(me) {
    if (!me) return;
    if (me.password_expired) {
        window.location.href = '/change-password.html';
        return;
    }
    routeByRole(me.role);
}
