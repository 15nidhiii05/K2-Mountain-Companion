from fastapi import APIRouter, HTTPException
from sqlalchemy import select

from ..config import settings
from ..deps import DB, CurrentUser
from ..models import EmergencyContact, SosAlert, SosAuditLog, utcnow
from ..schemas import SosCreate, SosOut
from ..services.sms import build_sos_message, send_sms

router = APIRouter(prefix="/sos", tags=["sos"])


def _audit(db, alert, event: str, detail: str = ""):
    db.add(SosAuditLog(alert_id=alert.id, event=event, detail=detail[:500]))


@router.post("", response_model=SosOut, status_code=201)
def create_sos(body: SosCreate, db: DB, user: CurrentUser):
    # Idempotent: a queued alert retried by the app must not create duplicates.
    if body.client_request_id:
        existing = db.scalar(
            select(SosAlert).where(
                SosAlert.user_id == user.id, SosAlert.client_request_id == body.client_request_id
            )
        )
        if existing:
            return existing

    contact = db.scalar(
        select(EmergencyContact)
        .where(EmergencyContact.user_id == user.id)
        .order_by(EmergencyContact.is_primary.desc(), EmergencyContact.id)
    )
    now = utcnow()
    link = (
        f"https://www.google.com/maps?q={body.latitude},{body.longitude}"
        if body.latitude is not None
        else None
    )
    alert = SosAlert(
        user_id=user.id,
        client_request_id=body.client_request_id,
        trigger=body.trigger,
        latitude=body.latitude,
        longitude=body.longitude,
        accuracy_m=body.accuracy_m,
        location_time=body.location_time,
        location_link=link,
        contact_name=contact.name if contact else None,
        contact_phone=contact.phone_number if contact else None,
        client_created_at=body.client_created_at,
    )
    db.add(alert)
    db.flush()
    _audit(db, alert, "created", f"trigger={body.trigger} has_location={link is not None}")

    if contact is None:
        alert.delivery_status = "no_contact"
        alert.delivery_detail = "No emergency contact is saved, so nobody was notified."
    elif not settings.sms_configured:
        alert.delivery_status = "not_configured"
        alert.delivery_detail = "SMS provider is not configured on the server. Nobody was texted."
    else:
        result = send_sms(contact.phone_number, build_sos_message(user, alert, now))
        alert.delivery_status = result.status
        alert.delivery_detail = result.detail
        alert.provider_message_id = result.message_id
    _audit(db, alert, f"sms_{alert.delivery_status}", alert.delivery_detail)

    db.commit()
    db.refresh(alert)
    return alert


@router.get("", response_model=list[SosOut])
def list_alerts(db: DB, user: CurrentUser):
    return list(
        db.scalars(select(SosAlert).where(SosAlert.user_id == user.id).order_by(SosAlert.created_at.desc()))
    )


@router.get("/{alert_id}", response_model=SosOut)
def get_alert(alert_id: int, db: DB, user: CurrentUser):
    alert = db.get(SosAlert, alert_id)
    if alert is None or alert.user_id != user.id:
        raise HTTPException(404, "Alert not found.")
    return alert


@router.post("/{alert_id}/cancel", response_model=SosOut)
def cancel_alert(alert_id: int, db: DB, user: CurrentUser):
    """Marks the alert cancelled. It does NOT recall an SMS that was already sent."""
    alert = db.get(SosAlert, alert_id)
    if alert is None or alert.user_id != user.id:
        raise HTTPException(404, "Alert not found.")
    if alert.status == "active":
        alert.status = "cancelled"
        alert.resolved_at = utcnow()
        _audit(db, alert, "cancelled_by_user")
        db.commit()
        db.refresh(alert)
    return alert