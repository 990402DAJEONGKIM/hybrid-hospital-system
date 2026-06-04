"""
GCP DR 예약 API — RDS 스키마 기준
2026-06-04
"""
import uuid
import os
import hashlib
from datetime import datetime, timezone, timedelta, date, time as dt_time
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from passlib.context import CryptContext
from jose import JWTError, jwt
from sqlalchemy import (
    create_engine, Column, String, Boolean, SmallInteger, Integer,
    DateTime, Date, Time, Text, ForeignKey, text as sa_text
)
from sqlalchemy.dialects.postgresql import UUID, INET
from sqlalchemy.orm import DeclarativeBase, relationship, Session, sessionmaker
from pydantic import BaseModel

# ── 환경변수 ───────────────────────────────────────────────────────────────────
DATABASE_URL  = os.environ["DATABASE_URL"]
JWT_SECRET    = os.environ["JWT_SECRET"]
JWT_ALGORITHM = os.environ.get("JWT_ALGORITHM", "HS256")
API_KEY       = os.environ["API_KEY"]
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "false").lower() == "true"
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "").split(",")
ACCESS_TOKEN_EXPIRE_MINUTES = 30
REFRESH_TOKEN_EXPIRE_DAYS   = 7

# ── DB ────────────────────────────────────────────────────────────────────────
engine       = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ── ORM ───────────────────────────────────────────────────────────────────────
class Base(DeclarativeBase):
    pass

class Role(Base):
    __tablename__ = "roles"
    role_id   = Column(Integer, primary_key=True)
    role_code = Column(String(30), nullable=False, unique=True)
    role_name = Column(String(100), nullable=False)

class User(Base):
    __tablename__ = "users"
    user_id              = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    member_number        = Column(String(20), unique=True)
    display_name         = Column(String(100))
    email                = Column(String(255), unique=True)
    password_hash        = Column(String(255), nullable=False)
    role_id              = Column(Integer, ForeignKey("roles.role_id"), nullable=False)
    doctor_id            = Column(UUID(as_uuid=True))
    is_active            = Column(Boolean, nullable=False, default=True)
    failed_login_cnt     = Column(SmallInteger, nullable=False, default=0)
    locked_until         = Column(DateTime(timezone=True))
    last_login_at        = Column(DateTime(timezone=True))
    password_changed_at  = Column(DateTime(timezone=True))
    password_expires_at  = Column(DateTime(timezone=True))
    must_change_password = Column(Boolean, nullable=False, default=False)
    created_at           = Column(DateTime(timezone=True), nullable=False)
    updated_at           = Column(DateTime(timezone=True), nullable=False)
    role_ref             = relationship("Role")

class SessionModel(Base):
    __tablename__ = "sessions"
    session_id         = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id            = Column(UUID(as_uuid=True), ForeignKey("users.user_id"), nullable=False)
    refresh_token_hash = Column(String(64), unique=True, nullable=False)
    user_agent         = Column(Text)
    ip_address         = Column(INET)
    expires_at         = Column(DateTime(timezone=True), nullable=False)
    last_used_at       = Column(DateTime(timezone=True), nullable=False)
    created_at         = Column(DateTime(timezone=True), nullable=False)
    is_revoked         = Column(Boolean, nullable=False, default=False)

class LoginHistory(Base):
    __tablename__ = "login_history"
    history_id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id    = Column(UUID(as_uuid=True))
    email      = Column(String(255))
    result     = Column(String(20), nullable=False)
    ip_address = Column(INET)
    user_agent = Column(Text)
    event_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

class PasswordPolicy(Base):
    __tablename__ = "password_policy"
    policy_id         = Column(Integer, primary_key=True)
    min_length        = Column(Integer, nullable=False, default=8)
    require_uppercase = Column(Boolean, nullable=False, default=True)
    require_lowercase = Column(Boolean, nullable=False, default=True)
    require_digit     = Column(Boolean, nullable=False, default=True)
    require_special   = Column(Boolean, nullable=False, default=True)
    expire_days       = Column(Integer, nullable=False, default=90)
    max_failed_logins = Column(Integer, nullable=False, default=5)
    lockout_minutes   = Column(Integer, nullable=False, default=30)
    updated_at        = Column(DateTime(timezone=True), nullable=False)

