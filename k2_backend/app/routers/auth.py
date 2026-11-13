import hmac
import smtplib
from datetime import timedelta

from fastapi import APIRouter, HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from ..config import settings
from ..deps import DB
from ..models import EmailOtp, User, utcnow
from ..schemas import LoginIn, OtpRequest, OtpVerify, SignupTokenOut, TokenOut, UserCreate, UserOut
from ..security import (
    create_access_token, create_signup_token, hash_otp, hash_password,
    new_otp, read_signup_token, verify_password,
)
from ..services.mailer import send_otp_email

router = APIRouter(prefix="/auth", tags=["auth"])

RESEND_SECONDS = 60
MAX_ATTEMPTS = 5


@router.post("/request-otp", status_code=202)
def request_otp(body: OtpRequest, db: DB):
    email = body.email.lower()
    if db.scalar(select(User).where(User.email == email)):
        raise HTTPException(409, "An account with this email already exists. Log in instead.")
    now = utcnow()
    row = db.get(EmailOtp, email)
    if row and (now - row.last_sent_at).total_seconds() < RESEND_SECONDS:
        raise HTTPException(429, "Please wait a minute before requesting another code.")
    if not settings.email_configured and not settings.dev_print_otp:
        raise HTTPException(503, "Email sending is not configured on the server.")

    code = new_otp()
    if settings.email_configured:
        try:
            send_otp_email(email, code)
        except (smtplib.SMTPException, OSError) as e:
            print(f"[MAIL ERROR] {type(e).__name__}: {e}")
            raise HTTPException(
                502,
                "Could not send the email. Check the address and try again."
            )
    else:
        print(f"[DEV] OTP for {email}: {code}")

    if row is None:
        row = EmailOtp(email=email)
        db.add(row)
    row.code_hash = hash_otp(email, code)
    row.expires_at = now + timedelta(minutes=settings.otp_minutes)
    row.attempts = 0
    row.last_sent_at = now
    db.commit()
    return {"detail": f"Code sent. It expires in {settings.otp_minutes} minutes."}


@router.post("/verify-otp", response_model=SignupTokenOut)
def verify_otp(body: OtpVerify, db: DB):
    email = body.email.lower()
    row = db.get(EmailOtp, email)
    if row is None or row.expires_at < utcnow():
        raise HTTPException(400, "Code expired or not requested. Request a new one.")
    if row.attempts >= MAX_ATTEMPTS:
        db.delete(row)
        db.commit()
        raise HTTPException(429, "Too many wrong attempts. Request a new code.")
    if not hmac.compare_digest(row.code_hash, hash_otp(email, body.code)):
        row.attempts += 1
        db.commit()
        raise HTTPException(400, "Incorrect code.")
    db.delete(row)
    db.commit()
    return SignupTokenOut(signup_token=create_signup_token(email))


@router.post("/register", response_model=UserOut, status_code=201)
def register(body: UserCreate, db: DB):
    email = read_signup_token(body.signup_token)
    if email is None:
        raise HTTPException(401, "Email not verified, or verification expired. Start again.")
    if db.scalar(select(User).where(User.email == email)):
        raise HTTPException(409, "An account with this email already exists.")
    user = User(
        email=email,
        password_hash=hash_password(body.password),
        full_name=body.full_name.strip(),
        phone_number=body.phone_number,
        height_cm=body.height_cm,
        weight_kg=body.weight_kg,
        blood_group=body.blood_group.strip().upper(),
        allergies=body.allergies.strip(),
        medical_conditions=body.medical_conditions.strip(),
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "An account with this email already exists.")
    db.refresh(user)
    return user


@router.post("/login", response_model=TokenOut)
def login(body: LoginIn, db: DB):
    user = db.scalar(select(User).where(User.email == body.email.lower()))
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(401, "Incorrect email or password.")
    return TokenOut(access_token=create_access_token(user.id))