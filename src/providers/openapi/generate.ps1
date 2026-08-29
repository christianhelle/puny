openapi2zig generate -o ../runtime.zig --runtime-only
openapi2zig generate -i openai.json -o ../openai/ --multiple-files --file-name models=contracts.zig --runtime-module ../runtime.zig
openapi2zig generate -i lmstudio.json -o ../lmstudio --multiple-files --file-name models=contracts.zig --runtime-module ../runtime.zig
openapi2zig generate -i anthropic.json -o ../anthropic/ --multiple-files --file-name models=contracts.zig --runtime-module ../runtime.zig
