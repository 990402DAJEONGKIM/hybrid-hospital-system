"""
최초 admin 계정 생성 스크립트
실행: python3 create_admin.py
"""
import sys
from core.database import SessionLocal
from core.security import hash_password
from models.db import User

EMAIL    = "admin@hospital.com"
PASSWORD = "Admin1234!"

db   = SessionLocal()
existing = db.query(User).filter(User.email == EMAIL).first()

if existing:
    print(f"이미 존재하는 계정입니다: {EMAIL}")
    sys.exit(0)

admin = User(
    email         = EMAIL,
    password_hash = hash_password(PASSWORD),
    role          = "admin",
)
db.add(admin)
db.commit()
db.refresh(admin)

print(f"admin 계정 생성 완료")
print(f"  이메일   : {EMAIL}")
print(f"  비밀번호 : {PASSWORD}")
print(f"  user_id  : {admin.user_id}")
