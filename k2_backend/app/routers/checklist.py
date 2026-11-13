from fastapi import APIRouter
from sqlalchemy import delete, select

from ..deps import DB, CurrentUser
from ..models import ChecklistCheck
from ..schemas import ChecklistIn

router = APIRouter(prefix="/checklist", tags=["checklist"])


@router.get("")
def get_checklist(db: DB, user: CurrentUser):
    keys = list(db.scalars(select(ChecklistCheck.item_key).where(ChecklistCheck.user_id == user.id)))
    return {"checked": sorted(keys)}


@router.put("")
def put_checklist(body: ChecklistIn, db: DB, user: CurrentUser):
    """Replaces the whole set (last write wins)."""
    wanted = set(body.checked)
    db.execute(delete(ChecklistCheck).where(ChecklistCheck.user_id == user.id))
    db.add_all([ChecklistCheck(user_id=user.id, item_key=k) for k in wanted])
    db.commit()
    return {"checked": sorted(wanted)}