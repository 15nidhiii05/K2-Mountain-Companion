from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import models  # noqa: F401  (registers tables)
from .config import settings
from .database import Base, engine
from .routers import auth, camps, checklist, contacts, help_stations, hydration, sos, treks, users, vitals

@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)  # use Alembic migrations once the schema settles
    yield


app = FastAPI(title="K2 Mountain Companion API", version="0.1.0", lifespan=lifespan)

origins = [o.strip() for o in settings.cors_origins.split(",") if o.strip()]
if origins:
    app.add_middleware(
        CORSMiddleware, allow_origins=origins, allow_methods=["*"], allow_headers=["*"]
    )
for r in (auth, users, contacts, treks, vitals, hydration, sos, checklist, camps, help_stations):
    app.include_router(r.router)

@app.get("/health", tags=["meta"])
def health():
    return {"status": "ok", "sms_configured": settings.sms_configured}