class AuditLog(Base):
    __tablename__ = "audit_logs"
    audit_log_id    = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id         = Column(UUID(as_uuid=True))
    patient_id_hash = Column(String(64))
    action_type     = Column(String(20), nullable=False)
    target_table    = Column(String(50))
    target_id       = Column(UUID(as_uuid=True))
    source_ip       = Column(INET)
    result_code     = Column(String(20))
    event_at        = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

class AppointmentType(Base):
    __tablename__ = "appointment_types"
    type_id                 = Column(Integer, primary_key=True)
    type_code               = Column(String(30), unique=True, nullable=False)
    type_name               = Column(String(100), nullable=False)
    requires_previous_visit = Column(Boolean, nullable=False, default=False)
    description             = Column(Text)
    is_active               = Column(Boolean, nullable=False, default=True)
    sort_order              = Column(Integer, nullable=False, default=0)

class AppointmentStatus(Base):
    __tablename__ = "appointment_statuses"
    status_id   = Column(Integer, primary_key=True)
    status_code = Column(String(20), unique=True, nullable=False)
    status_name = Column(String(50), nullable=False)
    is_terminal = Column(Boolean, nullable=False, default=False)
    sort_order  = Column(Integer, nullable=False, default=0)

class Appointment(Base):
    __tablename__ = "appointments"
    appointment_id        = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    patient_user_id       = Column(UUID(as_uuid=True), ForeignKey("users.user_id"), nullable=False)
    patient_id_hash       = Column(String(64))
    type_id               = Column(Integer, ForeignKey("appointment_types.type_id"), nullable=False)
    status_id             = Column(Integer, ForeignKey("appointment_statuses.status_id"), nullable=False)
    department_code       = Column(String(20))
    doctor_id             = Column(UUID(as_uuid=True))
    ward_id               = Column(UUID(as_uuid=True))
    room_type_pref        = Column(String(20))
    has_chronic_condition = Column(Boolean)
    appointment_date      = Column(Date, nullable=False)
    appointment_time      = Column(Time, nullable=False)
    confirmed_at          = Column(DateTime(timezone=True))
    confirmed_by          = Column(UUID(as_uuid=True))
    cancelled_at          = Column(DateTime(timezone=True))
    cancelled_by          = Column(UUID(as_uuid=True))
    cancel_reason         = Column(String(200))
    notes                 = Column(Text)
    created_at            = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at            = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    type_ref              = relationship("AppointmentType")
    status_ref            = relationship("AppointmentStatus")

class AppointmentHistory(Base):
    __tablename__ = "appointment_history"
    history_id     = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    appointment_id = Column(UUID(as_uuid=True), ForeignKey("appointments.appointment_id"), nullable=False)
    changed_by     = Column(UUID(as_uuid=True))
    prev_status_id = Column(Integer, ForeignKey("appointment_statuses.status_id"))
    new_status_id  = Column(Integer, ForeignKey("appointment_statuses.status_id"))
    prev_date      = Column(Date)
    new_date       = Column(Date)
    prev_time      = Column(Time)
    new_time       = Column(Time)
    change_reason  = Column(String(200))
    changed_at     = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

# ── 유틸 ──────────────────────────────────────────────────────────────────────
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_client_ip(request: Request) -> str:
    xff = request.headers.get("X-Forwarded-For")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"

def verify_api_key(request: Request) -> str:
    if request.headers.get("X-API-Key", "") != API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API Key")
    return API_KEY

def create_access_token(user: User) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    return jwt.encode({"sub": str(user.user_id), "role": user.role_ref.role_code, "exp": expire}, JWT_SECRET, algorithm=JWT_ALGORITHM)

