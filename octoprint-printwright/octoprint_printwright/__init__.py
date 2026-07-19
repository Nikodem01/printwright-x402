import json

import octoprint.plugin
from octoprint.events import Events


class PrintwrightPlugin(octoprint.plugin.EventHandlerPlugin):
    """Observe job starts without delaying OctoPrint's serialized event bus."""

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


__plugin_name__ = "Printwright"
__plugin_version__ = "0.0.1"
__plugin_description__ = "Observe print starts for per-print licensing."
__plugin_pythoncompat__ = ">=3.10,<4"
__plugin_implementation__ = PrintwrightPlugin()
