# PrivMsg for iPhone

PrivMsg keeps its existing conversations and file uploads, with native clipboard
file intake, an iOS share extension, and a Files screen for dragging actual files
into another app. It supports iOS 17 and later on iPhone and iPad. This is source
code for an Xcode development install.

## Install from the package

The repository's top-level `Install-PrivMsg.command` can be downloaded alone.
Run it with `bash ~/Downloads/Install-PrivMsg.command`. It downloads a pinned
source revision to `~/Developer/PrivMsg-iOS`, then runs the installer below.
It reuses signing settings across revisions and never resets an existing checkout.

1. Extract the entire package on your Mac. Keep the folders together.
2. Open full Xcode once and finish its setup. The Xcode version must support the
   iOS version installed on your phone. Sign in under Xcode Settings > Accounts.
3. Connect and unlock your iPhone, accept Trust, and enable Settings > Privacy &
   Security > Developer Mode. Restart the phone if Apple requests it.
4. Run the installer in Terminal:

   ```bash
   bash "/path/to/PrivMsg/ios/Install-PrivMsg.command"
   ```

   You can type `bash `, drag `Install-PrivMsg.command` into Terminal, then press
   Return. This avoids needing to change executable permissions or macOS security
   settings. The script does not remove quarantine flags or change Gatekeeper.

The script generates the Xcode project using Python's standard library, reuses
an unambiguous development team where available, builds, installs and opens the
app. It needs no Homebrew, XcodeGen, CocoaPods or additional Swift packages.
Apple signing may need internet access.

If no signing team is available, the script opens Xcode. Select the blue PrivMsg
project, then the PrivMsg target, and choose your Personal Team under Signing &
Capabilities. Select the same team for PrivMsgShare if Xcode requests it. Save
with Command-S and return to Terminal. You can also select
your iPhone in Xcode and press Run. Apple account login, device trust and
Developer Mode require your own interaction.

Sign in to PrivMsg once in the new app. Your existing Safari login is not copied
into the app. Conversations and uploads use the same existing PrivMsg account.

## Drag files to ChatGPT or another app

Open the hamburger menu, then Files in PrivMsg. Hold a file until it lifts, keep holding,
and tap other file rows with another finger to add them to the drag. Swipe Home
or use the app switcher while continuing to hold, then drop into a destination
that accepts files. Large uncached files need network access and preparation;
native preview and Share provide alternatives when the destination rejects a
drag. The exact gesture and target-app acceptance require an iPhone check.

The list follows the currently open conversation and includes saved recordings.
Tap a file to prepare its original and preview it before dragging a large file.
Use Select, choose several files, then Share as an alternative. Files are copied
out, never removed from your conversations. Downloads are limited to three files
at once and up to 4 GiB per file. The destination app may impose smaller limits.

The app bundles its own copy of the PrivMsg interface, so installation does not
depend on a website deployment. Firebase sign-in, messages and uploads still
need internet access. The home-screen icon follows the supplied white visor/head
concept. The exact Vagaries wordmark is bundled for the single web header,
sign-in, and native loading/error states. The app has no second native header or
top corner buttons. Branding displays without an external image request.

## Paste files into a conversation

Copy files in another app, then use Paste in the message field or the composer's
plus menu. Native clipboard intake reads original file representations exposed
by that app and stages attachments for the normal Send action. Ordinary text
and web links remain text. A link copied by another app cannot supply the file's
bytes; use that app's Share action for the actual document instead.

Clipboard intake accepts up to 20 files and 100 MiB in one batch. It uses
temporary files and transfers data into the web composer in bounded chunks.
Changing accounts or conversations cancels an in-progress paste. Clipboard
access occurs only after your Paste action, never by background polling.

## Send from the iOS share sheet

In ChatGPT, Files, Photos, or another app, share the actual file and choose
PrivMsg. If it is not visible initially, open More in the share sheet and enable
PrivMsg. Review the filenames, add an optional message, and tap Send. Keep the
share sheet open until it reports completion. Web links are sent as links.

Sign in to PrivMsg once inside the share sheet. The extension has its own secure
sign-in and does not copy the containing app's web session. It remembers only a
refresh token in its own Keychain, not your password. Uploads go directly to the
existing backend and today's conversation, so you do not need to open PrivMsg
first. A failed transfer can be retried without publishing a duplicate message.

The extension is embedded as PrivMsgShare.appex with the same signing team and
the app's bundle identifier plus .Share. It needs no App Group or shared
Keychain entitlement.

To update an existing download, save and quit Xcode, then run the repository's
`Update-PrivMsg.command` with your existing `ios` folder as its argument. The
updater downloads a pinned complete revision, backs up the old source under
`Local`, preserves your Xcode Team and bundle identifier, and runs the installer.

## Renew the development install

Run the same script again with the same team and bundle identifier. Do not
delete the installed app first. Free Personal Team provisioning normally needs
renewal after seven days. Reinstalling the same bundle preserves its container;
changing the bundle identifier creates a different app.

The script keeps your selection in `Local/Signing.json` and also adopts saved
changes made in Xcode before regenerating the project. It never reads or stores
your Apple password, removes another checkout, or uninstalls the app.

```bash
# Explicit team or device when more than one is available:
bash Install-PrivMsg.command --team YOURTEAMID --device YOUR_DEVICE_UDID

# Generate and open without installing:
bash Install-PrivMsg.command --project-only

# Check compilation without device signing:
bash Install-PrivMsg.command --simulator-build
```

Build logs are in `Local/device-build.log` or `Local/simulator-build.log`. If the
bundle identifier is already registered to another Apple team, choose a unique
identifier in Xcode or use `--bundle-id`, then keep that identifier for renewals.
Keep the extracted package for rerunning the installer.

## Repair the first downloadable package

The initial package incorrectly copied a top-level `Resources` directory into
the iOS app bundle. Apple reserves that name. It can cause CodeSign to report
an unsigned icon PNG, or Simulator installation to report a missing bundle ID.
Current packages use `WebContent` and CI verifies the built bundle and signature.

For an already configured original download, save and quit Xcode, then run the
current `tools/repair_bundle_layout.py` with the old package's `ios` folder as its
argument. It backs up changed project files, renames the folder, updates the
references, and preserves the Team and bundle identifier saved in Xcode. Reopen
the project, use Product > Clean Build Folder (Shift-Command-K), and Run again.
Cleaning is necessary to remove the old directory from the previous build.

Apple reference: [iOS bundle structure](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html).

## Verification

`python3 generate_project.py` regenerates the project. `python3
validate_project.py` checks file references, signing consistency, resources,
icon and scheme structure. These checks do not compile Swift. A successful
Mac build and physical-device testing remain necessary for signing, login,
native paste, downloads, and the hold/tap/switch-app/drop gesture.

The GitHub `iOS build` workflow performs an unsigned Simulator compilation.
For maintainers, `node tools/build_web_bundle.mjs` refreshes the bundled web UI
from the repository's entry page and its pinned vendor source; it is not needed
for installation. `node --test tests/native-bridge.test.mjs` checks the bridge.

Apple references: [command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference),
[device installation](https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line),
[Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/).
