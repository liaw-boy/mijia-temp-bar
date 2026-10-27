"""輕量本機除錯日誌 (~/.local/state/mijia-temp-bar/mijia_temp_bar.log)。"""

import logging
import sys
from logging.handlers import RotatingFileHandler

from .settings import STATE_DIR

LOG_PATH = STATE_DIR / "mijia_temp_bar.log"

_logger = logging.getLogger("MijiaTempBar")


def setup_logging() -> None:
    if _logger.handlers:
        return
    _logger.setLevel(logging.INFO)

    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(logging.Formatter("[MijiaTempBar] %(message)s"))
    _logger.addHandler(stream)

    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        file_handler = RotatingFileHandler(LOG_PATH, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
        file_handler.setFormatter(logging.Formatter("[%(asctime)s] %(message)s", "%Y-%m-%dT%H:%M:%S%z"))
        _logger.addHandler(file_handler)
    except OSError as e:
        _logger.warning("無法建立日誌檔 %s: %s", LOG_PATH, e)


def mijia_log(message: str) -> None:
    _logger.info(message)
