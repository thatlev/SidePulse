# Set up SidePulse

This guide is for people and coding agents setting up the complete local path:
agent hooks → SidePulse Mac app → iPhone display.

## Agent safety rules

- Do not add SidePulse instructions to `AGENTS.md`, `CLAUDE.md`, or project
  prompts. SidePulse is driven by lifecycle hooks and should consume no model
  context.
- Back up existing agent config before changing it. The SidePulse app and
  installer already do this and only remove entries they own.
- Never request an Apple ID password, private signing key, or two-factor code.
  The user enters account details directly in Xcode.
- Do not claim completion until an agent is connected and, when the iPhone is
  requested, the Mac app's **Requests served** counter increases.

## 1. Build and open the Mac app

```bash
git clone https://github.com/thatlev/SidePulse.git
cd SidePulse/macos/SidePulseMac
./build.sh --install --run
```

Look for the LED dots in the menu bar. The Mac app contains the file watcher,
local HTTP server, and Bonjour advertisement; no cloud account is used.

## 2. Install helpers and connect agents

From the repository root:

```bash
./install.sh --yes
```

Open the SidePulse menu, choose the Solo or Multi-agent controller, and press
**Connect all**. The app detects Claude Code, Codex, and Kimi from their local
config folders. Codex may require one `/hooks` review after new hooks are
added.

## 3. Build the iPhone app

Requirements:

- full Xcode with an Apple ID under **Xcode → Settings → Accounts**
- an unlocked, trusted iPhone with Developer Mode enabled
- the Mac and iPhone on the same local network

Open the project:

```bash
open ios/SidePulseSim/SidePulseSim.xcodeproj
```

Select the **SidePulseSim** target, open **Signing & Capabilities**, enable
automatic signing, and choose the user's team. Select the iPhone as the run
destination and press **Run**.

On first launch, allow Local Network access. SidePulse discovers the Mac over
Bonjour; there is no address to type. The onboarding succeeds when the Mac
app's **Requests served** value rises above zero.

## Troubleshooting

- **App is no longer available:** rebuild it to the phone. Free Apple ID builds
  normally expire after seven days.
- **No Mac appears:** keep both devices on the same Wi-Fi, allow Local Network
  access for SidePulse, and make sure the Mac app says **Live**.
- **No agents available:** launch each agent once so its local config folder
  exists, then reopen the SidePulse menu.
- **Connect all is disabled:** run `./install.sh --yes`; the selected controller
  must exist in `~/bin`.
- **Lights never change:** run an actual agent task, check **Writes seen**, then
  check **Requests served**. The first counter isolates hook problems; the
  second isolates phone/network problems.
