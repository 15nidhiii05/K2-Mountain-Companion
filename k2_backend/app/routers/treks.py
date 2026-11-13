from fastapi import APIRouter, HTTPException
from sqlalchemy import select

from ..deps import DB, CurrentUser
from ..models import Trek, TrekPoint, utcnow
from ..schemas import TrekCreate, TrekDetailOut, TrekOut

router = APIRouter(prefix="/treks", tags=["treks"])


@router.post("", response_model=TrekOut, status_code=201)
def create_trek(body: TrekCreate, db: DB, user: CurrentUser):
    now = utcnow()
    trek = Trek(
        user_id=user.id,
        name=body.name.strip(),
        status=body.status,
        start_date=body.start_date or now,
        end_date=body.end_date or (now if body.status != "in_progress" else None),
        total_distance_km=body.total_distance_km,
        max_altitude_m=body.max_altitude_m,
        elevation_gain_m=body.elevation_gain_m,
        points=[TrekPoint(**p.model_dump()) for p in body.points],
    )
    db.add(trek)
    db.commit()
    db.refresh(trek)
    return trek


@router.get("", response_model=list[TrekOut])
def list_treks(db: DB, user: CurrentUser):
    return list(db.scalars(select(Trek).where(Trek.user_id == user.id).order_by(Trek.start_date.desc())))


@router.get("/{trek_id}", response_model=TrekDetailOut)
def get_trek(trek_id: int, db: DB, user: CurrentUser):
    trek = db.get(Trek, trek_id)
    if trek is None or trek.user_id != user.id:
        raise HTTPException(404, "Trek not found.")
    return trek


@router.delete("/{trek_id}", status_code=204)
def delete_trek(trek_id: int, db: DB, user: CurrentUser):
    trek = db.get(Trek, trek_id)
    if trek is None or trek.user_id != user.id:
        raise HTTPException(404, "Trek not found.")
    db.delete(trek)
    db.commit()