# ── 추가 엔드포인트 ────────────────────────────────────────────────────────────

@app.get("/portal/my-profile")
def portal_my_profile(
    _: str = Depends(verify_api_key),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    now = datetime.now(timezone.utc)
    password_expired = bool(user.password_expires_at and user.password_expires_at < now)
    return {
        "user_id":       str(user.user_id),
        "member_number": user.member_number,
        "display_name":  user.display_name,
        "email":         user.email,
        "role":          user.role_ref.role_code,
        "must_change_password": user.must_change_password or password_expired,
        "password_expired": password_expired,
    }

@app.get("/portal/my-records")
def portal_my_records(
    _: str = Depends(verify_api_key),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    from sqlalchemy import text
    # patient_id_hash를 appointments에서 조회
    appt = db.query(Appointment).filter(
        Appointment.patient_user_id == user.user_id,
        Appointment.patient_id_hash.isnot(None)
    ).first()
    if not appt or not appt.patient_id_hash:
        return []

    pid_hash = appt.patient_id_hash

    # sync_encounters
    encounters = db.execute(text("""
        SELECT e.encounter_id, e.encounter_type, e.department_code,
               d.department_name, e.doctor_id, doc.doctor_name,
               e.visit_date, e.status_code
        FROM sync_encounters e
        LEFT JOIN sync_departments d ON e.department_code = d.department_code
        LEFT JOIN sync_doctors doc ON e.doctor_id = doc.doctor_id
        WHERE e.patient_id_hash = :pid
        ORDER BY e.visit_date DESC
    """), {"pid": pid_hash}).fetchall()

    result = []
    for e in encounters:
        # 진단 조회
        diagnoses = db.execute(text("""
            SELECT diagnosis_code, is_primary
            FROM sync_diagnoses
            WHERE patient_id_hash = :pid AND encounter_id = :eid
        """), {"pid": pid_hash, "eid": str(e.encounter_id)}).fetchall()

        result.append({
            "encounter_id":    str(e.encounter_id),
            "encounter_type":  e.encounter_type,
            "department_code": e.department_code,
            "department_name": e.department_name,
            "doctor_id":       str(e.doctor_id) if e.doctor_id else None,
            "doctor_name":     e.doctor_name,
            "visit_date":      e.visit_date.isoformat() if e.visit_date else None,
            "status_code":     e.status_code,
            "diagnoses":       [{"diagnosis_code": d.diagnosis_code, "is_primary": d.is_primary} for d in diagnoses],
        })
    return result

@app.get("/portal/recent-encounter")
def portal_recent_encounter(
    _: str = Depends(verify_api_key),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    from sqlalchemy import text
    appt = db.query(Appointment).filter(
        Appointment.patient_user_id == user.user_id,
        Appointment.patient_id_hash.isnot(None)
    ).first()
    if not appt or not appt.patient_id_hash:
        return None

    pid_hash = appt.patient_id_hash
    encounter = db.execute(text("""
        SELECT e.encounter_id, e.encounter_type, e.department_code,
               d.department_name, e.doctor_id, doc.doctor_name, e.visit_date
        FROM sync_encounters e
        LEFT JOIN sync_departments d ON e.department_code = d.department_code
        LEFT JOIN sync_doctors doc ON e.doctor_id = doc.doctor_id
        WHERE e.patient_id_hash = :pid
        ORDER BY e.visit_date DESC
        LIMIT 1
    """), {"pid": pid_hash}).fetchone()

    if not encounter:
        return None
    return {
        "encounter_id":    str(encounter.encounter_id),
        "encounter_type":  encounter.encounter_type,
        "department_code": encounter.department_code,
        "department_name": encounter.department_name,
        "doctor_id":       str(encounter.doctor_id) if encounter.doctor_id else None,
        "doctor_name":     encounter.doctor_name,
        "visit_date":      encounter.visit_date.isoformat() if encounter.visit_date else None,
    }

@app.get("/portal/allergies")
def portal_allergies(
    _: str = Depends(verify_api_key),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    from sqlalchemy import text
    appt = db.query(Appointment).filter(
        Appointment.patient_user_id == user.user_id,
        Appointment.patient_id_hash.isnot(None)
    ).first()
    if not appt or not appt.patient_id_hash:
        return []

    allergies = db.execute(text("""
        SELECT allergy_id, allergy_name, severity_code, synced_at
        FROM sync_allergies
        WHERE patient_id_hash = :pid
    """), {"pid": appt.patient_id_hash}).fetchall()

    return [{"allergy_id": str(a.allergy_id), "allergy_name": a.allergy_name,
             "severity_code": a.severity_code} for a in allergies]

@app.get("/portal/surgery-histories")
def portal_surgery_histories(
    _: str = Depends(verify_api_key),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    from sqlalchemy import text
    appt = db.query(Appointment).filter(
        Appointment.patient_user_id == user.user_id,
        Appointment.patient_id_hash.isnot(None)
    ).first()
    if not appt or not appt.patient_id_hash:
        return []

    surgeries = db.execute(text("""
        SELECT surgery_history_id, surgery_name, surgery_date, synced_at
        FROM sync_surgery_histories
        WHERE patient_id_hash = :pid
        ORDER BY surgery_date DESC
    """), {"pid": appt.patient_id_hash}).fetchall()

    return [{"surgery_history_id": str(s.surgery_history_id), "surgery_name": s.surgery_name,
             "surgery_date": s.surgery_date.isoformat() if s.surgery_date else None} for s in surgeries]