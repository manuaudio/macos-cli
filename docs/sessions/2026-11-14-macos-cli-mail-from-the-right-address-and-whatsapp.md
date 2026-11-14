# Explicit Mail senders and WhatsApp commands

Mail draft, send and reply now require an address owned by exactly one account.
The outgoing message's sender is read back before sending. Unknown and ambiguous
addresses fail before creating a message. Account output includes every address;
address add/remove is idempotent and retries busy Apple events within its wait.
Long bodies accept UTF-8 files and stdin. Send confirmation requires a new matching
Sent-folder record, excluding preexisting rows; empty or lagging indexes cannot
report success.

Mail metadata queries use the read-only Envelope Index and system account labels;
body reads use Mail. WhatsApp reads use its read-only database, with SQLite backup
for a locked store. Individual-chat sending uses the URL scheme and an AX button
action only after matching the recipient header and composer. It starts disabled
by policy. Group sending is unavailable; no live send was attempted.

Reused the existing Mail JXA, Notes sqlite3 subprocess, Accessibility traversal and
auth policy conventions. Local source/archive/notes searches found no reusable
WhatsApp command implementation. Pure sender/query/confirmation logic lives in
the existing MacCLICore target.

Validation: tests-touched through build-slot passed 4 messaging tests and 40 CLI
tests; one unrelated calendar write test was skipped. Synthetic SQLite stores
cover recipient and subject searches, escaping, WhatsApp rows and reference-date
conversion. Live read checks listed account addresses, returned three WhatsApp
chats and one indexed mail row. A nonexistent sender returned sender_not_found
(exit 3) without sending.

The requested real draft check was attempted with an address selected from Mail's
account list. Existing mail.send policy denied it (exit 4), before draft creation.
The policy was left unchanged. This acceptance check remains open; no draft sender
or live delivery behavior is claimed as verified. WhatsApp Accessibility is also
unavailable on this test binary; the send action was not exercised.
