from datetime import date, datetime
from typing import Literal, Optional
from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator, model_validator
import re

class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)

# ---- auth / users
def _clean_e164(v: str) -> str:
    v = re.sub(r"[\s\-().]", "", v)
    if not re.fullmatch(r"\+[1-9]\d{7,14}", v):
        raise ValueError("Phone number must start with + and a country code, e.g. +919812345678")
    return v

class OtpRequest(BaseModel):
    email: EmailStr

class OtpVerify(BaseModel):
    email: EmailStr
    code: str = Field(pattern=r"^\d{6}$")

class SignupTokenOut(BaseModel):
    signup_token: str

class UserCreate(BaseModel):
    signup_token: str
    password: str = Field(min_length=8, max_length=72)
    full_name: str = Field(min_length=1, max_length=120)
    phone_number: str = Field(max_length=32)
    height_cm: int = Field(default=0, ge=0, le=300)
    weight_kg: int = Field(default=0, ge=0, le=500)
    blood_group: str = Field(default="", max_length=8)
    allergies: str = Field(default="", max_length=1000)
    medical_conditions: str = Field(default="", max_length=1000)

    @field_validator("password")
    @classmethod
    def _strong(cls, v):
        if not (any(c.isalpha() for c in v) and any(c.isdigit() for c in v)):
            raise ValueError("Password needs at least one letter and one number.")
        return v

    @field_validator("phone_number")
    @classmethod
    def _phone(cls, v):
        return _clean_e164(v)

class LoginIn(BaseModel):
    email: EmailStr
    password: str


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(ORM):
    id: int
    email: str
    full_name: str
    phone_number: str
    height_cm: int
    weight_kg: int
    blood_group: str
    allergies: str
    medical_conditions: str
    role: str


class UserUpdate(BaseModel):
    full_name: Optional[str] = Field(default=None, min_length=1, max_length=120)
    height_cm: Optional[int] = Field(default=None, ge=0, le=300)
    weight_kg: Optional[int] = Field(default=None, ge=0, le=500)
    blood_group: Optional[str] = Field(default=None, max_length=8)
    allergies: Optional[str] = Field(default=None, max_length=1000)
    medical_conditions: Optional[str] = Field(default=None, max_length=1000)


# ---- contacts
class ContactCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    phone_number: str = Field(min_length=3, max_length=32)
    relationship: str = Field(default="", max_length=60)

    @field_validator("phone_number")
    @classmethod
    def _phone(cls, v):
        return _clean_e164(v)


class ContactOut(ORM):
    id: int
    name: str
    phone_number: str
    relationship: str = Field(validation_alias="relationship_")
    is_primary: bool


# ---- treks
class TrekPointIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    alt: Optional[float] = None
    accuracy: Optional[float] = None
    recorded_at: datetime


