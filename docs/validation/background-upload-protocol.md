# Background upload v1

The server advertises `backgroundUploadsV1` on `/server/features`. Existing multipart and Imora chunk transports remain compatible with older servers.

Preparation uses one worker while backgrounded, in Low Power Mode, or at serious thermal pressure. Critical thermal pressure stops new preparation until conditions recover. Existing work drains before more workers start under a reduced budget.

Authenticated, redirect-rejecting POST `/assets/background-uploads` opens or resumes a server/user/content/metadata-bound upload. Its AES-256-GCM key and opaque staging capability stay in the protected app process and server staging state. Parts use a 12-byte nonce, ciphertext, and 16-byte tag. Authenticated data is the UTF-8 decimal string `uploadId:offset:plaintextLength`; parts are 8 MiB, except the final part.

The system URLSession receives only an encrypted file, a fixed staging URL, and the upload-only capability. It receives no account bearer token, encryption key, cookies, or credential store. A redirect can therefore carry only authenticated ciphertext and a capability that cannot read or import media. The daemon response is discarded and cannot create a backup receipt.

POST `/assets/background-uploads/:id/status` uses the guarded authenticated client. It rechecks ownership and upload permission, acknowledges contiguous parts through durable offset checkpoints, verifies the complete original checksum, and imports through existing quota, duplicate, Live Photo, and asset creation logic. The client revalidates its current source/deletion authority before requesting status. An existing receipt cannot identify a removed cloud copy as backed up.

The new background session is reattached after process relaunch. Continued processing covers preparation and finishes with an explicit handoff status once a scoped library transfer is accepted by the daemon. This is not whole-library completion; the manager retains its run and durable intent. The completed preparation task can no longer expire and pause ongoing system uploads. Before handoff, cancellation or continued-processing expiration still requires the existing explicit-resume action. A user force quit cancels system transfers. iOS determines discretionary preparation opportunities; there is no guarantee that unprepared files can start immediately while locked.

Server staging is separate from the media library. It has a seven-day lifetime, account/session bounds and disk reservations. Public staging cannot import, download or delete an asset. Cancellation removes staging only. No database migration is required; rollback to a server without this feature leaves existing media untouched.

Physical locked-screen and interrupted-video acceptance must record transferred bytes, committed offsets and final original verification. Process residency and simulated unit tests alone do not establish that acceptance.
