# Mail Ledger

Mail Ledger is an iOS 17+ sample app for organizing credit-card billing dates and amounts. It supports manual entry, pasted billing emails, and optional read-only Gmail or iCloud Mail imports.

This repository is a public portfolio edition. Production identifiers, credentials, store metadata, support pages, release notes, and branding assets are intentionally excluded.

## Highlights

- SwiftUI interface with SwiftData persistence
- Rule-based extraction of billing amounts and payment dates
- Gmail OAuth with PKCE and the read-only Gmail scope
- iCloud Mail access over IMAP/TLS using an app-specific password
- Keychain storage for local credentials
- Review flow before imported billing data is saved
- StoreKit 2 entitlement handling with an unconfigured sample product ID
- AdMob development defaults using Google's official test identifiers
- XCTest coverage for parsers and mail-import behavior

## Project structure

| Path | Purpose |
| --- | --- |
| `CardBills/Models` | SwiftData models for cards and bills |
| `CardBills/Services` | Billing-email parser and demo data |
| `CardBills/Gmail` | OAuth, Gmail API, and import rules |
| `CardBills/iCloud` | IMAP client and credential storage |
| `CardBills/Views` | SwiftUI screens and review flows |
| `CardBillsTests` | Parser and integration-unit tests |

## Build

1. Open `CardBills.xcodeproj` in Xcode.
2. Select your own development team and replace the sample bundle identifier.
3. Build for an iOS 17 or later simulator.

The app remains usable for manual entry and pasted-email parsing without mail credentials. To test Gmail integration, copy `GmailOAuth.local.xcconfig.example` to the ignored `GmailOAuth.local.xcconfig` file and provide your own iOS OAuth client values. Production secrets must never be committed.

## Privacy and security notes

- OAuth tokens and iCloud app-specific passwords are stored in the device Keychain.
- Gmail access requests only `gmail.readonly`.
- Imported messages are reviewed before billing records are saved.
- The repository contains placeholders and official advertising test IDs only.

## Scope

This is a source-code portfolio project. It is not connected to an App Store listing, production OAuth consent screen, advertising account, or hosted support site.
