#!/usr/bin/env node

import { VerificationError, verify } from "./index.js";

const usage = `Usage: printwright-verify <cert_id|url> [options]

Verify a PWC-1 certificate directly against a Hedera mirror node.

Options:
  --network testnet|mainnet  Hedera network (default: testnet)
  --topic 0.0.N             Override the certificate topic
  --mirror https://...      Override the mirror-node base URL
  --json                    Print the result as JSON
  --help                    Show this help`;

try {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    console.log(usage);
    process.exit(0);
  }
  const result = await verify(options.input, options);
  if (options.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(`✓ ${result.certificate.cert_id} verified as PWC-1 on Hedera`);
    console.log(`  topic ${result.topic_id} · sequence ${result.sequence_number}`);
    console.log(`  consensus ${result.consensus_timestamp}`);
    console.log(`  ${result.certificate.license_type} · model ${result.certificate.model_id} · unit ${result.certificate.unit_serial}`);
  }
} catch (error) {
  const code = error instanceof VerificationError ? error.code : "unexpected_error";
  console.error(`✗ ${code}: ${error.message}`);
  process.exit(1);
}

function parseArguments(args) {
  if (args.includes("--help") || args.includes("-h")) return { help: true };
  const options = { network: "testnet", json: false };
  const positional = [];
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--json") {
      options.json = true;
    } else if ([ "--network", "--topic", "--mirror" ].includes(argument)) {
      const value = args[index + 1];
      if (!value || value.startsWith("--")) throw new VerificationError(`${argument} needs a value`, "invalid_input");
      options[argument.slice(2)] = value;
      index += 1;
    } else if (argument.startsWith("-")) {
      throw new VerificationError(`unknown option ${argument}`, "invalid_input");
    } else {
      positional.push(argument);
    }
  }
  if (positional.length !== 1) throw new VerificationError("provide exactly one certificate id or URL", "invalid_input");
  options.input = positional[0];
  return options;
}
