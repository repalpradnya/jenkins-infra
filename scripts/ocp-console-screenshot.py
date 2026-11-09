#!/usr/bin/env python3

import os
import tarfile
import time
import subprocess
import sys
import urllib.parse
from pathlib import Path
from datetime import datetime

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.firefox.service import Service
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC


def get_output_base():
    base = os.environ.get('OUTPUT_DIR', '').strip()
    if base:
        return Path(base)
    return Path("/root/ui-screenshots")


def run(cmd):
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise Exception(
            f"Command failed: {cmd}\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )
    return result.stdout.strip()


def get_console_url():
    url = os.environ.get('CONSOLE_URL', '').strip()
    if url:
        print(f"Console URL from env: {url}")
        return url.rstrip("/")
    print("Determining OpenShift console URL via oc...")
    try:
        url = run("oc whoami --show-console")
        if not url:
            raise Exception("Empty console URL returned")
        print(f"Console URL: {url}")
        return url.rstrip("/")
    except Exception as e:
        raise Exception(f"Unable to determine console URL: {e}")


def get_password():
    password = os.environ.get('KUBEADMIN_PASSWORD', '').strip()
    if password:
        print("Password retrieved from env var")
        return password
    pw_file = Path("/root/openstack-upi/auth/kubeadmin-password")
    if not pw_file.exists():
        raise Exception(f"Password file not found: {pw_file}")
    password = pw_file.read_text().strip()
    if not password:
        raise Exception("kubeadmin password file is empty")
    return password


def get_geckodriver():
    for path in [
        "/usr/local/bin/geckodriver",
        "/usr/bin/geckodriver",
    ]:
        if Path(path).exists():
            return path
    try:
        return run("which geckodriver")
    except Exception:
        pass
    raise Exception("geckodriver not found")


def create_driver():
    print("Creating Firefox driver...")
    opts = Options()
    opts.accept_insecure_certs = True
    opts.add_argument("--headless")
    opts.add_argument("--width=1920")
    opts.add_argument("--height=2160")

    geckodriver = get_geckodriver()
    print(f"Using geckodriver: {geckodriver}")

    service = Service(executable_path=geckodriver)
    driver = webdriver.Firefox(service=service, options=opts)
    driver.set_window_size(1920, 2160)
    return driver


def full_page_screenshot(driver, path):
    """
    Takes a full page screenshot by temporarily expanding
    the window height to match the entire page scrollHeight.
    This captures all content including parts below the fold.
    """
    try:
        # Get total page height including content below scroll
        total_height = driver.execute_script(
            "return document.body.scrollHeight"
        )

        # Use at least the initial window height
        total_height = max(total_height, 2160)

        print(f"  Page scrollHeight: {total_height}px")

        # Expand window to full page height, keep width fixed
        driver.set_window_size(1920, total_height)
        time.sleep(2)

        # Take screenshot at full height
        driver.save_screenshot(str(path))

    finally:
        # Always reset back to original size
        # even if screenshot fails
        driver.set_window_size(1920, 2160)
        time.sleep(1)


def dismiss_popup(driver):
    """Dismiss the welcome popup/tour modal — appears only once after login."""
    print("Checking for welcome popup...")
    for popup_selector in [
        "button[aria-label='Close']",
        "button[data-test='tour-step-footer-secondary']",
        "[data-test='guided-tour-modal'] button",
        ".pf-v5-c-modal-box button[aria-label='Close']",
        ".pf-c-modal-box button[aria-label='Close']",
    ]:
        try:
            popup_btn = WebDriverWait(driver, 5).until(
                EC.element_to_be_clickable(
                    (By.CSS_SELECTOR, popup_selector)
                )
            )
            popup_btn.click()
            print(f"Welcome popup dismissed via: {popup_selector}")
            time.sleep(2)
            return True
        except Exception:
            continue
    print("No welcome popup found")
    return False


def login(driver, console_url, password):
    print(f"Opening console URL: {console_url}")

    # Load the console URL — it will redirect to OAuth login naturally
    # This sets the state cookie correctly
    driver.get(console_url)

    try:
        # Wait for redirect to OAuth login page
        print("Waiting for OAuth redirect...")
        WebDriverWait(driver, 60).until(
            lambda d: "oauth" in d.current_url.lower()
            or "login" in d.current_url.lower()
        )
        print(f"Redirected to: {driver.current_url}")

        # Try clicking kube:admin provider if present
        try:
            kube_admin_link = WebDriverWait(driver, 10).until(
                EC.element_to_be_clickable(
                    (By.LINK_TEXT, "kube:admin")
                )
            )
            kube_admin_link.click()
            print("Clicked kube:admin provider link")
            time.sleep(3)
            WebDriverWait(driver, 30).until(
                EC.presence_of_element_located((By.TAG_NAME, "form"))
            )
        except Exception:
            print("No provider selector — already on login form")

        print(f"Login form URL: {driver.current_url}")

        # Find username field
        username_field = None
        for selector_type, selector in [
            (By.ID, "inputUsername"),
            (By.NAME, "username"),
            (By.NAME, "login"),
            (By.CSS_SELECTOR, "input[type='text']"),
            (By.XPATH, "//input[@type='text']"),
        ]:
            try:
                username_field = WebDriverWait(driver, 5).until(
                    EC.presence_of_element_located(
                        (selector_type, selector)
                    )
                )
                print(
                    f"Username field: {selector_type}='{selector}' "
                    f"id='{username_field.get_attribute('id')}'"
                )
                break
            except Exception:
                continue

        if not username_field:
            raise Exception("Could not find username field")

        # Use JavaScript to set values — handles React controlled inputs
        driver.execute_script(
            """
            var el = arguments[0];
            var setter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            ).set;
            setter.call(el, arguments[1]);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            """,
            username_field, "kubeadmin"
        )
        time.sleep(1)
        print(f"Username set: '{username_field.get_attribute('value')}'")

        # Find password field
        password_field = None
        for selector_type, selector in [
            (By.ID, "inputPassword"),
            (By.NAME, "password"),
            (By.CSS_SELECTOR, "input[type='password']"),
            (By.XPATH, "//input[@type='password']"),
        ]:
            try:
                password_field = WebDriverWait(driver, 5).until(
                    EC.presence_of_element_located(
                        (selector_type, selector)
                    )
                )
                print(
                    f"Password field: {selector_type}='{selector}' "
                    f"id='{password_field.get_attribute('id')}'"
                )
                break
            except Exception:
                continue

        if not password_field:
            raise Exception("Could not find password field")

        driver.execute_script(
            """
            var el = arguments[0];
            var setter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            ).set;
            setter.call(el, arguments[1]);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            """,
            password_field, password
        )
        time.sleep(1)
        print(f"Password length: {len(password_field.get_attribute('value'))}")

        # Find and click submit button
        submit_btn = None
        for selector_type, selector in [
            (By.CSS_SELECTOR, "button[type='submit']"),
            (By.CSS_SELECTOR, "input[type='submit']"),
            (By.XPATH, "//button[contains(text(),'Log')]"),
        ]:
            try:
                submit_btn = WebDriverWait(driver, 5).until(
                    EC.element_to_be_clickable(
                        (selector_type, selector)
                    )
                )
                print(f"Submit: {selector_type}='{selector}'")
                break
            except Exception:
                continue

        if not submit_btn:
            raise Exception("Could not find submit button")

        submit_btn.click()
        print("Submit clicked")
        time.sleep(5)
        print(f"URL after submit: {driver.current_url}")

        # Wait until fully on console — not on oauth/login/error
        print("Waiting for redirect to console...")
        WebDriverWait(driver, 120).until(
            lambda d: "console-openshift-console" in d.current_url
            and "oauth" not in d.current_url
            and "login" not in d.current_url
            and "error" not in d.current_url
        )

        # Wait for page to fully render
        WebDriverWait(driver, 60).until(
            lambda d: d.execute_script(
                "return document.readyState"
            ) == "complete"
        )
        time.sleep(15)
        print(f"Login successful — current URL: {driver.current_url}")

        # Dismiss welcome popup — appears once after first login
        dismiss_popup(driver)

    except Exception as e:
        driver.save_screenshot("/tmp/login_failure.png")
        print(f"Login failure — URL: {driver.current_url}")
        print(f"Page title: {driver.title}")
        raise Exception(f"Login failed: {e}")


def scroll_to_section(driver, heading_text):
    """
    Scroll the page so the section whose heading text equals heading_text
    is at the top. Falls back to scrolling the console's main scroll
    container down by one viewport if the heading is not found.
    """
    found = driver.execute_script(
        """
        var res = document.evaluate(
            "//*[normalize-space(text())='" + arguments[0] + "']",
            document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null
        );
        var el = res.singleNodeValue;
        if (!el) { return false; }
        el.scrollIntoView({block: 'start'});
        return true;
        """,
        heading_text
    )
    if not found:
        print(f"  Heading '{heading_text}' not found — scrolling one viewport")
        driver.execute_script(
            """
            var c = document.getElementById('content-scrollable')
                    || document.scrollingElement;
            c.scrollTop += c.clientHeight;
            """
        )
    time.sleep(5)


def screenshot_with_retry(driver, name, url, output_dir, retries=2,
                          scroll_to=None):
    for attempt in range(retries + 1):
        try:
            print(f"  Loading URL: {url}")
            driver.get(url)

            # Wait for document ready
            WebDriverWait(driver, 60).until(
                lambda d: d.execute_script(
                    "return document.readyState"
                ) == "complete"
            )

            # Wait for OCP spinners to disappear
            for spinner in [
                ".pf-v5-c-spinner",
                ".pf-c-spinner",
                ".co-m-loader",
                "[data-test='loading-indicator']"
            ]:
                try:
                    WebDriverWait(driver, 20).until(
                        EC.invisibility_of_element_located(
                            (By.CSS_SELECTOR, spinner)
                        )
                    )
                except Exception:
                    pass

            # Extra wait for React rendering
            time.sleep(10)

            path = output_dir / f"{name}.png"

            if scroll_to:
                # Pause, scroll to the requested section and capture the
                # current viewport (resizing the window would reset scroll)
                scroll_to_section(driver, scroll_to)
                driver.save_screenshot(str(path))
            else:
                # Take full page screenshot using scrollHeight
                full_page_screenshot(driver, path)

            size = path.stat().st_size
            print(
                f"  Saved: {path} "
                f"({size} bytes, attempt {attempt + 1})"
            )
            return True

        except Exception as e:
            print(f"  Attempt {attempt + 1} failed for {name}: {e}")
            if attempt == retries:
                try:
                    driver.save_screenshot(
                        str(output_dir / f"{name}_FAILED.png")
                    )
                except Exception:
                    pass
                return False
            time.sleep(15)


def capture_pages(driver, console_url, output_dir):
    cpu_url = (
        f"{console_url}/monitoring/dashboards/dashboard-k8s-resources-cluster"
    )
    # (name, url, heading to scroll to before capturing or None)
    # Files are saved with a numeric prefix so they sort in capture order.
    pages = [
        ("dashboard",
         f"{console_url}/dashboards",
         None),
        ("alerts",
         f"{console_url}/monitoring/alerts?rowFilter-alert-source=platform",
         None),
        ("apiserver",
         f"{console_url}/monitoring/dashboards/grafana-dashboard-apiserver-performance",
         None),
        ("etcd",
         f"{console_url}/monitoring/dashboards/etcd-dashboard",
         None),
        ("CPU",
         cpu_url,
         None),
        # Same page as CPU, scrolled down to the Memory section
        ("memory",
         cpu_url,
         "CPU Quota"),
        ("prometheus",
         f"{console_url}/monitoring/dashboards/dashboard-prometheus",
         None),
        ("cluster-settings",
         f"{console_url}/settings/cluster",
         None),
    ]

    success = 0
    failed = []

    for index, (name, url, scroll_to) in enumerate(pages, start=1):
        file_name = f"{index:02d}-{name}"
        print(f"\nCapturing {file_name}:")
        if screenshot_with_retry(driver, file_name, url, output_dir,
                                 scroll_to=scroll_to):
            success += 1
        else:
            print(f"  FAILED: {name}")
            failed.append(name)

    print(f"\nCaptured {success}/{len(pages)} pages")
    if failed:
        print(f"Failed pages: {failed}")
    if success == 0:
        raise Exception("All page captures failed")


def create_tar(output_base):
    tar_name = str(output_base.parent / "ui-screenshots.tar.gz")
    if not output_base.exists():
        raise Exception(f"{output_base} does not exist")
    with tarfile.open(tar_name, "w:gz") as tar:
        tar.add(str(output_base), arcname="ui-screenshots")
    print(f"Created archive: {tar_name}")
    return tar_name


def main():
    print("=" * 60)
    print("OCP SCREENSHOT COLLECTION")
    print("=" * 60)

    output_base = get_output_base()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = output_base / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"Output directory: {output_dir}")

    try:
        console_url = get_console_url()
        password = get_password()
    except Exception as e:
        print(f"ERROR: Pre-flight check failed: {e}")
        sys.exit(1)

    driver = None
    try:
        driver = create_driver()
        login(driver, console_url, password)
        capture_pages(driver, console_url, output_dir)
    except Exception as e:
        print(f"ERROR: Screenshot collection failed: {e}")
        sys.exit(1)
    finally:
        if driver:
            driver.quit()

    try:
        create_tar(output_base)
    except Exception as e:
        print(f"ERROR: Failed to create tar: {e}")
        sys.exit(1)

    print("Screenshot collection completed successfully")
    sys.exit(0)


if __name__ == "__main__":
    main()