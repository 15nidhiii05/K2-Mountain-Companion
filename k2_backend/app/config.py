
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        extra="ignore",
    )

    # Security and database
    secret_key: str
    database_url: str = "sqlite:///./k2.db"
    access_token_minutes: int = 60 * 24 * 7

    # CORS
    cors_origins: str = ""

    # Twilio SMS configuration
    twilio_account_sid: str = ""
    twilio_auth_token: str = ""
    twilio_from_number: str = ""

    # Email / SMTP configuration
    smtp_host: str = "smtp.gmail.com"
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""

    # OTP configuration
    otp_minutes: int = 10
    dev_print_otp: bool = False

    @property
    def sms_configured(self) -> bool:
        return all([
            self.twilio_account_sid,
            self.twilio_auth_token,
            self.twilio_from_number,
        ])

    @property
    def email_configured(self) -> bool:
        return bool(self.smtp_user and self.smtp_password)


settings = Settings()
