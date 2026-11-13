import math
from typing import Optional

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from ..deps import DB, AdminUser, CurrentUser
from ..models import HelpStation
from ..schemas import HelpStationIn, HelpStationOut

router = APIRouter(prefix="/help-stations", tags=["help-stations"])


def _km(lat1, lon1, lat2, lon2) -> float:
    r = 6371.0088
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (
        math.sin((p2 - p1) / 2) ** 2
        + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    )
    return 2 * r * math.asin(math.sqrt(a))


@router.get("", response_model=list[HelpStationOut])
def list_stations(
    db: DB,
    user: CurrentUser,
    lat: Optional[float] = Query(None, ge=-90, le=90),
    lon: Optional[float] = Query(None, ge=-180, le=180),
    limit: int = Query(10, ge=1, le=50),
    verified_only: bool = False,
):
    q = select(HelpStation)
    if verified_only:
        q = q.where(HelpStation.verification_status == "verified")
    have_pos = lat is not None and lon is not None
    out = []
    for s in db.scalars(q):
        o = HelpStationOut.model_validate(s)
        if have_pos:
            o.distance_km = round(_km(lat, lon, s.latitude, s.longitude), 1)
        out.append(o)
    if have_pos:
        out.sort(key=lambda o: o.distance_km)
    return out[:limit]


@router.post("", response_model=HelpStationOut, status_code=201)
def create_station(body: HelpStationIn, db: DB, admin: AdminUser):
    s = HelpStation(**body.model_dump())
    db.add(s)
    db.commit()
    db.refresh(s)
    return s


@router.put("/{station_id}", response_model=HelpStationOut)
def replace_station(station_id: int, body: HelpStationIn, db: DB, admin: AdminUser):
    s = db.get(HelpStation, station_id)
    if s is None:
        raise HTTPException(404, "Station not found.")
    for k, v in body.model_dump().items():
        setattr(s, k, v)
    db.commit()
    db.refresh(s)
    return s


@router.delete("/{station_id}", status_code=204)
def delete_station(station_id: int, db: DB, admin: AdminUser):
    s = db.get(HelpStation, station_id)
    if s is None:
        raise HTTPException(404, "Station not found.")
    db.delete(s)
    db.commit()