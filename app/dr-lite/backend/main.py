import hashlib
import os
import secrets
import uuid
from datetime import date as date_type
from datetime import datetime, timedelta, time as time_type, timezone
from typing import Optional

from dotenv import load_dotenv
from fastapi import Cookie, Depends, FastAPI, HTTPException, Query, Request, Response, Security
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import APIKeyHeader
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel, EmailStr
from sqlalchemy import Boolean, Column, Date, DateTime, ForeignKey, Integer, SmallInteger, String, Text, Time, Uuid, create_engine, text
from sqlalchemy.dialects.postgresql import INET
from sqlalchemy.orm import DeclarativeBase, Session, relationship, sessionmaker

load_dotenv()

DATABASE_URL = os.environ["DATABASE_URL"]
JWT_SECRET = os.getenv("JWT_SECRET", "changeme")
JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
API_KEY = os.getenv("API_KEY", "")
COOKIE_SECURE = os.getenv("COOKIE_SECURE", "true").lower() == "true"
ACCESS_TOKEN_EXPIRE_SECONDS = int(os.getenv("ACCESS_TOKEN_EXPIRE_SECONDS", "1800"))
REFRESH_TOKEN_EXPIRE_HOURS = int(os.getenv("REFRESH_TOKEN_EXPIRE_HOURS", "8"))

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
api_key_header = APIKeyHeader(name="X-API-Key")


class Base(DeclarativeBase):
    pass


class Role(Base):
    __tablename__ = "roles"

    role_id = Column(Integer, primary_key=True)
    role_code = Column(String(30), nullable=False, unique=True)
    role_name = Column(String(100), nullable=False)


class User(Base):
    __tablename__ = "users"

    user_id = Column(Uuid, primary_key=True, default=uuid.uuid4)
    email = Column(String(255), nullable=False, unique=True)
    password_hash = Column(String(255), nullable=False)
    role_id = Column(Integer, ForeignKey("roles.role_id"), nullable=False)
    patient_id_hash = Column(String(64))
    doctor_id = Column(Uuid)
    is_active = Column(Boolean, nullable=False, default=True)
    failed_login_cnt = Column(SmallInteger, nullable=False, default=0)
    locked_until = Column(DateTime(timezone=True))
    last_login_at = Column(DateTime(timezone=True))
    password_changed_at = Column(DateTime(timezone=True))
    password_expires_at = Column(DateTime(timezone=True))
    updated_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    role_ref = relationship("Role")


class SessionModel(Base):
    __tablename__ = "sessions"

    session_id = Column(Uuid, primary_key=True, default=uuid.uuid4)
    user_id = Column(Uuid, ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False)
    refresh_token_hash = Column(String(64), nullable=False, unique=True)
    user_agent = Column(Text)
    ip_address = Column(INET)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    last_used_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    created_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    is_revoked = Column(Boolean, nullable=False, default=False)


class PasswordPolicy(Base):
    __tablename__ = "password_policy"

    policy_id = Column(Integer, primary_key=True)
    expire_days = Column(Integer, nullable=False, default=90)
    max_failed_logins = Column(Integer, nullable=False, default=5)
    lockout_minutes = Column(Integer, nullable=False, default=30)


