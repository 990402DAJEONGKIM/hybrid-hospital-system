"""
통합 앱 초기 계정 생성 스크립트
실행: python3 create_admin.py
"""
import sys
from datetime import datetime, timezone
from core.database import SessionLocal
from core.security import hash_password
from models.db import Role, User

db = SessionLocal()

# 기본 역할 생성
roles_data = [
    ("admin",   "관리자"),
    ("doctor",  "의사"),
    ("nurse",   "간호사"),
    ("patient", "환자"),
]
for code, name in roles_data:
    if not db.query(Role).filter(Role.role_code == code).first():
        db.add(Role(role_code=code, role_name=name, is_active=True,
                    created_at=datetime.now(timezone.utc)))
db.commit()

# admin 계정 생성
EMAIL    = "admin@hospital.com"
PASSWORD = "Admin1234!"

admin_role = db.query(Role).filter(Role.role_code == "admin").first()

if db.query(User).filter(User.email == EMAIL).first():
    print(f"이미 존재합니다: {EMAIL}")
    sys.exit(0)

user = User(
    email         = EMAIL,
    password_hash = hash_password(PASSWORD),
    role_id       = admin_role.role_id,
)
db.add(user)
db.commit()
db.refresh(user)

print("admin 계정 생성 완료")
print(f"  이메일   : {EMAIL}")
print(f"  비밀번호 : {PASSWORD}")
