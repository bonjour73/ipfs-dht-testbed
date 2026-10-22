#!/usr/bin/env python3
import csv
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.common.exceptions import TimeoutException, WebDriverException

if len(sys.argv) not in (6, 7):
    print(
        "Usage: bench_gateway_selenium.py <cid> <page_name> <leecher_region> <run_count> <output_csv> [gateway_base_url]",
        file=sys.stderr,
    )
    sys.exit(1)

cid, page_name, leecher_region, run_count, output_csv = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    int(sys.argv[4]),
    sys.argv[5],
)
gateway_base_url = sys.argv[6] if len(sys.argv) == 7 else os.environ.get("SELENIUM_GATEWAY_URL", "http://127.0.0.1:8080")
url = f"{gateway_base_url.rstrip('/')}/ipfs/{cid}/"

Path(output_csv).parent.mkdir(parents=True, exist_ok=True)

options = Options()
options.add_argument("--headless=new")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.add_argument("--disable-gpu")
options.add_argument("--window-size=1440,900")
if os.environ.get("CHROME_BINARY"):
    options.binary_location = os.environ["CHROME_BINARY"]

service_kwargs = {}
if os.environ.get("CHROMEDRIVER_PATH"):
    service_kwargs["executable_path"] = os.environ["CHROMEDRIVER_PATH"]
service = Service(**service_kwargs)

driver = webdriver.Chrome(service=service, options=options)
driver.set_page_load_timeout(int(os.environ.get("BENCH_REQUEST_TIMEOUT_SECONDS", "120")))

header = [
    "timestamp",
    "page",
    "leecher_region",
    "run_index",
    "success",
    "error_type",
    "navigation_start_ms",
    "response_start_ms",
    "dom_content_loaded_event_end_ms",
    "load_event_end_ms",
    "ttfb_ms",
    "dom_content_loaded_ms",
    "load_ms",
    "final_url",
    "title",
    "url",
]

write_header = not Path(output_csv).exists() or Path(output_csv).stat().st_size == 0
try:
    with open(output_csv, "a", newline="") as f:
        writer = csv.writer(f)
        if write_header:
            writer.writerow(header)

        for i in range(1, run_count + 1):
            success = 1
            error_type = ""
            final_url = ""
            title = ""
            nav = response_start = dcl_end = load_end = ""
            ttfb = dcl_ms = load_ms = ""

            try:
                driver.get(url)
                timing = driver.execute_script(
                    """
                    const entry = performance.getEntriesByType('navigation')[0];
                    if (!entry) return null;
                    return {
                      startTime: entry.startTime,
                      responseStart: entry.responseStart,
                      domContentLoadedEventEnd: entry.domContentLoadedEventEnd,
                      loadEventEnd: entry.loadEventEnd
                    };
                    """
                )
                if timing is None:
                    raise RuntimeError("navigation timing entry unavailable")

                title = driver.title
                final_url = driver.current_url
                nav = timing.get("startTime", "")
                response_start = timing.get("responseStart", "")
                dcl_end = timing.get("domContentLoadedEventEnd", "")
                load_end = timing.get("loadEventEnd", "")
                ttfb = response_start - nav if response_start != "" and nav != "" else ""
                dcl_ms = dcl_end - nav if dcl_end != "" and nav != "" else ""
                load_ms = load_end - nav if load_end != "" and nav != "" else ""
            except TimeoutException:
                success = 0
                error_type = "timeout"
            except (WebDriverException, RuntimeError) as exc:
                success = 0
                error_type = type(exc).__name__
                title = str(exc)

            writer.writerow([
                datetime.now(timezone.utc).isoformat(),
                page_name,
                leecher_region,
                i,
                success,
                error_type,
                nav,
                response_start,
                dcl_end,
                load_end,
                ttfb,
                dcl_ms,
                load_ms,
                final_url,
                title,
                url,
            ])
            f.flush()
            time.sleep(2)
finally:
    driver.quit()
