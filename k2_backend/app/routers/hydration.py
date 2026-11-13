from datetime import timedelta, timezone

from fastapi import APIRouter, Query
from sqlalchemy import select

from ..deps import DB, CurrentUser
from ..models import HydrationLog, utcnow
from ..schemas import HydrationIn, HydrationOut

router = APIRouter(prefix="/hydration", tags=["hydration"])


def _summary(rows):
    return {
        "total_ml": sum(r.amount_ml for r in rows),
        "entries": [HydrationOut.model_validate(r) for r in rows],
    }


@router.post("", response_model=HydrationOut, status_code=201)
def log_water(body: HydrationIn, db: DB, user: CurrentUser):
    # Idempotent: a log retried by the app (client_id) is never counted twice.
    if body.client_id:
        existing = db.scalar(
            select(HydrationLog).where(
                HydrationLog.user_id == user.id, HydrationLog.client_id == body.client_id
            )
        )
        if existing:
            return existing
    now = utcnow()
    when = body.logged_at or now
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    if when > now + timedelta(minutes=5):
        when = now
    row = HydrationLog(
        user_id=user.id, amount_ml=body.amount_ml, client_id=body.client_id, logged_at=when
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


@router.get("/today")
def today(db: DB, user: CurrentUser, tz_offset_minutes: int = Query(0, ge=-840, le=840)):
    """Entries since local midnight. The app sends its UTC offset (India = 330)."""
    offset = timedelta(minutes=tz_offset_minutes)
    local_now = utcnow() + offset
    start = local_now.replace(hour=0, minute=0, second=0, microsecond=0) - offset
    rows = list(
        db.scalars(
            select(HydrationLog)
            .where(HydrationLog.user_id == user.id, HydrationLog.logged_at >= start)
            .order_by(HydrationLog.logged_at.desc())
        )
    )
    return _summary(rows)


@router.get("/recent")
def recent(db: DB, user: CurrentUser):
    since = utcnow() - timedelta(hours=24)
    rows = list(
        db.scalars(
            select(HydrationLog)
            .where(HydrationLog.user_id == user.id, HydrationLog.logged_at >= since)
            .order_by(HydrationLog.logged_at.desc())
        )
    )
    return _summary(rows)