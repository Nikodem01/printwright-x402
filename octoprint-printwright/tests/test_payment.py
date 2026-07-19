import base64
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import Mock, patch

from octoprint_printwright.payment import PaymentClient, PaymentError


class FakePrintwrightHandler(BaseHTTPRequestHandler):
    cert_id = "sandbox-pw-000009"
    required = None
    paid_headers = None

    def do_GET(self):
        if self.path == "/api/v1/models/7/download?license=commercial_unit":
            if self.headers.get("PAYMENT-SIGNATURE"):
                type(self).paid_headers = self.headers
                self._json(
                    200,
                    {
                        "sandbox": True,
                        "license": {"cert_id": self.cert_id, "serial": 1},
                        "verify_url": f"{self.server.base_url}/verify/{self.cert_id}",
                        "sandbox_url": f"{self.server.base_url}/api/v1/sandbox/transactions/sandbox-tx",
                    },
                )
                return

            body = self.required or {
                "x402Version": 2,
                "sandbox": True,
                "resource": {
                    "url": f"{self.server.base_url}{self.path}",
                    "mimeType": "application/json",
                },
                "accepts": [
                    {
                        "scheme": "exact",
                        "network": "hedera:sandbox",
                        "amount": "25",
                        "asset": "sandbox:credit",
                        "payTo": "sandbox:designer",
                        "maxTimeoutSeconds": 180,
                        "extra": {"feePayer": "sandbox:facilitator", "sandbox": True},
                    }
                ],
            }
            encoded = base64.b64encode(json.dumps(body).encode()).decode()
            self.send_response(402)
            self.send_header("Content-Type", "application/json")
            self.send_header("PAYMENT-REQUIRED", encoded)
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())
            return

        if self.path == f"/api/v1/certificates/{self.cert_id}":
            self._json(
                200,
                {
                    "status": "sandbox",
                    "hcs": {"sandbox": True, "mirror_url": "/api/v1/sandbox/topics/topic/messages/9"},
                },
            )
            return

        self._json(404, {"error": "not found"})

    def log_message(self, _format, *_args):
        pass

    def _json(self, status, body):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class PaymentClientTest(unittest.TestCase):
    def setUp(self):
        FakePrintwrightHandler.required = None
        FakePrintwrightHandler.paid_headers = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakePrintwrightHandler)
        self.server.base_url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_sandbox_job_completes_without_a_signer_and_returns_public_proof(self):
        result = PaymentClient(
            base_url=self.server.base_url,
            model_id=7,
            license_kind="commercial_unit",
            sandbox=True,
            max_amount=500,
        ).buy()

        self.assertEqual("sandbox-pw-000009", result["cert_id"])
        self.assertEqual("sandbox", result["status"])
        self.assertTrue(result["sandbox"])
        self.assertEqual(
            f"{self.server.base_url}/verify/sandbox-pw-000009",
            result["verify_url"],
        )
        payload = json.loads(
            base64.b64decode(FakePrintwrightHandler.paid_headers["PAYMENT-SIGNATURE"])
        )
        self.assertTrue(payload["payload"]["transaction"].startswith("sandbox:"))

    def test_real_requirement_is_capped_before_the_signer_runs(self):
        signer = Mock()
        FakePrintwrightHandler.required = {
            "x402Version": 2,
            "resource": {
                "url": f"{self.server.base_url}/api/v1/models/7/download?license=commercial_unit"
            },
            "accepts": [
                {
                    "scheme": "exact",
                    "network": "hedera:testnet",
                    "amount": "500001",
                    "asset": "0.0.429274",
                    "payTo": "0.0.1234",
                    "maxTimeoutSeconds": 180,
                    "extra": {"feePayer": "0.0.5678"},
                }
            ],
        }

        with self.assertRaisesRegex(PaymentError, "exceeds configured maximum"):
            PaymentClient(
                base_url=self.server.base_url,
                model_id=7,
                license_kind="commercial_unit",
                asset="0.0.429274",
                max_amount=500000,
                signer=signer,
            ).buy()
        signer.assert_not_called()

    def test_challenge_resource_must_match_the_configured_job(self):
        FakePrintwrightHandler.required = {
            "x402Version": 2,
            "resource": {"url": "https://attacker.invalid/collect"},
            "accepts": [],
        }

        with self.assertRaisesRegex(PaymentError, "resource URL"):
            PaymentClient(
                base_url=self.server.base_url,
                model_id=7,
                license_kind="commercial_unit",
                sandbox=True,
                max_amount=500,
            ).buy()

    def test_hcli_receives_the_raw_challenge_and_only_a_payer_reference(self):
        client = PaymentClient(
            base_url=self.server.base_url,
            model_id=7,
            license_kind="commercial_unit",
            asset="0.0.429274",
            max_amount=500000,
            hcli_path="/usr/local/bin/hcli",
            signer_from="farm-payer",
        )
        completed = Mock(
            returncode=0,
            stdout=json.dumps({"paymentSignatureHeader": "signed-header"}),
        )

        with patch("octoprint_printwright.payment.subprocess.run", return_value=completed) as run:
            signature = client._hcli_sign("raw-challenge", {"asset": "0.0.429274"})

        self.assertEqual("signed-header", signature)
        command = run.call_args.args[0]
        self.assertEqual("/usr/local/bin/hcli", command[0])
        self.assertEqual(["--format", "json"], command[1:3])
        self.assertIn("raw-challenge", command)
        self.assertIn("farm-payer", command)
        self.assertNotIn("privateKey", " ".join(command))

    def test_real_remote_marketplace_requires_tls(self):
        with self.assertRaisesRegex(PaymentError, "must use HTTPS"):
            PaymentClient(
                base_url="http://printwright.example",
                model_id=7,
                license_kind="commercial_unit",
                asset="0.0.429274",
                max_amount=500000,
            )

    def test_inline_private_key_style_signer_is_rejected(self):
        with self.assertRaisesRegex(PaymentError, "hcli alias"):
            PaymentClient(
                base_url=self.server.base_url,
                model_id=7,
                license_kind="commercial_unit",
                asset="0.0.429274",
                max_amount=500000,
                signer_from="0.0.1234:must-not-live-in-octoprint",
            )


if __name__ == "__main__":
    unittest.main()
