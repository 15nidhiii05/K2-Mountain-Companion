"""Usage:  python -m app.make_admin you@example.com"""
import sys

from sqlalchemy import select

from . import models  # noqa: F401
from .database import SessionLocal
from .models import User


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: python -m app.make_admin EMAIL")
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.email == sys.argv[1].lower()))
        if user is None:
            sys.exit("No user with that email.")
        user.role = "admin"
        db.commit()
        print(f"{user.email} is now an admin.")


if __name__ == "__main__":
    main()