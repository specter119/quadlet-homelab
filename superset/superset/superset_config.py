# ---------------------------------------------------
# Superset minimal config (no Redis / no Celery)
# ---------------------------------------------------
import os

SQLALCHEMY_DATABASE_URI = os.environ["DATABASE_URL"]
SECRET_KEY = os.environ["SECRET_KEY"]

# Cache - SimpleCache (no Redis needed)
CACHE_CONFIG = {
    "CACHE_TYPE": "SimpleCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
}
DATA_CACHE_CONFIG = CACHE_CONFIG
FILTER_STATE_CACHE_CONFIG = CACHE_CONFIG
EXPLORE_FORM_DATA_CACHE_CONFIG = CACHE_CONFIG

# Behind reverse proxy (Traefik)
ENABLE_PROXY_FIX = True

# CSRF
WTF_CSRF_ENABLED = True

# Talisman (HTTPS headers) - disabled since Traefik handles TLS
TALISMAN_ENABLED = False
