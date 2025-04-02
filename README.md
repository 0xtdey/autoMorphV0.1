# AutoMorph

AutoMorph is a self-repaying loan protocol that enables users to maximize their capital efficiency while minimizing debt management overhead. The protocol leverages AAVE's lending markets to generate yield on user deposits, which automatically pays down their debt positions over time.

## Overview

When users deposit WETH as collateral into AutoMorph, they receive amWETH tokens which can be freely used across DeFi protocols. Meanwhile, their original WETH collateral is deposited into AAVE's lending pool to generate yield. This yield is automatically harvested and used to reduce the user's debt position.

## Key Features

- **Self-Repaying Loans**: Your collateral works to pay off your debt automatically through yield generation
- **Automated Management**: Chainlink Keepers update debt positions at regular intervals without requiring user intervention
- **Capital Efficiency**: Use amWETH tokens in other DeFi protocols while your original collateral generates yield
- **Simple UX**: Deposit WETH, receive amWETH, and let the protocol handle the rest

## Fees 
A 0.03% fee is applied to every deposit. This fee is automatically allocated to Yearn Finance to generate yield. The yield earned contributes to the treasury's growth, ensuring long-term sustainability and supporting further development of the platform.

## How It Works

1. Deposit WETH → Receive amWETH tokens
2. Original WETH is deposited in AAVE to generate yield
3. Yield automatically pays down your debt position
4. Chainlink Keepers manage position updates
5. Use amWETH freely while your debt decreases over time

## Security Note

This protocol is in development and has not been audited.

