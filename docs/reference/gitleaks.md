---
description: gitleaks rules, removed global exceptions, regeneration, and consumer migration.
status: stable
tags: [lint, security]
title: gitleaks policy
type: Reference
generated:
  - role: generated
    harness: codex:0.164.0
    model: openai:gpt-6.1-sol
    effort: high
    surface: exec
    session: sha-256-64:209e905fa0e35399
    at: "2026-11-11T19:10:43Z"
---

# gitleaks policy

Every committed `.gitleaks.toml` extends the adjacent `.gitleaks-rules.toml`. The generated base retains all 222 default rules from gitleaks 8.30.1, including their individual allowlists, without the upstream global allowlist. Each independently released module needs its own generated copy so its config works outside Bazel and after release archives strip the module prefix. The local cache allowlist remains unchanged. A rule-specific exception permits only the exact public Bedrock detection prefix declaration in the generated base and upstream snapshot. It can't suppress a credential path or a token on another line.

## Upstream global allowlist

Entries below come from [`config/gitleaks.toml` at v8.30.1, lines 22-69](https://github.com/gitleaks/gitleaks/blob/v8.30.1/config/gitleaks.toml#L22-L69). The line numbers also match the byte-for-byte snapshot in `lint/gitleaks/upstream.toml`.

<!-- cspell:disable -->
```text
22: [allowlist]
23: description = "global allow lists"
24: paths = [
25:     '''gitleaks\.toml''',
26:     '''(?i)\.(?:bmp|gif|jpe?g|png|svg|tiff?)$''',
27:     '''(?i)\.(?:eot|[ot]tf|woff2?)$''',
28:     '''(?i)\.(?:docx?|xlsx?|pdf|bin|socket|vsidx|v2|suo|wsuo|.dll|pdb|exe|gltf)$''',
29:     '''go\.(?:mod|sum|work(?:\.sum)?)$''',
30:     '''(?:^|/)vendor/modules\.txt$''',
31:     '''(?:^|/)vendor/(?:github\.com|golang\.org/x|google\.golang\.org|gopkg\.in|istio\.io|k8s\.io|sigs\.k8s\.io)(?:/.*)?$''',
32:     '''(?:^|/)gradlew(?:\.bat)?$''',
33:     '''(?:^|/)gradle\.lockfile$''',
34:     '''(?:^|/)mvnw(?:\.cmd)?$''',
35:     '''(?:^|/)\.mvn/wrapper/MavenWrapperDownloader\.java$''',
36:     '''(?:^|/)node_modules(?:/.*)?$''',
37:     '''(?:^|/)(?:deno\.lock|npm-shrinkwrap\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock)$''',
38:     '''(?:^|/)bower_components(?:/.*)?$''',
39:     '''(?:^|/)(?:angular|bootstrap|jquery(?:-?ui)?|plotly|swagger-?ui)[a-zA-Z0-9.-]*(?:\.min)?\.js(?:\.map)?$''',
40:     '''(?:^|/)javascript\.json$''',
41:     '''(?:^|/)(?:Pipfile|poetry)\.lock$''',
42:     '''(?i)(?:^|/)(?:v?env|virtualenv)/lib(?:64)?(?:/.*)?$''',
43:     '''(?i)(?:^|/)(?:lib(?:64)?/python[23](?:\.\d{1,2})+|python/[23](?:\.\d{1,2})+/lib(?:64)?)(?:/.*)?$''',
44:     '''(?i)(?:^|/)[a-z0-9_.]+-[0-9.]+\.dist-info(?:/.+)?$''',
45:     '''(?:^|/)vendor/(?:bundle|ruby)(?:/.*?)?$''',
46:     '''\.gem$''',
47:     '''verification-metadata\.xml''',
48:     '''Database.refactorlog''',
49:     '''(?:^|/)\.git$''',
50: ]
51: regexes = [
52:     '''(?i)^true|false|null$''',
53:     '''^(?i:a+|b+|c+|d+|e+|f+|g+|h+|i+|j+|k+|l+|m+|n+|o+|p+|q+|r+|s+|t+|u+|v+|w+|x+|y+|z+|\*+|\.+)$''',
54:     '''^\$(?:\d+|{\d+})$''',
55:     '''^\$(?:[A-Z_]+|[a-z_]+)$''',
56:     '''^\${(?:[A-Z_]+|[a-z_]+)}$''',
57:     '''^\{\{[ \t]*[\w ().|]+[ \t]*}}$''',
58:     '''^\$\{\{[ \t]*(?:(?:env|github|secrets|vars)(?:\.[A-Za-z]\w+)+[\w "'&./=|]*)[ \t]*}}$''',
59:     '''^%(?:[A-Z_]+|[a-z_]+)%$''',
60:     '''^%[+\-# 0]?[bcdeEfFgGoOpqstTUvxX]$''',
61:     '''^\{\d{0,2}}$''',
62:     '''^@(?:[A-Z_]+|[a-z_]+)@$''',
63:     '''^/Users/(?i)[a-z0-9]+/[\w .-/]+$''',
64:     '''^/(?:bin|etc|home|opt|tmp|usr|var)/[\w ./-]+$''',
65: ]
66: stopwords = [
67:     "014df517-39d1-4453-b7b3-9930c563627c",
68:     "abcdefghijklmnopqrstuvwxyz",
69: ]
```
<!-- cspell:enable -->

Paths suppress entire scanned files before rules run. They don't inspect paths mentioned in content. The regexes inspect the extracted secret by default, and stop words match case-insensitive substrings of the secret. Conditions default to OR. The first regular expression has alternatives with different anchoring. It suppresses any token beginning with `true`. It also accepts tokens containing `false` or ending with `null`. The final two regexes suppress extracted values resembling absolute paths, including values with spaces. See [`config/allowlist.go`, lines 144-204](https://github.com/gitleaks/gitleaks/blob/v8.30.1/config/allowlist.go#L144-L204), [`config/config.go`, lines 318-361](https://github.com/gitleaks/gitleaks/blob/v8.30.1/config/config.go#L318-L361), and [`detect/detect.go`, lines 823-903](https://github.com/gitleaks/gitleaks/blob/v8.30.1/detect/detect.go#L823-L903).

gitleaks 8.30.1 has no option to extend default rules while discarding only the default global allowlist. Its `Extend` struct exposes `path`, `URL`, `useDefault`, and `disabledRules`. Extension always appends global allowlists. An empty local allowlist can't override this behavior. See [`config/config.go`, lines 100-107 and 486-487](https://github.com/gitleaks/gitleaks/blob/v8.30.1/config/config.go#L100-L107).

## Reproductions

Pinned Linux archive checksum: `551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`, matching `pins/extensions.bzl`. Version output is `8.30.1`. These made-up fixtures assemble tokens at runtime:

```bash
printf 'api_key = %s%s # /home/x/.codex/auth.json\n' true Kj82Fd90cYbqJ6uV3nW7sH1p >creds.txt
printf '<add key="Password" value="/home/x/.codex/auth.json %s%s" />\n' Kj82Fd90 cYbqJ6uV3nW7sH1p >nuget.config
```

Run `gitleaks dir --no-banner --redact --verbose --config CONFIG FILE` for each fixture. The outputs are:

| Fixture | `[extend] useDefault = true` | Default rules without global allowlist | Suppressing entry |
| --- | --- | --- | --- |
| `creds.txt` | Exit 0, `no leaks found` | Exit 1, `leaks found: 1`, `RuleID: generic-api-key`, `Line: 1`, `Secret: REDACTED` | Upstream line 52 |
| `nuget.config` | Exit 0, `no leaks found` | Exit 1, `leaks found: 1`, `RuleID: nuget-config-password`, `Line: 1`, `Secret: REDACTED` | Upstream line 64 |

A path beside an independently detected token doesn't by itself suppress that token. Suppression depends on the extracted secret and the matching allowlist entry.

`//lint/tests:defaults_default_allowlist_test` runs both negative controls with the pinned binary. Tree, text, and history scenarios assert that the committed policy detects the first fixture. History scanning removes both fixtures before scanning and requires both rules, proving that it reads past commits. Private scanning adds a credential-path rule and verifies it alongside the default token rule. This exercises the full private → committed → generated config chain. A merge-range scenario requires a full history scan when the generated base changes.

## Regeneration and migration

Run `python3 lint/gitleaks/update.py` after changing the gitleaks pin in `pins/extensions.bzl`. It downloads that exact tag's config and records the source version and checksum. Generation removes only the global allowlist and compares parsed rules before and after. The command writes every generated copy. It fails when platform pins disagree. `python3 lint/gitleaks/update.py --check` performs the offline checks, including checksum verification, byte-for-byte regeneration, and discovery of every tracked or newly added `.gitleaks.toml`. `//lint/tests:gitleaks_configs_test` runs this check in the checkout, including nested modules. A Renovate pin bump fails until regeneration.

Consuming repositories copy `.gitleaks-rules.toml` from the rules release into the scan root and replace `[extend] useDefault = true` with `[extend] path = ".gitleaks-rules.toml"`. Keep local allowlists with their reasons. Include the base in `gitleaks_test` inputs, with `data = [".gitleaks-rules.toml"]`, and update it whenever the release changes its gitleaks pin. The private config still extends `.gitleaks.toml`, within gitleaks' two extension levels. Text and history scanners run in the workspace root and resolve the same base. Run tree, text, and full history scans after migrating and review new findings before adding any exceptions.
