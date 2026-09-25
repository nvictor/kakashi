import XCTest
@testable import WorkflowCore

final class CoreTests: XCTestCase {
    func parse(_ extra: String = "", command: String = "echo {{value}}") throws -> Workflow {
        try WorkflowParser.parse("""
        schema_version: 1
        id: example
        title: Example
        shell: posix
        inputs:
          - id: value
            label: Value
            type: string
        steps:
          - id: show
            title: Show value
            command: \(command)
        \(extra)
        """, source: URL(fileURLWithPath: "/example.workflow.yaml"))
    }
    func testStrictYAML() throws {
        XCTAssertEqual(try parse().steps.count, 1)
        for extra in ["oops: true", "title: Duplicate", "---\nid: next", "tags: [123]", "description: true", "description: !custom hello", "description: &anchor text\ntags: [*anchor]"] {
            XCTAssertThrowsError(try parse(extra), extra)
        }
        XCTAssertThrowsError(try parse(command: "echo {{missing}}"))
        let text = "schema_version: 2\nid: x\ntitle: X\nshell: posix\nsteps: []"
        XCTAssertThrowsError(try WorkflowParser.parse(text, source: URL(fileURLWithPath: "/x")))
    }
    func testStrictFieldLocation() {
        XCTAssertThrowsError(try parse("unknown: x")) { error in
            let d = error as! Diagnostic
            XCTAssertEqual(d.field, "$.unknown"); XCTAssertEqual(d.line, 13); XCTAssertEqual(d.column, 1)
        }
    }
    func testContextScanner() throws {
        let known: Set<String> = ["value"]
        for command in ["echo {{value}}", "echo {{value}} | cat", "echo one && printf '%s' {{value}}", "echo {{value}}\nprintf '%s' {{value}}", "echo {{value}} || echo fallback"] {
            XCTAssertEqual(try Template.references(command, known: known), known, command)
        }
        for command in ["echo '{{value}}'", "echo \"{{value}}\"", "echo x{{value}}", "echo {{value}}x", "echo --arg={{value}}", "X={{value}} echo hi", "echo $(echo {{value}})", "echo `echo {{value}}`", "cat <<EOF\n{{value}}\nEOF", "echo hi # {{value}}", "echo {{oops}}", "echo {{value}", "echo value}}", "echo \\{{value}}", "{{value}} arg", "echo {{value}}; cat", "if true; then echo {{value}}; fi", "echo {{value}} > file", "echo {{value}} &&"] {
            XCTAssertThrowsError(try Template.references(command, known: known), command)
        }
    }
    func testSecretInputs() throws {
        let text = """
        schema_version: 1
        id: secret
        title: Secret
        shell: posix
        inputs:
          - id: token
            label: Token
            type: secret
        steps:
          - id: call
            title: Call
            command: curl -H {{token}} https://example.com
          - id: plain
            title: Plain
            command: echo hello
        """
        let workflow = try WorkflowParser.parse(text, source: URL(fileURLWithPath: "/s.workflow.yaml"))
        let values = ["token": "abc'def"]
        XCTAssertEqual(try Template.render(workflow.steps[0], workflow: workflow, values: values), "curl -H 'abc'\"'\"'def' https://example.com")
        XCTAssertEqual(try Template.render(workflow.steps[0], workflow: workflow, values: values, masked: true), "curl -H \(Template.mask) https://example.com")
        XCTAssertTrue(Template.usesSecret(workflow.steps[0], workflow: workflow))
        XCTAssertFalse(Template.usesSecret(workflow.steps[1], workflow: workflow))
        let withDefault = text.replacingOccurrences(of: "type: secret", with: "type: secret\n    default: hunter2")
        XCTAssertThrowsError(try WorkflowParser.parse(withDefault, source: URL(fileURLWithPath: "/s.workflow.yaml")))
    }
    func testRoundTripArguments() throws {
        let workflow = try parse(command: "printf '%s' {{value}}")
        for value in ["space here", "it's fine", "$HOME", "`id`", "; echo unwanted", "{{value}}", "$(touch /tmp/never-kakashi)", "", "日本語 🥷"] {
            var w = workflow; w.inputs[0].required = false
            let rendered = try Template.render(w.steps[0], workflow: w, values: ["value": value])
            // Controlled printf harness, never an authored workflow command.
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "set -- " + Template.quote(value) + "; test \"$#\" -eq 1 || exit 99; printf '%s' \"$1\""]
            let pipe = Pipe(); process.standardOutput = pipe; try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); XCTAssertEqual(String(data: data, encoding: .utf8), value)
            XCTAssertEqual(rendered, "printf '%s' " + Template.quote(value))
        }
    }
    func testRequiredInputsAndMultiline() throws {
        var w = try parse()
        XCTAssertThrowsError(try Template.render(w.steps[0], workflow: w, values: [:]))
        w.steps.append(Step(id: "literal", title: "Literal", description: "", command: "echo first\necho second\n\n"))
        XCTAssertEqual(try Template.render(w.steps[1], workflow: w, values: [:]), "echo first\necho second")
        w.inputs[0].required = false
        XCTAssertEqual(try Template.render(w.steps[0], workflow: w, values: [:]), "echo ''")
        for value in ["a\nb", "a\rb", "\0"] { XCTAssertThrowsError(try Template.render(w.steps[0], workflow: w, values: ["value": value])) }
        w.inputs[0].type = .choice; w.inputs[0].options = ["debug", "release"]; w.inputs[0].defaultValue = "debug"
        XCTAssertEqual(try Template.render(w.steps[0], workflow: w, values: [:]), "echo 'debug'")
        XCTAssertThrowsError(try Template.render(w.steps[0], workflow: w, values: ["value": "other"]))
    }
    func testSessionReconciliation() throws {
        var w = try parse(); var session = Session()
        session.reconcile([w]); session.set("kept", workflow: w.id, input: "value")
        w.title = "Renamed"; session.reconcile([w]); XCTAssertEqual(session.values[w.id]?["value"], "kept")
        w.inputs[0].defaultValue = "new"; session.reconcile([w]); XCTAssertEqual(session.values[w.id]?["value"], "new")
        session.reconcile([]); XCTAssertTrue(session.values.isEmpty)
    }
    func testDirectoryLifecycle() throws {
        let fm = FileManager.default; let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        XCTAssertTrue(CatalogReader.scan(root).valid); XCTAssertEqual(CatalogReader.scan(root).filesChecked, 0)
        let text = "schema_version: 1\nid: example\ntitle: Example\nshell: posix\nsteps: [{id: one, title: One, command: echo hello}]\n"
        let a = root.appendingPathComponent("a.workflow.yaml"); let b = root.appendingPathComponent("b.workflow.yaml")
        try text.write(to: a, atomically: true, encoding: .utf8); XCTAssertEqual(CatalogReader.scan(root).workflows.count, 1)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.workflow.yaml"), withDestinationURL: a)
        XCTAssertEqual(CatalogReader.scan(root).filesChecked, 1)
        let hidden = root.appendingPathComponent(".hidden"); try fm.createDirectory(at: hidden, withIntermediateDirectories: true)
        try text.write(to: hidden.appendingPathComponent("c.workflow.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CatalogReader.scan(root).filesChecked, 1)
        try "invalid".write(to: a, atomically: true, encoding: .utf8); XCTAssertTrue(CatalogReader.scan(root).workflows.isEmpty)
        try text.write(to: a, atomically: true, encoding: .utf8); try fm.moveItem(at: a, to: b)
        XCTAssertEqual(CatalogReader.scan(root).workflows.first?.source.resolvingSymlinksInPath(), b.resolvingSymlinksInPath())
        try text.write(to: a, atomically: true, encoding: .utf8)
        XCTAssertTrue(CatalogReader.scan(root).workflows.isEmpty); XCTAssertEqual(CatalogReader.scan(root).diagnostics.count, 2)
        try fm.removeItem(at: a); try fm.removeItem(at: b); XCTAssertTrue(CatalogReader.scan(root).workflows.isEmpty)
        XCTAssertTrue(CatalogReader.scan(root.appendingPathComponent("missing")).ioFailure)
    }
    func testSearch() throws {
        var w = try parse(); w.title = "Release project"; w.tags = ["swift"]
        w.steps[0].title = "Inspect status"; w.steps[0].command = "git status"
        let index = SearchIndex([w])
        XCTAssertEqual(index.search("").count, 1)
        XCTAssertEqual(index.search("SWIFT status").first?.stepID, "show")
        XCTAssertTrue(index.search("missing status").isEmpty)
        XCTAssertEqual(index.search("release project").first?.stepID, nil)
        var other = w; other.id = "another"
        XCTAssertEqual(SearchIndex([w, other]).search("").first?.workflowID, "another")
    }
    func testWarmSearchBenchmark() throws {
        let base = try parse()
        let workflows = (0..<1000).map { i -> Workflow in
            var w = base; w.id = "workflow-\(i)"; w.title = "Workflow \(i)"
            w.steps = (0..<10).map { Step(id: "step-\($0)", title: "Inspect status \($0)", description: "Review swift project", command: "git status") }; return w
        }
        let index = SearchIndex(workflows); _ = index.search("swift status")
        let start = ContinuousClock.now
        for _ in 0..<10 { XCTAssertEqual(index.search("swift status").count, 10000) }
        print("SEARCH_BENCHMARK mean over 10 searches: \(start.duration(to: .now) / 10)")
    }
}
