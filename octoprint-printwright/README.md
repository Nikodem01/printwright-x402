# Printwright for OctoPrint

This is the installable OctoPrint edge for Printwright's per-print licensing rail. The V43
kill-test intentionally does one thing: observe OctoPrint's real `PrintStarted` event, immediately
emit a bounded structured record, and return without network work on OctoPrint's serialized event
bus. V44 adds the asynchronous x402 purchase only after this event path proves reliable.

The spike is tested against OctoPrint 1.11.7 and its bundled virtual printer. It does not claim a
physical printer ran. The event record includes only `name`, storage `path`, `origin`, and optional
file `size`; it deliberately omits the OctoPrint user/owner fields.

Install into the same Python environment as OctoPrint:

```sh
python -m pip install ./octoprint-printwright
```

Run the isolated virtual-printer acceptance rehearsal from the repository root:

```sh
OCTOPRINT_BIN=/path/to/octoprint scripts/octoprint_spike_smoke.sh
```

The script boots a temporary loopback instance with a generated one-run API key, connects
`VIRTUAL`, uploads a harmless G-code fixture, starts it, and requires a
`PRINTWRIGHT_JOB_STARTED` record. It deletes its temporary OctoPrint home on exit.
