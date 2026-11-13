import os
from app.security import create_signup_token
from app.routers import auth as auth_router

# Set BEFORE importing the app. Blank Twilio values mean tests can never send a real SMS.
os.environ.update(
    SECRET_KEY="test-secret-0123456789abcdef0123456789abcdef",
    DATABASE_URL="sqlite:///./test_k2.db",
    TWILIO_ACCOUNT_SID="",
    TWILIO_AUTH_TOKEN="",
    TWILIO_FROM_NUMBER="",
)

import pytest
from fastapi.testclient import TestClient

from app.database import Base, engine
from app.main import app


@pytest.fixture()
def client():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    with TestClient(app) as c:
        yield c

def reg_body(email, **over):
    b = {"signup_token": create_signup_token(email), "password": "secret123",
         "full_name": "Asha", "phone_number": "+919812345678",
         "height_cm": 165, "weight_kg": 60, "blood_group": "o+"}
    b.update(over)
    return b


def signup(client, email="a@example.com"):
    r = client.post("/auth/register", json=reg_body(email))
    assert r.status_code == 201, r.text
    token = client.post("/auth/login", json={"email": email, "password": "secret123"}).json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


def test_duplicate_email(client):
    signup(client)
    assert client.post("/auth/register", json=reg_body("a@example.com")).status_code == 409


def test_wrong_password(client):
    signup(client)
    assert client.post("/auth/login", json={"email": "a@example.com", "password": "nope-nope"}).status_code == 401


def test_requires_auth(client):
    for path in ("/users/me", "/contacts", "/treks", "/vitals", "/sos"):
        assert client.get(path).status_code == 401


def test_first_contact_is_primary(client):
    h = signup(client)
    r = client.post("/contacts", json={"name": "Mum", "phone_number": "+91 98123 45678"}, headers=h)
    assert r.json()["is_primary"] is True
    assert r.json()["phone_number"] == "+919812345678"


def test_sos_does_not_claim_delivery_without_provider(client):
    h = signup(client)
    client.post("/contacts", json={"name": "Mum", "phone_number": "+919812345678"}, headers=h)
    body = {"trigger": "manual", "latitude": 35.88, "longitude": 76.51, "accuracy_m": 8, "client_request_id": "abc"}
    a = client.post("/sos", json=body, headers=h).json()
    assert a["delivery_status"] == "not_configured"
    assert "maps?q=35.88,76.51" in a["location_link"]
    assert client.post("/sos", json=body, headers=h).json()["id"] == a["id"]  # idempotent


def test_sos_without_contact(client):
    h = signup(client)
    assert client.post("/sos", json={"trigger": "manual"}, headers=h).json()["delivery_status"] == "no_contact"


def test_users_cannot_see_each_others_data(client):
    a = signup(client, "a@example.com")
    b = signup(client, "b@example.com")
    sos_id = client.post("/sos", json={"trigger": "manual"}, headers=a).json()["id"]
    assert client.get(f"/sos/{sos_id}", headers=b).status_code == 404
    assert client.get("/sos", headers=b).json() == []


def test_trek_roundtrip(client):
    h = signup(client)
    r = client.post(
        "/treks",
        json={"name": "Test", "total_distance_km": 1.5, "max_altitude_m": 3400,
              "points": [{"lat": 35.1, "lon": 76.1, "recorded_at": "2026-11-03T06:00:00Z"}]},
        headers=h,
    )
    assert r.status_code == 201
    assert client.get("/treks", headers=h).json()[0]["total_distance_km"] == 1.5
    assert len(client.get(f"/treks/{r.json()['id']}", headers=h).json()["points"]) == 1

from sqlalchemy import select
from app.database import SessionLocal
from app.models import User


def make_admin(email):
    with SessionLocal() as db:
        u = db.scalar(select(User).where(User.email == email))
        u.role = "admin"
        db.commit()


def test_checklist_replace(client):
    h = signup(client)
    client.put("/checklist", json={"checked": ["A", "B"]}, headers=h)
    client.put("/checklist", json={"checked": ["B"]}, headers=h)
    assert client.get("/checklist", headers=h).json()["checked"] == ["B"]


def test_camps_sync_is_idempotent(client):
    h = signup(client)
    assert client.get("/camps", headers=h).json()["initialized"] is False
    body = {
        "reached_stage": 1,
        "waypoints": [{"stage": 1, "lat": 35.8, "lon": 76.5, "radius_m": 150}],
        "events": [{"client_id": "e1", "stage": 1, "method": "manual", "at": "2026-11-04T06:00:00Z"}],
    }
    client.put("/camps", json=body, headers=h)
    r = client.put("/camps", json=body, headers=h).json()
    assert r["initialized"] and r["reached_stage"] == 1
    assert len(r["events"]) == 1 and len(r["waypoints"]) == 1


def test_hydration_today_and_idempotent(client):
    h = signup(client)
    for _ in range(2):
        client.post("/hydration", json={"amount_ml": 500, "client_id": "w1"}, headers=h)
    r = client.get("/hydration/today?tz_offset_minutes=330", headers=h).json()
    assert r["total_ml"] == 500


def test_help_stations_admin_only_and_sorted(client):
    h = signup(client)
    body = {"name": "Test Post", "latitude": 35.9, "longitude": 76.5, "source": "Test source"}
    assert client.post("/help-stations", json=body, headers=h).status_code == 403
    make_admin("a@example.com")
    assert client.post("/help-stations", json=body, headers=h).status_code == 201
    r = client.get("/help-stations?lat=35.8825&lon=76.5133", headers=h).json()
    assert len(r) == 1 and r[0]["distance_km"] > 0
    bad = dict(body, verification_status="verified")  # verified but no last_verified
    assert client.post("/help-stations", json=bad, headers=h).status_code == 422

def test_otp_flow(client, monkeypatch):
    sent = {}
    monkeypatch.setattr(auth_router, "send_otp_email", lambda to, code: sent.update(code=code))
    monkeypatch.setattr(auth_router.settings, "smtp_user", "x")
    monkeypatch.setattr(auth_router.settings, "smtp_password", "y")
    assert client.post("/auth/request-otp", json={"email": "n@example.com"}).status_code == 202
    assert client.post("/auth/request-otp", json={"email": "n@example.com"}).status_code == 429  # cooldown
    bad = "000000" if sent["code"] != "000000" else "111111"
    assert client.post("/auth/verify-otp", json={"email": "n@example.com", "code": bad}).status_code == 400
    r = client.post("/auth/verify-otp", json={"email": "n@example.com", "code": sent["code"]})
    assert r.status_code == 200
    reg = client.post("/auth/register", json=reg_body("n@example.com", signup_token=r.json()["signup_token"]))
    assert reg.status_code == 201 and reg.json()["phone_number"] == "+919812345678"
    assert client.post("/auth/request-otp", json={"email": "n@example.com"}).status_code == 409


def test_register_rejects_bad_input(client):
    assert client.post("/auth/register", json=reg_body("a@example.com", signup_token="junk")).status_code == 401
    assert client.post("/auth/register", json=reg_body("a@example.com", password="12345678")).status_code == 422
    assert client.post("/auth/register", json=reg_body("a@example.com", phone_number="9812345678")).status_code == 422


def test_otp_not_configured(client, monkeypatch):
    monkeypatch.setattr(auth_router.settings, "smtp_user", "")
    monkeypatch.setattr(auth_router.settings, "dev_print_otp", False)
    assert client.post("/auth/request-otp", json={"email": "z@example.com"}).status_code == 503