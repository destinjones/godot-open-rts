# Decisions

Notable choices and the reason for each, newest last, so the next session knows why.

## 2026-10-11: onboarding cleared despite the feature freeze
Destin asked for the onboarding and first-run thread (guided first match, first-time
hints, tooltips, first-run defaults, searchable manual) explicitly, so it goes ahead while
features are otherwise frozen. It stays out of models, shaders, VFX, audio and the control
layer.

## 2026-10-11: tutorials are data, run through the play harness
The tutorial steps moved from a constant in Guide.gd to data/tutorial/*.json: standard.json
keeps the old ten steps for every Guided match, first_match.json is the guided first match
on the main menu. A step waits for one of a fixed list of conditions (Guide.CONDITIONS) and
may run play-harness orders when it starts (give, spawn, declare_war, camera), so new
tutorials need no code. The same script is played end to end by
tools/harness/scenarios/tutorial-first-match.json. Why: Destin asked for data, not
hard-coded cutscenes, and reusing the harness keeps one order format. Known gap: a save
made mid-tutorial resumes with the standard steps, because carrying the script name would
change the save format, which needs asking first.

## 2026-10-11: first-time hints are remembered in the options
A hint (HINT_*) now shows once ever, not once per match. The keys it has shown are kept
in Options (`seen_hints`, saved in options.tres), with a "Show first-time tips" switch and
a "Show all tips again" button on Options > Interface. Only a real game, one started from
source/Main.gd, writes them (FeatureFlags.remember_first_run), so tests and the play
harness never use up a player's hints. Alerts (unit cap, city full, raids) are not hints
and still repeat. Why: hints that come back every match read as nagging.

## 2026-10-11: build-menu tooltips are cards made from the building-card data
Build and production buttons open a rich hover card (RichTooltipButton + Tooltips.gd)
built from BuildingInfoText, the same source as the selection card: role, what it does,
needs, makes, health, the cost with what the player is short of, and why it is locked.
The plain tooltip_text (BuildMenu.describe) stays as the fallback. The controls thread
owns hud/ layout; this only swaps the button class and fills the tooltip. Why: one source
of truth for what a building does, and a locked or unaffordable button says why.

## 2026-10-11: first-run defaults and the intro card
On the very first launch the main menu shows a "What is Ironbound?" card (IntroCard.gd):
four lines on the game loop, then Play the tutorial or Go to the menu. Either answer sets
Options.intro_seen, so it shows once. The Play menu starts a new player on Plain & Simple
(small, open, 50x50) against an Easy AI, then remembers the last map and AI difficulty
(Options.last_map, last_ai_difficulty). Like the hints, only a real game writes these
(FeatureFlags.remember_first_run, renamed from remember_seen_hints). Why: the old default
was whichever two-player map sorted first, often a large or asymmetric one, against a
Normal AI; AoE4 and Northgard both point a new player at a guided match first.

## 2026-10-11: the manual is searchable and hints link into it
The F1 manual has a search box (Ctrl+F): it keeps the topics whose title or text holds
every word typed, title matches first, and marks the words. Each hint names its manual
topic (Guide.HINT_TOPICS) and shows a "Read more" button that opens it; alerts have none.
The "(F1: ...)" pointers in two hint texts went, the button replaces them. Known gap:
the camera polls W A S D, so typing in the search box also pans the map; the fix belongs
to the camera (control layer), passed to the controls thread.