class LoginHistory(Base):
    __tablename__ = "login_history"

    history_id = Column(Uuid, primary_key=True, default=uuid.uuid4)
    user_id = Column(Uuid, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    email = Column(String(255))
    result = Column(String(10), nullable=False)
    ip_address = Column(INET)
    user_agent = Column(Text)
    event_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class AppointmentType(Base):
    __tablename__ = "appointment_types"

    type_id = Column(Integer, primary_key=True)
    type_code = Column(String(30), nullable=False, unique=True)
    type_name = Column(String(100), nullable=False)
    requires_previous_visit = Column(Boolean, nullable=False, default=False)
    description = Column(Text)
    is_active = Column(Boolean, nullable=False, default=True)
    sort_order = Column(Integer, nullable=False, default=0)


class AppointmentStatus(Base):
    __tablename__ = "appointment_statuses"

    status_id = Column(Integer, primary_key=True)
    status_code = Column(String(20), nullable=False, unique=True)
    status_name = Column(String(50), nullable=False)
    is_terminal = Column(Boolean, nullable=False, default=False)


class SyncDepartment(Base):
    __tablename__ = "sync_departments"

    department_code = Column(String(20), primary_key=True)
    department_name = Column(String(100))
    is_active = Column(Boolean)


class SyncDoctor(Base):
    __tablename__ = "sync_doctors"

    doctor_id = Column(Uuid, primary_key=True)
    doctor_name = Column(String(100))
    department_code = Column(String(20), ForeignKey("sync_departments.department_code"))
    is_active = Column(Boolean)


class SyncPatient(Base):
    __tablename__ = "sync_patients"

    patient_id_hash = Column(String(64), primary_key=True)
    patient_name = Column(String(100))
    birth_date = Column(Date)
    is_active = Column(Boolean, default=True)


class SyncEncounter(Base):
    __tablename__ = "sync_encounters"

    encounter_id = Column(String(36), primary_key=True)
    patient_id_hash = Column(String(64))
    department_code = Column(String(20), ForeignKey("sync_departments.department_code"))


class Appointment(Base):
    __tablename__ = "appointments"

    appointment_id = Column(Uuid, primary_key=True, default=uuid.uuid4)
    patient_user_id = Column(Uuid, ForeignKey("users.user_id"), nullable=False)
    patient_id_hash = Column(String(64), ForeignKey("sync_patients.patient_id_hash"))
    type_id = Column(Integer, ForeignKey("appointment_types.type_id"), nullable=False)
    status_id = Column(Integer, ForeignKey("appointment_statuses.status_id"), nullable=False)
    department_code = Column(String(20), ForeignKey("sync_departments.department_code"))
    doctor_id = Column(Uuid, ForeignKey("sync_doctors.doctor_id"))
    ward_id = Column(Uuid)
    room_type_pref = Column(String(20))
    has_chronic_condition = Column(Boolean)
    appointment_date = Column(Date, nullable=False)
    appointment_time = Column(Time, nullable=False)
    confirmed_at = Column(DateTime(timezone=True))
    confirmed_by = Column(Uuid)
    cancelled_at = Column(DateTime(timezone=True))
    cancelled_by = Column(Uuid)
    cancel_reason = Column(String(200))
    notes = Column(Text)
    created_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    appt_type = relationship("AppointmentType")
    appt_status = relationship("AppointmentStatus")
    # [FIX] doctor_name을 _appointment_out에서 쓸 수 있도록 relationship 추가
    doctor_ref = relationship("SyncDoctor", foreign_keys=[doctor_id])


class AppointmentHistory(Base):
    __tablename__ = "appointment_history"

    history_id = Column(Uuid, primary_key=True, default=uuid.uuid4)
    appointment_id = Column(Uuid, ForeignKey("appointments.appointment_id", ondelete="CASCADE"), nullable=False)
    changed_by = Column(Uuid, ForeignKey("users.user_id"))
    prev_status_id = Column(Integer, ForeignKey("appointment_statuses.status_id"))
    new_status_id = Column(Integer, ForeignKey("appointment_statuses.status_id"))
    prev_date = Column(Date)
    new_date = Column(Date)
    prev_time = Column(Time)
    new_time = Column(Time)
    change_reason = Column(String(200))
    changed_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class AuditLog(Base):
    __tablename__ = "audit_logs"

    audit_log_id = Column(Uuid, primary_key=True, default=uuid.uuid4)
    user_id = Column(Uuid, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    patient_id_hash = Column(String(64))
    action_type = Column(String(20), nullable=False)
    target_table = Column(String(50))
    target_id = Column(Uuid)
    source_ip = Column(INET)
    result_code = Column(String(20))
    event_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


# ── Pydantic 요청 모델 ─────────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class AppointmentCancelRequest(BaseModel):
    cancel_reason: Optional[str] = None


class AppointmentCreateRequest(BaseModel):
    type_code: str
    department_code: str
    doctor_id: Optional[str] = None
    appointment_date: str
    appointment_time: str
    notes: Optional[str] = None


# ── FastAPI 앱 ─────────────────────────────────────────────────────────────────

app = FastAPI(title="김이박 병원 DR 예약 API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "*").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Key"],
)


# ── 공통 유틸 ──────────────────────────────────────────────────────────────────

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def verify_api_key(key: str = Security(api_key_header)) -> str:
    if key != API_KEY:
        raise HTTPException(status_code=403, detail="유효하지 않은 API 키입니다.")
    return key


def get_client_ip(request: Request) -> Optional[str]:
    real_ip = request.headers.get("X-Real-IP")
    if real_ip:
        return real_ip
    forwarded_for = request.headers.get("X-Forwarded-For")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()
    return request.client.host if request.client else None


def get_password_policy(db: Session) -> PasswordPolicy:
    policy = db.query(PasswordPolicy).first()
    if policy:
        return policy
    fallback = object.__new__(PasswordPolicy)
    fallback.expire_days = 90
    fallback.max_failed_logins = 5
    fallback.lockout_minutes = 30
    return fallback


def create_access_token(user: User) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user.user_id),
        "role": user.role_ref.role_code,
        "pid": user.patient_id_hash,
        "iat": int(now.timestamp()),
        "exp": int((now.timestamp()) + ACCESS_TOKEN_EXPIRE_SECONDS),
    }
    if user.doctor_id:
        payload["did"] = str(user.doctor_id)
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def get_current_user(access_token: str | None = Cookie(default=None), _: str = Depends(verify_api_key)) -> dict:
    if not access_token:
        raise HTTPException(status_code=401, detail="로그인이 필요합니다.")
    try:
        return jwt.decode(access_token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except JWTError:
        raise HTTPException(status_code=401, detail="유효하지 않은 인증입니다.")


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def _set_auth_cookies(response: Response, access_token: str, refresh_token: str) -> None:
    response.set_cookie(
        key="access_token",
        value=access_token,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite="strict",
        max_age=ACCESS_TOKEN_EXPIRE_SECONDS,
        path="/",
    )
    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite="strict",
        max_age=REFRESH_TOKEN_EXPIRE_HOURS * 3600,
        path="/auth/refresh",
    )