class TrekCreate(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    status: Literal["in_progress", "completed", "abandoned"] = "completed"
    start_date: Optional[datetime] = None
    end_date: Optional[datetime] = None
    total_distance_km: float = Field(default=0, ge=0)
    max_altitude_m: float = Field(default=0, ge=-500, le=9000)
    elevation_gain_m: float = Field(default=0, ge=0)
    points: list[TrekPointIn] = Field(default_factory=list, max_length=5000)


class TrekOut(ORM):
    id: int
    name: str
    status: str
    start_date: datetime
    end_date: Optional[datetime]
    total_distance_km: float
    max_altitude_m: float
    elevation_gain_m: float
    created_at: datetime


class TrekPointOut(ORM):
    lat: float
    lon: float
    alt: Optional[float]
    accuracy: Optional[float]
    recorded_at: datetime


class TrekDetailOut(TrekOut):
    points: list[TrekPointOut]


# ---- vitals / hydration
class VitalIn(BaseModel):
    heart_rate: Optional[int] = Field(default=None, ge=20, le=250)
    spo2: Optional[int] = Field(default=None, ge=30, le=100)
    breathing_rate: Optional[int] = Field(default=None, ge=0, le=80)
    source: str = Field(default="simulated", max_length=40)
    recorded_at: Optional[datetime] = None


class VitalOut(ORM):
    id: int
    heart_rate: Optional[int]
    spo2: Optional[int]
    breathing_rate: Optional[int]
    source: str
    recorded_at: datetime

class HydrationIn(BaseModel):
    amount_ml: int = Field(ge=1, le=5000)
    logged_at: Optional[datetime] = None
    client_id: Optional[str] = Field(default=None, max_length=64)

class HydrationOut(ORM):
    id: int
    amount_ml: int
    logged_at: datetime


# ---- SOS
class SosCreate(BaseModel):
    trigger: Literal["manual", "auto"] = "manual"
    latitude: Optional[float] = Field(default=None, ge=-90, le=90)
    longitude: Optional[float] = Field(default=None, ge=-180, le=180)
    accuracy_m: Optional[float] = Field(default=None, ge=0)
    location_time: Optional[datetime] = None
    client_request_id: Optional[str] = Field(default=None, max_length=64)
    client_created_at: Optional[datetime] = None

    @model_validator(mode="after")
    def _both_coords(self):
        if (self.latitude is None) != (self.longitude is None):
            raise ValueError("latitude and longitude must be sent together")
        return self


class SosOut(ORM):
    id: int
    trigger: str
    status: str
    latitude: Optional[float]
    longitude: Optional[float]
    accuracy_m: Optional[float]
    location_time: Optional[datetime]
    location_link: Optional[str]
    contact_name: Optional[str]
    contact_phone: Optional[str]
    delivery_status: str
    delivery_detail: str
    created_at: datetime

# ---- checklist
class ChecklistIn(BaseModel):
    checked: list[str] = Field(default_factory=list, max_length=200)

    @field_validator("checked")
    @classmethod
    def _item_len(cls, v):
        if any(not k or len(k) > 200 for k in v):
            raise ValueError("each item must be 1 to 200 characters")
        return v


# ---- camps
class CampWaypointIO(ORM):
    stage: int = Field(ge=0, le=3)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    alt_m: Optional[float] = Field(default=None, ge=-500, le=9000)
    radius_m: float = Field(default=150, ge=20, le=2000)


class CampEventIn(BaseModel):
    client_id: str = Field(min_length=1, max_length=64)
    stage: int = Field(ge=0, le=3)
    method: Literal["gps", "manual"]
    at: datetime


class CampEventOut(ORM):
    stage: int
    method: str
    at: datetime


class CampsIn(BaseModel):
    reached_stage: int = Field(ge=0, le=3)
    waypoints: list[CampWaypointIO] = Field(default_factory=list, max_length=4)
    events: list[CampEventIn] = Field(default_factory=list, max_length=100)

    @field_validator("waypoints")
    @classmethod
    def _unique_stages(cls, v):
        if len({w.stage for w in v}) != len(v):
            raise ValueError("duplicate stage")
        return v


class CampsOut(BaseModel):
    initialized: bool
    reached_stage: int
    waypoints: list[CampWaypointIO]
    events: list[CampEventOut]


# ---- help stations
class HelpStationIn(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    kind: Literal["help_post", "medical", "ranger", "rescue", "other"] = "help_post"
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    altitude_m: Optional[float] = None
    phone: Optional[str] = Field(default=None, max_length=40)
    radio_channel: Optional[str] = Field(default=None, max_length=40)
    source: str = Field(min_length=3, max_length=300)  # where this record came from
    source_url: Optional[str] = Field(default=None, max_length=300)
    last_verified: Optional[date] = None
    verification_status: Literal["unverified", "verified"] = "unverified"

    @model_validator(mode="after")
    def _verified_needs_date(self):
        if self.verification_status == "verified" and self.last_verified is None:
            raise ValueError("a verified station needs last_verified")
        return self


class HelpStationOut(ORM):
    id: int
    name: str
    kind: str
    latitude: float
    longitude: float
    altitude_m: Optional[float]
    phone: Optional[str]
    radio_channel: Optional[str]
    source: str
    source_url: Optional[str]
    last_verified: Optional[date]
    verification_status: str
    distance_km: Optional[float] = None  # straight-line, not route distance