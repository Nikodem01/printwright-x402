import importlib.metadata
import json
import unittest
from unittest.mock import Mock

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

    def test_package_registers_octoprint_entry_point(self):
        entry_points = importlib.metadata.entry_points(group="octoprint.plugin")
        entry_point = next(point for point in entry_points if point.name == "printwright")
        self.assertEqual("octoprint_printwright", entry_point.value)


if __name__ == "__main__":
    unittest.main()