def _record_audit(
    db: Session,
    action_type: str,
    result_code: str,
    user_id=None,
    patient_id_hash: Optional[str] = None,
    target_table: Optional[str] = None,
    target_id=None,
    source_ip: Optional[str] = None,
) -> None:
    db.add(AuditLog(
        user_id=user_id,
        patient_id_hash=patient_id_hash,
        action_type=action_type,
        target_table=target_table,
        target_id=target_id,
        source_ip=source_ip,
        result_code=result_code,
    ))


def _require_patient(current_user: dict) -> None:
    if current_user.get("role") != "patient" or not current_user.get("pid"):
        raise HTTPException(status_code=403, detail="환자 계정만 이용 가능합니다.")


def _appointment_out(appt: Appointment) -> dict:
    return {
        "appointment_id": str(appt.appointment_id),
        "type_code": appt.appt_type.type_code if appt.appt_type else None,
        "type_name": appt.appt_type.type_name if appt.appt_type else None,
        "status_code": appt.appt_status.status_code if appt.appt_status else None,
        "status_name": appt.appt_status.status_name if appt.appt_status else None,
        "department_code": appt.department_code,
        "doctor_id": str(appt.doctor_id) if appt.doctor_id else None,
        # [FIX] doctor_ref relationship으로 의사 이름 포함
        "doctor_name": appt.doctor_ref.doctor_name if appt.doctor_ref else None,
        "appointment_date": str(appt.appointment_date),
        "appointment_time": appt.appointment_time.strftime("%H:%M") if appt.appointment_time else None,
        "notes": appt.notes,
        "created_at": appt.created_at.isoformat() if appt.created_at else None,
        "cancelled_at": appt.cancelled_at.isoformat() if appt.cancelled_at else None,
        "cancel_reason": appt.cancel_reason,
    }


# ── 엔드포인트 ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok", "mode": "gcp-dr"}


