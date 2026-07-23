# Changelog

## [Unreleased Changes]

### Features
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


