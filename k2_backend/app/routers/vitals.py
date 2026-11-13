from fastapi import APIRouter, Query
from sqlalchemy import select

from ..deps import DB, CurrentUser
from ..models import VitalReading, utcnow
from ..schemas import VitalIn, VitalOut

router = APIRouter(prefix="/vitals", tags=["vitals"])


@router.post("", response_model=VitalOut, status_code=201)
def add_vital(body: VitalIn, db: DB, user: CurrentUser):
    v = VitalReading(
        user_id=user.id,
        heart_rate=body.heart_rate,
        spo2=body.spo2,
        breathing_rate=body.breathing_rate,
        source=body.source,
        recorded_at=body.recorded_at or utcnow(),
    )
    db.add(v)
    db.commit()
    db.refresh(v)
    return v


@router.get("", response_model=list[VitalOut])
def history(db: DB, user: CurrentUser, limit: int = Query(200, ge=1, le=1000)):
    return list(
        db.scalars(
            select(VitalReading)
            .where(VitalReading.user_id == user.id)
            .order_by(VitalReading.recorded_at.desc())
            .limit(limit)
        )
    )