@app.post("/auth/login")
def login(
    body: LoginRequest,
    request: Request,
    db: Session = Depends(get_db),
    _: str = Depends(verify_api_key),
):
    now = datetime.now(timezone.utc)
    ip_address = get_client_ip(request)
    history = LoginHistory(email=body.email, ip_address=ip_address, user_agent=request.headers.get("user-agent"))
    user = db.query(User).join(Role).filter(User.email == body.email).first()

    if not user:
        history.result = "fail"
        db.add(history)
        db.commit()
        raise HTTPException(status_code=401, detail="이메일 또는 비밀번호가 올바르지 않습니다.")

    history.user_id = user.user_id
    if user.locked_until and user.locked_until > now:
        history.result = "locked"
        db.add(history)
        db.commit()
        remaining = int((user.locked_until - now).total_seconds() / 60)
        raise HTTPException(status_code=401, detail=f"계정이 잠겨 있습니다. {remaining}분 후 재시도하세요.")

    if not user.is_active:
        history.result = "fail"
        db.add(history)
        db.commit()
        raise HTTPException(status_code=401, detail="비활성화된 계정입니다. 관리자에게 문의하세요.")

    if not pwd_context.verify(body.password, user.password_hash):
        policy = get_password_policy(db)
        history.result = "fail"
        user.failed_login_cnt += 1
        if user.failed_login_cnt >= policy.max_failed_logins:
            user.locked_until = now + timedelta(minutes=policy.lockout_minutes)
            history.result = "locked"
            _record_audit(db, "ACCOUNT_LOCKED", "401", user_id=user.user_id, source_ip=ip_address)
        db.add(history)
        db.commit()
        raise HTTPException(status_code=401, detail="이메일 또는 비밀번호가 올바르지 않습니다.")

    if user.role_ref.role_code != "patient" or not user.patient_id_hash:
        history.result = "fail"
        db.add(history)
        db.commit()
        raise HTTPException(status_code=403, detail="DR 예약 사이트는 환자 계정만 사용할 수 있습니다.")

    user.failed_login_cnt = 0
    user.locked_until = None
    user.last_login_at = now
    history.result = "success"
    db.add(history)
    _record_audit(db, "LOGIN", "200", user_id=user.user_id, patient_id_hash=user.patient_id_hash, source_ip=ip_address)

    access_token = create_access_token(user)
    refresh_token = _generate_refresh_token()
    db.add(SessionModel(
        user_id=user.user_id,
        refresh_token_hash=_sha256(refresh_token),
        user_agent=request.headers.get("user-agent"),
        ip_address=ip_address,
        expires_at=now + timedelta(hours=REFRESH_TOKEN_EXPIRE_HOURS),
    ))
    db.commit()

    response = JSONResponse({
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_SECONDS,
        "access_token_expires_at": (now + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)).isoformat(),
    })
    _set_auth_cookies(response, access_token, refresh_token)
    return response


@app.post("/auth/refresh")
def refresh(request: Request, db: Session = Depends(get_db), _: str = Depends(verify_api_key)):
    refresh_token = request.cookies.get("refresh_token")
    if not refresh_token:
        raise HTTPException(status_code=401, detail="유효하지 않은 세션입니다. 다시 로그인하세요.")

    now = datetime.now(timezone.utc)
    session = db.query(SessionModel).filter(SessionModel.refresh_token_hash == _sha256(refresh_token)).first()
    if not session or session.is_revoked or session.expires_at < now:
        if session and not session.is_revoked:
            session.is_revoked = True
            db.commit()
        raise HTTPException(status_code=401, detail="유효하지 않은 세션입니다. 다시 로그인하세요.")

    user = db.query(User).join(Role).filter(User.user_id == session.user_id, User.is_active == True).first()
    if not user:
        session.is_revoked = True
        db.commit()
        raise HTTPException(status_code=401, detail="사용자를 찾을 수 없습니다.")

    session.is_revoked = True
    session.last_used_at = now
    access_token = create_access_token(user)
    new_refresh_token = _generate_refresh_token()
    db.add(SessionModel(
        user_id=user.user_id,
        refresh_token_hash=_sha256(new_refresh_token),
        user_agent=request.headers.get("user-agent"),
        ip_address=get_client_ip(request),
        expires_at=now + timedelta(hours=REFRESH_TOKEN_EXPIRE_HOURS),
    ))
    db.commit()

    response = JSONResponse({
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_SECONDS,
        "access_token_expires_at": (now + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)).isoformat(),
    })
    _set_auth_cookies(response, access_token, new_refresh_token)
    return response


@app.post("/auth/logout")
def logout(request: Request, db: Session = Depends(get_db), _: str = Depends(verify_api_key)):
    refresh_token = request.cookies.get("refresh_token")
    if refresh_token:
        session = db.query(SessionModel).filter(SessionModel.refresh_token_hash == _sha256(refresh_token)).first()
        if session:
            session.is_revoked = True
            _record_audit(db, "LOGOUT", "200", user_id=session.user_id, source_ip=get_client_ip(request))
            db.commit()
    response = JSONResponse({"message": "로그아웃되었습니다."})
    response.delete_cookie("access_token", path="/")
    response.delete_cookie("refresh_token", path="/auth/refresh")
    return response


