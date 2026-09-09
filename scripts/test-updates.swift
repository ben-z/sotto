import AppKit
import SottoCore

actor Requests {
    var count = 0
    func next() -> Int { count += 1; return count }
}

@main struct UpdateTests {
    @MainActor static func main() async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw SottoError(message) }
        }
        func release(_ tag: String) throws -> AppRelease {
            try JSONDecoder().decode(AppRelease.self, from: Data("""
            {"tag_name":"\(tag)","draft":false,"prerelease":false,"assets":[{"name":"Sotto-\(tag.dropFirst())-macOS-universal.zip","state":"uploaded","size":100}]}
            """.utf8))
        }
        func finish(_ checker: UpdateChecker) async throws {
            let deadline = Date().addingTimeInterval(3)
            while checker.isChecking && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try expect(!checker.isChecking, "Update request did not complete")
        }
        let latest = try release("v0.1.2")
        let requests = Requests()
        let checker = UpdateChecker(version: "0.1.1") { _ in
            _ = await requests.next()
            try await Task.sleep(for: .milliseconds(30))
            return latest
        }
        checker.configure(automatic: false)
        try expect(checker.status == "Automatic update checks off", "Disabled startup status")
        try expect(await requests.count == 0, "Disabled checks made a request")
        checker.check(); checker.check()
        try await finish(checker)
        try expect(await requests.count == 1, "Duplicate checks must coalesce")
        try expect(!checker.downloadItem.isHidden, "Manual check while disabled must offer update")
        try expect(checker.downloadItem.title == "Download Sotto v0.1.2…", "Download label")
        let current = UpdateChecker(version: "0.1.2") { _ in latest }
        current.configure(automatic: true)
        try await finish(current)
        try expect(current.downloadItem.isHidden && current.status.contains("up to date"), "Current release state")
        current.configure(automatic: false)
        let failed = UpdateChecker(version: "0.1.1") { _ in throw URLError(.notConnectedToInternet) }
        failed.check(); try await finish(failed)
        try expect(failed.status.contains("Couldn’t check") && failed.detail != nil, "Offline errors must be visible")
        failed.configure(automatic: false)
        try expect(failed.detail == nil, "Disabling must clear stale error details")
        try expect(failed.downloadItem.isHidden, "Failure must not offer an unknown release")
        let attempts = Requests()
        let retry = UpdateChecker(version: "0.1.1") { _ in
            if await attempts.next() == 1 { throw URLError(.timedOut) }
            return latest
        }
        retry.check(); try await finish(retry)
        retry.check(); try await finish(retry)
        try expect(!retry.downloadItem.isHidden && retry.detail == nil, "Retry must recover and clear error details")
        let race = UpdateChecker(version: "0.1.1") { _ in
            // Simulate a transport that completes even after cancellation.
            try? await Task.sleep(for: .milliseconds(30))
            return latest
        }
        race.configure(automatic: true)
        await Task.yield()
        race.configure(automatic: false)
        race.configure(automatic: true)
        try await finish(race)
        try expect(!race.downloadItem.isHidden, "Re-enabling during cancellation lost its request")
        race.configure(automatic: false)
        let pendingRelease = try JSONDecoder().decode(AppRelease.self, from: Data("""
        {"tag_name":"v0.1.3","draft":false,"prerelease":false,"assets":[]}
        """.utf8))
        let pending = UpdateChecker(version: "0.1.1") { _ in pendingRelease }
        var notifications = 0
        pending.onChange = { notifications += 1 }
        pending.check(); try await finish(pending)
        try expect(pending.status.contains("being prepared") && pending.downloadItem.isHidden, "Pending download must have a specific status")
        try expect(notifications >= 2, "Settings must receive progress and completion")
        let missing = UpdateChecker(version: nil) { _ in latest }
        missing.check(); try await finish(missing)
        try expect(missing.status.contains("Couldn’t check"), "Missing version must fail")
        print("Update checks passed: disabled, manual, duplicate, current, available, offline, retry, cancellation, missing version")
    }
}
