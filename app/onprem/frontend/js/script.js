// ── 공통 fetch (API Key 없음 — 내부망 전용) ──────────────────
const _fetchDefaults = {
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
};

async function _refreshTokens() {
    try {
        const res = await fetch(`${BASE_URL}/auth/refresh`, { method: 'POST', ..._fetchDefaults });
        return res.ok;
    } catch { return false; }
}

// ── 세션 만료 경고 ────────────────────────────────────────────
let _sessionWarnShown = false;

function _showSessionWarning(remaining) {
    if (_sessionWarnShown) return;
    _sessionWarnShown = true;
    const mins = Math.ceil(remaining / 60);
    let banner = document.getElementById('_sessionWarnBanner');
    if (!banner) {
        banner = document.createElement('div');
        banner.id = '_sessionWarnBanner';
        banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;background:#d97706;color:#fff;text-align:center;padding:10px 16px;font-weight:bold;font-size:14px;';
        banner.innerHTML = `세션이 약 ${mins}분 후 만료됩니다.
            <button onclick="extendSession()" style="margin-left:12px;padding:4px 14px;background:#fff;color:#d97706;border:none;border-radius:4px;font-weight:bold;cursor:pointer;">세션 연장</button>`;
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
    window.location.href = '/login.html';
}

async function requireLogin() {
    const res = await apiCall('/auth/me');
    if (!res || !res.ok) { window.location.href = '/login.html'; return null; }
    const me = await res.json();
    if (!['doctor', 'nurse', 'admin'].includes(me.role)) { window.location.href = '/login.html'; return null; }
    if (me.password_expired) { window.location.href = '/change-password.html'; return null; }
    return me;
}

// ── 사이드바 메뉴 렌더링 ─────────────────────────────────────
async function renderSidebar(me) {
    const nav = document.getElementById('sidebar-nav');
    if (!nav) return;

    const res = await apiCall('/auth/me/menus');
    if (!res || !res.ok) return;
    const menus = await res.json();

    const ICONS = {
        'user-injured': 'fa-user-injured', 'search': 'fa-search',
        'plus-circle': 'fa-plus-circle', 'hospital': 'fa-hospital',
        'users': 'fa-users', 'clipboard-list': 'fa-clipboard-list',
        'history': 'fa-history', 'key': 'fa-key', 'circle': 'fa-circle',
        'stethoscope': 'fa-stethoscope',
    };

    const currentPage = window.location.pathname.split('/').pop();
    nav.innerHTML = menus.map(m => {
        const icon = ICONS[m.icon] || 'fa-circle';
        const active = currentPage === m.menu_url.replace('/', '') ? 'sidebar-active' : '';
        return `<a href="${m.menu_url}" class="sidebar-link ${active}">
            <i class="fas ${icon} sidebar-icon"></i>
            <span>${m.menu_name}</span>
        </a>`;
    }).join('');
}

// ── 공통 헤더 초기화 ──────────────────────────────────────────
async function initPage() {
    const me = await requireLogin();
    if (!me) return null;

    const userInfo = document.getElementById('user-info');
    if (userInfo) {
        const ROLE_LABEL = { doctor: '의사', nurse: '원무과', admin: '관리자' };
        userInfo.textContent = `${ROLE_LABEL[me.role] || me.role} · ${me.email}`;
    }

    const logoutBtn = document.getElementById('logoutBtn');
    if (logoutBtn) logoutBtn.addEventListener('click', logout);

    await renderSidebar(me);
    return me;
}

// ── 유틸 ─────────────────────────────────────────────────────
function setStatus(elId, msg, ok) {
    const el = document.getElementById(elId);
    if (!el) return;
    el.textContent = msg;
    el.className   = ok ? 'status-ok' : 'status-err';
    el.style.display = 'block';
}

function formatDate(iso) {
    if (!iso) return '-';
    return iso.slice(0, 10);
}

function formatDateTime(iso) {
    if (!iso) return '-';
    return iso.replace('T', ' ').slice(0, 16);
}
