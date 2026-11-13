from fastapi import APIRouter, HTTPException
from sqlalchemy import select

from ..deps import DB, CurrentUser
from ..models import EmergencyContact
from ..schemas import ContactCreate, ContactOut
from ..services.sms import normalize_phone

router = APIRouter(prefix="/contacts", tags=["contacts"])


def _mine(db, user):
    return list(
        db.scalars(
            select(EmergencyContact)
            .where(EmergencyContact.user_id == user.id)
            .order_by(EmergencyContact.is_primary.desc(), EmergencyContact.id)
        )
    )


@router.get("", response_model=list[ContactOut])
def list_contacts(db: DB, user: CurrentUser):
    return _mine(db, user)


@router.post("", response_model=ContactOut, status_code=201)
def add_contact(body: ContactCreate, db: DB, user: CurrentUser):
    first = not _mine(db, user)
    c = EmergencyContact(
        user_id=user.id,
        name=body.name.strip(),
        phone_number=normalize_phone(body.phone_number),
        relationship_=body.relationship.strip(),
        is_primary=first,  # the first contact is primary
    )
    db.add(c)
    db.commit()
    db.refresh(c)
    return c


@router.post("/{contact_id}/primary", response_model=ContactOut)
def make_primary(contact_id: int, db: DB, user: CurrentUser):
    contacts = _mine(db, user)
    target = next((c for c in contacts if c.id == contact_id), None)
    if target is None:
        raise HTTPException(404, "Contact not found.")
    for c in contacts:
        c.is_primary = c.id == contact_id
    db.commit()
    db.refresh(target)
    return target


@router.delete("/{contact_id}", status_code=204)
def delete_contact(contact_id: int, db: DB, user: CurrentUser):
    c = db.get(EmergencyContact, contact_id)
    if c is None or c.user_id != user.id:
        raise HTTPException(404, "Contact not found.")
    was_primary = c.is_primary
    db.delete(c)
    db.flush()
    if was_primary:
        rest = _mine(db, user)
        if rest:
            rest[0].is_primary = True
    db.commit()