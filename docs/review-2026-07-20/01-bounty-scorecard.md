# Bounty alignment scorecard

Sources of truth are the live Hedera x402 bounty page, the repository's protocol fixtures/evidence, and the published judging rubric used by the submission validator. Scores here are intentionally evidence-based rather than aspirational.

## Hard requirements traceability

| Requirement | Repository evidence | Status |
| --- | --- | --- |
| x402 payment solution on Hedera | two-leg 402 flow, exact-Hedera facilitator integration, protocol fixtures, conformance suite | Met |
| Testnet operation | testnet defaults, mirror/HashScan links, captured transaction fixtures and operational evidence | Met; refresh final browser evidence after wallet work |
| HBAR or USDC | both HBAR and Hedera USDC quote/settlement paths | Exceeds |
| Public open repository | this app repository is public; no private strategy or credentials are required at runtime | Met; re-run secret gate before push |
| Real transaction and HashScan evidence | receipt/certificate surfaces link transaction IDs and HCS topics | Met in existing evidence; capture final demo transaction |
| Demo under five minutes | repository has a concise end-to-end story and demo tooling | Human action: record final video |
| Submission before deadline | no code action can submit the external form | Human action |

## Judging score — final engineering state

| Category | Weight | Evidence-based score | Rationale |
| --- | ---: | ---: | --- |
| Idea | 15% | 5/5 | Clear agent-native commerce problem, differentiated by machine-readable licensing and verifiable fulfillment. |
| Technical implementation | 30% | 5/5 | Real x402/Hedera flow, HBAR/USDC, fee-sponsored transaction construction, HCS certificates, SDK/MCP/chat/batch surfaces, extensive recovery/idempotency controls. |
| Impact | 15% | 4/5 | Large creator/agent/print-server opportunity with a credible marketplace loop; production traction is not yet proven. |
| Usefulness | 15% | 5/5 | Complete discovery-to-recovery journey, no mandatory buyer signup, current browser wallet connection, clear library recovery, and designer operations. |
| Pitch/demo | 15% | 4/5 | Strong narrative and visible proof surfaces; final deployed recording is outstanding. |
| Validation | 10% | 1/5 | Internal automated evidence is deep, but independent user interviews/usage are not documented. |
| **Weighted total** | **100%** | **86/100** | Deployment-ready engineering; independent validation is now the material scoring constraint. |

## Remaining scoring opportunity

The machine-verifiable target has been met. Validation cannot honestly increase without external-user evidence; five documented uncoached trials would move the score more than additional speculative product surface.

## Demo proof chain

The final recording should show one uninterrupted path:

1. search or ask the shopkeeper for a model;
2. inspect files, print guidance, designer, and license terms;
3. connect a wallet and approve exactly one x402 payment;
4. show the settled transaction on HashScan;
5. download from the durable receipt;
6. open the public certificate and show its HCS evidence;
7. briefly show the designer sales/portfolio view and agent API/MCP path.

Keep the video below five minutes and use a fresh testnet transaction whose links remain in the submission notes.
