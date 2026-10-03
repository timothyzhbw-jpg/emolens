# EmoLens at LovHack Season 3

Submission notes for [LovHack Season 3](https://lovhack-season-3.devpost.com/) (Sept 26 – Oct 4, 2026, AI track). The sections below map to the Devpost form fields and can be pasted in directly.

## Disclosure: what existed before, and what was built during the hackathon

LovHack asks entrants to say clearly what was created during the event and to disclose pre-existing work. So, plainly:

**Before LovHack (Sept 22–23, 2026, up to release 0.5.1, commit `cfe1e1a`)**, EmoLens already existed as a **Chinese-only** macOS app. It had the screen-capture and OCR pipeline, the pixel-based bubble detector, emoji/sticker/voice handling, the Chinese emotion prompt and decision-model question set, contact memory, the Chinese keyword safety nets, cloud model support and the DMG packaging.

**Built during LovHack Season 3 (all commits after `cfe1e1a`)**:

1. **An English version of the whole product.** The panel, settings, memory sheet, menus, errors and the demo chat are bilingual, with an in-app English / 中文 switch that follows the system language by default and a `--language` flag for every CLI tool.
2. **English analysis.** A new English system prompt with 12 hand-written English few-shot examples (sarcasm, playful sulking, holding back, hyperbole, manipulation, crisis, impersonation scam, …), an English output schema, and an English decision-model question set. English labels map back onto the existing internal labels, so memory, colors and history work identically in both languages.
3. **English safety nets.** Crisis-language patterns tuned to catch passive warning signs ("I'm just a burden", "everyone would be better off if I wasn't around") while **ignoring everyday hyperbole** ("I'm dead 💀", "kill me now"). Scam patterns cover loans, one-time codes and gift cards. The crisis card shows US resources (988, Crisis Text Line) and findahelpline.com.
4. **English chat formats.** Paste mode now understands English export formats (timestamped `[date, time] Name: text`, `Name — Today at 9:41 PM`, Delivered/Read lines), and OCR prefers English when the app is in English.
5. **An English evaluation set and scorer.** 45 labeled chats in [`eval/en.jsonl`](../eval/en.jsonl), with hard negatives (hyperbole that must *not* be flagged, ordinary hurt that is *not* manipulation), and [`scripts/score_eval.py`](../scripts/score_eval.py).
6. **Adaption Labs integration.** [`scripts/adaption_localize_eval.py`](../scripts/adaption_localize_eval.py) uses the Adaption Adaptive Data API (`datasets.create` → `localize` → `download`) to rewrite the eval set into British, Australian, Indian and Canadian English while keeping the labels, so we can measure whether EmoLens still catches sarcasm and warning signs across Englishes. An `estimate` mode quotes the credit cost before anything is spent.
7. **CI that renders the UI.** GitHub Actions now builds, runs the 126 unit tests (16 new for the English pipeline) and renders every panel state in both languages on macOS. The English screenshots in the README come from there.

## Devpost form

**Project name:** EmoLens

**Tagline:** Read the subtext in "no it's fine, whatever": a private, on-device emotion lens for your chats.

### Inspiration

Most fights over text aren't about what was said. "k", "no it's fine", "ok 🙂" can mean three different things depending on who sent them and why. People, especially people texting a partner or a parent, regularly misread those messages, and some messages matter far more: a friend hinting they don't want to be around anymore, or a "friend" whose account was hacked asking for gift cards. We wanted a second pair of eyes that reads the subtext *as it arrives*, never uploads your chats by default, and is careful about the messages that matter most.

### What it does

EmoLens is a floating macOS panel that watches your messaging app's window, the way a screen share does. When the other person sends something, it tells you:

- the emotion and its intensity, and whether they **mean it**, are being **sarcastic**, are **playfully sulking**, or are **holding back**;
- relationship signals: upset with you, brushing you off, testing you, pulling away, a fight or breakup signal, **emotional manipulation**, **self-harm risk**, **money or account-code requests**;
- how to respond, and one line you could send;
- per-contact memory ("interview next Wednesday"), saved only when you confirm.

It reads emoji, stickers and voice-message transcripts, not just text. There's also a paste mode for chats copied from anywhere. Everything runs on your Mac by default; cloud models are opt-in and the panel always says when messages leave your machine.

### How we built it

- **Swift + SwiftUI** floating panel; **ScreenCaptureKit** captures just the chat window; **Apple Vision** OCR reads the text locally.
- A pixel-level layout detector finds bubbles, avatars, emoji and stickers, so left vs. right tells "them" from "me". Emoji are painted out before OCR, then cropped and named by a vision model.
- The default analysis model is **Qwen 3.5 4B on Ollama**, running locally with a structured JSON answer and few-shot examples. Users can opt into **Anthropic Claude** (structured outputs) or any **OpenAI-compatible** API, and optionally a calibrated **System One decision model** (local Kev or TypeSafe's Jev) that double-checks the serious signals.
- **Keyword safety nets** run on every engine and are deliberately conservative about everyday hyperbole.
- For the hackathon we built the **English version**: a bilingual UI layer, an English prompt and examples, label mapping, English safety nets and paste formats, an English eval set, and an **Adaption Labs** pipeline that localizes the eval set into other Englishes.
- **GitHub Actions** on macOS builds, tests and renders UI previews on every push.

### Challenges we ran into

- **Hyperbole vs. danger.** "I'm dead 💀" and "I just want it all to stop" look similar to a keyword list. We wrote hard-negative test cases first and only added patterns that pass them.
- **Two languages, one brain.** Memory, colors and history were built on Chinese labels. Instead of rewriting everything, the English model answers with English labels that map onto the same internal labels, and a unit test checks that the few-shot examples use exactly the same format as the live prompt.
- **Developing a macOS app from a Linux cloud session.** We couldn't compile locally, so every change was validated by macOS CI, including rendering the screenshots.

### Accomplishments that we're proud of

- The full English version passed the macOS build and all 126 unit tests on its first CI run.
- On the new English eval set, the keyword nets alone catch 5/6 crisis messages and 3/3 scams with **zero** false positives on hyperbole and normal chat (the nets were written alongside the set, so this is a sanity check rather than a benchmark).
- It's private by default: no chat ever leaves the Mac unless you choose a cloud model.

### What we learned

Subtext is cultural. The same "fine." reads differently in a family chat and a work chat, and in Sydney and in Ohio. Small local models can do a surprising amount if the prompt teaches the conventions (🙂 after being stood up is not happy), but the high-stakes signals need a second line of defense that doesn't depend on the model.

### What's next

- Run the Adaption-localized eval across GB/AU/IN/CA English and tune the prompt where it slips.
- Ship the English DMG (0.6.0) with notarization.
- More languages through the same label mapping, starting with Spanish.

### Built with

Swift, SwiftUI, ScreenCaptureKit, Apple Vision, Ollama, Qwen 3.5, Anthropic Claude API, OpenAI-compatible APIs, Kev / TypeSafe Jev (System One), Adaption Labs Adaptive Data API, Python, GitHub Actions

### Links

- Code: https://github.com/timothyzhbw-jpg/emolens
- Demo video: *(add your link)*

## Demo video script (about 2 minutes)

1. **Hook (10 s).** A chat on screen with Mia: "no it's fine, work is obviously more important. who am i anyway". Voice-over: "Is this fine? It's not."
2. **Setup (15 s).** `swift run EmoLensDemo --language en` and open EmoLens. Point at "Analyzed on this Mac only, nothing uploaded".
3. **Live reads (45 s).** Let the demo script play. Show **Hurt · Sarcastic** with the suggested apology; "ok 🙂" read as *not* happy; the voice message prompt, then the transcription being analyzed; the "hmph" sticker read as playful; "my birthday is next wednesday" → "Remember this?" → Remember.
4. **The serious part (30 s).** The passcode message → **Emotional manipulation** + "Hold your boundary". Switch to Paste mode and paste "sometimes i feel like nobody would even notice if i disappeared" → crisis card with 988 / Crisis Text Line. Then paste "LMAO I'm dead 💀" → no crisis flag.
5. **Under the hood (15 s).** Settings: language switch, local vs. cloud model. Mention the eval set and the Adaption localization across Englishes.
6. **Close (5 s).** "EmoLens: read the subtext, privately."

## Submission checklist

- [ ] Every team member meets the eligibility rules (LovHack Season 3 is for students aged 13–24; teams of 1–4).
- [ ] Devpost form filled from the sections above, **including the disclosure section**.
- [ ] Demo video recorded (script above) and linked.
- [ ] Repository link added; this branch merged to `main` so judges see the English README.
- [ ] Optional: a 0.6.0 DMG built on a Mac (`./scripts/make_dmg.sh`, with `VERSION` bumped in `scripts/build_app.sh`) and published under Releases, so judges can try it without building.
- [ ] Optional: with your Adaption credits, run `python3 scripts/adaption_localize_eval.py estimate`, then `run`, and add the localized results to the README.
- [ ] Submitted before the Oct 4 deadline (check the timezone on the Devpost page).
