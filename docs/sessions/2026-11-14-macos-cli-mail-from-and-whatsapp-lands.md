# 2026-11-14 — macos-cli-mail-from-and-whatsapp-lands

**What.** The Mail-sender and WhatsApp work (lane macos-cli-mail-from-the-right-address-and-whatsapp)
rebased onto main after the "what the factory still scripts by hand" merge; the CHANGELOG and README
capability table kept both sides. Drafts got their own capability, `mail.draft`, on by default:
`mail draft` and the new `mail reply --draft` save the message unsent (`Mail.save`) in the owning
account's Drafts and answer with its `id` and `account`. `mail send`, `mail reply` and `whatsapp send`
stay behind `mail.send` and `whatsapp.send`.

**Why.** Manu 2026-11-14: "create drafts of emails that then I check and then we send". From a person's
accounts, agents draft; a person sends. The earlier lane stopped because its live draft check needed
`mail.send`, which this Mac's policy denies.

**Live send stays off by Manu's decision.** `~/.config/macos-cli/auth.json` was not touched;
`mail.send` and `whatsapp.send` remain denied on this Mac. No mail and no WhatsApp message was sent.

**How proven.** `swift test --filter 'CLITests|MessagingTests'` with `MACOS_CLI_TEST_MAIL_FROM` set:
`testMailDraftWorksWhileSendIsDenied` (draft saved in Google Drafts, sender read back, draft deleted),
`testMailSendDeniedCreatesNothing` (exit 4 `capability_denied`, no draft, no outgoing message),
`testUnknownMailSenderCannotSend` (exit 3 `sender_not_found`). Live from the built binary:
`macos mail accounts --json`, `macos whatsapp chats --json --limit 3`.
