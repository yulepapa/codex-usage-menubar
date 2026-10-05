import Foundation

@main enum ResetRPCContractTests {
    static func main() throws {
        guard ProcessInfo.processInfo.environment["CODEX_PATH"]?.hasSuffix("/mock-codex") == true,
              ProcessInfo.processInfo.environment["CODEX_USAGE_EXPECT_CONSUME"] == "1" else {
            fatalError("Synthetic RPC test requires its mock transport")
        }
        let result = try CodexAppServerClient().consume(creditID: "synthetic-credit", key: "synthetic-attempt")
        guard result == "alreadyRedeemed" else { fatalError("Unexpected mock response") }
        print("Synthetic reset RPC contract passed; no real reset was consumed")
    }
}
