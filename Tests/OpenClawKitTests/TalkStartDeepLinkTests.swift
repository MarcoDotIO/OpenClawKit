import Foundation
import Testing
@testable import OpenClawKit

@Suite("Talk start deep link")
struct TalkStartDeepLinkTests {
    @Test
    func talkStartParsesWithAndWithoutASession() throws {
        #expect(DeepLinkParser.parse(try #require(URL(string: "openclaw://talk/start")))
            == .talkStart(TalkStartDeepLink()))
        #expect(DeepLinkParser.parse(try #require(URL(string: "openclaw://talk/start/")))
            == .talkStart(TalkStartDeepLink()))
        #expect(DeepLinkParser.parse(try #require(URL(string: "OPENCLAW://Talk/Start?sessionKey=%20agent:main:main%20")))
            == .talkStart(TalkStartDeepLink(sessionKey: "agent:main:main")))
        #expect(DeepLinkParser.parse(try #require(URL(string: "openclaw://talk/start?sessionKey=")))
            == .talkStart(TalkStartDeepLink(sessionKey: nil)))
    }

    @Test
    func otherTalkPathsAndAuthoritiesAreRejected() throws {
        for raw in ["openclaw://talk", "openclaw://talk/stop", "openclaw://user:pw@talk/start", "openclaw://talk:9/start"] {
            #expect(DeepLinkParser.parse(try #require(URL(string: raw))) == nil, "\(raw)")
        }
    }

    @Test
    func canonicalURLRoundTrips() throws {
        let link = TalkStartDeepLink(sessionKey: "agent:main:main")
        let url = try #require(link.url)
        #expect(url.absoluteString == "openclaw://talk/start?sessionKey=agent:main:main")
        #expect(DeepLinkParser.parse(url) == .talkStart(link))
        #expect(TalkStartDeepLink().url?.absoluteString == "openclaw://talk/start")
    }
}
