# Changelog

## [Unreleased Changes]

### Features
- Refactor session.zig into display and session persistence modules ([#147](https://github.com/christianhelle/puny/pull/147)) ([@christianhelle](https://github.com/christianhelle/))
- Extract chat command handlers into session_commands.zig ([#144](https://github.com/christianhelle/puny/pull/144)) ([@christianhelle](https://github.com/christianhelle/))
- Extract smaller modules from debug_log and openai modules ([#143](https://github.com/christianhelle/puny/pull/143)) ([@christianhelle](https://github.com/christianhelle/))
- Add @ file mentions to attach files to prompts ([#141](https://github.com/christianhelle/puny/pull/141)) ([@christianhelle](https://github.com/christianhelle/))
- Extract atomic file writes into a shared module ([#142](https://github.com/christianhelle/puny/pull/142)) ([@christianhelle](https://github.com/christianhelle/))
- Skip welcome commands when a prompt is supplied ([#139](https://github.com/christianhelle/puny/pull/139)) ([@christianhelle](https://github.com/christianhelle/))
- Refactor markdown.zig into width and table modules ([#140](https://github.com/christianhelle/puny/pull/140)) ([@christianhelle](https://github.com/christianhelle/))
- Fix reasoning token count stuck at 0 in stats ([#135](https://github.com/christianhelle/puny/pull/135)) ([@christianhelle](https://github.com/christianhelle/))
- Fix and improve the README documentation ([#138](https://github.com/christianhelle/puny/pull/138)) ([@christianhelle](https://github.com/christianhelle/))
- Split OpenCode Zen Gemini streaming into its own module ([#134](https://github.com/christianhelle/puny/pull/134)) ([@christianhelle](https://github.com/christianhelle/))
- Extract git repo root discovery into core/git_root.zig ([#133](https://github.com/christianhelle/puny/pull/133)) ([@christianhelle](https://github.com/christianhelle/))
- Extract the session stats tracker into stats.zig ([#132](https://github.com/christianhelle/puny/pull/132)) ([@christianhelle](https://github.com/christianhelle/))
- Extract provider resolution helpers into resolve.zig ([#131](https://github.com/christianhelle/puny/pull/131)) ([@christianhelle](https://github.com/christianhelle/))
- Add debug_log.zig with the http debug logger and its tests ([#130](https://github.com/christianhelle/puny/pull/130)) ([@christianhelle](https://github.com/christianhelle/))
- Refactor and move LineEditor to its own module ([#129](https://github.com/christianhelle/puny/pull/129)) ([@christianhelle](https://github.com/christianhelle/))
- Multi-line prompt support with line editor ([#128](https://github.com/christianhelle/puny/pull/128)) ([@christianhelle](https://github.com/christianhelle/))
- Show token stats footer after each response ([#127](https://github.com/christianhelle/puny/pull/127)) ([@christianhelle](https://github.com/christianhelle/))
- Fix slow startup caused by spawning git twice at launch ([#126](https://github.com/christianhelle/puny/pull/126)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.3.3](https://github.com/christianhelle/puny/releases/tag/v0.3.3) (2026-08-11)

### Features
- Fix release workflow changelog job failing on push ([#124](https://github.com/christianhelle/puny/pull/124)) ([@christianhelle](https://github.com/christianhelle/))
- Fix exit screen rendering on fresh Windows consoles ([#125](https://github.com/christianhelle/puny/pull/125)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.3.2](https://github.com/christianhelle/puny/releases/tag/v0.3.2) (2026-08-11)

### Features
- Enable ANSI escape processing on legacy Windows consoles ([#123](https://github.com/christianhelle/puny/pull/123)) ([@christianhelle](https://github.com/christianhelle/))
- Isolate mock sessions from session history in test-regression ([#122](https://github.com/christianhelle/puny/pull/122)) ([@christianhelle](https://github.com/christianhelle/))
- Remove the --check-update CLI flag ([#121](https://github.com/christianhelle/puny/pull/121)) ([@christianhelle](https://github.com/christianhelle/))
- Add install-release-safe, install-release-fast, and install-debug build steps ([#120](https://github.com/christianhelle/puny/pull/120)) ([@christianhelle](https://github.com/christianhelle/))
- Add non-blocking update check with exit notice ([#119](https://github.com/christianhelle/puny/pull/119)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.3.1](https://github.com/christianhelle/puny/releases/tag/v0.3.1) (2026-08-10)

### Features
- Split slow tests into regression suite for fast zig build test ([#118](https://github.com/christianhelle/puny/pull/118)) ([@christianhelle](https://github.com/christianhelle/))
- Add /thinking command to change reasoning effort mid-session ([#117](https://github.com/christianhelle/puny/pull/117)) ([@christianhelle](https://github.com/christianhelle/))
- Add --no-skills flag to disable skills entirely ([#116](https://github.com/christianhelle/puny/pull/116)) ([@christianhelle](https://github.com/christianhelle/))
- Change prompt text to `>` ([#115](https://github.com/christianhelle/puny/pull/115)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.3.0](https://github.com/christianhelle/puny/releases/tag/v0.3.0) (2026-08-10)

### Features
- Protect API keys at rest with XChaCha20-Poly1305 encryption ([#113](https://github.com/christianhelle/puny/pull/113)) ([@christianhelle](https://github.com/christianhelle/))
- Improve test coverage across the codebase ([#112](https://github.com/christianhelle/puny/pull/112)) ([@christianhelle](https://github.com/christianhelle/))
- Case insensitive commands ([#111](https://github.com/christianhelle/puny/pull/111)) ([@christianhelle](https://github.com/christianhelle/))
- Vim style commands ([#110](https://github.com/christianhelle/puny/pull/110)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce help command ([#109](https://github.com/christianhelle/puny/pull/109)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.7](https://github.com/christianhelle/puny/releases/tag/v0.2.7) (2026-08-08)

### Features
- Harden sessions index handling and fix review findings ([#107](https://github.com/christianhelle/puny/pull/107)) ([@christianhelle](https://github.com/christianhelle/))
- Include diagrams in PRD files using mermaid charts ([#108](https://github.com/christianhelle/puny/pull/108)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce sessions.json index for fast session listing ([#106](https://github.com/christianhelle/puny/pull/106)) ([@christianhelle](https://github.com/christianhelle/))
- Add /new command to create new session ([#105](https://github.com/christianhelle/puny/pull/105)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.6](https://github.com/christianhelle/puny/releases/tag/v0.2.6) (2026-08-07)

### Features
- Bound session metadata memory in listSessions ([#104](https://github.com/christianhelle/puny/pull/104)) ([@christianhelle](https://github.com/christianhelle/))
- fix `/sessions` crash on oversized session meta files ([#103](https://github.com/christianhelle/puny/pull/103)) ([@christianhelle](https://github.com/christianhelle/))
- Send skill content to the model on bare skill load ([#102](https://github.com/christianhelle/puny/pull/102)) ([@christianhelle](https://github.com/christianhelle/))
- Remove auto-commit instructions from system prompt ([#101](https://github.com/christianhelle/puny/pull/101)) ([@christianhelle](https://github.com/christianhelle/))
- Add timeouts to tool execution so a hung command or fetch cannot stall the agent ([#100](https://github.com/christianhelle/puny/pull/100)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.5](https://github.com/christianhelle/puny/releases/tag/v0.2.5) (2026-08-06)

### Features
- Store /file command in prompt history for prompt-file prompts ([#99](https://github.com/christianhelle/puny/pull/99)) ([@christianhelle](https://github.com/christianhelle/))
- Add --prompt-file flag and /file command to load prompts from files and URLs ([#98](https://github.com/christianhelle/puny/pull/98)) ([@christianhelle](https://github.com/christianhelle/))
- Update system and planning prompts for concise output ([#97](https://github.com/christianhelle/puny/pull/97)) ([@christianhelle](https://github.com/christianhelle/))
- Fix welcome screen available commands ([#96](https://github.com/christianhelle/puny/pull/96)) ([@christianhelle](https://github.com/christianhelle/))
- Remove Dockerfile and generate on demand instead ([#95](https://github.com/christianhelle/puny/pull/95)) ([@christianhelle](https://github.com/christianhelle/))
- Add zig build install-release step ([#94](https://github.com/christianhelle/puny/pull/94)) ([@christianhelle](https://github.com/christianhelle/))
- Fix session statistics accuracy and request provider usage ([#93](https://github.com/christianhelle/puny/pull/93)) ([@christianhelle](https://github.com/christianhelle/))
- Format JSON in debug log output ([#92](https://github.com/christianhelle/puny/pull/92)) ([@christianhelle](https://github.com/christianhelle/))
- Upgrade regression tests uses temp dir instead of repo root ([#91](https://github.com/christianhelle/puny/pull/91)) ([@christianhelle](https://github.com/christianhelle/))
- Resume the most recent session without creating a new session id ([#90](https://github.com/christianhelle/puny/pull/90)) ([@christianhelle](https://github.com/christianhelle/))
- Remove empty sessions on exit so empty session folders don't accumulate ([#87](https://github.com/christianhelle/puny/pull/87)) ([@christianhelle](https://github.com/christianhelle/))
- Add real-time markdown rendering ([#85](https://github.com/christianhelle/puny/pull/85)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.4](https://github.com/christianhelle/puny/releases/tag/v0.2.4) (2026-07-31)

### Features
- Fix incorrect startup time measurement ([#84](https://github.com/christianhelle/puny/pull/84)) ([@christianhelle](https://github.com/christianhelle/))
- Show session load time in restored session header ([#83](https://github.com/christianhelle/puny/pull/83)) ([@christianhelle](https://github.com/christianhelle/))
- Extract upgrade logic into a dedicated upgrade module ([#82](https://github.com/christianhelle/puny/pull/82)) ([@christianhelle](https://github.com/christianhelle/))
- Generate HTML plan with system theme awareness (dark and light mode) ([#81](https://github.com/christianhelle/puny/pull/81)) ([@christianhelle](https://github.com/christianhelle/))
- Improve MacOS/Linux upgrade experience ([#80](https://github.com/christianhelle/puny/pull/80)) ([@christianhelle](https://github.com/christianhelle/))
- Fix release binary version and install.sh cleanup trap ([#79](https://github.com/christianhelle/puny/pull/79)) ([@christianhelle](https://github.com/christianhelle/))
- Add retry logic and validation to Windows self-upgrade pipeline ([#78](https://github.com/christianhelle/puny/pull/78)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.3](https://github.com/christianhelle/puny/releases/tag/v0.2.3) (2026-07-31)

### Features
- Reduce excessive whitespace and staircase effect in terminal output ([#76](https://github.com/christianhelle/puny/pull/76)) ([@christianhelle](https://github.com/christianhelle/))
- Use OpenAI Compatible endpoints for all LM Studio models ([#77](https://github.com/christianhelle/puny/pull/77)) ([@christianhelle](https://github.com/christianhelle/))
- Add circular navigation to list picker ([#75](https://github.com/christianhelle/puny/pull/75)) ([@christianhelle](https://github.com/christianhelle/))
- Fix list picker layout and arrow key navigation on Unix ([#74](https://github.com/christianhelle/puny/pull/74)) ([@christianhelle](https://github.com/christianhelle/))
- Change reasoning efforts to default, none, minimal, low, medium, high, and xhigh ([#73](https://github.com/christianhelle/puny/pull/73)) ([@christianhelle](https://github.com/christianhelle/))
- Add reasoning effort selection to /model command ([#72](https://github.com/christianhelle/puny/pull/72)) ([@christianhelle](https://github.com/christianhelle/))
- Add coding agent instruction file support ([#71](https://github.com/christianhelle/puny/pull/71)) ([@christianhelle](https://github.com/christianhelle/))
- Native self-upgrade for --upgrade (fixes Windows Defender false positive) ([#70](https://github.com/christianhelle/puny/pull/70)) ([@christianhelle](https://github.com/christianhelle/))

### Closed Issues
- Thread blocked - running `puny --upgrade` blocked by Windows ([#69](https://github.com/christianhelle/puny/issues/69)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.2](https://github.com/christianhelle/puny/releases/tag/v0.2.2) (2026-07-29)

### Features
- Auto-trigger reconfigure on first launch when config file missing ([#68](https://github.com/christianhelle/puny/pull/68)) ([@christianhelle](https://github.com/christianhelle/))
- Show startup time metrics on Welcome Screen ([#67](https://github.com/christianhelle/puny/pull/67)) ([@christianhelle](https://github.com/christianhelle/))
- Add --chat-log CLI flag for conversation logging ([#65](https://github.com/christianhelle/puny/pull/65)) ([@christianhelle](https://github.com/christianhelle/))
- Allow models to load skills via tool call ([#64](https://github.com/christianhelle/puny/pull/64)) ([@christianhelle](https://github.com/christianhelle/))
- Add markdown table rendering integration and regression tests ([#62](https://github.com/christianhelle/puny/pull/62)) ([@christianhelle](https://github.com/christianhelle/))
- Fix app crashes when using --provider CLI argument ([#63](https://github.com/christianhelle/puny/pull/63)) ([@christianhelle](https://github.com/christianhelle/))
- Improve markdown table renderer ([#61](https://github.com/christianhelle/puny/pull/61)) ([@christianhelle](https://github.com/christianhelle/))
- Add integration tests for OpenCode Zen and LM Studio ([#60](https://github.com/christianhelle/puny/pull/60)) ([@christianhelle](https://github.com/christianhelle/))
- Disable mock provider from interactive picker ([#59](https://github.com/christianhelle/puny/pull/59)) ([@christianhelle](https://github.com/christianhelle/))
- Show navigation instructions in list picker ([#58](https://github.com/christianhelle/puny/pull/58)) ([@christianhelle](https://github.com/christianhelle/))
- Custom model and provider list pickers ([#57](https://github.com/christianhelle/puny/pull/57)) ([@christianhelle](https://github.com/christianhelle/))
- Add integration tests against OpenCode Go ([#56](https://github.com/christianhelle/puny/pull/56)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.1](https://github.com/christianhelle/puny/releases/tag/v0.2.1) (2026-07-26)

### Features
- Add --prune CLI flag for session pruning ([#55](https://github.com/christianhelle/puny/pull/55)) ([@christianhelle](https://github.com/christianhelle/))
- Add support for restoring Sessions ([#54](https://github.com/christianhelle/puny/pull/54)) ([@christianhelle](https://github.com/christianhelle/))
- Make --upgrade fire-and-forget to avoid upgrade failure when binary is in use ([#50](https://github.com/christianhelle/puny/pull/50)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce Sessions and update Planning Mode to create a PRD in HTML and Markdown formats ([#53](https://github.com/christianhelle/puny/pull/53)) ([@christianhelle](https://github.com/christianhelle/))
- Extract ClientConfig for provider dispatch ([#52](https://github.com/christianhelle/puny/pull/52)) ([@christianhelle](https://github.com/christianhelle/))
- Extract chat loop from main.zig into ChatSession module ([#51](https://github.com/christianhelle/puny/pull/51)) ([@christianhelle](https://github.com/christianhelle/))
- Add support for Windows ARM64 ([#49](https://github.com/christianhelle/puny/pull/49)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.2.0](https://github.com/christianhelle/puny/releases/tag/v0.2.0) (2026-07-24)

### Features
- Allow /skills in one-shot mode ([#48](https://github.com/christianhelle/puny/pull/48)) ([@christianhelle](https://github.com/christianhelle/))
- Setup Snapcraft distribution ([#47](https://github.com/christianhelle/puny/pull/47)) ([@christianhelle](https://github.com/christianhelle/))
- Add install scripts, docs site, GitHub Pages, and --upgrade flag ([#46](https://github.com/christianhelle/puny/pull/46)) ([@christianhelle](https://github.com/christianhelle/))
- Add support for skills ([#45](https://github.com/christianhelle/puny/pull/45)) ([@christianhelle](https://github.com/christianhelle/))
- Fix reasoning line tracking, Anthropic thinking field, and Google thinkingConfig ([#44](https://github.com/christianhelle/puny/pull/44)) ([@christianhelle](https://github.com/christianhelle/))
- Suppress reasoning/thinking output by default and add --show-thinking to allow it ([#43](https://github.com/christianhelle/puny/pull/43)) ([@christianhelle](https://github.com/christianhelle/))
- Refactor Config: per-provider apiKey, model, and URL ([#42](https://github.com/christianhelle/puny/pull/42)) ([@christianhelle](https://github.com/christianhelle/))
- Migrate from deprecated API's ([#41](https://github.com/christianhelle/puny/pull/41)) ([@christianhelle](https://github.com/christianhelle/))
- Generate Tool Schemas at Comptime ([#40](https://github.com/christianhelle/puny/pull/40)) ([@christianhelle](https://github.com/christianhelle/))
- Memory and Resource usage Optimization ([#39](https://github.com/christianhelle/puny/pull/39)) ([@christianhelle](https://github.com/christianhelle/))
- Show app memory usage in /stats ([#38](https://github.com/christianhelle/puny/pull/38)) ([@christianhelle](https://github.com/christianhelle/))
- Changelog generator workflow ([#28](https://github.com/christianhelle/puny/pull/28)) ([@christianhelle](https://github.com/christianhelle/))
- Improve --mock mode ([#34](https://github.com/christianhelle/puny/pull/34)) ([@christianhelle](https://github.com/christianhelle/))
- Add OpenCode Go as a provider ([#37](https://github.com/christianhelle/puny/pull/37)) ([@christianhelle](https://github.com/christianhelle/))
- Clear app state and free memory usage upon /reset ([#36](https://github.com/christianhelle/puny/pull/36)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce /provider command for switching provider 
 ([#35](https://github.com/christianhelle/puny/pull/35)) ([@christianhelle](https://github.com/christianhelle/))
- Provider Picker widget ([#33](https://github.com/christianhelle/puny/pull/33)) ([@christianhelle](https://github.com/christianhelle/))
- HTTP Debug Logging to File ([#32](https://github.com/christianhelle/puny/pull/32)) ([@christianhelle](https://github.com/christianhelle/))
- Add --debug HTTP request/response logging for all providers ([#31](https://github.com/christianhelle/puny/pull/31)) ([@christianhelle](https://github.com/christianhelle/))
- Decouple providers from generated lmstudio.zig ([#30](https://github.com/christianhelle/puny/pull/30)) ([@christianhelle](https://github.com/christianhelle/))
- Filter Copilot models to the CLI's picker-enabled chat-completions set ([#29](https://github.com/christianhelle/puny/pull/29)) ([@christianhelle](https://github.com/christianhelle/))
- Add GitHub Copilot model provider ([#27](https://github.com/christianhelle/puny/pull/27)) ([@christianhelle](https://github.com/christianhelle/))
- Fix Gemini tool-calling across turns ([#26](https://github.com/christianhelle/puny/pull/26)) ([@christianhelle](https://github.com/christianhelle/))
- Add Google (Gemini) support to the OpenCode Zen provider ([#25](https://github.com/christianhelle/puny/pull/25)) ([@christianhelle](https://github.com/christianhelle/))
- Show a sensible welcome hint when --prompt prefills the first message ([#24](https://github.com/christianhelle/puny/pull/24)) ([@christianhelle](https://github.com/christianhelle/))
- Replace regression script with zig build test-regression ([#23](https://github.com/christianhelle/puny/pull/23)) ([@christianhelle](https://github.com/christianhelle/))
- Include git commit sha in version information ([#22](https://github.com/christianhelle/puny/pull/22)) ([@christianhelle](https://github.com/christianhelle/))
- Docker support ([#21](https://github.com/christianhelle/puny/pull/21)) ([@christianhelle](https://github.com/christianhelle/))


## [v0.1.0](https://github.com/christianhelle/puny/releases/tag/v0.1.0) (2026-07-17)

### Features
- Show token statistics using /stats and upon exit ([#3](https://github.com/christianhelle/puny/pull/3)) ([@christianhelle](https://github.com/christianhelle/))
- Build for all platforms in regression test script ([#6](https://github.com/christianhelle/puny/pull/6)) ([@christianhelle](https://github.com/christianhelle/))
- Enable Claude, GPT, and Qwen models from OpenCode Zen ([#20](https://github.com/christianhelle/puny/pull/20)) ([@christianhelle](https://github.com/christianhelle/))
- Add GitHub Workflows ([#19](https://github.com/christianhelle/puny/pull/19)) ([@christianhelle](https://github.com/christianhelle/))
- Add OpenCode Zen as a model provider ([#18](https://github.com/christianhelle/puny/pull/18)) ([@christianhelle](https://github.com/christianhelle/))
- LM Studio Authorization support ([#17](https://github.com/christianhelle/puny/pull/17)) ([@christianhelle](https://github.com/christianhelle/))
- Restructure code into multiple folders by logical groups ([#16](https://github.com/christianhelle/puny/pull/16)) ([@christianhelle](https://github.com/christianhelle/))
- Silent auto-retry on request failure ([#15](https://github.com/christianhelle/puny/pull/15)) ([@christianhelle](https://github.com/christianhelle/))
- Prompt History ([#14](https://github.com/christianhelle/puny/pull/14)) ([@christianhelle](https://github.com/christianhelle/))
- Improve startup experience ([#13](https://github.com/christianhelle/puny/pull/13)) ([@christianhelle](https://github.com/christianhelle/))
- Multi-model Token Stats ([#12](https://github.com/christianhelle/puny/pull/12)) ([@christianhelle](https://github.com/christianhelle/))
- Improve tool call output ([#11](https://github.com/christianhelle/puny/pull/11)) ([@christianhelle](https://github.com/christianhelle/))
- Show reasoning duration for each prompt ([#10](https://github.com/christianhelle/puny/pull/10)) ([@christianhelle](https://github.com/christianhelle/))
- Increment stats in real time to support token stats for cancelled prompts ([#9](https://github.com/christianhelle/puny/pull/9)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce persisted configuration state ([#8](https://github.com/christianhelle/puny/pull/8)) ([@christianhelle](https://github.com/christianhelle/))
- Improve prompt cancellation ([#7](https://github.com/christianhelle/puny/pull/7)) ([@christianhelle](https://github.com/christianhelle/))
- Fix Linux build ([#5](https://github.com/christianhelle/puny/pull/5)) ([@christianhelle](https://github.com/christianhelle/))
- Add support to Cancel a prompt ([#4](https://github.com/christianhelle/puny/pull/4)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce /model command to change model mid session ([#2](https://github.com/christianhelle/puny/pull/2)) ([@christianhelle](https://github.com/christianhelle/))
- Introduce --mock flag for testing ([#1](https://github.com/christianhelle/puny/pull/1)) ([@christianhelle](https://github.com/christianhelle/))


---
***This changelog was generated with [chlogr](https://github.com/christianhelle/chlogr). Any changes to this file will be overwritten.***