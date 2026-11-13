import smtplib
import ssl
from email.message import EmailMessage

from ..config import settings

def send_otp_email(to: str, code: str) -> None:
    """Raises smtplib.SMTPException or OSError on failure."""
    msg = EmailMessage()
    msg["Subject"] = "Your K2 verification code"
    msg["From"] = settings.smtp_from or settings.smtp_user
    msg["To"] = to
    msg.set_content(
        f"Your K2 Mountain Companion verification code is {code}.\n\n"
        f"It expires in {settings.otp_minutes} minutes. "
        "If you did not request it, ignore this email."
    )
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as s:
        s.starttls(context=ssl.create_default_context())
        s.login(settings.smtp_user, settings.smtp_password)
        s.send_message(msg)