def create_refresh_token(user: User) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    return jwt.encode({"sub": str(user.user_id), "type": "refresh", "exp": expire}, JWT_SECRET, algorithm=JWT_ALGORITHM)

def get_current_user(request: Request, db: Session = Depends(get_db)) -> User:
    token = request.cookies.get("access_token")
    if not token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = payload.get("sub")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    user = db.query(User).join(Role).filter(User.user_id == user_id, User.is_active == True).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return user

def get_password_policy(db: Session) -> PasswordPolicy:
    policy = db.query(PasswordPolicy).first()
    if not policy:
        policy = PasswordPolicy(policy_id=1, min_length=8, require_uppercase=True, require_lowercase=True,
                                require_digit=True, require_special=True, expire_days=90,
                                max_failed_logins=5, lockout_minutes=30, updated_at=datetime.now(timezone.utc))
    return policy

def _record_audit(db: Session, action_type: str, result_code: str, **kwargs):
    try:
        db.add(AuditLog(action_type=action_type, result_code=result_code, **kwargs))
        db.commit()
    except Exception:
        db.rollback()

def _get_patient_id_hash(user: User, db: Session) -> Optional[str]:
    appt = db.query(Appointment).filter(
        Appointment.patient_user_id == user.user_id,
        Appointment.patient_id_hash.isnot(None)
    ).first()
    return appt.patient_id_hash if appt else None

# ── Pydantic ──────────────────────────────────────────────────────────────────
class LoginRequest(BaseModel):
    member_number: str
    password: str

class AppointmentCancelRequest(BaseModel):
    cancel_reason: Optional[str] = None

class AppointmentCreateRequest(BaseModel):
    type_code: str
    department_code: str
    doctor_id: Optional[str] = None
    ward_id: Optional[str] = None
    room_type_pref: Optional[str] = None
    has_chronic_condition: Optional[bool] = None
    appointment_date: str
    appointment_time: str
    notes: Optional[str] = None

class ChangePasswordRequest(BaseModel):
    old_password: str
    new_password: str

# ── FastAPI ───────────────────────────────────────────────────────────────────
app = FastAPI(title="김이박 병원 DR 예약 API")
app.add_middleware(CORSMiddleware, allow_origins=ALLOWED_ORIGINS, allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

# ── 엔드포인트 ────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/auth/login")
def login(body: LoginRequest, request: Request, response: Response, db: Session = Depends(get_db), _: str = Depends(verify_api_key)):
    now = datetime.now(timezone.utc)
    ip  = get_client_ip(request)
    ua  = request.headers.get("user-agent")
    history = LoginHistory(email=None, ip_address=ip, user_agent=ua)

    user = db.query(User).join(Role).filter(User.member_number == body.member_number).first()
    if not user:
        history.result = "fail"
        db.add(history); db.commit()
        raise HTTPException(status_code=401, detail="회원번호 또는 비밀번호가 올바르지 않습니다.")

    history.user_id = user.user_id

    if user.locked_until and user.locked_until > now:
        history.result = "locked"
        db.add(history); db.commit()
        remaining = int((user.locked_until - now).total_seconds() / 60)
        raise HTTPException(status_code=401, detail=f"계정이 잠겨 있습니다. {remaining}분 후 재시도하세요.")

    if not user.is_active:
        history.result = "fail"
        db.add(history); db.commit()
        raise HTTPException(status_code=401, detail="비활성화된 계정입니다.")

    if not pwd_context.verify(body.password, user.password_hash):
        policy = get_password_policy(db)
        user.failed_login_cnt += 1
        history.result = "fail"
        if user.failed_login_cnt >= policy.max_failed_logins:
            user.locked_until = now + timedelta(minutes=policy.lockout_minutes)
            history.result = "locked"
            _record_audit(db, "ACCOUNT_LOCKED", "401", user_id=user.user_id, source_ip=ip)
        db.add(history); db.commit()
        raise HTTPException(status_code=401, detail="회원번호 또는 비밀번호가 올바르지 않습니다.")

    if user.role_ref.role_code != "patient":
        history.result = "fail"
        db.add(history); db.commit()
        raise HTTPException(status_code=403, detail="환자 계정만 사용할 수 있습니다.")

    user.failed_login_cnt = 0
    user.locked_until     = None
    user.last_login_at    = now
    history.result        = "success"
    db.add(history)
    _record_audit(db, "LOGIN", "200", user_id=user.user_id, source_ip=ip)
    db.commit()

    access_token  = create_access_token(user)
    refresh_token = create_refresh_token(user)
    rt_hash = hashlib.sha256(refresh_token.encode()).hexdigest()
    db.add(SessionModel(user_id=user.user_id, refresh_token_hash=rt_hash, user_agent=ua, ip_address=ip,
                        expires_at=now + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS),
                        last_used_at=now, created_at=now))
    db.commit()

    response.set_cookie("access_token",  access_token,  httponly=True, secure=COOKIE_SECURE, samesite="lax", max_age=ACCESS_TOKEN_EXPIRE_MINUTES*60)
    response.set_cookie("refresh_token", refresh_token, httponly=True, secure=COOKIE_SECURE, samesite="lax", max_age=REFRESH_TOKEN_EXPIRE_DAYS*86400)

    password_expired = bool(user.password_expires_at and user.password_expires_at < now)
    return {"user_id": str(user.user_id), "member_number": user.member_number, "display_name": user.display_name,
            "role": user.role_ref.role_code, "must_change_password": user.must_change_password or password_expired}

