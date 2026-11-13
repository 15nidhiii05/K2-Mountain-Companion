from fastapi import APIRouter
from sqlalchemy import delete, select

from ..deps import DB, CurrentUser
from ..models import CampEvent, CampState, CampWaypoint, utcnow
from ..schemas import CampEventOut, CampsIn, CampsOut, CampWaypointIO

router = APIRouter(prefix="/camps", tags=["camps"])


def _state(db, user) -> CampsOut:
    cs = db.get(CampState, user.id)
    wps = list(
        db.scalars(select(CampWaypoint).where(CampWaypoint.user_id == user.id).order_by(CampWaypoint.stage))
    )
    evs = list(
        db.scalars(
            select(CampEvent).where(CampEvent.user_id == user.id).order_by(CampEvent.at.desc()).limit(100)
        )
    )
    return CampsOut(
        initialized=cs is not None,
        reached_stage=cs.reached_stage if cs else 0,
        waypoints=[CampWaypointIO.model_validate(w) for w in wps],
        events=[CampEventOut.model_validate(e) for e in evs],
    )


@router.get("", response_model=CampsOut)
def get_camps(db: DB, user: CurrentUser):
    return _state(db, user)


@router.put("", response_model=CampsOut)
def put_camps(body: CampsIn, db: DB, user: CurrentUser):
    """Replaces waypoints and progress; appends new events (each client_id is stored once)."""
    db.execute(delete(CampWaypoint).where(CampWaypoint.user_id == user.id))
    db.add_all([CampWaypoint(user_id=user.id, **w.model_dump()) for w in body.waypoints])
    cs = db.get(CampState, user.id)
    if cs is None:
        cs = CampState(user_id=user.id)
        db.add(cs)
    cs.reached_stage = body.reached_stage
    cs.updated_at = utcnow()
    known = set(db.scalars(select(CampEvent.client_id).where(CampEvent.user_id == user.id)))
    for e in body.events:
        if e.client_id in known:
            continue
        known.add(e.client_id)
        db.add(CampEvent(user_id=user.id, client_id=e.client_id, stage=e.stage, method=e.method, at=e.at))
    db.commit()
    return _state(db, user)