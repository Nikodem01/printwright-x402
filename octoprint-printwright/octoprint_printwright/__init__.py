import json
import threading

import octoprint.plugin
from octoprint.events import Events

from .payment import PaymentClient, PaymentError


class PrintwrightPlugin(
    octoprint.plugin.EventHandlerPlugin,
    octoprint.plugin.SettingsPlugin,
    octoprint.plugin.TemplatePlugin,
):
    """Observe job starts without delaying OctoPrint's serialized event bus."""

    def __init__(self):
        self._payment_lock = threading.Lock()

    def get_settings_defaults(self):
        return {
            "enabled": False,
            "base_url": "http://localhost:3000",
            "model_id": None,
            "license_kind": "commercial_unit",
            "network": "testnet",
            "asset": None,
            "max_amount": 0,
            "sandbox": False,
            "hcli_path": "hcli",
            "signer_from": None,
        }

    def on_event(self, event, payload):
        if event != Events.PRINT_STARTED:
            return

        payload = payload or {}
        record = {
            "event": "print_started",
            "name": payload.get("name"),
            "origin": payload.get("origin"),
            "path": payload.get("path"),
            "size": payload.get("size"),
        }
        self._logger.info(
            "PRINTWRIGHT_JOB_STARTED %s",
            json.dumps(record, separators=(",", ":"), sort_keys=True),
        )
        if not self._setting("enabled", False):
            return

        self._printer.pause_print()
        if not self._payment_lock.acquire(blocking=False):
            self._logger.error("PRINTWRIGHT_LICENSE_FAILED payment_already_running")
            return

        worker = threading.Thread(
            target=self._license_job,
            name="printwright-license",
            daemon=True,
        )
        try:
            worker.start()
        except Exception:
            self._payment_lock.release()
            raise

    def _license_job(self):
        try:
            if self._setting("sandbox", False) and not self._virtual_printer():
                raise PaymentError("sandbox mode is restricted to the VIRTUAL printer")
            result = PaymentClient(
                base_url=self._setting("base_url", "http://localhost:3000"),
                model_id=self._setting("model_id", 0),
                license_kind=self._setting("license_kind", "commercial_unit"),
                network=self._setting("network", "testnet"),
                asset=self._setting("asset"),
                max_amount=self._setting("max_amount", 0),
                sandbox=self._setting("sandbox", False),
                hcli_path=self._setting("hcli_path", "hcli"),
                signer_from=self._setting("signer_from"),
            ).buy()
            self._logger.info(
                "PRINTWRIGHT_LICENSED %s",
                json.dumps(result, separators=(",", ":"), sort_keys=True),
            )
            self._printer.resume_print()
        except PaymentError as error:
            self._logger.error("PRINTWRIGHT_LICENSE_FAILED %s", str(error))
        except Exception as error:
            self._logger.error(
                "PRINTWRIGHT_LICENSE_FAILED internal_%s", type(error).__name__
            )
        finally:
            self._payment_lock.release()

    def _setting(self, name, default=None):
        try:
            value = self._settings.get([name])
        except (AttributeError, KeyError):
            return default
        return default if value is None else value

    def _virtual_printer(self):
        try:
            _state, port, _baudrate, _profile = self._printer.get_current_connection()
        except (AttributeError, TypeError, ValueError):
            return False
        return port == "VIRTUAL"


__plugin_name__ = "Printwright"
__plugin_version__ = "0.1.0"
__plugin_description__ = "License each print over x402 before resuming the job."
__plugin_pythoncompat__ = ">=3.10,<4"
__plugin_implementation__ = PrintwrightPlugin()
