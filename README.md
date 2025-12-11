# Truemarkets Protocol

## Overview

Truemarkets is a **decentralized prediction market platform** that enables users to forecast outcomes of real-world events through market-driven information discovery. The platform breaks down information asymmetries by allowing participants to express real-time sentiment about news and events, creating a "truth machine" where market accuracy increases through collective participation and scrutiny.

The platform places bounties on truth by incentivizing accurate information discovery, transforming traditional news consumption into a participatory, market-driven ecosystem. By giving participants "skin in the game" through direct trading on event outcomes, Truemarkets creates more transparent and dynamic information discovery than centralized reporting systems.

At its core, Truemarkets utilizes an **intersubjective optimistic oracle system** that enables sophisticated dispute resolution for complex, nuanced market outcomes that go beyond simple token voting mechanisms.

## System Architecture

Truemarkets implements a modular, upgradeable architecture with dual-version support for Uniswap V3 and V4 markets, featuring:

- **Market Layer**: Individual prediction markets with yes/no position tokens
- **Oracle Layer**: Decentralized resolution with multi-tier dispute system
- **Token Layer**: Governance tokens and staking mechanisms
- **Trading Layer**: Liquidity management and Universal Router integration
- **NFT Layer**: Soulbound tokens for attesters and patron NFTs

## Market Lifecycle

Markets in Truemarkets follow a sophisticated state machine that ensures fair trading, accurate resolution, and robust dispute handling:

**Key States:**
- **Created**: Market is active for trading
- **Open for Resolution**: Trading ended, awaiting outcome submission
- **Resolution Proposed**: Outcome submitted, in challenge period
- **Dispute Raised**: Challenge submitted, Oracle Council voting
- **Set by Council**: Council decision made, second challenge period active
- **Reset by Council**: Council reset decision, returning to resolution phase
- **Escalated Dispute Raised**: Second challenge raised, token holder voting
- **Finalized**: Market settled, tokens redeemable

The oracle system uses a multi-tier dispute resolution process with bonds and slashing mechanisms to ensure fair outcomes.

## Deployment Information

For contract addresses, versions, and configuration parameters, see [network_config.json](./network_config.json), which contains:
- Contract addresses for all environments
- Version information for each contract

## Audits

- **[GuardianAudits](https://github.com/GuardianAudits/Audits/blob/main/Truemarkets/2025-03-18_Truemarkets_Report.pdf)**
- **[iosiro](https://iosiro.com/audits/truth-markets-v2-smart-contract-audit)**

## Links

- **Website**: [truemarkets.org](https://truemarkets.org)
- **Documentation**: [docs.truemarkets.org](https://docs.truemarkets.org/)
- **X (Twitter)**: [@truemarkets](https://x.com/truemarkets)
- **Discord**: [Join our community](https://discord.gg/truemarkets)

---

*This repository contains the smart contracts for the Truemarkets prediction market platform and its underlying intersubjective optimistic oracle system. The platform enables decentralized prediction markets with sophisticated dispute resolution for accurate outcome determination.*
