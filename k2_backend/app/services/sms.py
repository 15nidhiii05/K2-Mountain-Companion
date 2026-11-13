import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

from ..config import settings

_E164 = re.compile(r"^\+[1-9]\d{7,14}$")


def normalize_phone(raw: str) -> str:
    return re.sub(r"[\s\-().]", "", raw)


@dataclass
class SmsResult:
    status: str  # accepted | failed
    detail: str = ""
    message_id: Optional[str] = None


def build_sos_message(user, alert, now: datetime) -> str:
    kind = "automatic" if alert.trigger == "auto" else "manual"
    parts = [f"K2 SOS: {user.full_name} triggered a {kind} emergency alert."]
    if alert.location_link:
        when = ""
        if alert.location_time:
            stale = now - alert.location_time > timedelta(minutes=2)
            when = f", {'LAST KNOWN ' if stale else ''}fix {alert.location_time:%H:%M} UTC"
        acc = f" (+/-{round(alert.accuracy_m)} m{when})" if alert.accuracy_m is not None else ""
        parts.append(f"Location: {alert.location_link}{acc}")
    else:
        parts.append("Location unavailable (no GPS fix).")
    if user.blood_group:
        parts.append(f"Blood group: {user.blood_group}.")
    if alert.client_created_at and now - alert.client_created_at > timedelta(minutes=2):
        parts.append(f"Alert was created at {alert.client_created_at:%H:%M} UTC and delivered late.")
    if user.phone_number:
        parts.append(f"Their phone: {user.phone_number}.")
    parts.append("Call them or local emergency services.")
    return " ".join(parts)


def send_sms(to: str, body: str) -> SmsResult:
    to = normalize_phone(to)
    if not _E164.match(to):
        return SmsResult("failed", "Contact number needs a country code, e.g. +919812345678.")
    url = f"https://api.twilio.com/2010-04-01/Accounts/{settings.twilio_account_sid}/Messages.json"
    try:
        r = httpx.post(
            url,
            auth=(settings.twilio_account_sid, settings.twilio_auth_token),
            data={"To": to, "From": settings.twilio_from_number, "Body": body},
            timeout=15,
        )
    except httpx.HTTPError as e:
        return SmsResult("failed", f"SMS provider unreachable ({e.__class__.__name__}).")
    if r.status_code in (200, 201):
        return SmsResult(
            "accepted",
            "Accepted by the SMS provider. Delivery to the phone is not confirmed.",
            r.json().get("sid"),
        )
    try:
        msg = r.json().get("message", r.text)
    except ValueError:
        msg = r.text
    return SmsResult("failed", f"SMS provider error {r.status_code}: {msg}"[:300])