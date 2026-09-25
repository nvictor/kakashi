# Author workflows for Kakashi

Put one workflow in each UTF-8 `*.workflow.yaml` or `*.workflow.yml` file. Kakashi discovers files recursively, skipping hidden entries and symbolic links. Keep each file at or below 1 MiB.

## Write and validate a workflow

1. Group commands around one task. A single command is a valid workflow.
2. Describe prerequisites in the workflow description. Each step must make sense when copied on its own.
3. Keep workflow, input, and step IDs stable when editing.
4. Validate the folder:

```sh
swift run --package-path WorkflowCore -c release workflow-validator validate ./examples --format json
```

## Credentials

Never put credentials in workflow files. Use one of these instead:

- A `secret` input. Kakashi hides its value in previews, rejects defaults, marks the copied command as concealed for clipboard managers, and clears it from the clipboard after 60 seconds.
- An existing environment variable in the command text, for example `tool --token "$SERVICE_TOKEN"`. Kakashi does not read or expand it.

Quoting input values does not make an authored command safe.

## Fields

The structural contract is [workflow.schema.json](../schema/workflow.schema.json), using JSON Schema draft 2020-12. The shared semantic validator also checks ID uniqueness, choice defaults, and placeholder syntax/context. Unknown fields are errors.

| Root field | Required | Value |
| --- | --- | --- |
| `schema_version` | Yes | Integer `1` |
| `id` | Yes | `[a-z][a-z0-9-]*`, unique across the directory |
| `title` | Yes | Nonblank string |
| `shell` | Yes | `posix` |
| `description` | No | String, default empty |
| `tags` | No | Array of strings, default empty |
| `inputs` | No | Ordered array of input definitions, default empty |
| `steps` | Yes | Nonempty ordered array of steps |

| Input field | Required | Value |
| --- | --- | --- |
| `id` | Yes | ID unique among this workflow's inputs |
| `label` | Yes | Nonblank string |
| `type` | Yes | `string`, `path`, `choice`, or `secret` |
| `description` | No | Helper text, default empty |
| `required` | No | Boolean `true` or `false`, default `true` |
| `default` | No | String; choice defaults must appear in `options`; forbidden for secrets |
| `options` | For choices | Nonempty array of unique nonempty strings; forbidden for other types |

| Step field | Required | Value |
| --- | --- | --- |
| `id` | Yes | ID unique among this workflow's steps |
| `title` | Yes | Nonblank string |
| `command` | Yes | Nonblank string, including YAML multiline blocks |
| `description` | No | String, default empty |

Quote numeric, boolean, or date-looking strings, such as `default: '8080'`. YAML anchors, aliases, custom tags, duplicate keys, and multiple documents are unsupported.

Input values and defaults cannot contain NUL, carriage returns, or newlines. Path values are literal strings: use absolute paths, because `~`, environment variables, and glob patterns are not expanded. Paths need not exist.

An empty required input blocks only steps referencing it. An optional unset input renders as the empty argument `''`.

## Placeholder subset

Use `{{input-id}}` as one complete unquoted argument after the command name:

```yaml
command: git -C {{project-dir}} status --short --branch
```

For `project-dir` equal to `/tmp/it's a project`, the preview is:

```sh
git -C '/tmp/it'"'"'s a project' status --short --branch
```

Kakashi quotes each value once. Dollar signs, backticks, semicolons, and template delimiters in the value remain literal characters.

Templated commands may use newlines, pipes, `&&`, and `||`:

```yaml
command: |
  git -C {{project-dir}} status --short
  git -C {{project-dir}} diff --stat
```

Unsupported placeholder forms include:

```text
echo "{{value}}"
echo prefix{{value}}
echo --option={{value}}
NAME={{value}} command
echo $(command {{value}})
command # {{value}}
```

For commands containing placeholders, v1 also rejects redirections, heredocs, semicolons, background `&`, shell control words, assignments, substitutions, and brace syntax. Substitution-looking text is conservatively rejected even in quoted literals. Avoid a trailing connector. Commands without template delimiters remain opaque literal shell text.

There are no filters, expressions, raw values, includes, or literal template delimiter escapes. If an option requires concatenation, make the complete option the input value, as the listening-port example does.

## Examples

These are complete, validated source files:

- [Inspect a Swift project](../examples/inspect-project.workflow.yaml): one path and one build choice shared by status and test steps.
- [Inspect a listening port](../examples/listening-port.workflow.yaml): a single step using a complete `-iTCP:8080` argument.
- [Inspect a Git release tag](../examples/inspect-release.workflow.yaml): two local read-only inspection steps sharing a repository and tag.

## Fix validation failures

- **Unknown input:** declare the referenced ID or fix the placeholder spelling.
- **Expected a string:** quote values such as numbers or booleans.
- **Duplicate ID:** assign distinct IDs to every conflicting workflow. All conflicting files are excluded.
- **Unsupported template context:** separate the input into its own unquoted argument.
- **Cannot read folder:** reconnect the drive or choose the folder again.

Diagnostics identify the file and field, with one-based line and column when the parser provides them.