@app.post("/auth/refresh")
def refresh(request: Request, response: Response, db: Session = Depends(get_db), _: str = Depends(verify_api_key)):
    token = request.cookies.get("refresh_token")
    if not token:
        raise HTTPException(status_code=401, detail="Refresh token missing")
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = payload.get("sub")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid refresh token")
    rt_hash = hashlib.sha256(token.encode()).hexdigest()
    session = db.query(SessionModel).filter(SessionModel.refresh_token_hash == rt_hash,
                                            SessionModel.is_revoked == False,
                                            SessionModel.expires_at > datetime.now(timezone.utc)).first()
    if not session:
        raise HTTPException(status_code=401, detail="Session expired or revoked")
    user = db.query(User).join(Role).filter(User.user_id == user_id, User.is_active == True).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    new_access = create_access_token(user)
    session.last_used_at = datetime.now(timezone.utc)
    db.commit()
    response.set_cookie("access_token", new_access, httponly=True, secure=COOKIE_SECURE, samesite="lax", max_age=ACCESS_TOKEN_EXPIRE_MINUTES*60)
    return {"ok": True}

@app.post("/auth/logout")
def logout(request: Request, response: Response, db: Session = Depends(get_db), _: str = Depends(verify_api_key)):
    token = request.cookies.get("refresh_token")
    if token:
        rt_hash = hashlib.sha256(token.encode()).hexdigest()
        session = db.query(SessionModel).filter(SessionModel.refresh_token_hash == rt_hash).first()
        if session:
            session.is_revoked = True
            db.commit()
    response.delete_cookie("access_token")
    response.delete_cookie("refresh_token")
    return {"ok": True}

@app.get("/auth/me")
def me(_: str = Depends(verify_api_key), user: User = Depends(get_current_user)):
    now = datetime.now(timezone.utc)
    password_expired = bool(user.password_expires_at and user.password_expires_at < now)
    return {"user_id": str(user.user_id), "member_number": user.member_number, "display_name": user.display_name,
            "role": user.role_ref.role_code, "must_change_password": user.must_change_password or password_expired,
            "password_expired": password_expired}

@app.post("/auth/change-password")
def change_password(body: ChangePasswordRequest, db: Session = Depends(get_db), _: str = Depends(verify_api_key), user: User = Depends(get_current_user)):
    if not pwd_context.verify(body.old_password, user.password_hash):
        raise HTTPException(status_code=400, detail="현재 비밀번호가 올바르지 않습니다.")
    policy = get_password_policy(db)
    now = datetime.now(timezone.utc)
    user.password_hash        = pwd_context.hash(body.new_password)
    user.password_changed_at  = now
    user.must_change_password = False
    user.password_expires_at  = now + timedelta(days=policy.expire_days)
    user.updated_at           = now
    db.commit()
    return {"ok": True}

