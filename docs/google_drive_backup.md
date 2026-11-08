# Automatic backup to Google Drive

Closing the day takes a backup. If this is set up, that backup goes to the
owner's own Google Drive by itself; if it is not, the app offers to send a
copy through the share sheet instead, and says plainly that nothing is
connected. Nothing about the POS depends on any of it.

The whole thing is one Google account and one client id. It is free, and
it is a one-time job.

## What the app asks for

One scope: `https://www.googleapis.com/auth/drive.file`.

That scope can see **only the files the app itself created**. It cannot read
her photos, her documents or anything else in her Drive. It is also not a
"sensitive" scope, so Google does not put the app through a review — which
is the difference between this taking an afternoon and taking six weeks.

Backups land in a folder called **Kubo Cà Phê backups**, created on first
upload.

## One-time setup

1. Sign in at <https://console.cloud.google.com> with the account the
   backups should live in, and create a project (any name).
2. **APIs & Services → Library → Google Drive API → Enable.**
3. **APIs & Services → OAuth consent screen:** choose *External*, fill in the
   app name, support email and developer email. Leave it in *Testing* and add
   her Google account under **Test users** — a testing app is limited to
   those users, which is exactly what is wanted here. Publishing is not
   needed and would trigger a review.
4. **Credentials → Create credentials → OAuth client ID → iOS.**
   Bundle ID: the one in `ios/Runner.xcodeproj` (`PRODUCT_BUNDLE_IDENTIFIER`).
   Google gives back a client id of the form
   `1234-abcd.apps.googleusercontent.com` and a reversed form
   `com.googleusercontent.apps.1234-abcd`.
5. Put the **reversed** client id into `ios/Runner/Info.plist`, replacing
   `REVERSED_CLIENT_ID_GOES_HERE` in the `CFBundleURLSchemes` array. iOS needs
   it to hand the sign-in back to the app.
6. Build with the plain client id passed in:

   ```sh
   flutter build ipa \
     --dart-define=GOOGLE_CLIENT_ID=1234-abcd.apps.googleusercontent.com
   ```

7. In the app: **Manage → Backup → Connect Google Drive**, sign in once, and
   allow access. The account's email then shows on that screen, along with
   when the last copy went up.

A build without `GOOGLE_CLIENT_ID` is not broken: the Backup screen says
automatic cloud backup is not set up, and the share-sheet copy still works.

## What happens day to day

* Closing the day writes a backup and uploads it. The snackbar says
  "saved to the cloud" when it went.
* No signal, Drive full, or a sign-in that has lapsed: the day still closes,
  the reason is recorded and shown on the Backup screen, and she is offered
  the share sheet there and then.
* Opening the app the next morning retries anything that never went up.
* A backup is only ever marked as "copied off the phone" once it really has
  been. Nothing is ever deleted from the phone because it reached the cloud.

## What this is not

It is not sync. Two phones running Kubo are two shops; the backup is a copy,
not a shared set of orders. Sharing one set of orders between devices is a
different and much larger piece of work.