@app.get("/portal/me")
def me(current_user: dict = Depends(get_current_user), db: Session = Depends(get_db)):
    user = db.query(User).filter(User.user_id == uuid.UUID(current_user["sub"])).first()
    if not user:
        raise HTTPException(status_code=401, detail="사용자를 찾을 수 없습니다.")
    policy = get_password_policy(db)
    now = datetime.now(timezone.utc)
    password_expired = False
    if user.password_expires_at:
        password_expired = user.password_expires_at <= now
    elif user.password_changed_at:
        password_expired = (now - user.password_changed_at).days >= policy.expire_days
    return {
        "email": user.email,
        "role": user.role_ref.role_code,
        "patient_id_hash": current_user.get("pid"),
        "password_expired": password_expired,
        "password_expire_days": policy.expire_days,
    }


@app.get("/portal/appointment-types")
def appointment_types(_: dict = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.query(AppointmentType).filter(AppointmentType.is_active == True).order_by(AppointmentType.sort_order).all()
    return [
        {
            "type_code": row.type_code,
            "type_name": row.type_name,
            "requires_previous_visit": row.requires_previous_visit,
            "description": row.description,
        }
        for row in rows
    ]


@app.get("/portal/departments")
def departments(_: dict = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.query(SyncDepartment).filter(SyncDepartment.is_active == True).order_by(SyncDepartment.department_name).all()
    return [{"department_code": row.department_code, "department_name": row.department_name} for row in rows]


@app.get("/portal/doctors")
def doctors(
    department_code: Optional[str] = Query(default=None),
    _: dict = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    q = db.query(SyncDoctor).filter(SyncDoctor.is_active == True)
    if department_code:
        q = q.filter(SyncDoctor.department_code == department_code)
    return [
        {"doctor_id": str(row.doctor_id), "doctor_name": row.doctor_name, "department_code": row.department_code}
        for row in q.order_by(SyncDoctor.doctor_name).all()
    ]


@app.get("/portal/appointments/available-slots")
def available_slots(
    date: str = Query(...),
    doctor_id: Optional[str] = Query(default=None),
    department_code: Optional[str] = Query(default=None),
    _: dict = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        target_date = date_type.fromisoformat(date)
    except ValueError:
        raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")
    if target_date < date_type.today():
        raise HTTPException(status_code=400, detail="과거 날짜는 조회할 수 없습니다.")

    all_slots = [time_type(h, m) for h in range(9, 18) for m in (0, 30) if not (h == 17 and m == 30)]
    q = db.query(Appointment.appointment_time).join(AppointmentStatus).filter(
        Appointment.appointment_date == target_date,
        ~AppointmentStatus.status_code.in_(["cancelled", "no_show"]),
    )
    if doctor_id:
        q = q.filter(Appointment.doctor_id == uuid.UUID(doctor_id))
    if department_code:
        q = q.filter(Appointment.department_code == department_code)
    booked = {row[0] for row in q.all()}
    return [{"time": slot.strftime("%H:%M"), "available": slot not in booked} for slot in all_slots]


@app.get("/portal/appointments")
def list_appointments(current_user: dict = Depends(get_current_user), db: Session = Depends(get_db)):
    _require_patient(current_user)
    rows = (
        db.query(Appointment)
        .filter(Appointment.patient_id_hash == current_user["pid"])
        .order_by(Appointment.appointment_date.desc(), Appointment.appointment_time.desc())
        .all()
    )
    return [_appointment_out(row) for row in rows]


@app.post("/portal/appointments", status_code=201)
def create_appointment(
    body: AppointmentCreateRequest,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_patient(current_user)
    appt_type = db.query(AppointmentType).filter(
        AppointmentType.type_code == body.type_code,
        AppointmentType.is_active == True,
    ).first()
    if not appt_type:
        raise HTTPException(status_code=400, detail="유효하지 않은 예약 유형입니다.")

    if appt_type.requires_previous_visit:
        visited = db.query(SyncEncounter).filter(
            SyncEncounter.patient_id_hash == current_user["pid"],
            SyncEncounter.department_code == body.department_code,
        ).first()
        if not visited:
            raise HTTPException(status_code=400, detail="이전 내원 이력이 필요한 예약입니다.")

    dept = db.query(SyncDepartment).filter(
        SyncDepartment.department_code == body.department_code,
        SyncDepartment.is_active == True,
    ).first()
    if not dept:
        raise HTTPException(status_code=400, detail="존재하지 않는 진료과입니다.")

    doctor_uuid = uuid.UUID(body.doctor_id) if body.doctor_id else None
    if doctor_uuid:
        doctor = db.query(SyncDoctor).filter(
            SyncDoctor.doctor_id == doctor_uuid,
            SyncDoctor.department_code == body.department_code,
            SyncDoctor.is_active == True,
        ).first()
        if not doctor:
            raise HTTPException(status_code=400, detail="해당 진료과에 소속된 의사가 아닙니다.")

    try:
        appt_date = date_type.fromisoformat(body.appointment_date)
        hour, minute = body.appointment_time.split(":")
        appt_time = time_type(int(hour), int(minute))
    except ValueError:
        raise HTTPException(status_code=422, detail="날짜 또는 시간 형식이 올바르지 않습니다.")
    if appt_date < date_type.today():
        raise HTTPException(status_code=400, detail="과거 날짜로는 예약할 수 없습니다.")

    pending = db.query(AppointmentStatus).filter(AppointmentStatus.status_code == "pending").first()
    if not pending:
        raise HTTPException(status_code=500, detail="예약 대기 상태 설정이 없습니다.")

    patient_user_id = uuid.UUID(current_user["sub"])
    appt = Appointment(
        patient_user_id=patient_user_id,
        patient_id_hash=current_user["pid"],
        type_id=appt_type.type_id,
        status_id=pending.status_id,
        department_code=body.department_code,
        doctor_id=doctor_uuid,
        appointment_date=appt_date,
        appointment_time=appt_time,
        notes=f"[GCP DR] {body.notes or ''}".strip(),
    )
    db.add(appt)
    db.flush()
    db.add(AppointmentHistory(
        appointment_id=appt.appointment_id,
        changed_by=patient_user_id,
        new_status_id=pending.status_id,
        new_date=appt_date,
        new_time=appt_time,
        change_reason="GCP DR 예약 신청",
    ))
    _record_audit(
        db,
        "CREATE_APPOINTMENT",
        "201",
        user_id=patient_user_id,
        patient_id_hash=current_user["pid"],
        target_table="appointments",
        target_id=appt.appointment_id,
        source_ip=get_client_ip(request),
    )
    db.commit()
    db.refresh(appt)
    return _appointment_out(appt)


@app.post("/portal/appointments/{appointment_id}/cancel")
def cancel_appointment(
    appointment_id: uuid.UUID,
    body: AppointmentCancelRequest,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_patient(current_user)
    appt = db.query(Appointment).filter(
        Appointment.appointment_id == appointment_id,
        Appointment.patient_id_hash == current_user["pid"],
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약 정보를 찾을 수 없습니다.")

    if appt.appt_status and appt.appt_status.is_terminal:
        raise HTTPException(status_code=400, detail="이미 종료된 예약은 취소할 수 없습니다.")

    cancelled = db.query(AppointmentStatus).filter(AppointmentStatus.status_code == "cancelled").first()
    if not cancelled:
        raise HTTPException(status_code=500, detail="예약 취소 상태 설정이 없습니다.")

    now = datetime.now(timezone.utc)
    patient_user_id = uuid.UUID(current_user["sub"])
    db.add(AppointmentHistory(
        appointment_id=appt.appointment_id,
        changed_by=patient_user_id,
        prev_status_id=appt.status_id,
        new_status_id=cancelled.status_id,
        prev_date=appt.appointment_date,
        new_date=appt.appointment_date,
        prev_time=appt.appointment_time,
        new_time=appt.appointment_time,
        change_reason=body.cancel_reason or "GCP DR 환자 요청",
    ))

    appt.status_id = cancelled.status_id
    appt.cancelled_at = now
    appt.cancelled_by = patient_user_id
    appt.cancel_reason = body.cancel_reason or "GCP DR 환자 요청"
    appt.updated_at = now
    _record_audit(
        db,
        "CANCEL_APPOINTMENT",
        "200",
        user_id=patient_user_id,
        patient_id_hash=current_user["pid"],
        target_table="appointments",
        target_id=appt.appointment_id,
        source_ip=get_client_ip(request),
    )
    db.commit()
    db.refresh(appt)
    return _appointment_out(appt)