@app.get("/portal/me")
def portal_me(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    now = datetime.now(timezone.utc)
    password_expired = bool(user.password_expires_at and user.password_expires_at < now)
    return {"user_id": str(user.user_id), "member_number": user.member_number, "display_name": user.display_name,
            "role": user.role_ref.role_code, "must_change_password": user.must_change_password or password_expired,
            "password_expired": password_expired}

@app.get("/portal/my-profile")
def portal_my_profile(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    now = datetime.now(timezone.utc)
    password_expired = bool(user.password_expires_at and user.password_expires_at < now)
    return {"user_id": str(user.user_id), "member_number": user.member_number, "display_name": user.display_name,
            "email": user.email, "role": user.role_ref.role_code,
            "must_change_password": user.must_change_password or password_expired, "password_expired": password_expired}

@app.get("/portal/appointment-types")
def get_appointment_types(_: str = Depends(verify_api_key), __: User = Depends(get_current_user), db: Session = Depends(get_db)):
    types = db.query(AppointmentType).filter(AppointmentType.is_active == True).order_by(AppointmentType.sort_order).all()
    return [{"type_id": t.type_id, "type_code": t.type_code, "type_name": t.type_name,
             "requires_previous_visit": t.requires_previous_visit, "description": t.description} for t in types]

@app.get("/portal/departments")
def get_departments(visited_only: Optional[bool] = None, _: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    if visited_only:
        pid_hash = _get_patient_id_hash(user, db)
        if pid_hash:
            rows = db.execute(sa_text("SELECT DISTINCT e.department_code, d.department_name FROM sync_encounters e JOIN sync_departments d ON e.department_code=d.department_code WHERE e.patient_id_hash=:pid"), {"pid": pid_hash}).fetchall()
            return [{"department_code": r.department_code, "department_name": r.department_name} for r in rows]
        return []
    depts = db.execute(sa_text("SELECT department_code, department_name FROM sync_departments WHERE is_active=true")).fetchall()
    return [{"department_code": d.department_code, "department_name": d.department_name} for d in depts]

@app.get("/portal/doctors")
def get_doctors(department_code: Optional[str] = None, _: str = Depends(verify_api_key), __: User = Depends(get_current_user), db: Session = Depends(get_db)):
    q = "SELECT doctor_id, doctor_name, department_code FROM sync_doctors WHERE is_active=true"
    params = {}
    if department_code:
        q += " AND department_code=:dept"
        params["dept"] = department_code
    rows = db.execute(sa_text(q), params).fetchall()
    return [{"doctor_id": str(r.doctor_id), "doctor_name": r.doctor_name, "department_code": r.department_code} for r in rows]

@app.get("/portal/appointments/available-slots")
def get_available_slots(appointment_date: str, doctor_id: Optional[str] = None, department_code: Optional[str] = None,
                        _: str = Depends(verify_api_key), __: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        target_date = date.fromisoformat(appointment_date)
    except ValueError:
        raise HTTPException(status_code=400, detail="날짜 형식 오류 (YYYY-MM-DD)")
    all_slots = [dt_time(h, m) for h in range(9, 18) for m in (0, 30)]
    active_status_ids = [r[0] for r in db.execute(sa_text("SELECT status_id FROM appointment_statuses WHERE status_code IN ('pending','confirmed')")).fetchall()]
    q = db.query(Appointment.appointment_time).filter(Appointment.appointment_date == target_date, Appointment.status_id.in_(active_status_ids))
    if doctor_id:
        q = q.filter(Appointment.doctor_id == uuid.UUID(doctor_id))
    if department_code:
        q = q.filter(Appointment.department_code == department_code)
    booked = {r[0] for r in q.all()}
    return {"date": appointment_date, "available_slots": [s.strftime("%H:%M") for s in all_slots if s not in booked]}

@app.get("/portal/appointments")
def get_appointments(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appointments = db.query(Appointment).filter(Appointment.patient_user_id == user.user_id).order_by(Appointment.appointment_date.desc(), Appointment.appointment_time.desc()).all()
    result = []
    for a in appointments:
        dept_name = None
        doctor_name = None
        if a.department_code:
            r = db.execute(sa_text("SELECT department_name FROM sync_departments WHERE department_code=:c"), {"c": a.department_code}).fetchone()
            dept_name = r.department_name if r else None
        if a.doctor_id:
            r = db.execute(sa_text("SELECT doctor_name FROM sync_doctors WHERE doctor_id=:d"), {"d": a.doctor_id}).fetchone()
            doctor_name = r.doctor_name if r else None
        result.append({"appointment_id": str(a.appointment_id),
                       "type_code": a.type_ref.type_code if a.type_ref else None,
                       "type_name": a.type_ref.type_name if a.type_ref else None,
                       "status_code": a.status_ref.status_code if a.status_ref else None,
                       "status_name": a.status_ref.status_name if a.status_ref else None,
                       "department_code": a.department_code, "department_name": dept_name,
                       "doctor_id": str(a.doctor_id) if a.doctor_id else None, "doctor_name": doctor_name,
                       "appointment_date": a.appointment_date.isoformat(),
                       "appointment_time": a.appointment_time.strftime("%H:%M"),
                       "notes": a.notes, "created_at": a.created_at.isoformat()})
    return result

@app.post("/portal/appointments", status_code=201)
def create_appointment(body: AppointmentCreateRequest, _: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    atype = db.query(AppointmentType).filter(AppointmentType.type_code == body.type_code).first()
    if not atype:
        raise HTTPException(status_code=400, detail="유효하지 않은 예약 유형입니다.")
    pending_status = db.query(AppointmentStatus).filter(AppointmentStatus.status_code == "pending").first()
    if not pending_status:
        raise HTTPException(status_code=500, detail="예약 상태 설정 오류")
    try:
        appt_date = date.fromisoformat(body.appointment_date)
        h, m = map(int, body.appointment_time.split(":"))
        appt_time = dt_time(h, m)
    except (ValueError, AttributeError):
        raise HTTPException(status_code=400, detail="날짜/시간 형식 오류")
    patient_id_hash = _get_patient_id_hash(user, db)
    appt = Appointment(patient_user_id=user.user_id, patient_id_hash=patient_id_hash,
                       type_id=atype.type_id, status_id=pending_status.status_id,
                       department_code=body.department_code,
                       doctor_id=uuid.UUID(body.doctor_id) if body.doctor_id else None,
                       ward_id=uuid.UUID(body.ward_id) if body.ward_id else None,
                       room_type_pref=body.room_type_pref, has_chronic_condition=body.has_chronic_condition,
                       appointment_date=appt_date, appointment_time=appt_time, notes=body.notes)
    db.add(appt)
    _record_audit(db, "APPOINTMENT_CREATE", "201", user_id=user.user_id, patient_id_hash=patient_id_hash)
    db.commit()
    db.refresh(appt)
    return {"appointment_id": str(appt.appointment_id), "status": "pending"}

@app.post("/portal/appointments/{appointment_id}/cancel")
def cancel_appointment(appointment_id: str, body: AppointmentCancelRequest, _: str = Depends(verify_api_key),
                       user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.query(Appointment).filter(Appointment.appointment_id == uuid.UUID(appointment_id),
                                        Appointment.patient_user_id == user.user_id).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")
    if appt.status_ref and appt.status_ref.is_terminal:
        raise HTTPException(status_code=400, detail="이미 완료되거나 취소된 예약입니다.")
    cancelled_status = db.query(AppointmentStatus).filter(AppointmentStatus.status_code == "cancelled").first()
    if not cancelled_status:
        raise HTTPException(status_code=500, detail="취소 상태 설정 오류")
    prev_status_id = appt.status_id
    now = datetime.now(timezone.utc)
    appt.status_id     = cancelled_status.status_id
    appt.cancelled_at  = now
    appt.cancelled_by  = user.user_id
    appt.cancel_reason = body.cancel_reason
    appt.updated_at    = now
    db.add(AppointmentHistory(appointment_id=appt.appointment_id, changed_by=user.user_id,
                              prev_status_id=prev_status_id, new_status_id=cancelled_status.status_id,
                              change_reason=body.cancel_reason))
    _record_audit(db, "APPOINTMENT_CANCEL", "200", user_id=user.user_id, patient_id_hash=appt.patient_id_hash)
    db.commit()
    return {"ok": True}

@app.get("/portal/my-records")
def portal_my_records(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    pid_hash = _get_patient_id_hash(user, db)
    if not pid_hash:
        return []
    rows = db.execute(sa_text("""
        SELECT e.encounter_id, e.encounter_type, e.department_code, d.department_name,
               e.doctor_id, doc.doctor_name, e.visit_date, e.status_code
        FROM sync_encounters e
        LEFT JOIN sync_departments d ON e.department_code=d.department_code
        LEFT JOIN sync_doctors doc ON e.doctor_id=doc.doctor_id
        WHERE e.patient_id_hash=:pid ORDER BY e.visit_date DESC
    """), {"pid": pid_hash}).fetchall()
    return [{"encounter_id": str(r.encounter_id), "encounter_type": r.encounter_type,
             "department_code": r.department_code, "department_name": r.department_name,
             "doctor_name": r.doctor_name, "visit_date": r.visit_date.isoformat() if r.visit_date else None,
             "status_code": r.status_code} for r in rows]

@app.get("/portal/recent-encounter")
def portal_recent_encounter(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    pid_hash = _get_patient_id_hash(user, db)
    if not pid_hash:
        return None
    r = db.execute(sa_text("""
        SELECT e.encounter_id, e.encounter_type, e.department_code, d.department_name,
               e.doctor_id, doc.doctor_name, e.visit_date
        FROM sync_encounters e
        LEFT JOIN sync_departments d ON e.department_code=d.department_code
        LEFT JOIN sync_doctors doc ON e.doctor_id=doc.doctor_id
        WHERE e.patient_id_hash=:pid ORDER BY e.visit_date DESC LIMIT 1
    """), {"pid": pid_hash}).fetchone()
    if not r:
        return None
    return {"encounter_id": str(r.encounter_id), "encounter_type": r.encounter_type,
            "department_code": r.department_code, "department_name": r.department_name,
            "doctor_name": r.doctor_name, "visit_date": r.visit_date.isoformat() if r.visit_date else None}

@app.get("/portal/allergies")
def portal_allergies(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    pid_hash = _get_patient_id_hash(user, db)
    if not pid_hash:
        return []
    rows = db.execute(sa_text("SELECT allergy_id, allergy_name, severity_code FROM sync_allergies WHERE patient_id_hash=:pid"), {"pid": pid_hash}).fetchall()
    return [{"allergy_id": str(r.allergy_id), "allergy_name": r.allergy_name, "severity_code": r.severity_code} for r in rows]

@app.get("/portal/surgery-histories")
def portal_surgery_histories(_: str = Depends(verify_api_key), user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    pid_hash = _get_patient_id_hash(user, db)
    if not pid_hash:
        return []
    rows = db.execute(sa_text("SELECT surgery_history_id, surgery_name, surgery_date FROM sync_surgery_histories WHERE patient_id_hash=:pid ORDER BY surgery_date DESC"), {"pid": pid_hash}).fetchall()
    return [{"surgery_history_id": str(r.surgery_history_id), "surgery_name": r.surgery_name,
             "surgery_date": r.surgery_date.isoformat() if r.surgery_date else None} for r in rows]
