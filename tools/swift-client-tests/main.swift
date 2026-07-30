import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL  \(label)")
    }
}

let green = "; idle\n#30D158 1s cosine\n"

check(
    PollProgramRecovery.resolve(
        statusCode: 200, data: Data(green.utf8),
        cachedProgram: "", needsReplay: false
    ) == .received(green),
    "200 delivers the response body"
)

check(
    PollProgramRecovery.resolve(
        statusCode: 304, data: Data(),
        cachedProgram: green, needsReplay: true
    ) == .replay(green),
    "304 after gray fallback replays the cached LED program"
)

check(
    PollProgramRecovery.resolve(
        statusCode: 304, data: Data(),
        cachedProgram: green, needsReplay: false
    ) == .unchanged,
    "ordinary 304 does not restart a running animation"
)

check(
    PollProgramRecovery.resolve(
        statusCode: 304, data: Data(),
        cachedProgram: "", needsReplay: true
    ) == .forceFullFetch,
    "304 recovery without a cache forces a complete next response"
)

print(failures == 0 ? "PASS  \(checks) checks" : "FAILED  \(failures)/\(checks) checks")
exit(failures == 0 ? 0 : 1)
