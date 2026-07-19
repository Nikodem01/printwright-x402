import importlib.metadata
import importlib.resources
import json
import unittest
from unittest.mock import Mock, patch

from octoprint.events import Events

from octoprint_printwright import PrintwrightPlugin


class PrintwrightPluginTest(unittest.TestCase):
    def setUp(self):
        self.plugin = PrintwrightPlugin()
        self.plugin._logger = Mock()

    def test_print_started_emits_bounded_structured_record(self):
        self.plugin.on_event(
            Events.PRINT_STARTED,
            {
                "name": "licensed-part.gcode",
                "path": "licensed-part.gcode",
                "origin": "local",
                "size": 123,
                "owner": "must-not-be-logged",
            },
        )

        message, encoded = self.plugin._logger.info.call_args.args
        self.assertEqual("PRINTWRIGHT_JOB_STARTED %s", message)
        self.assertEqual(
            {
                "event": "print_started",
                "name": "licensed-part.gcode",
                "origin": "local",
                "path": "licensed-part.gcode",
                "size": 123,
            },
            json.loads(encoded),
        )
        self.assertNotIn("owner", encoded)

    def test_unrelated_event_is_ignored(self):
        self.plugin.on_event(Events.PRINT_DONE, {"name": "licensed-part.gcode"})
        self.plugin._logger.info.assert_not_called()

    def test_enabled_hook_pauses_until_background_payment_returns_a_certificate(self):
        self.plugin._settings = Mock()
        values = {
            "enabled": True,
            "base_url": "https://printwright.example",
            "model_id": 7,
            "license_kind": "commercial_unit",
            "network": "testnet",
            "asset": "0.0.429274",
            "max_amount": 500000,
            "sandbox": False,
            "hcli_path": "hcli",
            "signer_from": "farm-payer",
        }
        self.plugin._settings.get.side_effect = lambda path: values[path[0]]
        self.plugin._printer = Mock()

        with patch("octoprint_printwright.threading.Thread") as thread:
            self.plugin.on_event(
                Events.PRINT_STARTED,
                {"name": "licensed-part.gcode", "path": "licensed-part.gcode", "origin": "local"},
            )

        self.plugin._printer.pause_print.assert_called_once_with()
        thread.assert_called_once()
        self.assertTrue(thread.call_args.kwargs["daemon"])
        self.assertEqual("printwright-license", thread.call_args.kwargs["name"])

    def test_package_registers_octoprint_entry_point(self):
        entry_points = importlib.metadata.entry_points(group="octoprint.plugin")
        entry_point = next(point for point in entry_points if point.name == "printwright")
        self.assertEqual("octoprint_printwright", entry_point.value)

    def test_package_includes_the_native_settings_panel(self):
        template = importlib.resources.files("octoprint_printwright").joinpath(
            "templates/printwright_settings.jinja2"
        )
        self.assertTrue(template.is_file())
        self.assertIn("Never paste a private key", template.read_text())

    def test_sandbox_never_resumes_a_physical_printer(self):
        self.plugin._settings = Mock()
        self.plugin._settings.get.side_effect = lambda path: {"sandbox": True}[path[0]]
        self.plugin._printer = Mock()
        self.plugin._printer.get_current_connection.return_value = (
            "Operational",
            "/dev/ttyUSB0",
            115200,
            {},
        )
        self.plugin._payment_lock.acquire()

        with patch("octoprint_printwright.PaymentClient") as client:
            self.plugin._license_job()

        client.assert_not_called()
        self.plugin._printer.resume_print.assert_not_called()
        self.plugin._logger.error.assert_called_once_with(
            "PRINTWRIGHT_LICENSE_FAILED %s",
            "sandbox mode is restricted to the VIRTUAL printer",
        )


if __name__ == "__main__":
    unittest.main()
