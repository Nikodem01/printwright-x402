import base64
import json
import subprocess
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class PaymentError(Exception):
    pass


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


class PaymentClient:
    def __init__(
        self,
        *,
        base_url,
        model_id,
        license_kind,
        max_amount,
        asset=None,
        network="testnet",
        sandbox=False,
        hcli_path="hcli",
        signer_from=None,
        signer=None,
        timeout=15,
        certificate_attempts=10,
        certificate_delay=2,
    ):
        self.base_url = base_url.rstrip("/") + "/"
        parsed_base = urlsplit(self.base_url)
        if parsed_base.username or parsed_base.password:
            raise PaymentError("marketplace URL must not contain credentials")
        if not self.sandbox_url_allowed(parsed_base, sandbox):
            raise PaymentError("real remote marketplaces must use HTTPS")
        try:
            self.model_id = int(model_id)
            self.max_amount = int(max_amount)
        except (TypeError, ValueError) as error:
            raise PaymentError("model id and maximum amount must be integers") from error
        if self.model_id <= 0:
            raise PaymentError("model id must be positive")
        if license_kind != "commercial_unit":
            raise PaymentError("OctoPrint jobs require a commercial_unit license")
        self.license_kind = license_kind
        self.asset = asset
        if network not in ("testnet", "mainnet"):
            raise PaymentError("network must be testnet or mainnet")
        self.network = network
        self.sandbox = bool(sandbox)
        self.hcli_path = hcli_path
        self.signer_from = str(signer_from) if signer_from else None
        if self.signer_from and not self._safe_signer_reference(self.signer_from):
            raise PaymentError("signer_from must be an hcli alias, account id, or key reference")
        self.signer = signer or self._hcli_sign
        self.opener = build_opener(_NoRedirect)
        self.timeout = timeout
        self.certificate_attempts = certificate_attempts
        self.certificate_delay = certificate_delay

    def buy(self):
        resource_url = urljoin(
            self.base_url,
            f"api/v1/models/{self.model_id}/download?{urlencode({'license': self.license_kind})}",
        )
        quote_headers = {"Accept": "application/json"}
        if self.sandbox:
            quote_headers["X-Sandbox"] = "true"

        status, headers, body = self._request(resource_url, quote_headers)
        if status != 402:
            raise PaymentError(f"expected HTTP 402, received {status}")

        raw_challenge = headers.get("PAYMENT-REQUIRED")
        if not raw_challenge:
            raise PaymentError("HTTP 402 omitted PAYMENT-REQUIRED")
        required = self._decode_challenge(raw_challenge)
        if self._canonical(required) != self._canonical(body):
            raise PaymentError("PAYMENT-REQUIRED header and body differ")
        if required.get("x402Version") != 2:
            raise PaymentError("payment challenge is not x402 version 2")
        if required.get("resource", {}).get("url") != resource_url:
            raise PaymentError("payment challenge resource URL does not match the job")

        accepted = self._select_requirement(required)
        if self.sandbox:
            signature = self._sandbox_signature(required, accepted)
        else:
            signature = self.signer(raw_challenge, accepted)
            if not isinstance(signature, str) or not signature:
                raise PaymentError("signer returned no payment signature")

        paid_headers = {"Accept": "application/json", "PAYMENT-SIGNATURE": signature}
        if self.sandbox:
            paid_headers["X-Sandbox"] = "true"
        status, _headers, receipt = self._request(resource_url, paid_headers)
        if status != 200:
            raise PaymentError(f"payment retry failed with HTTP {status}")
        if bool(receipt.get("sandbox")) != self.sandbox:
            raise PaymentError("payment receipt sandbox label does not match configuration")

        cert_id = receipt.get("license", {}).get("cert_id")
        if not cert_id:
            raise PaymentError("payment receipt omitted the certificate id")
        certificate = self._wait_for_certificate(cert_id)
        return {
            "cert_id": cert_id,
            "status": certificate.get("status"),
            "verify_url": receipt.get("verify_url"),
            "transaction_url": receipt.get("sandbox_url") or receipt.get("hashscan_url"),
            "mirror_url": certificate.get("hcs", {}).get("mirror_url"),
            "sandbox": self.sandbox,
        }

    def _select_requirement(self, required):
        candidates = required.get("accepts")
        if not isinstance(candidates, list):
            raise PaymentError("payment challenge has no accepted requirements")

        if self.sandbox:
            candidates = [
                item
                for item in candidates
                if item.get("scheme") == "exact"
                and item.get("network") == "hedera:sandbox"
                and item.get("asset") == "sandbox:credit"
                and item.get("extra", {}).get("sandbox") is True
            ]
            if required.get("sandbox") is not True:
                raise PaymentError("server did not return a labeled sandbox challenge")
        else:
            if not self.asset:
                raise PaymentError("a real payment asset must be configured")
            candidates = [
                item
                for item in candidates
                if item.get("scheme") == "exact"
                and item.get("network") == f"hedera:{self.network}"
                and item.get("asset") == self.asset
            ]

        if not candidates:
            raise PaymentError("payment challenge does not offer the configured exact asset")
        accepted = candidates[0]
        amount = str(accepted.get("amount", ""))
        if not amount.isdigit() or int(amount) <= 0:
            raise PaymentError("payment challenge amount is invalid")
        if self.max_amount <= 0 or int(amount) > self.max_amount:
            raise PaymentError("payment challenge amount exceeds configured maximum")
        if not str(accepted.get("payTo", "")):
            raise PaymentError("payment challenge omitted payTo")
        if not str(accepted.get("extra", {}).get("feePayer", "")):
            raise PaymentError("payment challenge omitted feePayer")
        timeout = accepted.get("maxTimeoutSeconds")
        if not isinstance(timeout, int) or not 0 < timeout <= 180:
            raise PaymentError("payment challenge timeout is invalid")
        if not self.sandbox and (
            not self._account_id(accepted["payTo"])
            or not self._account_id(accepted["extra"]["feePayer"])
        ):
            raise PaymentError("payment challenge contains an invalid Hedera account id")
        return accepted

    def _hcli_sign(self, raw_challenge, accepted):
        command = [
            self.hcli_path,
            "--format",
            "json",
            "x402",
            "sign",
            "--challenge",
            raw_challenge,
            "--asset",
            accepted["asset"],
        ]
        if self.signer_from:
            command.extend(["--from", self.signer_from])
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                check=False,
                text=True,
                timeout=45,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            raise PaymentError("hcli signer is unavailable") from error
        if result.returncode != 0:
            raise PaymentError("hcli refused the payment challenge")
        try:
            output = json.loads(result.stdout)
            signature = output["paymentSignatureHeader"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise PaymentError("hcli returned an invalid response") from error
        return signature

    def _sandbox_signature(self, required, accepted):
        payload = {
            "x402Version": 2,
            "resource": required.get("resource"),
            "accepted": accepted,
            "payload": {"transaction": f"sandbox:{uuid.uuid4()}"},
        }
        return base64.b64encode(self._canonical(payload).encode()).decode()

    def _wait_for_certificate(self, cert_id):
        certificate_url = urljoin(
            self.base_url, f"api/v1/certificates/{quote(cert_id, safe='')}"
        )
        for attempt in range(self.certificate_attempts):
            status, _headers, certificate = self._request(
                certificate_url, {"Accept": "application/json"}
            )
            if status != 200:
                raise PaymentError(f"certificate lookup failed with HTTP {status}")
            if certificate.get("status") in ("anchored", "sandbox"):
                return certificate
            if attempt + 1 < self.certificate_attempts:
                time.sleep(self.certificate_delay)
        raise PaymentError("certificate did not become ready before the deadline")

    def _request(self, url, headers):
        request = Request(url, headers=headers, method="GET")
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                return response.status, response.headers, self._json(response.read(1_000_001))
        except HTTPError as error:
            return error.code, error.headers, self._json(error.read(1_000_001))
        except URLError as error:
            raise PaymentError("Printwright marketplace is unavailable") from error

    @staticmethod
    def _decode_challenge(raw_challenge):
        try:
            decoded = base64.b64decode(raw_challenge, validate=True)
            return json.loads(decoded)
        except (ValueError, json.JSONDecodeError) as error:
            raise PaymentError("PAYMENT-REQUIRED is not valid base64 JSON") from error

    @staticmethod
    def _json(encoded):
        if len(encoded) > 1_000_000:
            raise PaymentError("Printwright response exceeded one megabyte")
        try:
            return json.loads(encoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PaymentError("Printwright returned invalid JSON") from error

    @staticmethod
    def _canonical(value):
        return json.dumps(value, separators=(",", ":"), sort_keys=True)

    @staticmethod
    def sandbox_url_allowed(parsed_base, sandbox):
        if parsed_base.scheme == "https":
            return True
        return parsed_base.scheme == "http" and (
            sandbox or parsed_base.hostname in ("localhost", "127.0.0.1", "::1")
        )

    @staticmethod
    def _safe_signer_reference(value):
        if value.startswith("kr_"):
            value = value[3:]
        if value.replace("-", "").replace("_", "").isalnum() and ":" not in value:
            return True
        return PaymentClient._account_id(value)

    @staticmethod
    def _account_id(value):
        parts = str(value).split(".")
        return len(parts) == 3 and parts[:2] == ["0", "0"] and parts[2].isdigit()
