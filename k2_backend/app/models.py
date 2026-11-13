from datetime import date, datetime, timezone
from typing import Optional
from sqlalchemy import Date, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import TypeDecorator

from .database import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class UTCDateTime(TypeDecorator):
    """Stores naive UTC, always returns timezone-aware UTC (so the app parses it correctly)."""

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).replace(tzinfo=None)

    def process_result_value(self, value, dialect):
        return None if value is None else value.replace(tzinfo=timezone.utc)


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    full_name: Mapped[str] = mapped_column(String(120))
    height_cm: Mapped[int] = mapped_column(Integer, default=0)
    weight_kg: Mapped[int] = mapped_column(Integer, default=0)
    blood_group: Mapped[str] = mapped_column(String(8), default="")
    phone_number: Mapped[str] = mapped_column(String(32), default="")
    allergies: Mapped[str] = mapped_column(Text, default="")
    medical_conditions: Mapped[str] = mapped_column(Text, default="")
    role: Mapped[str] = mapped_column(String(20), default="trekker")  # for future guide/rescue RBAC
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class EmergencyContact(Base):
    __tablename__ = "emergency_contacts"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(120))
    phone_number: Mapped[str] = mapped_column(String(32))
    relationship_: Mapped[str] = mapped_column("relationship", String(60), default="")
    is_primary: Mapped[bool] = mapped_column(default=False)


class Trek(Base):
    __tablename__ = "treks"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(160))
    status: Mapped[str] = mapped_column(String(20), default="completed")
    start_date: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    end_date: Mapped[Optional[datetime]] = mapped_column(UTCDateTime, nullable=True)
    total_distance_km: Mapped[float] = mapped_column(Float, default=0)
    max_altitude_m: Mapped[float] = mapped_column(Float, default=0)
    elevation_gain_m: Mapped[float] = mapped_column(Float, default=0)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    points: Mapped[list["TrekPoint"]] = relationship(
        back_populates="trek", cascade="all, delete-orphan", order_by="TrekPoint.recorded_at"
    )


class TrekPoint(Base):
    __tablename__ = "trek_points"
    id: Mapped[int] = mapped_column(primary_key=True)
    trek_id: Mapped[int] = mapped_column(ForeignKey("treks.id"), index=True)
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    alt: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    accuracy: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(UTCDateTime)
    trek: Mapped[Trek] = relationship(back_populates="points")


class VitalReading(Base):
    __tablename__ = "vital_readings"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    heart_rate: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    spo2: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    breathing_rate: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    source: Mapped[str] = mapped_column(String(40), default="simulated")  # simulated | ble:<device>
    recorded_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

class HydrationLog(Base):
    __tablename__ = "hydration_logs"
    __table_args__ = (UniqueConstraint("user_id", "client_id", name="uq_hydration_client"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    amount_ml: Mapped[int] = mapped_column(Integer)
    client_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    logged_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

class SosAlert(Base):
    __tablename__ = "sos_alerts"
    __table_args__ = (UniqueConstraint("user_id", "client_request_id", name="uq_sos_client_req"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    client_request_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    trigger: Mapped[str] = mapped_column(String(10))  # manual | auto
    status: Mapped[str] = mapped_column(String(12), default="active")  # active | cancelled | resolved
    latitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    longitude: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    accuracy_m: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    location_time: Mapped[Optional[datetime]] = mapped_column(UTCDateTime, nullable=True)
    location_link: Mapped[Optional[str]] = mapped_column(String(200), nullable=True)
    contact_name: Mapped[Optional[str]] = mapped_column(String(120), nullable=True)
    contact_phone: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)
    # pending | accepted | failed | not_configured | no_contact
    # "accepted" = the SMS provider accepted the message. It does NOT prove the phone received it.
    delivery_status: Mapped[str] = mapped_column(String(20), default="pending")
    delivery_detail: Mapped[str] = mapped_column(Text, default="")
    provider_message_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    client_created_at: Mapped[Optional[datetime]] = mapped_column(UTCDateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    resolved_at: Mapped[Optional[datetime]] = mapped_column(UTCDateTime, nullable=True)


class SosAuditLog(Base):
    __tablename__ = "sos_audit_log"
    id: Mapped[int] = mapped_column(primary_key=True)
    alert_id: Mapped[int] = mapped_column(ForeignKey("sos_alerts.id"), index=True)
    event: Mapped[str] = mapped_column(String(40))
    detail: Mapped[str] = mapped_column(Text, default="")
    at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

class ChecklistCheck(Base):
    __tablename__ = "checklist_checks"
    __table_args__ = (UniqueConstraint("user_id", "item_key", name="uq_checklist_user_item"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    item_key: Mapped[str] = mapped_column(String(200))


class CampWaypoint(Base):
    __tablename__ = "camp_waypoints"
    __table_args__ = (UniqueConstraint("user_id", "stage", name="uq_camp_user_stage"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    stage: Mapped[int] = mapped_column(Integer)  # 0 base, 1 camp 1, 2 camp 2, 3 summit
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    alt_m: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    radius_m: Mapped[float] = mapped_column(Float, default=150)


class CampState(Base):
    __tablename__ = "camp_state"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    reached_stage: Mapped[int] = mapped_column(Integer, default=0)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class CampEvent(Base):
    __tablename__ = "camp_events"
    __table_args__ = (UniqueConstraint("user_id", "client_id", name="uq_camp_event_client"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    client_id: Mapped[str] = mapped_column(String(64))
    stage: Mapped[int] = mapped_column(Integer)
    method: Mapped[str] = mapped_column(String(10))  # gps | manual
    at: Mapped[datetime] = mapped_column(UTCDateTime)


class HelpStation(Base):
    __tablename__ = "help_stations"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(160))
    kind: Mapped[str] = mapped_column(String(40), default="help_post")
    latitude: Mapped[float] = mapped_column(Float)
    longitude: Mapped[float] = mapped_column(Float)
    altitude_m: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    phone: Mapped[Optional[str]] = mapped_column(String(40), nullable=True)
    radio_channel: Mapped[Optional[str]] = mapped_column(String(40), nullable=True)
    source: Mapped[str] = mapped_column(String(300))
    source_url: Mapped[Optional[str]] = mapped_column(String(300), nullable=True)
    last_verified: Mapped[Optional[date]] = mapped_column(Date, nullable=True)
    verification_status: Mapped[str] = mapped_column(String(12), default="unverified")

class EmailOtp(Base):
    __tablename__ = "email_otps"
    email: Mapped[str] = mapped_column(String(255), primary_key=True)
    code_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_sent_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)